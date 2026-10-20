#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>
#import <signal.h>
#import "QBFilter.h"
#import "QBJumpBackend.h"
#import "QBJumpController.h"
#import "QBApplicationBackend.h"
#import "QBApplicationController.h"

static NSString *const QBEnabledKey = @"HideSystemItems";
static NSString *const QBJumpEnabledKey = @"HideViaJumpLauncher";

static NSString *LoginStatusName(SMAppServiceStatus status) {
    switch (status) {
        case SMAppServiceStatusEnabled: return @"enabled";
        case SMAppServiceStatusRequiresApproval: return @"requiresApproval";
        case SMAppServiceStatusNotRegistered: return @"notRegistered";
        case SMAppServiceStatusNotFound: return @"notFound";
    }
    return @"unknown";
}
static void PrintJSON(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil];
    puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}
@interface QBFlippedView : NSView
@end
@implementation QBFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface QBFilter (VerificationAccess)
- (BOOL)loadBackend;
- (NSArray<NSString *> *)runningIDs;
- (void)refresh;
@end
@interface QBVerificationFilter : QBFilter
@property(nonatomic, copy) NSArray<NSString *> *testIDs;
@end
@implementation QBVerificationFilter
- (NSArray<NSString *> *)runningIDs { return self.testIDs ?: [super runningIDs]; }
@end
@interface QBUnavailableVerificationFilter : QBFilter
@end
@implementation QBUnavailableVerificationFilter
- (BOOL)loadBackend { return NO; }
@end

@interface QBApp : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property id<QBHidingBackend> filter;
@property BOOL usesJumpBackend;
@property BOOL usesApplicationBackend;
@property id<QBHidingBackend> deferredBackend;
@property BOOL deferredUsesJump;
@property BOOL deferredEnabled;
@property BOOL preview;
@property BOOL restoringDefaults;
@property BOOL terminationPending;
@property NSWindow *window;
@property NSStatusItem *statusItem;
@property NSTextField *statusTitle;
@property NSTextField *statusDescription;
@property NSTextField *loginDescription;
@property NSButton *toggleButton;
@property NSButton *loginButton;
@property NSButton *loginSettingsButton;
@property NSButton *setupButton;
@property NSButton *jumpButton;
@property NSTextField *modeDescription;
@property NSMenuItem *toggleMenuItem;
@property NSStackView *legacyRow;
@property NSMutableArray *signalSources;
@end

static NSTextField *Label(NSString *text, CGFloat size, NSColor *color) {
    NSTextField *field = [NSTextField wrappingLabelWithString:text];
    field.font = [NSFont systemFontOfSize:size];
    field.textColor = color;
    field.maximumNumberOfLines = 0;
    return field;
}
static NSStackView *VStack(NSArray<NSView *> *views, CGFloat spacing) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = spacing;
    stack.detachesHiddenViews = YES;
    return stack;
}

