#import "QBJumpBackend.h"
#import "QBJumpController.h"
#import <libproc.h>
#import <sys/stat.h>
#import <signal.h>
#import <unistd.h>
#import <limits.h>
#import <errno.h>

static NSString *QBJumpQuote(NSString *value) {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}
static BOOL QBJumpIdentityMatches(NSDictionary *a, NSDictionary *b) {
    if (![a isKindOfClass:NSDictionary.class] || ![b isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in @[@"pid", @"uid", @"startSeconds", @"startMicroseconds", @"executablePath"])
        if (!a[key] || ![a[key] isEqual:b[key]]) return NO;
    return YES;
}
static BOOL QBJumpControllerAlive(NSDictionary *status) {
    NSDictionary *identity = status[@"controllerIdentity"];
    pid_t pid = [identity[@"pid"] intValue];
    struct proc_bsdinfo info = {0};
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (pid <= 1 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)
        || proc_pidpath(pid, path, sizeof(path)) <= 0) return NO;
    NSDictionary *actual = @{@"pid":@(pid), @"uid":@(info.pbi_uid), @"startSeconds":@(info.pbi_start_tvsec),
        @"startMicroseconds":@(info.pbi_start_tvusec), @"executablePath":[NSString stringWithUTF8String:path]};
    return [identity[@"executablePath"] isEqualToString:NSBundle.mainBundle.executablePath]
        && QBJumpIdentityMatches(identity, actual);
}
static BOOL QBJumpPrivateDirectory(NSString *path, BOOL create) {
    if (!path.isAbsolutePath || ![path.stringByResolvingSymlinksInPath isEqualToString:path]) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (create && ![fm createDirectoryAtPath:path withIntermediateDirectories:YES
                                attributes:@{NSFilePosixPermissions:@0700} error:NULL]) return NO;
    struct stat st;
    return lstat(path.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode)
        && st.st_uid == getuid() && chmod(path.fileSystemRepresentation, 0700) == 0;
}
static BOOL QBJumpWrite(NSData *data, NSString *path) {
    if (![data writeToFile:path options:NSDataWritingAtomic error:NULL]) return NO;
    return chmod(path.fileSystemRepresentation, 0600) == 0;
}
static NSDictionary *QBJumpValidStatus(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *d = value;
    NSSet *states = [NSSet setWithArray:@[@"checking", @"needsScreenPermission", @"needsAccessibility",
        @"needsJumpAutostart", @"starting", @"prepared", @"stopping", @"off", @"error"]];
    if (![d[@"schema"] isKindOfClass:NSNumber.class] || [d[@"schema"] doubleValue] != 1
        || ![d[@"state"] isKindOfClass:NSString.class] || ![states containsObject:d[@"state"]]
        || ![d[@"message"] isKindOfClass:NSString.class]) return nil;
    for (NSString *key in @[@"controllerPID", @"agentPID", @"screenAllowed", @"accessibilityAllowed"])
        if (![d[key] isKindOfClass:NSNumber.class]) return nil;
    for (NSString *key in @[@"controllerPID", @"agentPID"])
        if ([d[key] doubleValue] != [d[key] longLongValue]) return nil;
    if ([d[@"controllerPID"] longLongValue] < 2 || [d[@"controllerPID"] longLongValue] > INT_MAX
        || [d[@"agentPID"] longLongValue] < 0 || [d[@"agentPID"] longLongValue] > INT_MAX) return nil;
    for (NSString *key in @[@"screenAllowed", @"accessibilityAllowed"])
        if ([d[key] doubleValue] != 0 && [d[key] doubleValue] != 1) return nil;
    NSDictionary *identity = d[@"controllerIdentity"];
    if (![identity isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *key in @[@"pid", @"uid", @"startSeconds", @"startMicroseconds"])
        if (![identity[key] isKindOfClass:NSNumber.class] || [identity[key] doubleValue] < 0
            || [identity[key] doubleValue] != [identity[key] longLongValue]) return nil;
    if (![identity[@"pid"] isEqual:d[@"controllerPID"]] || [identity[@"uid"] unsignedIntValue] != getuid()
        || [identity[@"startSeconds"] longLongValue] == 0 || [identity[@"startMicroseconds"] longLongValue] >= 1000000
        || ![identity[@"executablePath"] isKindOfClass:NSString.class] || ![identity[@"executablePath"] isAbsolutePath]) return nil;
    if (d[@"restorationConfirmed"] && ![d[@"restorationConfirmed"] isKindOfClass:NSNumber.class]) return nil;
    return d;
}
static NSDictionary *QBJumpReadStatus(NSString *directory) {
    NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"status.json"]];
    if (!data || data.length > 65536) return nil;
    return QBJumpValidStatus([NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]);
}

