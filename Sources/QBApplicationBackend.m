#import "QBApplicationBackend.h"
#import "QBLocalization.h"
#import "QBApplicationController.h"
#import <libproc.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <limits.h>
#import <string.h>
#import <errno.h>

static NSString * const QBSelectedApplicationKey = @"selectedApplicationPath";

static NSString *QBApplicationQuote(NSString *value) {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}
static BOOL QBApplicationInteger(id value, long long minimum, long long maximum) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    const char *type = [value objCType];
    return type && strlen(type) == 1 && strchr("cCsSiIlLqQ", type[0])
        && [value doubleValue] >= minimum && [value doubleValue] <= maximum
        && [value doubleValue] == [value longLongValue];
}
static BOOL QBApplicationBoolean(id value) {
    return ([value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID())
        || QBApplicationInteger(value, 0, 1);
}
static BOOL QBApplicationCanonicalPath(id value) {
    return [value isKindOfClass:NSString.class] && [value isAbsolutePath]
        && [value isEqualToString:[value stringByStandardizingPath]]
        && [value isEqualToString:[value stringByResolvingSymlinksInPath]];
}
static BOOL QBApplicationValidIdentity(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *d = value;
    return QBApplicationInteger(d[@"pid"], 2, INT_MAX) && QBApplicationInteger(d[@"uid"], 0, UINT_MAX)
        && QBApplicationInteger(d[@"startSeconds"], 1, LLONG_MAX)
        && QBApplicationInteger(d[@"startMicroseconds"], 0, 999999)
        && QBApplicationCanonicalPath(d[@"executablePath"]);
}
static BOOL QBApplicationIdentityMatches(NSDictionary *a, NSDictionary *b) {
    if (!QBApplicationValidIdentity(a) || !QBApplicationValidIdentity(b)) return NO;
    for (NSString *key in @[@"pid", @"uid", @"startSeconds", @"startMicroseconds", @"executablePath"])
        if (![a[key] isEqual:b[key]]) return NO;
    return YES;
}
static NSDictionary *QBApplicationIdentity(pid_t pid) {
    struct proc_bsdinfo info = {0};
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (pid <= 1 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)
        || proc_pidpath(pid, path, sizeof(path)) <= 0) return nil;
    NSString *executable = [[NSString stringWithUTF8String:path] stringByResolvingSymlinksInPath];
    if (!executable) return nil;
    return @{@"pid":@(pid), @"uid":@(info.pbi_uid), @"startSeconds":@(info.pbi_start_tvsec),
        @"startMicroseconds":@(info.pbi_start_tvusec), @"executablePath":executable};
}
static BOOL QBApplicationIdentityAlive(NSDictionary *identity) {
    return QBApplicationValidIdentity(identity) && [identity[@"uid"] unsignedIntValue] == getuid()
        && QBApplicationIdentityMatches(identity, QBApplicationIdentity([identity[@"pid"] intValue]));
}
static BOOL QBApplicationPrivateDirectory(NSString *path, BOOL create) {
    if (!QBApplicationCanonicalPath(path)) return NO;
    if (create && ![NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:NULL]) return NO;
    struct stat st = {0};
    return lstat(path.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode)
        && st.st_uid == getuid() && (st.st_mode & 0777) == 0700;
}
static BOOL QBApplicationWrite(NSData *data, NSString *path, mode_t mode) {
    NSString *temporary = [path stringByAppendingFormat:@".%@.tmp", NSUUID.UUID.UUIDString];
    int fd = open(temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode);
    if (fd < 0) return NO;
    const unsigned char *bytes = data.bytes;
    NSUInteger remaining = data.length;
    BOOL success = fchmod(fd, mode) == 0;
    while (success && remaining) {
        ssize_t count = write(fd, bytes, remaining);
        if (count <= 0) { success = NO; break; }
        bytes += count; remaining -= (NSUInteger)count;
    }
    if (success && fsync(fd) != 0) success = NO;
    if (close(fd) != 0) success = NO;
    if (success && rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation) != 0) success = NO;
    if (!success) unlink(temporary.fileSystemRepresentation);
    return success;
}
static id QBApplicationReadJSON(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return nil;
    struct stat st = {0};
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != getuid()
        || (st.st_mode & 077) != 0 || st.st_size < 0 || st.st_size > 65536) { close(fd); return nil; }
    NSMutableData *data = [NSMutableData data];
    unsigned char buffer[4096];
    ssize_t count;
    while ((count = read(fd, buffer, sizeof(buffer))) != 0) {
        if (count < 0) { if (errno == EINTR) continue; close(fd); return nil; }
        [data appendBytes:buffer length:(NSUInteger)count];
        if (data.length > 65536) { close(fd); return nil; }
    }
    close(fd);
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
}
static NSDictionary *QBApplicationCheckedStatus(id value, BOOL recovery) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *d = value;
    NSSet *states = [NSSet setWithArray:@[@"checking", @"needsScreenPermission", @"needsCloseApplication",
        @"starting", @"prepared", @"stopping", @"needsManualClose", @"off", @"error"]];
    if (!QBApplicationInteger(d[@"schema"], 1, 1) || ![d[@"state"] isKindOfClass:NSString.class]
        || ![states containsObject:d[@"state"]] || ![d[@"message"] isKindOfClass:NSString.class]
        || !QBApplicationInteger(d[@"controllerPID"], 2, INT_MAX)
        || !QBApplicationInteger(d[@"applicationPID"], 0, INT_MAX)
        || ![d[@"applicationPID"] isEqual:d[@"agentPID"]]
        || !QBApplicationInteger(d[@"agentPID"], 0, INT_MAX)
        || !QBApplicationValidIdentity(d[@"controllerIdentity"])
        || ![d[@"controllerIdentity"][@"pid"] isEqual:d[@"controllerPID"]]
        || [d[@"controllerIdentity"][@"uid"] unsignedIntValue] != getuid()) return nil;
    for (NSString *key in @[@"screenAllowed", @"accessibilityAllowed", @"restorationConfirmed", @"captureVerified", @"indicatorVerified"])
        if (!QBApplicationBoolean(d[key])) return nil;
    for (NSString *key in @[@"busy", @"active", @"recovered"])
        if (d[key] && !QBApplicationBoolean(d[key])) return nil;
    // A crash may leave a private UUID directory before its owner marker is
    // written. Only the recovery function's explicit empty, completed ACK can
    // represent that no application was selected or created in that directory.
    BOOL noTarget = recovery && [d[@"applicationPath"] isKindOfClass:NSString.class]
        && [d[@"applicationPath"] length] == 0 && [d[@"state"] isEqualToString:@"off"]
        && [d[@"restorationConfirmed"] boolValue] && [d[@"applicationPID"] intValue] == 0
        && !d[@"applicationIdentity"] && ![d[@"busy"] boolValue] && ![d[@"active"] boolValue];
    if (!noTarget && (!QBApplicationCanonicalPath(d[@"applicationPath"])
        || ![[d[@"applicationPath"] pathExtension].lowercaseString isEqualToString:@"app"])) return nil;
    if ([d[@"accessibilityAllowed"] boolValue] || [d[@"captureVerified"] boolValue] || [d[@"indicatorVerified"] boolValue]) return nil;
    if ([d[@"applicationPID"] intValue] > 0 && ([d[@"applicationPID"] isEqual:d[@"controllerPID"]]
        || [d[@"restorationConfirmed"] boolValue])) return nil;
    NSDictionary *child = d[@"applicationIdentity"];
    if (child && (!QBApplicationValidIdentity(child) || [child[@"uid"] unsignedIntValue] != getuid()
        || ![child[@"executablePath"] hasPrefix:[d[@"applicationPath"] stringByAppendingString:@"/"]])) return nil;
    if ([d[@"applicationPID"] intValue] > 0 && (!child || ![child[@"pid"] isEqual:d[@"applicationPID"]])) return nil;
    if ([d[@"state"] isEqualToString:@"prepared"] && ([d[@"applicationPID"] intValue] <= 1
        || [d[@"restorationConfirmed"] boolValue])) return nil;
    return d;
}
static NSDictionary *QBApplicationValidStatus(id value) { return QBApplicationCheckedStatus(value, NO); }
static NSURL *QBApplicationURL(NSURL *url, NSString **error) {
    if (!url.isFileURL) { if (error) *error = @"Выберите локальное приложение .app."; return nil; }
    NSString *path = url.path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    NSBundle *bundle = [NSBundle bundleWithPath:path];
    NSString *executable = bundle.executablePath.stringByResolvingSymlinksInPath;
    struct stat appStat = {0}, executableStat = {0};
    if (![path.pathExtension.lowercaseString isEqualToString:@"app"] || !QBApplicationCanonicalPath(path)
        || [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound
        || lstat(path.fileSystemRepresentation, &appStat) != 0 || !S_ISDIR(appStat.st_mode)
        || !executable || ![executable hasPrefix:[path stringByAppendingString:@"/"]]
        || lstat(executable.fileSystemRepresentation, &executableStat) != 0 || !S_ISREG(executableStat.st_mode)
        || access(executable.fileSystemRepresentation, X_OK) != 0) {
        if (error) *error = @"В выбранном .app не найден исполняемый файл внутри приложения.";
        return nil;
    }
    if ([executable isEqualToString:QBApplicationIdentity(getpid())[@"executablePath"]]) {
        if (error) *error = @"Выберите другое приложение, а не сам QuietBar.";
        return nil;
    }
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

@interface QBApplicationBackend ()
@property(nonatomic, readwrite) BOOL available;
@property(nonatomic, readwrite) BOOL enabled;
@property(nonatomic, readwrite) QBFilterState state;
@property(nonatomic, readwrite, copy) NSString *errorMessage;
@property(nonatomic, readwrite, copy, nullable) NSURL *selectedApplicationURL;
@property(nonatomic, readwrite, copy) NSString *selectedApplicationName;
@property(nonatomic) BOOL recoveryEnabled;
@property(nonatomic, copy) NSString *baseDirectory;
@property(nonatomic, copy) NSString *sessionDirectory;
@property(nonatomic, copy) NSString *sessionApplicationPath;
@property(nonatomic, copy) NSString *controllerExecutablePath;
@property(nonatomic, copy) NSString *setupState;
@property(nonatomic, copy) NSDictionary *status;
@property(nonatomic, copy) NSArray *recoveryResults;
@property(nonatomic, copy) NSDictionary *lastRecovery;
@property(nonatomic) NSTimer *pollTimer;
@property(nonatomic) NSDate *launchDeadline;
@property(nonatomic) NSDate *stopDeadline;
@property(nonatomic) NSDate *recoveryRetryAfter;
@property(nonatomic) BOOL cleanupPending;
@property(nonatomic) BOOL restorationConfirmed;
@property(nonatomic) BOOL stopping;
@property(nonatomic) BOOL recovering;
@property(nonatomic) BOOL recoveryInFlight;
@property(nonatomic, copy) NSString *launchFailure;
@end

@implementation QBApplicationBackend
@synthesize onChange = _onChange;
- (instancetype)init { return [self initWithRecovery:YES]; }
- (instancetype)initWithRecovery:(BOOL)recovery {
    if (!(self = [super init])) return nil;
    _recoveryEnabled = recovery;
    _errorMessage = @"";
    _selectedApplicationName = @"";
    _baseDirectory = [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/QuietBar/Applications"] stringByResolvingSymlinksInPath];
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:QBSelectedApplicationKey];
    if (saved.length) {
        _selectedApplicationURL = QBApplicationURL([NSURL fileURLWithPath:saved], NULL);
        if (_selectedApplicationURL) _selectedApplicationName = [self nameForApplication:_selectedApplicationURL];
    }
    _available = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14
        && [NSFileManager.defaultManager isExecutableFileAtPath:@"/usr/bin/screen"]
        && [NSFileManager.defaultManager isExecutableFileAtPath:@"/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"];
    _state = _available ? QBFilterStateOff : QBFilterStateUnsupported;
    _restorationConfirmed = YES;
    if (recovery) [self recoverPreviousSessions];
    return self;
}
- (NSString *)nameForApplication:(NSURL *)url {
    NSBundle *bundle = [NSBundle bundleWithURL:url];
    id name = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: [bundle objectForInfoDictionaryKey:@"CFBundleName"];
    return [name isKindOfClass:NSString.class] && [name length] ? name : url.lastPathComponent.stringByDeletingPathExtension;
}
- (void)publish:(QBFilterState)state message:(NSString *)message {
    BOOL changed = self.state != state || ![self.errorMessage isEqualToString:message ?: @""];
    self.state = state; self.errorMessage = message ?: @"";
    if (changed && self.onChange) self.onChange();
}
- (void)ensurePolling {
    if (self.pollTimer) return;
    __weak QBApplicationBackend *weakSelf = self;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        (void)timer; [weakSelf poll];
    }];
    self.pollTimer.tolerance = 0.1;
}
- (NSDictionary *)diagnostics {
    NSMutableDictionary *result = [@{@"backend":@"experimentalApplicationLauncher", @"available":@(self.available),
        @"enabled":@(self.enabled), @"cleanupPending":@(self.cleanupPending || self.recovering),
        @"restorationConfirmed":@(self.restorationConfirmed && !self.recovering), @"recovering":@(self.recovering),
        @"captureVerified":@NO, @"indicatorVerified":@NO,
        @"selectedApplicationPath":self.selectedApplicationURL.path ?: @"", @"selectedApplicationName":self.selectedApplicationName ?: @"",
        @"sessionDirectory":self.sessionDirectory ?: @"", @"setupState":self.setupState ?: @"",
        @"recovery":self.recoveryResults ?: @[]} mutableCopy];
    if (self.status) result[@"controller"] = self.status;
    if (self.lastRecovery) result[@"lastRecovery"] = self.lastRecovery;
    return result;
}
- (BOOL)selectApplicationURL:(NSURL *)url error:(NSError **)error {
    NSString *message = nil;
    NSURL *selected = nil;
    if (!self.recoveryEnabled) message = @"В предпросмотре выбор приложения не сохраняется.";
    else if (self.cleanupPending || self.recovering) message = @"Сначала завершите предыдущий сеанс приложения.";
    else selected = QBApplicationURL(url, &message);
    if (!selected) {
        if (error) *error = [NSError errorWithDomain:@"QuietBar.ApplicationLauncher" code:1
            userInfo:@{NSLocalizedDescriptionKey:message ?: @"Выберите приложение .app."}];
        return NO;
    }
    self.selectedApplicationURL = selected;
    self.selectedApplicationName = [self nameForApplication:selected];
    [NSUserDefaults.standardUserDefaults setObject:selected.path forKey:QBSelectedApplicationKey];
    self.setupState = nil;
    [self publish:self.available ? QBFilterStateOff : QBFilterStateUnsupported message:@""];
    if (self.onChange) self.onChange();
    return YES;
}
- (void)chooseApplicationForWindow:(NSWindow *)window {
    if (!self.recoveryEnabled || self.cleanupPending || self.recovering) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = QBLocalized(@"Выберите приложение для экспериментального запуска");
    panel.prompt = QBLocalized(@"Выбрать");
    panel.message = QBLocalized(@"Выберите одно приложение .app. Перед запуском его потребуется закрыть вручную.");
    panel.canChooseFiles = YES; panel.canChooseDirectories = YES;
    panel.treatsFilePackagesAsDirectories = NO; panel.allowsMultipleSelection = NO;
    __weak QBApplicationBackend *weakSelf = self;
    void (^chosen)(NSModalResponse) = ^(NSModalResponse response) {
        QBApplicationBackend *s = weakSelf;
        if (!s || response != NSModalResponseOK || s.cleanupPending || s.recovering) return;
        NSError *error = nil;
        if (![s selectApplicationURL:panel.URL error:&error]) [s publish:QBFilterStateNeedsSetup message:error.localizedDescription];
    };
    if (window) [panel beginSheetModalForWindow:window completionHandler:chosen];
    else [panel beginWithCompletionHandler:chosen];
}
- (BOOL)recoveryComplete:(NSDictionary *)value previous:(NSDictionary *)previous {
    NSDictionary *result = QBApplicationCheckedStatus(value, YES);
    if (!result || ![result[@"restorationConfirmed"] boolValue] || [result[@"busy"] boolValue]
        || [result[@"active"] boolValue] || QBApplicationIdentityAlive(result[@"applicationIdentity"])) return NO;
    NSDictionary *oldController = previous[@"controllerIdentity"];
    if ([oldController[@"pid"] intValue] != getpid() && QBApplicationIdentityAlive(oldController)) return NO;
    NSDictionary *controller = result[@"controllerIdentity"];
    return [controller[@"pid"] intValue] == getpid() || !QBApplicationIdentityAlive(controller);
}
- (void)recoverPreviousSessions {
    if (!self.recoveryEnabled || self.recoveryInFlight || self.sessionDirectory) return;
    self.recovering = YES; self.recoveryInFlight = YES;
    self.cleanupPending = YES; self.restorationConfirmed = NO;
    [self ensurePolling];
    NSString *base = self.baseDirectory;
    __weak QBApplicationBackend *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableArray *results = [NSMutableArray array];
        struct stat st = {0};
        BOOL exists = lstat(base.fileSystemRepresentation, &st) == 0;
        BOOL inaccessible = !exists && errno != ENOENT;
        if (inaccessible || (exists && !QBApplicationPrivateDirectory(base, NO))) {
            [results addObject:@{@"state":@"error", @"restorationConfirmed":@NO,
                @"message":@"Каталог предыдущих сеансов недоступен или имеет неподходящие права."}];
        } else if (exists) {
            NSArray *names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:base error:NULL] sortedArrayUsingSelector:@selector(compare:)];
            if (!names) [results addObject:@{@"state":@"error", @"restorationConfirmed":@NO,
                @"message":@"Не удалось прочитать список предыдущих сеансов приложения."}];
            for (NSString *name in names) {
                if (![[NSUUID alloc] initWithUUIDString:name]) continue;
                NSString *directory = [base stringByAppendingPathComponent:name];
                NSDictionary *result = QBApplicationPrivateDirectory(directory, NO) ? QBRecoverApplicationController(directory) : nil;
                if (!result) result = @{@"state":@"error", @"restorationConfirmed":@NO,
                    @"message":@"Не удалось проверить предыдущий сеанс приложения."};
                NSMutableDictionary *record = [result mutableCopy]; record[@"sessionDirectory"] = directory;
                [results addObject:record];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            QBApplicationBackend *s = weakSelf;
            if (!s) return;
            s.recoveryResults = results; s.recovering = NO; s.recoveryInFlight = NO;
            NSDictionary *pending = nil;
            for (NSDictionary *result in results) if (![s recoveryComplete:result previous:nil]) {
                if (!pending || [result[@"state"] isEqualToString:@"error"] || [result[@"state"] isEqualToString:@"needsManualClose"]) pending = result;
            }
            s.recoveryRetryAfter = [NSDate dateWithTimeIntervalSinceNow:2];
            if (pending) {
                s->_enabled = NO; s.cleanupPending = YES; s.restorationConfirmed = NO;
                s.setupState = pending[@"state"];
                QBFilterState state = [pending[@"state"] isEqualToString:@"needsManualClose"] ? QBFilterStateNeedsSetup
                    : ([pending[@"busy"] boolValue] || [pending[@"state"] isEqualToString:@"checking"] ? QBFilterStateStopping : QBFilterStateError);
                [s publish:state message:pending[@"message"] ?: @"Предыдущий сеанс ещё не завершён. Закройте приложение вручную и повторите завершение."];
            } else [s finish: s.available ? QBFilterStateOff : QBFilterStateUnsupported message:@""];
        });
    });
}
- (BOOL)prepareSession {
    NSString *error = nil;
    NSURL *application = QBApplicationURL(self.selectedApplicationURL, &error);
    if (!application || !QBApplicationPrivateDirectory(self.baseDirectory, YES)) return NO;
    NSDictionary *identity = QBApplicationIdentity(getpid());
    if (!QBApplicationValidIdentity(identity)) return NO;
    NSString *identifier = NSUUID.UUID.UUIDString;
    NSString *directory = [self.baseDirectory stringByAppendingPathComponent:identifier];
    if (mkdir(directory.fileSystemRepresentation, 0700) != 0) return NO;
    self.sessionDirectory = directory;
    self.sessionApplicationPath = application.path;
    self.controllerExecutablePath = identity[@"executablePath"];
    NSString *nonce = NSUUID.UUID.UUIDString;
    NSDictionary *owner = @{@"schema":@1, @"nonce":nonce, @"ownerPID":identity[@"pid"],
        @"executablePath":identity[@"executablePath"], @"ownerStartSeconds":identity[@"startSeconds"],
        @"ownerStartMicroseconds":identity[@"startMicroseconds"], @"applicationPath":application.path};
    NSData *data = [NSJSONSerialization dataWithJSONObject:owner options:0 error:NULL];
    if (!data || !QBApplicationWrite(data, [directory stringByAppendingPathComponent:@"app-owner.json"], 0600)) return NO;
    NSString *command = [NSString stringWithFormat:
        @"#!/bin/sh\nset -eu\numask 077\nif [ -e %@ ]; then exit 0; fi\nexec /usr/bin/screen -dmS %@ %@ --application-controller %@ %@ %@\n",
        QBApplicationQuote([directory stringByAppendingPathComponent:@"stop"]),
        QBApplicationQuote([@"quietbar-app-" stringByAppendingString:identifier]), QBApplicationQuote(identity[@"executablePath"]),
        QBApplicationQuote(directory), QBApplicationQuote([identity[@"pid"] stringValue]), QBApplicationQuote(nonce)];
    return QBApplicationWrite([command dataUsingEncoding:NSUTF8StringEncoding], [directory stringByAppendingPathComponent:@"launch.command"], 0700);
}
- (void)setEnabled:(BOOL)enabled {
    if (!enabled) { [self stop]; return; }
    if (!self.recoveryEnabled) { [self publish:QBFilterStateNeedsSetup message:@"Предпросмотр: запуск приложений отключён."]; return; }
    if (self.cleanupPending || self.recovering) return;
    if (!self.available) { [self publish:QBFilterStateUnsupported message:@"Для запуска нужны macOS 14 или новее, Terminal и screen."]; return; }
    NSString *error = nil;
    if (!QBApplicationURL(self.selectedApplicationURL, &error)) {
        [self publish:QBFilterStateNeedsSetup message:self.selectedApplicationURL ? error : @"Сначала выберите приложение .app."]; return;
    }
    self.status = nil; self.setupState = nil; self.launchFailure = nil; self.lastRecovery = nil;
    self.stopping = NO; self.stopDeadline = nil; self.recoveryRetryAfter = nil;
    if (![self prepareSession]) {
        if (self.sessionDirectory) {
            for (NSString *name in @[@"app-owner.json", @"launch.command"])
                unlink([self.sessionDirectory stringByAppendingPathComponent:name].fileSystemRepresentation);
            rmdir(self.sessionDirectory.fileSystemRepresentation);
        }
        self.sessionDirectory = nil;
        [self publish:QBFilterStateError message:@"Не удалось подготовить защищённый сеанс запуска."]; return;
    }
    _enabled = YES; self.cleanupPending = YES; self.restorationConfirmed = NO;
    self.launchDeadline = [NSDate dateWithTimeIntervalSinceNow:20];
    [self ensurePolling];
    [self publish:QBFilterStateStarting message:@"Проверяем разрешение записи экрана для Terminal…"];
    NSTask *open = [NSTask new];
    open.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
    open.arguments = @[@"-g", @"-j", @"-b", @"com.apple.Terminal", [self.sessionDirectory stringByAppendingPathComponent:@"launch.command"]];
    NSString *directory = self.sessionDirectory;
    __weak QBApplicationBackend *weakSelf = self;
    open.terminationHandler = ^(NSTask *task) {
        if (task.terminationStatus == 0) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            QBApplicationBackend *s = weakSelf;
            if (s && [s.sessionDirectory isEqualToString:directory]) [s cancelWithError:@"Terminal не принял запрос запуска."];
        });
    };
    if (![open launchAndReturnError:NULL]) [self cancelWithError:@"Не удалось открыть Terminal для запуска приложения."];
}
- (BOOL)writeStop {
    return self.sessionDirectory && QBApplicationPrivateDirectory(self.sessionDirectory, NO)
        && QBApplicationWrite([NSData data], [self.sessionDirectory stringByAppendingPathComponent:@"stop"], 0600);
}
- (void)cancelWithError:(NSString *)message { self.launchFailure = message; [self stop]; }
- (void)stop {
    _enabled = NO;
    if (!self.recoveryEnabled) return;
    if (!self.sessionDirectory) {
        if (self.cleanupPending || self.recovering) { self.recoveryRetryAfter = nil; [self recoverPreviousSessions]; }
        else [self publish:self.available ? QBFilterStateOff : QBFilterStateUnsupported message:@""];
        return;
    }
    if (!self.cleanupPending) return;
    if (![self writeStop]) { [self publish:QBFilterStateError message:@"Не удалось записать отмену запуска. Завершение сеанса не подтверждено."]; return; }
    self.stopping = YES; self.recoveryRetryAfter = nil;
    self.stopDeadline = [NSDate dateWithTimeIntervalSinceNow:20];
    [self publish:QBFilterStateStopping message:@"Завершаем экспериментальный запуск. Приложение может потребовать закрытия вручную…"];
    [self poll];
}
- (void)finish:(QBFilterState)state message:(NSString *)message {
    _enabled = NO; self.cleanupPending = NO; self.restorationConfirmed = YES;
    self.stopping = NO; self.recovering = NO;
    [self.pollTimer invalidate]; self.pollTimer = nil;
    self.sessionDirectory = nil; self.sessionApplicationPath = nil; self.controllerExecutablePath = nil;
    BOOL changed = self.state != state || ![self.errorMessage isEqualToString:message ?: @""];
    [self publish:state message:message];
    if (!changed && self.onChange) self.onChange();
}
- (void)recoverCurrentSession {
    if (self.recoveryInFlight || !self.sessionDirectory || self.recoveryRetryAfter.timeIntervalSinceNow > 0) return;
    self.recoveryInFlight = YES;
    NSString *directory = self.sessionDirectory;
    NSDictionary *previous = self.status;
    __weak QBApplicationBackend *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *result = QBRecoverApplicationController(directory);
        dispatch_async(dispatch_get_main_queue(), ^{
            QBApplicationBackend *s = weakSelf;
            if (!s || ![s.sessionDirectory isEqualToString:directory]) return;
            s.recoveryInFlight = NO; s.lastRecovery = result;
            s.recoveryRetryAfter = [NSDate dateWithTimeIntervalSinceNow:2];
            if ([s recoveryComplete:result previous:previous]) {
                QBFilterState state = s.launchFailure ? QBFilterStateError : QBFilterStateOff;
                [s finish:state message:s.launchFailure ?: @""];
            } else {
                s->_enabled = NO;
                s.setupState = result[@"state"];
                QBFilterState state = [result[@"state"] isEqualToString:@"needsManualClose"] ? QBFilterStateNeedsSetup
                    : ([result[@"busy"] boolValue] ? QBFilterStateStopping : QBFilterStateError);
                [s publish:state message:result[@"message"] ?: @"Завершение сеанса ещё не подтверждено. Закройте приложение вручную и повторите завершение."];
            }
        });
    });
}
- (void)poll {
    if (!self.cleanupPending) return;
    if (!self.sessionDirectory) {
        if (!self.recoveryInFlight && self.recoveryRetryAfter.timeIntervalSinceNow <= 0) [self recoverPreviousSessions];
        return;
    }
    NSString *path = [self.sessionDirectory stringByAppendingPathComponent:@"status.json"];
    NSDictionary *status = QBApplicationValidStatus(QBApplicationReadJSON(path));
    BOOL malformed = [NSFileManager.defaultManager fileExistsAtPath:path] && !status;
    if (status && (![status[@"applicationPath"] isEqualToString:self.sessionApplicationPath]
        || ![status[@"controllerIdentity"][@"executablePath"] isEqualToString:self.controllerExecutablePath])) {
        status = nil; malformed = YES;
    }
    if (malformed) {
        self.launchFailure = @"Состояние контроллера не прошло проверку. Запуск отменён; завершение ещё не подтверждено.";
        _enabled = NO; self.stopping = YES; [self writeStop];
        [self publish:QBFilterStateError message:self.launchFailure]; [self recoverCurrentSession]; return;
    }
    if (status) self.status = status;
    status = status ?: self.status;
    NSString *phase = status[@"state"];
    BOOL controllerAlive = QBApplicationIdentityAlive(status[@"controllerIdentity"]);
    BOOL childAlive = QBApplicationIdentityAlive(status[@"applicationIdentity"]);
    BOOL needsSetup = [@[@"needsScreenPermission", @"needsCloseApplication", @"needsManualClose"] containsObject:phase ?: @""];
    BOOL terminal = needsSetup || [phase isEqualToString:@"off"] || [phase isEqualToString:@"error"];
    NSString *message = status[@"message"] ?: @"";
    if (terminal && !controllerAlive && !childAlive && [status[@"restorationConfirmed"] boolValue]) {
        self.setupState = needsSetup ? phase : nil;
        [self finish:needsSetup ? QBFilterStateNeedsSetup : (self.launchFailure || [phase isEqualToString:@"error"] ? QBFilterStateError : QBFilterStateOff)
            message:self.launchFailure ?: (needsSetup || [phase isEqualToString:@"error"] ? message : @"")];
        return;
    }
    if (needsSetup) {
        self.setupState = phase; _enabled = NO; self.stopping = YES; [self writeStop];
        [self publish:QBFilterStateNeedsSetup message:message];
        if (!controllerAlive) [self recoverCurrentSession];
        return;
    }
    if (status && !controllerAlive) {
        if (!terminal && !self.launchFailure) self.launchFailure = @"Контроллер завершился. Проверяем завершение принадлежащего сеансу приложения…";
        _enabled = NO; self.stopping = YES; [self writeStop];
        [self publish:QBFilterStateStopping message:self.launchFailure ?: message];
        [self recoverCurrentSession]; return;
    }
    if (self.stopping) {
        if (!status) [self recoverCurrentSession];
        if (self.stopDeadline && self.stopDeadline.timeIntervalSinceNow <= 0)
            [self publish:QBFilterStateError message:@"Завершение ещё не подтверждено. Закройте запущенное приложение вручную и повторите завершение."];
        return;
    }
    if ([phase isEqualToString:@"prepared"] && controllerAlive && childAlive) {
        [self publish:QBFilterStatePrepared message:message.length ? message : @"Приложение запущено. Захват и отсутствие индикатора ещё не проверены."]; return;
    }
    if ([phase isEqualToString:@"stopping"]) {
        _enabled = NO; self.stopping = YES; self.stopDeadline = [NSDate dateWithTimeIntervalSinceNow:20];
        [self publish:QBFilterStateStopping message:message]; return;
    }
    if ([phase isEqualToString:@"starting"] || [phase isEqualToString:@"checking"])
        [self publish:QBFilterStateStarting message:message];
    if (self.launchDeadline.timeIntervalSinceNow <= 0)
        [self cancelWithError:@"Контроллер не подтвердил живое приложение за 20 секунд. Запуск отменён; ожидаем завершения."];
}
- (void)openSetup {
    if (!self.recoveryEnabled) return;
    if ([@[@"needsCloseApplication", @"needsManualClose"] containsObject:self.setupState ?: @""]) {
        NSString *path = self.sessionApplicationPath ?: self.selectedApplicationURL.path;
        for (NSRunningApplication *application in NSWorkspace.sharedWorkspace.runningApplications) {
            NSDictionary *identity = QBApplicationIdentity(application.processIdentifier);
            if (QBApplicationValidIdentity(identity) && [identity[@"uid"] unsignedIntValue] == getuid() && path.length
                && [application.bundleURL.path.stringByResolvingSymlinksInPath isEqualToString:path]) {
                [application activateWithOptions:0]; break;
            }
        }
        [self publish:QBFilterStateNeedsSetup message:@"Закройте выбранное приложение вручную, затем повторите запуск или завершение сеанса."];
        return;
    }
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
}
- (void)openAccessibilitySettings {
    if (!self.recoveryEnabled) return;
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}
+ (NSDictionary *)selfTest {
    NSMutableArray *checks = [NSMutableArray array], *failures = [NSMutableArray array];
    void (^check)(NSString *, BOOL) = ^(NSString *name, BOOL passed) { [checks addObject:name]; if (!passed) [failures addObject:name]; };
    NSDictionary *identity = @{@"pid":@123, @"uid":@(getuid()), @"startSeconds":@100,
        @"startMicroseconds":@20, @"executablePath":@"/fixture/QuietBar"};
    NSDictionary *child = @{@"pid":@124, @"uid":@(getuid()), @"startSeconds":@101,
        @"startMicroseconds":@21, @"executablePath":@"/fixture/Example.app/Contents/MacOS/Example"};
    NSDictionary *valid = @{@"schema":@1, @"state":@"prepared", @"message":@"test", @"controllerPID":@123,
        @"controllerIdentity":identity, @"applicationIdentity":child, @"agentPID":@124, @"applicationPID":@124,
        @"applicationPath":@"/fixture/Example.app", @"screenAllowed":@YES, @"accessibilityAllowed":@NO,
        @"restorationConfirmed":@NO, @"captureVerified":@NO, @"indicatorVerified":@NO};
    check(@"shell arguments quoted literally", [QBApplicationQuote(@"a'b $`x`\n") isEqualToString:@"'a'\\''b $`x`\n'"]);
    check(@"complete status accepted", QBApplicationValidStatus(valid) != nil);
    check(@"non object status rejected", QBApplicationValidStatus(@[]) == nil);
    for (NSArray *fixture in @[@[@"schema", @YES], @[@"schema", @2], @[@"controllerPID", @"123"],
        @[@"controllerPID", @123.5], @[@"agentPID", @(-1)], @[@"applicationPID", @125],
        @[@"screenAllowed", @0.5], @[@"restorationConfirmed", @"true"], @[@"indicatorVerified", @YES],
        @[@"captureVerified", @YES], @[@"accessibilityAllowed", @YES], @[@"state", @"active"],
        @[@"applicationPath", @"/fixture/../Example.app"]]) {
        NSMutableDictionary *bad = [valid mutableCopy]; bad[fixture[0]] = fixture[1];
        check([NSString stringWithFormat:@"invalid %@ rejected (%@)", fixture[0], fixture[1]], QBApplicationValidStatus(bad) == nil);
    }
    NSMutableDictionary *missing = [valid mutableCopy]; [missing removeObjectForKey:@"applicationIdentity"];
    check(@"live child requires full identity", QBApplicationValidStatus(missing) == nil);
    NSMutableDictionary *restored = [valid mutableCopy]; restored[@"state"] = @"off"; restored[@"restorationConfirmed"] = @YES;
    check(@"restored status cannot retain live child PID", QBApplicationValidStatus(restored) == nil);
    NSMutableDictionary *emptyRecovery = [restored mutableCopy];
    emptyRecovery[@"applicationPath"] = @""; emptyRecovery[@"applicationPID"] = @0; emptyRecovery[@"agentPID"] = @0;
    [emptyRecovery removeObjectForKey:@"applicationIdentity"];
    check(@"empty recovery ACK is not a launch status", QBApplicationValidStatus(emptyRecovery) == nil);
    check(@"completed no-target recovery ACK accepted", QBApplicationCheckedStatus(emptyRecovery, YES) != nil);
    emptyRecovery[@"restorationConfirmed"] = @NO;
    check(@"unconfirmed no-target recovery rejected", QBApplicationCheckedStatus(emptyRecovery, YES) == nil);
    check(@"identity matches itself", QBApplicationIdentityMatches(identity, identity));
    for (NSArray *fixture in @[@[@"startSeconds", @101], @[@"startMicroseconds", @1000000],
        @[@"uid", @(-1)], @[@"pid", @YES], @[@"executablePath", @"/fixture/Other"]]) {
        NSMutableDictionary *other = [identity mutableCopy]; other[fixture[0]] = fixture[1];
        check([NSString stringWithFormat:@"changed identity %@ rejected", fixture[0]], !QBApplicationIdentityMatches(identity, other));
    }
    return @{@"passed":@(failures.count == 0), @"checks":checks, @"failures":failures,
        @"launchPerformed":@NO, @"serviceMutations":@0, @"preferenceMutations":@0,
        @"captureVerified":@NO, @"indicatorVerified":@NO};
}
- (void)dealloc {
    [_pollTimer invalidate];
    if (_recoveryEnabled && _cleanupPending && _sessionDirectory && QBApplicationPrivateDirectory(_sessionDirectory, NO))
        QBApplicationWrite([NSData data], [_sessionDirectory stringByAppendingPathComponent:@"stop"], 0600);
}
@end