@implementation QBApp
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSArray *arguments = NSProcessInfo.processInfo.arguments;
    self.preview = [arguments containsObject:@"--preview"];
    QBFilter *nativeFilter = [[QBFilter alloc] initWithClockTracking:YES];
    self.usesJumpBackend = [arguments containsObject:@"--legacy-jump"];
    self.usesApplicationBackend = !self.usesJumpBackend && (!nativeFilter.available || [arguments containsObject:@"--legacy-apps"]);
    self.restoringDefaults = YES;
    NSString *enabledKey = self.usesJumpBackend ? QBJumpEnabledKey : QBEnabledKey;
    BOOL enabled = !self.preview && !self.usesApplicationBackend && [NSUserDefaults.standardUserDefaults boolForKey:enabledKey];
    self.filter = self.usesJumpBackend ? (id<QBHidingBackend>)[[QBJumpBackend alloc] initWithRecovery:!self.preview]
        : self.usesApplicationBackend ? (id<QBHidingBackend>)[[QBApplicationBackend alloc] initWithRecovery:!self.preview] : nativeFilter;
    if (!self.preview && !self.usesApplicationBackend) {
        NSString *base=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/QuietBar/Applications"];
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:base error:nil]) {
            if (![[NSUUID alloc] initWithUUIDString:name]) continue;
            // An OS update can make the native API available after a launcher
            // session. Resolve that session before switching visibility backends.
            self.deferredBackend=self.filter; self.deferredUsesJump=self.usesJumpBackend;
            self.deferredEnabled=enabled;
            self.usesApplicationBackend=YES; self.usesJumpBackend=NO; enabled=NO;
            self.filter=[[QBApplicationBackend alloc] initWithRecovery:YES];
            break;
        }
    }
    __weak QBApp *weakSelf = self;
    self.filter.onChange = ^{ [weakSelf backendDidChange]; };
    [self buildMenu];
    [self buildWindow];
    [self installSignalHandlers];
    [self.filter setEnabled:enabled];
    self.restoringDefaults = NO;
    [self updateUI];
    [self updateLoginUI];
    BOOL background = [NSProcessInfo.processInfo.arguments containsObject:@"--background"];
    if ((!self.filter.enabled || self.preview) && !background) [self showSettings:nil];
}
- (void)backendDidChange {
    NSDictionary *diagnostics=[self launcherDiagnostics];
    if (self.deferredBackend && ![diagnostics[@"cleanupPending"] boolValue]
        && ![diagnostics[@"recovering"] boolValue]) {
        BOOL visible=self.window.visible;
        self.filter.onChange=nil; self.filter=self.deferredBackend; self.deferredBackend=nil;
        self.usesApplicationBackend=NO; self.usesJumpBackend=self.deferredUsesJump;
        __weak QBApp *weakSelf=self;
        self.filter.onChange=^{ [weakSelf updateUI]; };
        [self.window close]; [self buildWindow];
        [self.filter setEnabled:self.deferredEnabled];
        [self updateLoginUI];
        if (visible) [self showSettings:nil];
    }
    [self updateUI];
}
- (void)buildMenu {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    NSImage *image = [NSImage imageWithSystemSymbolName:@"menubar.rectangle" accessibilityDescription:@"QuietBar"];
    if (image) { image.template = YES; self.statusItem.button.image = image; }
    else self.statusItem.button.title = @"Q";
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"QuietBar"];
    self.toggleMenuItem = [[NSMenuItem alloc] initWithTitle:@"Скрыть значки" action:@selector(toggle:) keyEquivalent:@""];
    self.toggleMenuItem.target = self;
    [menu addItem:self.toggleMenuItem];
    NSMenuItem *settings = [[NSMenuItem alloc] initWithTitle:@"Настройки QuietBar…" action:@selector(showSettings:) keyEquivalent:@","];
    settings.target = self; [menu addItem:settings];
    NSMenuItem *diagnostics = [[NSMenuItem alloc] initWithTitle:@"Скопировать диагностику" action:@selector(copyDiagnostics:) keyEquivalent:@""];
    diagnostics.target = self; [menu addItem:diagnostics];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Завершить и вернуть значки" action:@selector(quit:) keyEquivalent:@"q"];
    quit.target = self; [menu addItem:quit];
    self.statusItem.menu = menu;
}
- (void)buildWindow {
    BOOL hasLegacy = [NSFileManager.defaultManager fileExistsAtPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/local.hide-screen-sharing-indicator.plist"]];
    CGFloat maxHeight = NSScreen.mainScreen.visibleFrame.size.height - 80;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,600,MIN(hasLegacy ? 830 : 760,maxHeight))
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = self.preview ? @"QuietBar 1.3 — предпросмотр" : @"QuietBar";
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    [self.window center];
    [self.window setFrameAutosaveName:@"QuietBarSettings"];
    NSTextField *heading = Label(@"Уберите фиолетовый значок",24,NSColor.labelColor);
    heading.font = [NSFont systemFontOfSize:24 weight:NSFontWeightSemibold];
    NSTextField *intro = Label(self.usesApplicationBackend
        ? @"Выберите приложение и запустите его через QuietBar. Экспериментальный способ для macOS 14 и новее; скрытие нужно проверить на вашем Mac."
        : self.usesJumpBackend
        ? @"Экспериментальный способ для Jump Desktop на macOS 14 и новее. Подготовьте запуск, затем подключитесь заново и проверьте экран и управление."
        : @"Системный фильтр скрывает фиолетовый значок и часть значков macOS при работающем захвате экрана.",13,NSColor.secondaryLabelColor);
    self.statusTitle = Label(@"Значки видимы",20,NSColor.labelColor);
    self.statusTitle.font = [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
    self.statusDescription = Label(@"Нажмите «Скрыть значки», чтобы включить скрытие.",13,NSColor.secondaryLabelColor);
    [self.statusDescription.heightAnchor constraintGreaterThanOrEqualToConstant:34].active = YES;
    self.toggleButton = [NSButton buttonWithTitle:@"Скрыть значки" target:self action:@selector(toggle:)];
    self.toggleButton.bezelStyle = NSBezelStyleRounded;
    self.toggleButton.controlSize = NSControlSizeLarge;
    self.setupButton = [NSButton buttonWithTitle:@"Настроить разрешения…" target:self action:@selector(openSetup:)];
    self.setupButton.bezelStyle = NSBezelStyleRounded;
    self.setupButton.hidden = YES;
    self.jumpButton = [NSButton buttonWithTitle:@"Открыть Jump Desktop Connect…" target:self action:@selector(openJump:)];
    self.jumpButton.bezelStyle = NSBezelStyleInline;
    self.jumpButton.hidden = !self.usesJumpBackend && !self.usesApplicationBackend;
    if (self.usesApplicationBackend) self.jumpButton.title = @"Выбрать приложение…";
    self.jumpButton.enabled = !self.preview;
    NSStackView *cardStack = VStack(@[self.statusTitle,self.statusDescription,self.toggleButton,self.setupButton,self.jumpButton],10);
    NSBox *card = [[NSBox alloc] init];
    card.boxType = NSBoxCustom; card.titlePosition = NSNoTitle;
    card.borderWidth = 0; card.cornerRadius = 14;
    card.fillColor = NSColor.controlBackgroundColor;
    card.contentViewMargins = NSZeroSize;
    cardStack.translatesAutoresizingMaskIntoConstraints = NO;
    [card.contentView addSubview:cardStack];
    [NSLayoutConstraint activateConstraints:@[
        [cardStack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:18],
        [cardStack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-18],
        [cardStack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:18],
        [cardStack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-18]
    ]];
    self.loginButton = [NSButton checkboxWithTitle:@"Запускать QuietBar при входе в систему" target:self action:@selector(toggleLogin:)];
    self.loginDescription = Label(@"",12,NSColor.secondaryLabelColor);
    self.loginSettingsButton = [NSButton buttonWithTitle:@"Открыть настройки входа…" target:self action:@selector(openLoginSettings:)];
    self.loginSettingsButton.bezelStyle = NSBezelStyleInline;
    self.loginSettingsButton.hidden = YES;
    NSStackView *login = VStack(@[self.loginButton,self.loginDescription,self.loginSettingsButton],6);
    NSTextField *details = Label(self.usesApplicationBackend
        ? @"Закройте выбранное приложение перед запуском. При первом запуске разрешите Terminal запись экрана в настройках macOS. Разрешения самого приложения также должны быть настроены.\n\nОтдельные фоновые службы и уже работающие экземпляры могут использовать обычный путь захвата. Выключение QuietBar просит выбранное приложение завершиться; сохраните открытые документы."
        : self.usesJumpBackend
        ? @"Первый запуск: разрешите Terminal запись экрана и универсальный доступ в настройках macOS. В Jump Desktop Connect включите General → Start Jump Desktop when my computer starts.\n\nКнопка «Подготовить Jump» перезапускает его пользовательский агент. Текущее соединение может прерваться. Выключение QuietBar возвращает обычный запуск."
        : @"Останутся часы, Wi-Fi, звук, Bluetooth, батарея и Пункт управления. У часов значки временно возвращаются, чтобы открывался Центр уведомлений. Выход из QuietBar возвращает значки.",12,NSColor.secondaryLabelColor);
    self.modeDescription = Label(self.usesApplicationBackend
        ? @"macOS 14+ · Intel и Apple Silicon. Запуск через QuietBar не гарантирует скрытие для каждого приложения. SIP не изменяется."
        : self.usesJumpBackend
        ? @"macOS 14 и новее · Intel и Apple Silicon. Экспериментальный режим: проверьте подключение и скрытие значка на этом Mac."
        : @"Системный способ проверен на macOS 27.0.1 · Apple Silicon. Доступность API определяется при запуске.",11,NSColor.tertiaryLabelColor);
    NSView *divider = [[NSBox alloc] init]; [(NSBox *)divider setBoxType:NSBoxSeparator];
    NSButton *quit = [NSButton buttonWithTitle:@"Завершить и вернуть значки" target:self action:@selector(quit:)];
    quit.bezelStyle = NSBezelStyleRounded;
    NSButton *diagnostics = [NSButton buttonWithTitle:@"Скопировать диагностику" target:self action:@selector(copyDiagnostics:)];
    diagnostics.bezelStyle = NSBezelStyleInline;
    NSTextField *legacyText = Label(@"Здесь установлена предыдущая фоновая версия. Отключите её, чтобы QuietBar мог возвращать значки.",12,NSColor.secondaryLabelColor);
    NSButton *legacyButton = [NSButton buttonWithTitle:@"Отключить предыдущую версию" target:self action:@selector(stopLegacy:)];
    legacyButton.bezelStyle = NSBezelStyleRounded;
    legacyButton.enabled = !self.preview;
    self.legacyRow = VStack(@[legacyText,legacyButton],6);
    self.legacyRow.hidden = !hasLegacy;
    NSStackView *root = VStack(@[heading,intro,card,login,details,self.legacyRow,divider,self.modeDescription,diagnostics,quit],16);
    root.translatesAutoresizingMaskIntoConstraints = NO;
    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;
    NSView *document = [[QBFlippedView alloc] init];
    document.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = document;
    [document addSubview:root];
    [self.window.contentView addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.window.contentView.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.window.contentView.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.window.contentView.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.window.contentView.bottomAnchor],
        [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        [root.leadingAnchor constraintEqualToAnchor:document.leadingAnchor constant:24],
        [root.trailingAnchor constraintEqualToAnchor:document.trailingAnchor constant:-24],
        [root.topAnchor constraintEqualToAnchor:document.topAnchor constant:24],
        [root.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-24],
        [card.widthAnchor constraintEqualToAnchor:root.widthAnchor],
        [card.heightAnchor constraintEqualToAnchor:cardStack.heightAnchor constant:36],
        [intro.widthAnchor constraintEqualToAnchor:root.widthAnchor],
        [details.widthAnchor constraintEqualToAnchor:root.widthAnchor],
        [self.modeDescription.widthAnchor constraintEqualToAnchor:root.widthAnchor],
        [legacyText.widthAnchor constraintEqualToAnchor:root.widthAnchor],
        [self.statusDescription.widthAnchor constraintEqualToAnchor:cardStack.widthAnchor],
        [divider.widthAnchor constraintEqualToAnchor:root.widthAnchor],
        [self.loginDescription.widthAnchor constraintEqualToAnchor:root.widthAnchor]
    ]];
}
- (void)updateUI {
    if (!self.statusTitle) return;
    NSString *title, *body;
    switch (self.filter.state) {
        case QBFilterStateOff:
            title=self.usesJumpBackend ? @"Обычный запуск Jump" : @"Значки видимы";
            body=self.usesJumpBackend ? @"Нажмите «Подготовить Jump». Приложение проверит разрешения и перезапустит пользовательский агент Jump." : @"Нажмите «Скрыть значки», чтобы включить скрытие."; break;
        case QBFilterStateStarting:
            title=self.usesJumpBackend ? @"Готовим запуск Jump…" : @"Включаем скрытие…";
            body=self.usesJumpBackend ? (self.filter.errorMessage.length ? self.filter.errorMessage : @"Проверяем разрешения и ждём готовности агента.") : @"Ждём ответ macOS."; break;
        case QBFilterStateActive:
            title=@"Скрытие включено"; body=@"macOS приняла настройку. Проверьте, исчезли ли нужные значки."; break;
        case QBFilterStateAtClock:
            title=@"Значки временно видимы"; body=@"Курсор у часов. Уведите его, и QuietBar снова скроет значки."; break;
        case QBFilterStateUnsupported:
            title=self.usesJumpBackend ? @"Нужен Jump Desktop Connect" : @"Скрытие недоступно";
            body=self.filter.errorMessage.length ? self.filter.errorMessage : @"В этой macOS недоступен нужный системный API."; break;
        case QBFilterStateError:
            title=self.usesJumpBackend ? @"Запуск Jump не подготовлен" : @"Не удалось скрыть значки"; body=self.filter.errorMessage; break;
        case QBFilterStateNeedsSetup:
            title=@"Нужна настройка"; body=self.filter.errorMessage; break;
        case QBFilterStatePrepared:
            title=@"Запуск Jump подготовлен";
            body=@"Подключитесь к этому Mac через Jump заново. Проверьте передачу экрана, мышь и клавиатуру, а затем — отсутствие фиолетового значка. Готовность агента сама по себе не подтверждает скрытие."; break;
        case QBFilterStateStopping:
            title=@"Возвращаем обычный запуск…";
            body=self.filter.errorMessage.length ? self.filter.errorMessage : @"Ждём завершения обёртки и восстановления агента Jump."; break;
    }
    if (self.usesApplicationBackend) {
        QBApplicationBackend *backend=(QBApplicationBackend *)self.filter;
        switch (self.filter.state) {
            case QBFilterStateOff:
                title=@"Готово к запуску";
                body=backend.selectedApplicationURL ? [NSString stringWithFormat:@"Выбрано: %@. Закройте приложение и нажмите «Запустить через QuietBar».",backend.selectedApplicationName] : @"Выберите приложение, которое захватывает или передаёт экран."; break;
            case QBFilterStateStarting: title=@"Запускаем приложение…"; body=self.filter.errorMessage.length ? self.filter.errorMessage : @"Проверяем приложение и разрешения macOS."; break;
            case QBFilterStatePrepared: title=@"Приложение запущено"; body=@"Включите захват или подключитесь к этому Mac. Проверьте передачу экрана, управление и отсутствие фиолетового индикатора. Сам запуск этого не подтверждает."; break;
            case QBFilterStateStopping: title=@"Завершаем запуск…"; body=self.filter.errorMessage.length ? self.filter.errorMessage : @"Ждём обычного завершения приложения. Сохраните открытые документы."; break;
            case QBFilterStateNeedsSetup: title=@"Нужно ваше действие"; body=self.filter.errorMessage; break;
            case QBFilterStateUnsupported: title=@"Запуск недоступен"; body=self.filter.errorMessage; break;
            case QBFilterStateError: title=@"Не удалось запустить приложение"; body=self.filter.errorMessage; break;
            default: break;
        }
    }
    if (self.preview) body = [@"Предпросмотр интерфейса.\n\n" stringByAppendingString:body ?: @""];
    self.statusTitle.stringValue = title;
    self.statusDescription.stringValue = body;
    NSString *button = self.usesJumpBackend ? (self.filter.enabled ? @"Вернуть обычный запуск" : @"Подготовить Jump")
                                         : (self.filter.enabled ? @"Показать значки" : @"Скрыть значки");
    if (self.usesApplicationBackend) button=self.filter.enabled ? @"Завершить запуск"
        : [(QBApplicationBackend *)self.filter selectedApplicationURL] ? @"Запустить через QuietBar" : @"Выбрать приложение…";
    if (!self.filter.enabled && [[self launcherDiagnostics][@"cleanupPending"] boolValue])
        button=self.usesApplicationBackend ? @"Проверить завершение" : @"Восстановить запуск Jump";
    self.toggleButton.title = button; self.toggleMenuItem.title = button;
    BOOL busy = self.filter.state==QBFilterStateStopping;
    self.toggleButton.enabled = self.filter.available && !self.preview && !busy;
    self.toggleMenuItem.enabled = self.toggleButton.enabled;
    self.setupButton.hidden = (!self.usesJumpBackend && !self.usesApplicationBackend) || self.filter.state!=QBFilterStateNeedsSetup;
    self.setupButton.enabled = !self.preview;
    self.setupButton.title = self.usesApplicationBackend ? @"Продолжить настройку…" : @"Настроить разрешения…";
    self.jumpButton.enabled = !self.preview && !self.filter.enabled && ![[self launcherDiagnostics][@"cleanupPending"] boolValue];
    if (self.usesApplicationBackend) {
        self.jumpButton.hidden=![(QBApplicationBackend *)self.filter selectedApplicationURL];
        self.jumpButton.title=@"Выбрать другое приложение…";
    }
    self.loginButton.enabled = !self.preview;
    if (!self.preview && !self.restoringDefaults && self.usesJumpBackend) {
        if (self.filter.state==QBFilterStatePrepared) [NSUserDefaults.standardUserDefaults setBool:YES forKey:QBJumpEnabledKey];
        else if (self.filter.state==QBFilterStateOff || self.filter.state==QBFilterStateNeedsSetup || self.filter.state==QBFilterStateError)
            [NSUserDefaults.standardUserDefaults setBool:NO forKey:QBJumpEnabledKey];
    }
    self.statusItem.button.toolTip = [@"QuietBar — " stringByAppendingString:title.lowercaseString];
}
- (NSDictionary *)launcherDiagnostics {
    if (self.usesJumpBackend) return [(QBJumpBackend *)self.filter diagnostics];
    if (self.usesApplicationBackend) return [(QBApplicationBackend *)self.filter diagnostics];
    return @{};
}
- (void)toggle:(id)sender {
    if (self.preview) return;
    if (!self.filter.enabled && [[self launcherDiagnostics][@"cleanupPending"] boolValue]) {
        [self.filter stop]; return;
    }
    if (self.usesApplicationBackend && ![(QBApplicationBackend *)self.filter selectedApplicationURL]) {
        [(QBApplicationBackend *)self.filter chooseApplicationForWindow:self.window]; return;
    }
    [self.filter setEnabled:!self.filter.enabled];
    if (!self.usesJumpBackend && !self.usesApplicationBackend) [NSUserDefaults.standardUserDefaults setBool:self.filter.enabled forKey:QBEnabledKey];
}
- (void)openSetup:(id)sender {
    if (self.preview) return;
    if (self.usesJumpBackend) [(QBJumpBackend *)self.filter openSetup];
    else if (self.usesApplicationBackend) {
        if (![(QBApplicationBackend *)self.filter selectedApplicationURL])
            [(QBApplicationBackend *)self.filter chooseApplicationForWindow:self.window];
        else [(QBApplicationBackend *)self.filter openSetup];
    }
}
- (void)openJump:(id)sender {
    if (self.preview) return;
    if (self.usesApplicationBackend) { [(QBApplicationBackend *)self.filter chooseApplicationForWindow:self.window]; return; }
    NSURL *url = [NSURL fileURLWithPath:@"/Applications/Jump Desktop Connect.app"];
    if ([NSFileManager.defaultManager fileExistsAtPath:url.path])
        [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:NSWorkspaceOpenConfiguration.configuration completionHandler:nil];
    else [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://jumpdesktop.com/downloads/"]];
}
- (void)copyDiagnostics:(id)sender {
#if defined(__arm64__)
    NSString *architecture=@"arm64";
#else
    NSString *architecture=@"x86_64";
#endif
    NSMutableDictionary *value=[@{@"version":NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"",
        @"macOS":NSProcessInfo.processInfo.operatingSystemVersionString,@"processArchitecture":architecture,
        @"backend":self.usesJumpBackend ? @"experimentalJumpLauncher" : self.usesApplicationBackend ? @"experimentalApplicationLauncher" : @"nativeAssessment",
        @"state":@(self.filter.state),@"enabled":@(self.filter.enabled),@"message":self.filter.errorMessage ?: @""} mutableCopy];
    if (self.usesJumpBackend || self.usesApplicationBackend) value[@"launcher"]=[self launcherDiagnostics];
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil];
    if (data) {
        NSPasteboard *pasteboard=NSPasteboard.generalPasteboard;
        [pasteboard clearContents];
        [pasteboard setString:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] forType:NSPasteboardTypeString];
    }
}
- (void)showSettings:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
    [self updateLoginUI];
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag { [self showSettings:nil]; return YES; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return NO; }
- (void)applicationDidBecomeActive:(NSNotification *)notification { [self updateLoginUI]; }
- (void)updateLoginUI {
    if (!self.loginButton) return;
    SMAppServiceStatus status = SMAppService.mainAppService.status;
    self.loginButton.state = (status==SMAppServiceStatusEnabled || status==SMAppServiceStatusRequiresApproval) ? NSControlStateValueOn : NSControlStateValueOff;
    self.loginSettingsButton.hidden = status!=SMAppServiceStatusRequiresApproval;
    switch (status) {
        case SMAppServiceStatusEnabled: self.loginDescription.stringValue=@"Автозапуск разрешён в настройках macOS."; break;
        case SMAppServiceStatusRequiresApproval: self.loginDescription.stringValue=@"Разрешите QuietBar в настройках входа macOS."; break;
        case SMAppServiceStatusNotRegistered: self.loginDescription.stringValue=@"Автозапуск выключен."; break;
        case SMAppServiceStatusNotFound: self.loginDescription.stringValue=@"Автозапуск ещё не настроен."; break;
    }
}
- (void)toggleLogin:(id)sender {
    NSError *error = nil;
    BOOL wantsEnabled = self.loginButton.state==NSControlStateValueOn;
    BOOL ok = wantsEnabled ? [SMAppService.mainAppService registerAndReturnError:&error]
                           : [SMAppService.mainAppService unregisterAndReturnError:&error];
    [self updateLoginUI];
    if (!ok) self.loginDescription.stringValue = wantsEnabled
        ? @"macOS не включила автозапуск. Перенесите приложение в «Программы» и попробуйте снова."
        : @"macOS не отключила автозапуск. Откройте настройки входа и отключите QuietBar.";
    if (!ok) self.loginSettingsButton.hidden = NO;
}
- (void)openLoginSettings:(id)sender { [SMAppService openSystemSettingsLoginItems]; }
- (BOOL)runLaunchctl:(NSArray<NSString *> *)arguments {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
    task.arguments = arguments;
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:nil]) return NO;
    [task waitUntilExit];
    return task.terminationStatus==0;
}
- (BOOL)legacyServiceConfirmedMissing:(NSString *)target {
    NSTask *task=[[NSTask alloc] init];
    task.executableURL=[NSURL fileURLWithPath:@"/bin/launchctl"];
    task.arguments=@[@"print",target];
    NSPipe *errorPipe=[NSPipe pipe];
    task.standardOutput=NSFileHandle.fileHandleWithNullDevice;
    task.standardError=errorPipe;
    if (![task launchAndReturnError:nil]) return NO;
    [task waitUntilExit];
    NSString *error=[[NSString alloc] initWithData:[errorPipe.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding];
    return task.terminationStatus==113 && [error containsString:@"Could not find service"]
        && [error containsString:@"local.hide-screen-sharing-indicator"];
}
- (void)stopLegacy:(id)sender {
    NSString *domain = [NSString stringWithFormat:@"gui/%u",getuid()];
    NSString *target = [domain stringByAppendingString:@"/local.hide-screen-sharing-indicator"];
    if (![self runLaunchctl:@[@"disable",target]]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText=@"Не удалось отключить предыдущую версию";
        alert.informativeText=@"Запустите сохранённую команду «Вернуть системные значки» и попробуйте снова.";
        [alert addButtonWithTitle:@"Закрыть"]; [alert beginSheetModalForWindow:self.window completionHandler:nil]; return;
    }
    BOOL stopped=[self runLaunchctl:@[@"bootout",target]];
    if (!stopped && ![self legacyServiceConfirmedMissing:target]) {
        NSAlert *alert=[[NSAlert alloc] init];
        alert.messageText=@"Остановка предыдущей версии не подтверждена";
        alert.informativeText=@"Строка управления сохранена. Попробуйте снова или запустите команду «Вернуть системные значки».";
        [alert addButtonWithTitle:@"Закрыть"];
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    self.legacyRow.hidden = YES;
}
- (void)installSignalHandlers {
    self.signalSources = [NSMutableArray array];
    __weak QBApp *weakSelf = self;
    for (NSNumber *number in @[@(SIGTERM),@(SIGINT)]) {
        int sig=number.intValue; signal(sig,SIG_IGN);
        dispatch_source_t source=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,sig,0,dispatch_get_main_queue());
        dispatch_source_set_event_handler(source, ^{ [weakSelf.filter stop]; [NSApp terminate:nil]; });
        dispatch_resume(source); [self.signalSources addObject:source];
    }
}
- (void)quit:(id)sender { [NSApp terminate:nil]; }
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if ((!self.usesJumpBackend && !self.usesApplicationBackend) || self.preview) return NSTerminateNow;
    NSDictionary *diagnostics = [self launcherDiagnostics];
    if (!self.filter.enabled && ![diagnostics[@"cleanupPending"] boolValue]) return NSTerminateNow;
    if (self.terminationPending) return NSTerminateLater;
    self.terminationPending = YES;
    [self.filter stop];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:35];
    __weak QBApp *weakSelf = self;
    [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        QBApp *app = weakSelf;
        if (!app) { [timer invalidate]; return; }
        NSDictionary *info = [app launcherDiagnostics];
        if (![info[@"cleanupPending"] boolValue] && !app.filter.enabled) {
            [timer invalidate]; app.terminationPending = NO; [NSApp replyToApplicationShouldTerminate:YES];
        } else if (deadline.timeIntervalSinceNow<=0) {
            [timer invalidate]; app.terminationPending = NO; [NSApp replyToApplicationShouldTerminate:NO];
            [app showSettings:nil];
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText=app.usesApplicationBackend ? @"Завершение приложения ещё не подтверждено" : @"Восстановление Jump ещё не подтверждено";
            alert.informativeText=@"QuietBar остаётся открытым. Проверьте состояние в окне приложения и повторите выключение.";
            [alert addButtonWithTitle:@"Понятно"]; [alert beginSheetModalForWindow:app.window completionHandler:nil];
        }
    }];
    return NSTerminateLater;
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.filter stop];
    if (self.statusItem) [NSStatusBar.systemStatusBar removeStatusItem:self.statusItem];
}
@end