@interface QBJumpBackend ()
@property(nonatomic, readwrite) BOOL available;
@property(nonatomic, readwrite) BOOL enabled;
@property(nonatomic, readwrite) QBFilterState state;
@property(nonatomic, readwrite, copy) NSString *errorMessage;
@property(nonatomic, copy) NSString *baseDirectory;
@property(nonatomic, copy) NSString *sessionDirectory;
@property(nonatomic, copy) NSString *setupState;
@property(nonatomic, copy) NSDictionary *status;
@property(nonatomic, copy) NSArray *recoveryResults;
@property(nonatomic) NSTimer *pollTimer;
@property(nonatomic) NSDate *launchDeadline;
@property(nonatomic) NSDate *stopDeadline;
@property(nonatomic) BOOL cleanupPending;
@property(nonatomic) BOOL restorationConfirmed;
@property(nonatomic) BOOL stopping;
@property(nonatomic) BOOL recovering;
@property(nonatomic) BOOL recoveryStarted;
@property(nonatomic) BOOL requestedAfterRecovery;
@property(nonatomic) BOOL recoveryInFlight;
@property(nonatomic) BOOL recoveryAttempted;
@property(nonatomic) NSDate *recoveryRetryAfter;
@property(nonatomic, copy) NSDictionary *lastRecovery;
@property(nonatomic, copy) NSString *launchFailure;
@end