// Exercises the production launcher only on explicitly provisioned hosted CI.
// Capture permissions and visual assertions belong to the external fixture harness.
static BOOL WriteApplicationTestJSON(NSDictionary *value, NSString *directory, NSString *name) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil];
    return data && [data writeToFile:[directory stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:nil];
}
static void RunApplicationTestSlice(void) {
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
}
static int RunApplicationIntegrationTest(NSArray<NSString *> *arguments) {
    NSDictionary *environment=NSProcessInfo.processInfo.environment;
    if (arguments.count!=4 || ![environment[@"GITHUB_ACTIONS"] isEqualToString:@"true"]
        || ![environment[@"RUNNER_OS"] isEqualToString:@"macOS"]
        || ![environment[@"RUNNER_ENVIRONMENT"] isEqualToString:@"github-hosted"]
        || ![environment[@"QB_APPLICATION_INTEGRATION"] isEqualToString:@"1"] || getuid()==0) return 77;
    NSString *temporary=[environment[@"RUNNER_TEMP"] stringByResolvingSymlinksInPath];
    NSString *output=[arguments[3] stringByResolvingSymlinksInPath];
    if (![temporary isAbsolutePath] || ![output hasPrefix:[temporary stringByAppendingString:@"/"]]
        || ![NSFileManager.defaultManager fileExistsAtPath:output]) return 77;
    NSURL *application=[NSURL fileURLWithPath:arguments[2]];
    NSString *bundleID=[NSBundle bundleWithURL:application].bundleIdentifier;
    if (![@[@"local.quietbar.fixture.direct",@"local.quietbar.fixture.delayed"] containsObject:bundleID ?: @""]) return 77;
    QBApplicationBackend *backend=[[QBApplicationBackend alloc] initWithRecovery:YES];
    NSDate *recoveryDeadline=[NSDate dateWithTimeIntervalSinceNow:10];
    while ([backend.diagnostics[@"recovering"] boolValue] && recoveryDeadline.timeIntervalSinceNow>0) RunApplicationTestSlice();
    NSError *error=nil;
    if (![backend selectApplicationURL:application error:&error]) {
        WriteApplicationTestJSON(@{@"passed":@NO,@"reason":error.localizedDescription ?: @"Invalid fixture"},output,@"final.json");
        return 1;
    }
    [backend setEnabled:YES];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:30];
    while (backend.state==QBFilterStateStarting && deadline.timeIntervalSinceNow>0) {
        WriteApplicationTestJSON(backend.diagnostics,output,@"diagnostics.json");
        RunApplicationTestSlice();
    }
    BOOL prepared=backend.state==QBFilterStatePrepared;
    WriteApplicationTestJSON(backend.diagnostics,output,@"prepared.json");
    if (prepared) {
        deadline=[NSDate dateWithTimeIntervalSinceNow:180];
        while (![NSFileManager.defaultManager fileExistsAtPath:[output stringByAppendingPathComponent:@"driver-stop"]]
            && backend.state==QBFilterStatePrepared && deadline.timeIntervalSinceNow>0) {
            WriteApplicationTestJSON(backend.diagnostics,output,@"diagnostics.json");
            RunApplicationTestSlice();
        }
    }
    [backend stop];
    deadline=[NSDate dateWithTimeIntervalSinceNow:35];
    while ([backend.diagnostics[@"cleanupPending"] boolValue] && deadline.timeIntervalSinceNow>0) RunApplicationTestSlice();
    NSMutableDictionary *final=[backend.diagnostics mutableCopy];
    BOOL restored=![final[@"cleanupPending"] boolValue] && !backend.enabled;
    final[@"preparedObserved"]=prepared ? @YES : @NO;
    final[@"passed"]=prepared && restored ? @YES : @NO;
    WriteApplicationTestJSON(final,output,@"final.json");
    return prepared && restored ? 0 : 1;
}

int main(void) {
    @autoreleasepool {
        NSArray *arguments = NSProcessInfo.processInfo.arguments;
        if (arguments.count>1 && [arguments[1] isEqualToString:@"--jump-controller"]) {
            if (arguments.count!=5 || [arguments[3] intValue]<=1) return 64;
            return QBRunJumpController(arguments[2],(pid_t)[arguments[3] intValue],arguments[4]);
        }
        if (arguments.count>1 && [arguments[1] isEqualToString:@"--application-controller"]) {
            if (arguments.count!=5 || [arguments[3] intValue]<=1) return 64;
            return QBRunApplicationController(arguments[2],(pid_t)[arguments[3] intValue],arguments[4]);
        }
        if ([arguments containsObject:@"--test-application-helpers"]) {
            NSDictionary *controller=QBApplicationControllerSelfTest();
            NSDictionary *backend=[QBApplicationBackend selfTest];
            BOOL passed=[controller[@"passed"] boolValue] && [backend[@"passed"] boolValue];
            PrintJSON(@{@"passed":@(passed),@"controller":controller,@"backend":backend});
            return passed ? 0 : 1;
        }
        if ([arguments containsObject:@"--test-legacy-helpers"]) {
            NSDictionary *controller=QBJumpControllerSelfTest();
            NSDictionary *backend=[QBJumpBackend selfTest];
            BOOL passed=[controller[@"passed"] boolValue] && [backend[@"passed"] boolValue];
            PrintJSON(@{@"passed":@(passed),@"controller":controller,@"backend":backend});
            return passed ? 0 : 1;
        }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        if (arguments.count>1 && [arguments[1] isEqualToString:@"--test-application-cycle"])
            return RunApplicationIntegrationTest(arguments);
        if ([arguments containsObject:@"--self-test"]) {
            QBFilter *filter=[[QBFilter alloc] initWithClockTracking:NO];
            PrintJSON(@{@"bundleID":NSBundle.mainBundle.bundleIdentifier ?: @"", @"filterAvailable":@(filter.available),
                @"macOS":NSProcessInfo.processInfo.operatingSystemVersionString,
                @"loginStatus":LoginStatusName(SMAppService.mainAppService.status),
                @"state":@(filter.state), @"enabled":@(filter.enabled),
                @"minimumMacOS":@"14.0",@"legacyJumpCandidate":@([NSFileManager.defaultManager fileExistsAtPath:@"/Applications/Jump Desktop Connect.app"]),
                @"selectedBackend":filter.available ? @"nativeAssessment" : @"experimentalApplicationLauncher"});
            [filter stop]; return 0;
        }
        if ([arguments containsObject:@"--test-unsupported"]) {
            // Simulate a missing API without changing the host system.
            QBFilter *filter=[[QBUnavailableVerificationFilter alloc] initWithClockTracking:NO];
            [filter setEnabled:YES];
            BOOL passed=!filter.available && !filter.enabled && filter.state==QBFilterStateUnsupported
                && [[filter valueForKey:@"tokens"] count]==0;
            [filter stop];
            passed=passed && filter.state==QBFilterStateUnsupported;
            PrintJSON(@{@"passed":@(passed),@"simulatedMissingAPI":@YES,@"activationBlocked":@(!filter.enabled)});
            return passed ? 0 : 1;
        }
        if ([arguments containsObject:@"--test-login-cycle"]) {
            SMAppService *service=SMAppService.mainAppService;
            SMAppServiceStatus before=service.status;
            if (before!=SMAppServiceStatusNotRegistered && before!=SMAppServiceStatusNotFound) {
                PrintJSON(@{@"skipped":@YES,@"reason":@"Existing login registration left unchanged",@"status":LoginStatusName(before)}); return 2;
            }
            NSError *registerError=nil,*unregisterError=nil;
            BOOL registered=[service registerAndReturnError:&registerError];
            NSString *registeredStatus=LoginStatusName(service.status);
            BOOL unregistered=[service unregisterAndReturnError:&unregisterError];
            BOOL restored=service.status==SMAppServiceStatusNotRegistered;
            PrintJSON(@{@"registerSucceeded":@(registered),@"registeredStatus":registeredStatus,
                @"unregisterSucceeded":@(unregistered),@"restored":@(restored),
                @"registerError":registerError.localizedDescription ?: @"",@"unregisterError":unregisterError.localizedDescription ?: @""});
            return registered&&unregistered&&restored ? 0 : 1;
        }
        if ([arguments containsObject:@"--test-filter-cycle"]) {
            QBVerificationFilter *filter=[[QBVerificationFilter alloc] initWithClockTracking:NO];
            if (!filter.available) { PrintJSON(@{@"supported":@NO}); return 2; }
            NSArray *baseIDs=[filter runningIDs];
            NSArray *fixtureIDs=[baseIDs arrayByAddingObject:@"local.quietbar.verification-fixture"];
            filter.testIDs=fixtureIDs;
            __block NSInteger phase=0;
            __block NSDate *phaseTime=NSDate.date;
            NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:12];
            [filter setEnabled:YES];
            [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
                (void)timer;
                if (NSDate.date.timeIntervalSince1970>deadline.timeIntervalSince1970 || filter.state==QBFilterStateError) {
                    [filter stop]; PrintJSON(@{@"passed":@NO,@"reason":@"Activation timed out or failed"}); exit(1);
                }
                if (phase==0 && filter.state==QBFilterStateActive) { phase=1; phaseTime=NSDate.date; }
                else if (phase==1 && [NSDate.date timeIntervalSinceDate:phaseTime]>1) {
                    // A bundle exits and returns before the first async activation finishes.
                    filter.testIDs=baseIDs; [filter refresh];
                    NSUInteger pendingGeneration=[[filter valueForKey:@"generation"] unsignedIntegerValue];
                    filter.testIDs=fixtureIDs; [filter refresh];
                    NSUInteger replacementGeneration=[[filter valueForKey:@"generation"] unsignedIntegerValue];
                    if (replacementGeneration<=pendingGeneration) {
                        [filter stop]; PrintJSON(@{@"passed":@NO,@"reason":@"Conflicting pending allowlist was not replaced"}); exit(1);
                    }
                    phase=2;
                } else if (phase==2 && filter.state==QBFilterStateActive) {
                    if (![[filter valueForKey:@"appliedIDs"] isEqualToArray:fixtureIDs]) {
                        [filter stop]; PrintJSON(@{@"passed":@NO,@"reason":@"Outdated allowlist won the activation race"}); exit(1);
                    }
                    [filter stop]; [filter setEnabled:YES]; [filter stop]; phase=3; phaseTime=NSDate.date;
                } else if (phase==3 && [NSDate.date timeIntervalSinceDate:phaseTime]>1) {
                    BOOL passed=filter.state==QBFilterStateOff && !filter.enabled;
                    PrintJSON(@{@"passed":@(passed),@"activationConfirmed":@YES,
                        @"pendingAllowlistRaceRestored":@(passed),@"rapidCancellationRestored":@(passed)});
                    [filter stop]; exit(passed ? 0 : 1);
                }
            }];
            [NSApp run]; return 1;
        }
        QBApp *delegate=[[QBApp alloc] init];
        NSApp.delegate=delegate;
        [NSApp run];
        return 0;
    }
}