@implementation QBJumpBackend
@synthesize onChange = _onChange;
- (instancetype)init {
    return [self initWithRecovery:YES];
}
- (instancetype)initWithRecovery:(BOOL)recovery {
    if (!(self = [super init])) return nil;
    _errorMessage = @"";
    _baseDirectory = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/QuietBar/LegacyJump"];
    NSBundle *jump = [NSBundle bundleWithPath:@"/Applications/Jump Desktop Connect.app"];
    _available = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14
        && [jump.bundleIdentifier isEqualToString:@"com.p5sys.jump.connect"]
        && [NSFileManager.defaultManager isExecutableFileAtPath:jump.executablePath ?: @""];
    _state = _available ? QBFilterStateOff : QBFilterStateUnsupported;
    _restorationConfirmed = YES;
    if (recovery) [self recoverPreviousSession];
    else _recoveryStarted = YES;
    return self;
}
- (void)publish:(QBFilterState)state message:(NSString *)message {
    BOOL changed = self.state != state || ![self.errorMessage isEqualToString:message ?: @""];
    self.state = state;
    self.errorMessage = message ?: @"";
    if (changed && self.onChange) self.onChange();
}
- (NSDictionary *)diagnostics {
    NSMutableDictionary *d = [@{@"backend":@"legacyJump", @"available":@(self.available),
        @"enabled":@(self.enabled), @"cleanupPending":@(self.cleanupPending || self.recovering),
        @"restorationConfirmed":@(self.restorationConfirmed && !self.recovering),
        @"recovering":@(self.recovering), @"captureVerified":@NO, @"indicatorVerified":@NO,
        @"sessionDirectory":self.sessionDirectory ?: @"", @"setupState":self.setupState ?: @"",
        @"recovery":self.recoveryResults ?: @[]} mutableCopy];
    if (self.status) d[@"controller"] = self.status;
    if (self.lastRecovery) d[@"lastRecovery"] = self.lastRecovery;
    return [d copy];
}
- (void)recoverPreviousSession {
    if (self.recoveryStarted) return;
    self.recoveryStarted = YES;
    self.recovering = YES;
    NSString *base = self.baseDirectory;
    __weak QBJumpBackend *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableArray *results = [NSMutableArray array];
        if (QBJumpPrivateDirectory(base, NO)) {
            NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:base error:NULL];
            for (NSString *name in names) {
                if (![[NSUUID alloc] initWithUUIDString:name]) continue;
                NSString *directory = [base stringByAppendingPathComponent:name];
                if (QBJumpPrivateDirectory(directory, NO)) {
                    NSDictionary *result = QBRecoverJumpController(directory);
                    if (result) [results addObject:result];
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            QBJumpBackend *s = weakSelf;
            if (!s) return;
            s.recoveryResults = results;
            s.recovering = NO;
            NSString *failure = nil;
            for (NSDictionary *result in results)
                if ([result[@"state"] isEqualToString:@"error"] && ![result[@"restorationConfirmed"] boolValue])
                    failure = result[@"message"] ?: @"Предыдущий сеанс Jump ещё не восстановлен.";
            s.cleanupPending = failure != nil;
            s.restorationConfirmed = !failure;
            BOOL requested = s.requestedAfterRecovery;
            s.requestedAfterRecovery = NO;
            if (failure) {
                s->_enabled = NO;
                [s publish:QBFilterStateError message:failure];
            } else if (requested) [s setEnabled:YES];
            else {
                [s publish:s.available ? QBFilterStateOff : QBFilterStateUnsupported message:@""];
                if (s.onChange) s.onChange();
            }
        });
    });
}
- (BOOL)prepareSession {
    if (!QBJumpPrivateDirectory(self.baseDirectory, YES)) return NO;
    NSString *identifier = NSUUID.UUID.UUIDString;
    self.sessionDirectory = [self.baseDirectory stringByAppendingPathComponent:identifier];
    if (mkdir(self.sessionDirectory.fileSystemRepresentation, 0700) != 0) {
        self.sessionDirectory = nil;
        return NO;
    }
    NSString *executable = NSBundle.mainBundle.executablePath;
    struct proc_bsdinfo info = {0};
    if (!executable.isAbsolutePath || proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return NO;
    NSString *nonce = NSUUID.UUID.UUIDString;
    NSDictionary *owner = @{@"schema":@1, @"nonce":nonce, @"ownerPID":@(getpid()),
        @"executablePath":executable, @"ownerStartSeconds":@(info.pbi_start_tvsec),
        @"ownerStartMicroseconds":@(info.pbi_start_tvusec)};
    NSData *data = [NSJSONSerialization dataWithJSONObject:owner options:0 error:NULL];
    if (!data || !QBJumpWrite(data, [self.sessionDirectory stringByAppendingPathComponent:@"app-owner.json"])) return NO;
    NSString *stop = [self.sessionDirectory stringByAppendingPathComponent:@"stop"];
    NSString *command = [NSString stringWithFormat:
        @"#!/bin/sh\nset -eu\nif [ -e %@ ]; then exit 0; fi\nexec /usr/bin/screen -dmS %@ %@ --jump-controller %@ %@ %@\n",
        QBJumpQuote(stop), QBJumpQuote([@"quietbar-" stringByAppendingString:identifier]),
        QBJumpQuote(executable), QBJumpQuote(self.sessionDirectory), QBJumpQuote(@(getpid()).stringValue), QBJumpQuote(nonce)];
    NSString *path = [self.sessionDirectory stringByAppendingPathComponent:@"launch.command"];
    if (!QBJumpWrite([command dataUsingEncoding:NSUTF8StringEncoding], path)
        || chmod(path.fileSystemRepresentation, 0700) != 0) return NO;
    return YES;
}
- (void)setEnabled:(BOOL)enabled {
    if (!enabled) { [self stop]; return; }
    if (self.recovering) {
        self.requestedAfterRecovery = YES;
        _enabled = YES;
        [self publish:QBFilterStateStarting message:@"Проверяем завершение предыдущего сеанса…"];
        return;
    }
    if (!self.available) {
        _enabled = NO;
        [self publish:QBFilterStateUnsupported message:@"Нужны macOS 14 или новее и установленный Jump Desktop Connect."];
        return;
    }
    if (self.cleanupPending) return;
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    self.sessionDirectory = nil;
    self.status = nil;
    self.setupState = nil;
    self.stopping = NO;
    self.launchFailure = nil;
    self.stopDeadline = nil;
    self.recoveryAttempted = NO;
    self.lastRecovery = nil;
    self.recoveryRetryAfter = nil;
    if (![self prepareSession]) {
        if (self.sessionDirectory) [NSFileManager.defaultManager removeItemAtPath:self.sessionDirectory error:NULL];
        self.sessionDirectory = nil;
        _enabled = NO;
        self.restorationConfirmed = YES;
        [self publish:QBFilterStateError message:@"Не удалось подготовить защищённый каталог запуска."];
        return;
    }
    _enabled = YES;
    self.cleanupPending = YES;
    self.restorationConfirmed = NO;
    self.launchDeadline = [NSDate dateWithTimeIntervalSinceNow:20];
    [self publish:QBFilterStateStarting message:@"Проверяем разрешения для запуска через Terminal…"];
    __weak QBJumpBackend *weakSelf = self;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        (void)timer; [weakSelf poll];
    }];
    self.pollTimer.tolerance = 0.1;
    NSTask *open = [NSTask new];
    open.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
    open.arguments = @[@"-g", @"-j", @"-b", @"com.apple.Terminal", [self.sessionDirectory stringByAppendingPathComponent:@"launch.command"]];
    NSString *directory = self.sessionDirectory;
    open.terminationHandler = ^(NSTask *task) {
        if (task.terminationStatus == 0) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            QBJumpBackend *s = weakSelf;
            if (s && [s.sessionDirectory isEqualToString:directory])
                [s cancelWithError:@"Terminal не принял запрос запуска. Попробуйте снова."];
        });
    };
    NSError *error = nil;
    if (![open launchAndReturnError:&error]) [self cancelWithError:@"Не удалось открыть Terminal для запуска."];
}
- (void)writeStop {
    if (!self.sessionDirectory) return;
    QBJumpWrite([NSData data], [self.sessionDirectory stringByAppendingPathComponent:@"stop"]);
}
- (void)cancelWithError:(NSString *)message {
    self.launchFailure = message;
    [self stop];
}
- (void)stop {
    self.requestedAfterRecovery = NO;
    _enabled = NO;
    if (!self.sessionDirectory && self.cleanupPending && !self.recovering) {
        self.recoveryStarted = NO;
        [self recoverPreviousSession];
        [self publish:QBFilterStateStopping message:@"Повторяем восстановление предыдущего сеанса…"];
        return;
    }
    if (!self.sessionDirectory || !self.cleanupPending) {
        if (!self.recovering) [self publish:self.available ? QBFilterStateOff : QBFilterStateUnsupported message:@""];
        else [self publish:QBFilterStateStopping message:@"Проверяем восстановление предыдущего сеанса…"];
        return;
    }
    [self writeStop];
    if (!self.recoveryInFlight) self.recoveryAttempted = NO;
    self.stopping = YES;
    if (!self.stopDeadline) self.stopDeadline = [NSDate dateWithTimeIntervalSinceNow:20];
    [self publish:QBFilterStateStopping message:@"Завершаем сеанс и восстанавливаем запуск Jump…"];
    [self poll];
}
- (void)finish:(QBFilterState)state message:(NSString *)message {
    _enabled = NO;
    self.cleanupPending = NO;
    self.restorationConfirmed = YES;
    self.stopping = NO;
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    BOOL changed = self.state != state || ![self.errorMessage isEqualToString:message ?: @""];
    [self publish:state message:message];
    if (!changed && self.onChange) self.onChange();
}
- (void)recoverCurrentSession {
    if (self.recoveryInFlight || self.recoveryAttempted || !self.sessionDirectory
        || self.recoveryRetryAfter.timeIntervalSinceNow > 0) return;
    self.recoveryInFlight = YES;
    self.recoveryAttempted = YES;
    NSString *directory = self.sessionDirectory;
    __weak QBJumpBackend *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *result = QBRecoverJumpController(directory);
        dispatch_async(dispatch_get_main_queue(), ^{
            QBJumpBackend *s = weakSelf;
            if (!s || ![s.sessionDirectory isEqualToString:directory]) return;
            s.recoveryInFlight = NO;
            s.lastRecovery = result;
            if ([result[@"restorationConfirmed"] boolValue]) {
                QBFilterState state = s.launchFailure ? QBFilterStateError : QBFilterStateOff;
                [s finish:state message:s.launchFailure ?: @""];
            } else if ([result[@"state"] isEqualToString:@"checking"] || [result[@"busy"] boolValue]) {
                s.recoveryAttempted = NO;
                s.recoveryRetryAfter = [NSDate dateWithTimeIntervalSinceNow:2];
                [s publish:QBFilterStateStopping message:result[@"message"] ?: @"Ожидаем завершения контроллера Jump…"];
            } else {
                [s publish:QBFilterStateError message:result[@"message"] ?: @"Не удалось подтвердить восстановление Jump."];
            }
        });
    });
}
- (void)poll {
    if (!self.sessionDirectory || !self.cleanupPending) return;
    NSDictionary *status = QBJumpReadStatus(self.sessionDirectory) ?: self.status;
    if (status) self.status = status;
    NSString *phase = status[@"state"];
    BOOL alive = status && QBJumpControllerAlive(status);
    BOOL restored = [status[@"restorationConfirmed"] boolValue];
    BOOL needsSetup = [@[@"needsScreenPermission", @"needsAccessibility", @"needsJumpAutostart"] containsObject:phase ?: @""];
    BOOL terminal = needsSetup || [phase isEqualToString:@"off"] || [phase isEqualToString:@"error"];
    NSString *message = status[@"message"] ?: @"";
    if (terminal && !alive && restored) {
        if (needsSetup) {
            self.setupState = phase;
            [self finish:QBFilterStateNeedsSetup message:message];
        } else if ([phase isEqualToString:@"error"] || self.launchFailure) {
            [self finish:QBFilterStateError message:self.launchFailure ?: message];
        } else [self finish:QBFilterStateOff message:@""];
        return;
    }
    if (terminal && !alive && !restored) {
        _enabled = NO;
        self.stopping = YES;
        [self writeStop];
        [self publish:QBFilterStateError message:message.length ? message : @"Восстановление Jump ещё не подтверждено."];
        if (!self.launchFailure && [phase isEqualToString:@"error"]) self.launchFailure = message;
        [self recoverCurrentSession];
        return;
    }
    if (status && !alive && !terminal) {
        self.launchFailure = @"Контроллер завершился неожиданно. Проверяем восстановление Jump…";
        _enabled = NO;
        self.stopping = YES;
        [self writeStop];
        [self publish:QBFilterStateStopping message:self.launchFailure];
        [self recoverCurrentSession];
        return;
    }
    if (self.stopping) {
        if (!status && !self.recoveryAttempted) [self recoverCurrentSession];
        if (self.stopDeadline.timeIntervalSinceNow <= 0)
            [self publish:QBFilterStateError message:@"Завершение сеанса ещё не подтверждено. QuietBar продолжает ждать восстановления Jump."];
        return;
    }
    if (needsSetup) {
        self.setupState = phase;
        _enabled = NO;
        [self writeStop];
        [self publish:QBFilterStateNeedsSetup message:message];
        return;
    }
    if ([phase isEqualToString:@"prepared"] && alive) {
        [self publish:QBFilterStatePrepared message:message.length ? message : @"Агент запущен. Подключение и скрытие индикатора ещё не проверены."];
        return;
    }
    if ([phase isEqualToString:@"starting"] || [phase isEqualToString:@"checking"])
        [self publish:QBFilterStateStarting message:message];
    if ([phase isEqualToString:@"stopping"]) {
        _enabled = NO;
        self.stopping = YES;
        self.stopDeadline = [NSDate dateWithTimeIntervalSinceNow:20];
        [self publish:QBFilterStateStopping message:message];
        return;
    }
    if (self.launchDeadline.timeIntervalSinceNow <= 0 && ![phase isEqualToString:@"prepared"])
        [self cancelWithError:@"Контроллер не подтвердил запуск за 20 секунд. Запуск отменён; ожидаем завершения."];
}
- (void)openSetup {
    if ([self.setupState isEqualToString:@"needsJumpAutostart"]) {
        NSURL *app = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.p5sys.jump.connect"];
        if (app) [NSWorkspace.sharedWorkspace openURL:app];
        return;
    }
    NSString *pane = [self.setupState isEqualToString:@"needsAccessibility"] ? @"Privacy_Accessibility" : @"Privacy_ScreenCapture";
    NSURL *url = [NSURL URLWithString:[@"x-apple.systempreferences:com.apple.preference.security?" stringByAppendingString:pane]];
    [NSWorkspace.sharedWorkspace openURL:url];
}
+ (NSDictionary *)selfTest {
    NSDictionary *identity = @{@"pid":@123, @"uid":@(getuid()), @"startSeconds":@100,
        @"startMicroseconds":@20, @"executablePath":@"/fixture/QuietBar"};
    NSDictionary *valid = @{@"schema":@1, @"state":@"prepared", @"message":@"test", @"controllerPID":@123,
        @"controllerIdentity":identity, @"agentPID":@124, @"screenAllowed":@YES,
        @"accessibilityAllowed":@YES, @"restorationConfirmed":@NO};
    NSMutableDictionary *invalid = [valid mutableCopy];
    invalid[@"state"] = @"active";
    BOOL quoting = [QBJumpQuote(@"a'b $`x`\n") isEqualToString:@"'a'\\''b $`x`\n'"];
    BOOL validation = QBJumpValidStatus(valid) && !QBJumpValidStatus(invalid) && !QBJumpValidStatus(@[]);
    invalid = [valid mutableCopy]; invalid[@"controllerPID"] = @"123";
    validation = validation && !QBJumpValidStatus(invalid);
    invalid = [valid mutableCopy]; invalid[@"schema"] = @2;
    validation = validation && !QBJumpValidStatus(invalid);
    invalid = [valid mutableCopy]; invalid[@"agentPID"] = @(-1);
    validation = validation && !QBJumpValidStatus(invalid);
    invalid = [valid mutableCopy]; invalid[@"controllerPID"] = @123.5;
    validation = validation && !QBJumpValidStatus(invalid);
    invalid = [valid mutableCopy]; invalid[@"screenAllowed"] = @0.5;
    validation = validation && !QBJumpValidStatus(invalid);
    NSMutableDictionary *reused = [identity mutableCopy]; reused[@"startSeconds"] = @101;
    BOOL identityComparison = QBJumpIdentityMatches(identity, identity) && !QBJumpIdentityMatches(identity, reused);
    return @{@"passed":@(quoting && validation && identityComparison), @"shellQuoting":@(quoting),
        @"statusValidation":@(validation), @"identityComparison":@(identityComparison), @"launchPerformed":@NO};
}
- (void)dealloc {
    [_pollTimer invalidate];
    if (_cleanupPending && _sessionDirectory)
        QBJumpWrite([NSData data], [_sessionDirectory stringByAppendingPathComponent:@"stop"]);
}
@end
