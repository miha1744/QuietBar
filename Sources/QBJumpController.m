#import "QBJumpController.h"
#import <ApplicationServices/ApplicationServices.h>
#import <CommonCrypto/CommonDigest.h>
#import <libproc.h>
#import <spawn.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <limits.h>
#import <math.h>

extern char **environ;

static NSString * const QBJumpExecutable = @"/Applications/Jump Desktop Connect.app/Contents/MacOS/JumpConnect";
static NSString * const QBJumpPlist = @"/Library/LaunchAgents/com.p5sys.jump.connect.agent.plist";
static NSString * const QBJumpLabel = @"com.p5sys.jump.connect.agent";
static NSString * const QBJumpRequirement = @"anchor apple generic and certificate leaf[subject.OU] = \"2HCKV38EEC\" and identifier \"com.p5sys.jump.connect\"";
static volatile sig_atomic_t QBJumpSignal = 0;

static void QBJumpHandleSignal(int value) { QBJumpSignal = value; }
static NSString *QBLegacyBase(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/QuietBar/LegacyJump"];
}
static NSString *QBUserJob(void) {
    return [NSString stringWithFormat:@"gui/%u/%@", getuid(), QBJumpLabel];
}
static NSString *QBUserDomain(void) { return [NSString stringWithFormat:@"gui/%u", getuid()]; }
static BOOL QBUUID(NSString *value) {
    return [value isKindOfClass:NSString.class] && [[NSUUID alloc] initWithUUIDString:value] != nil;
}
static BOOL QBInteger(id value, BOOL positive) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    double number = [value doubleValue];
    return isfinite(number) && number == [value longLongValue] && (positive ? number > 0 : number >= 0);
}
static BOOL QBHexHash(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] != 64) return NO;
    return [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
}
static BOOL QBPathShape(NSString *path, NSString *base) {
    if (![path isKindOfClass:NSString.class] || !path.isAbsolutePath) return NO;
    if (![path isEqualToString:path.stringByStandardizingPath]) return NO;
    return [path.stringByDeletingLastPathComponent isEqualToString:base] && QBUUID(path.lastPathComponent);
}
static BOOL QBPrivateDirectory(NSString *path, NSString **error) {
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode) ||
        info.st_uid != getuid() || (info.st_mode & 0077) != 0) {
        if (error) *error = @"Папка сеанса должна принадлежать текущему пользователю и быть закрыта для других пользователей.";
        return NO;
    }
    char resolved[PATH_MAX];
    if (!realpath(path.fileSystemRepresentation, resolved) ||
        ![path isEqualToString:[NSString stringWithUTF8String:resolved]]) {
        if (error) *error = @"Папка сеанса содержит символическую ссылку или недоступна.";
        return NO;
    }
    return YES;
}
static BOOL QBValidateDirectory(NSString *path, NSString **error) {
    if (!QBPathShape(path, QBLegacyBase())) {
        if (error) *error = @"Неверный путь сеанса Jump.";
        return NO;
    }
    return QBPrivateDirectory(QBLegacyBase(), error) && QBPrivateDirectory(path, error);
}
static NSDictionary *QBReadJSON(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != getuid() ||
        (info.st_mode & 0077) != 0 || info.st_size < 2 || info.st_size > 1024 * 1024) {
        close(fd); return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)info.st_size];
    NSUInteger position = 0;
    while (position < data.length) {
        ssize_t count = read(fd, (char *)data.mutableBytes + position, data.length - position);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { close(fd); return nil; }
        position += (NSUInteger)count;
    }
    close(fd);
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}
// Rename plus fsync makes the write-ahead journal durable before each takeover.
static BOOL QBWriteJSON(NSDictionary *value, NSString *directory, NSString *name) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    if (!data) return NO;
    NSString *template = [directory stringByAppendingPathComponent:@".quietbar-write-XXXXXX"];
    char *temporary = strdup(template.fileSystemRepresentation);
    int fd = mkstemp(temporary);
    if (fd < 0) { free(temporary); return NO; }
    BOOL success = fchmod(fd, 0600) == 0;
    NSUInteger position = 0;
    while (success && position < data.length) {
        ssize_t count = write(fd, (const char *)data.bytes + position, data.length - position);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { success = NO; break; }
        position += (NSUInteger)count;
    }
    if (success) success = fsync(fd) == 0;
    close(fd);
    if (success) success = rename(temporary, [directory stringByAppendingPathComponent:name].fileSystemRepresentation) == 0;
    if (!success) unlink(temporary);
    free(temporary);
    if (success) {
        int directoryFD = open(directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        success = directoryFD >= 0 && fsync(directoryFD) == 0;
        if (directoryFD >= 0) close(directoryFD);
    }
    return success;
}
static NSDictionary *QBProcessIdentity(pid_t pid) {
    struct proc_bsdinfo info = {0};
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (pid <= 1 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) ||
        proc_pidpath(pid, path, sizeof(path)) <= 0) return nil;
    return @{@"pid": @(pid), @"uid": @(info.pbi_uid), @"startSeconds": @(info.pbi_start_tvsec),
             @"startMicroseconds": @(info.pbi_start_tvusec), @"executablePath": [NSString stringWithUTF8String:path]};
}
static BOOL QBIdentityValid(NSDictionary *identity, NSString *executable) {
    return [identity isKindOfClass:NSDictionary.class] && QBInteger(identity[@"pid"], YES) &&
        [identity[@"pid"] longLongValue] > 1 && [identity[@"pid"] longLongValue] <= INT_MAX &&
        QBInteger(identity[@"uid"], NO) && [identity[@"uid"] unsignedIntValue] == getuid() &&
        QBInteger(identity[@"startSeconds"], YES) && QBInteger(identity[@"startMicroseconds"], NO) &&
        [identity[@"startMicroseconds"] unsignedLongLongValue] < 1000000 &&
        [identity[@"executablePath"] isEqualToString:executable];
}
static BOOL QBIdentitiesMatch(NSDictionary *a, NSDictionary *b) {
    if (![a isKindOfClass:NSDictionary.class] || ![b isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in @[@"pid", @"uid", @"startSeconds", @"startMicroseconds", @"executablePath"])
        if (!a[key] || ![a[key] isEqual:b[key]]) return NO;
    return YES;
}
static BOOL QBIdentityAlive(NSDictionary *identity) {
    return QBIdentitiesMatch(identity, QBProcessIdentity([identity[@"pid"] intValue]));
}
static NSString *QBCurrentExecutable(void) { return QBProcessIdentity(getpid())[@"executablePath"]; }
static BOOL QBPathExists(NSString *path) {
    struct stat info;
    return lstat(path.fileSystemRepresentation, &info) == 0;
}
static BOOL QBStopRequested(NSString *directory) {
    return QBPathExists([directory stringByAppendingPathComponent:@"stop"]);
}
// Recovery may run after the same app was moved. The old path need not exist,
// but it must still describe this app's Mach-O inside an ordinary .app bundle.
static BOOL QBHistoricalOwnerPath(NSString *path) {
    if (![path isKindOfClass:NSString.class] || !path.isAbsolutePath ||
        ![path isEqualToString:path.stringByStandardizingPath] ||
        [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
        ![path.lastPathComponent isEqualToString:QBCurrentExecutable().lastPathComponent]) return NO;
    NSString *macOS = path.stringByDeletingLastPathComponent;
    NSString *contents = macOS.stringByDeletingLastPathComponent;
    NSString *bundle = contents.stringByDeletingLastPathComponent;
    return [macOS.lastPathComponent isEqualToString:@"MacOS"] &&
        [contents.lastPathComponent isEqualToString:@"Contents"] &&
        [bundle.pathExtension.lowercaseString isEqualToString:@"app"];
}
static NSDictionary *QBOwnerMarker(NSString *directory, NSString *nonce, pid_t pid, BOOL historical, NSString **error) {
    NSDictionary *marker = QBReadJSON([directory stringByAppendingPathComponent:@"app-owner.json"]);
    NSDictionary *identity = @{@"pid": marker[@"ownerPID"] ?: @0,
                               @"uid": @(getuid()),
                               @"startSeconds": marker[@"ownerStartSeconds"] ?: @0,
                               @"startMicroseconds": marker[@"ownerStartMicroseconds"] ?: @0,
                               @"executablePath": marker[@"executablePath"] ?: @""};
    if (![marker[@"schema"] isEqual:@1] || !QBUUID(marker[@"nonce"]) ||
        (nonce && ![marker[@"nonce"] isEqualToString:nonce]) ||
        (pid > 0 && [marker[@"ownerPID"] intValue] != pid) ||
        (historical ? !QBHistoricalOwnerPath(identity[@"executablePath"]) : ![identity[@"executablePath"] isEqualToString:QBCurrentExecutable()]) ||
        !QBIdentityValid(identity, identity[@"executablePath"])) {
        if (error) *error = @"Не удалось подтвердить приложение, создавшее сеанс Jump.";
        return nil;
    }
    return @{@"identity": identity, @"nonce": marker[@"nonce"]};
}
static int QBGlobalLock(void) {
    NSString *path = [QBLegacyBase() stringByAppendingPathComponent:@"controller.lock"];
    int fd = open(path.fileSystemRepresentation, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    struct stat info;
    if (fd < 0) return -1;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != getuid() ||
        (info.st_mode & 0077) != 0 || flock(fd, LOCK_EX | LOCK_NB) != 0) {
        close(fd); return -1;
    }
    return fd;
}
static NSDictionary *QBCommand(NSString *executable, NSArray<NSString *> *arguments) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = arguments;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    NSError *error = nil;
    if (![task launchAndReturnError:&error])
        return @{@"code": @(-1), @"output": error.localizedDescription ?: @"launch failed", @"timedOut": @NO};
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:12];
    while (task.running && deadline.timeIntervalSinceNow > 0) [NSThread sleepForTimeInterval:0.05];
    BOOL timedOut = task.running;
    if (timedOut) {
        NSDictionary *identity = QBProcessIdentity(task.processIdentifier);
        [task terminate];
        NSDate *killDeadline = [NSDate dateWithTimeIntervalSinceNow:1];
        while (task.running && killDeadline.timeIntervalSinceNow > 0) [NSThread sleepForTimeInterval:0.05];
        if (task.running && QBIdentityAlive(identity)) kill(task.processIdentifier, SIGKILL);
    }
    [task waitUntilExit];
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return @{@"code": @(task.terminationStatus), @"output": output, @"timedOut": @(timedOut)};
}
static NSString *QBLineValue(NSString *output, NSString *key) {
    NSString *prefix = [key stringByAppendingString:@" = "];
    for (NSString *line in [output componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([trimmed hasPrefix:prefix]) return [trimmed substringFromIndex:prefix.length];
    }
    return nil;
}
static NSArray<NSString *> *QBPrintedArguments(NSString *output) {
    BOOL inside = NO;
    NSMutableArray *arguments = [NSMutableArray array];
    for (NSString *line in [output componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!inside) { if ([trimmed isEqualToString:@"arguments = {"]) inside = YES; continue; }
        if ([trimmed isEqualToString:@"}"]) return arguments;
        if (!trimmed.length) continue;
        if ([trimmed hasPrefix:@"["]) {
            NSRange separator = [trimmed rangeOfString:@"] = "];
            if (separator.location == NSNotFound) return nil;
            trimmed = [trimmed substringFromIndex:NSMaxRange(separator)];
        }
        [arguments addObject:trimmed];
    }
    return nil;
}
static NSDictionary *QBJobSnapshot(NSString **error) {
    NSDictionary *result = QBCommand(@"/bin/launchctl", @[@"print", QBUserJob()]);
    NSString *output = result[@"output"];
    if ([result[@"code"] intValue] != 0) {
        BOOL absent = ![result[@"timedOut"] boolValue] &&
            ([output rangeOfString:@"Could not find service" options:NSCaseInsensitiveSearch].location != NSNotFound ||
             [output rangeOfString:@"Could not find specified service" options:NSCaseInsensitiveSearch].location != NSNotFound);
        if (absent) return @{@"loaded": @NO, @"running": @NO};
        if (error) *error = @"Не удалось проверить пользовательский агент Jump.";
        return nil;
    }
    NSArray *expected = @[QBJumpExecutable, @"--minimized"];
    if (![QBLineValue(output, @"path") isEqualToString:QBJumpPlist] ||
        ![QBLineValue(output, @"program") isEqualToString:QBJumpExecutable] ||
        ![QBPrintedArguments(output) isEqualToArray:expected]) {
        if (error) *error = @"Регистрация пользовательского агента Jump отличается от поддерживаемой.";
        return nil;
    }
    NSString *pidText = QBLineValue(output, @"pid");
    pid_t pid = (pid_t)pidText.intValue;
    if (pid > 1 && !QBIdentityValid(QBProcessIdentity(pid), QBJumpExecutable)) {
        if (error) *error = @"Не удалось подтвердить запущенный процесс пользовательского агента Jump.";
        return nil;
    }
    return @{@"loaded": @YES, @"running": @(pid > 1), @"pid": @(MAX(pid, 0))};
}
static NSData *QBSourceData(NSString **error) {
    int fd = open(QBJumpPlist.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    struct stat info;
    if (fd < 0) { if (error) *error = @"Не найден штатный пользовательский агент Jump Desktop Connect."; return nil; }
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != 0 ||
        (info.st_mode & 0022) != 0 || info.st_size < 1 || info.st_size > 1024 * 1024) {
        close(fd); if (error) *error = @"Файл пользовательского агента Jump имеет неожиданного владельца или права."; return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)info.st_size];
    NSUInteger position = 0;
    while (position < data.length) {
        ssize_t count = read(fd, (char *)data.mutableBytes + position, data.length - position);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { close(fd); if (error) *error = @"Не удалось прочитать регистрацию Jump."; return nil; }
        position += (NSUInteger)count;
    }
    close(fd);
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];
    if (![plist isKindOfClass:NSDictionary.class] || ![plist[@"Label"] isEqualToString:QBJumpLabel] ||
        ![plist[@"ProgramArguments"] isEqualToArray:@[QBJumpExecutable, @"--minimized"]] ||
        (plist[@"Program"] && ![plist[@"Program"] isEqualToString:QBJumpExecutable]) ||
        plist[@"RootDirectory"] || plist[@"UserName"] || plist[@"GroupName"]) {
        if (error) *error = @"Настройки пользовательского агента Jump отличаются от поддерживаемых.";
        return nil;
    }
    return data;
}
static NSString *QBSHA256(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *result = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}
static BOOL QBSourceMatchesJournal(NSData *source, NSDictionary *journal) {
    return source && [QBSHA256(source) isEqualToString:journal[@"sourceSHA256"]];
}
static BOOL QBVerifyJump(NSString **error) {
    struct stat info;
    if (lstat(QBJumpExecutable.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode) ||
        (info.st_uid != 0 && info.st_uid != getuid()) || (info.st_mode & 0022) != 0) {
        if (error) *error = @"Установленный Jump Desktop Connect имеет неожиданный путь или права.";
        return NO;
    }
    NSDictionary *result = QBCommand(@"/usr/bin/codesign", @[@"--verify", @"--strict", @"-R", QBJumpRequirement, QBJumpExecutable]);
    if ([result[@"code"] intValue] != 0 || [result[@"timedOut"] boolValue]) {
        if (error) *error = @"Не удалось подтвердить подпись Phase Five Systems у Jump Desktop Connect.";
        return NO;
    }
    return YES;
}
static BOOL QBJournalValid(NSDictionary *journal, NSString *directory, NSString *ownerExecutable, NSString *nonce) {
    if (![journal isKindOfClass:NSDictionary.class] || ![journal[@"schema"] isEqual:@1] ||
        ![journal[@"stateDirectory"] isEqualToString:directory] || !QBUUID(journal[@"nonce"]) ||
        (nonce && ![journal[@"nonce"] isEqualToString:nonce]) ||
        ![journal[@"sourcePath"] isEqualToString:QBJumpPlist] || !QBHexHash(journal[@"sourceSHA256"]) ||
        ![journal[@"executablePath"] isEqualToString:QBJumpExecutable] ||
        !QBIdentityValid(journal[@"ownerIdentity"], ownerExecutable) ||
        !QBIdentityValid(journal[@"controllerIdentity"], ownerExecutable) ||
        [journal[@"ownerIdentity"][@"pid"] isEqual:journal[@"controllerIdentity"][@"pid"]] ||
        ![journal[@"originalLoaded"] isKindOfClass:NSNumber.class] ||
        ![journal[@"originalRunning"] isKindOfClass:NSNumber.class] ||
        ![journal[@"mutationStarted"] isKindOfClass:NSNumber.class] ||
        ![journal[@"registrationRestored"] isKindOfClass:NSNumber.class] ||
        ([journal[@"originalRunning"] boolValue] && ![journal[@"originalLoaded"] boolValue])) return NO;
    NSArray *phases = @[@"takeover-intent", @"spawn-intent", @"agent-suspended", @"active", @"restoring", @"restored"];
    if (![phases containsObject:journal[@"phase"] ?: @""] ||
        ([journal[@"registrationRestored"] boolValue] != [journal[@"phase"] isEqualToString:@"restored"]) ||
        (([journal[@"phase"] isEqualToString:@"active"] || [journal[@"phase"] isEqualToString:@"agent-suspended"]) && !journal[@"agentIdentity"])) return NO;
    id child = journal[@"agentIdentity"];
    if (child && (!QBIdentityValid(child, QBJumpExecutable) ||
                  [child[@"pid"] isEqual:journal[@"ownerIdentity"][@"pid"]] ||
                  [child[@"pid"] isEqual:journal[@"controllerIdentity"][@"pid"]])) return NO;
    return YES;
}
static BOOL QBWriteStatus(NSString *directory, NSString *state, NSString *message, NSDictionary *journal,
                          BOOL screen, BOOL accessibility, BOOL restored, NSString *restoreError) {
    NSDictionary *controllerIdentity = journal[@"controllerIdentity"] ?: QBProcessIdentity(getpid());
    NSMutableDictionary *status = [@{@"schema": @1, @"state": state, @"message": message ?: @"",
        @"controllerPID": journal[@"controllerIdentity"][@"pid"] ?: @(getpid()),
        @"agentPID": QBIdentityAlive(journal[@"agentIdentity"]) ? journal[@"agentIdentity"][@"pid"] : @0,
        @"screenAllowed": @(screen), @"accessibilityAllowed": @(accessibility),
        @"restorationConfirmed": @(restored), @"restoreError": restoreError ?: @"",
        @"indicatorVerified": @NO} mutableCopy];
    if (journal[@"nonce"]) status[@"nonce"] = journal[@"nonce"];
    status[@"controllerIdentity"] = controllerIdentity ?: @{};
    return QBWriteJSON(status, directory, @"status.json");
}
static BOOL QBTerminateOwnedChild(NSDictionary *identity, NSString **error) {
    if (!identity || !QBIdentityAlive(identity)) return YES;
    pid_t pid = [identity[@"pid"] intValue];
    if (kill(pid, SIGTERM) != 0 && errno != ESRCH) {
        if (error) *error = @"Не удалось остановить процесс Jump, созданный QuietBar."; return NO;
    }
    // A suspended child must be continued so that SIGTERM can be delivered.
    if (QBIdentityAlive(identity)) kill(pid, SIGCONT);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4];
    int status = 0;
    while (deadline.timeIntervalSinceNow > 0) {
        waitpid(pid, &status, WNOHANG);
        if (!QBIdentityAlive(identity)) return YES;
        [NSThread sleepForTimeInterval:0.05];
    }
    if (QBIdentityAlive(identity) && kill(pid, SIGKILL) != 0 && errno != ESRCH) {
        if (error) *error = @"Не удалось завершить процесс Jump, созданный QuietBar."; return NO;
    }
    deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (deadline.timeIntervalSinceNow > 0) {
        waitpid(pid, &status, WNOHANG);
        if (!QBIdentityAlive(identity)) return YES;
        [NSThread sleepForTimeInterval:0.05];
    }
    if (error) *error = @"Остановка процесса Jump пока не подтверждена.";
    return NO;
}
static BOOL QBRestore(NSMutableDictionary *journal, NSString *directory, NSString **error) {
    if (![journal[@"mutationStarted"] boolValue]) return YES;
    journal[@"phase"] = @"restoring";
    journal[@"registrationRestored"] = @NO;
    if (!QBWriteJSON(journal, directory, @"journal.json")) {
        if (error) *error = @"Не удалось сохранить журнал восстановления Jump."; return NO;
    }
    if (!QBTerminateOwnedChild(journal[@"agentIdentity"], error)) return NO;
    NSData *source = QBSourceData(error);
    if (!QBSourceMatchesJournal(source, journal)) {
        if (error && source) *error = @"Регистрация Jump изменилась. Автоматическое восстановление остановлено.";
        return NO;
    }
    if (!QBVerifyJump(error)) return NO;
    NSDictionary *snapshot = QBJobSnapshot(error);
    if (!snapshot) return NO;
    if ([journal[@"originalLoaded"] boolValue]) {
        if (![snapshot[@"loaded"] boolValue]) {
            // Only the recorded user-domain LaunchAgent may be registered.
            NSDictionary *result = QBCommand(@"/bin/launchctl", @[@"bootstrap", QBUserDomain(), QBJumpPlist]);
            snapshot = QBJobSnapshot(error);
            if (!snapshot || ![snapshot[@"loaded"] boolValue]) {
                if (error && !*error) *error = @"Не удалось восстановить регистрацию пользовательского агента Jump.";
                (void)result; return NO;
            }
        }
        if ([journal[@"originalRunning"] boolValue] && ![snapshot[@"running"] boolValue]) {
            NSDictionary *result = QBCommand(@"/bin/launchctl", @[@"kickstart", QBUserJob()]);
            if ([result[@"code"] intValue] != 0) {
                if (error) *error = @"Регистрация Jump восстановлена, но запуск прежнего агента не подтверждён.";
                return NO;
            }
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
            do {
                snapshot = QBJobSnapshot(error);
                if (!snapshot) return NO;
                if ([snapshot[@"running"] boolValue]) break;
                [NSThread sleepForTimeInterval:0.1];
            } while (deadline.timeIntervalSinceNow > 0);
            if (![snapshot[@"running"] boolValue]) {
                if (error) *error = @"Регистрация Jump восстановлена, но прежний агент не запустился.";
                return NO;
            }
        }
    } else if ([snapshot[@"loaded"] boolValue]) {
        if (error) *error = @"Во время сеанса регистрация Jump изменилась извне. Её состояние сохранено.";
        return NO;
    }
    journal[@"registrationRestored"] = @YES;
    journal[@"phase"] = @"restored";
    if (!QBWriteJSON(journal, directory, @"journal.json")) {
        if (error) *error = @"Агент восстановлен, но не удалось сохранить подтверждение восстановления.";
        return NO;
    }
    return YES;
}
static BOOL QBSpawnSuspended(NSString *directory, NSMutableDictionary *journal, NSString **error) {
    NSString *logPath = [directory stringByAppendingPathComponent:@"agent.log"];
    int logFD = open(logPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0600);
    struct stat info;
    if (logFD < 0 || fstat(logFD, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != getuid() || (info.st_mode & 0077) != 0) {
        if (logFD >= 0) close(logFD);
        if (error) *error = @"Не удалось создать закрытый журнал запуска Jump."; return NO;
    }
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int actionsResult = posix_spawn_file_actions_init(&actions);
    int attributesResult = posix_spawnattr_init(&attributes);
    if (actionsResult != 0 || attributesResult != 0) {
        if (actionsResult == 0) posix_spawn_file_actions_destroy(&actions);
        if (attributesResult == 0) posix_spawnattr_destroy(&attributes);
        close(logFD); if (error) *error = @"Не удалось подготовить безопасный запуск Jump."; return NO;
    }
    int configurationResult = posix_spawn_file_actions_adddup2(&actions, logFD, STDOUT_FILENO);
    if (!configurationResult) configurationResult = posix_spawn_file_actions_adddup2(&actions, logFD, STDERR_FILENO);
    if (!configurationResult && logFD != STDOUT_FILENO && logFD != STDERR_FILENO)
        configurationResult = posix_spawn_file_actions_addclose(&actions, logFD);
    // Inherit Terminal's normal responsibility. No responsibility disclamation.
    if (!configurationResult) configurationResult = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_START_SUSPENDED);
    char *arguments[] = {(char *)QBJumpExecutable.fileSystemRepresentation, "--minimized", NULL};
    pid_t child = 0;
    int result = configurationResult ?: posix_spawn(&child, QBJumpExecutable.fileSystemRepresentation, &actions, &attributes, arguments, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    close(logFD);
    if (result != 0) { if (error) *error = @"Не удалось запустить пользовательский агент Jump."; return NO; }
    NSDictionary *identity = QBProcessIdentity(child);
    if (!QBIdentityValid(identity, QBJumpExecutable)) {
        // This PID is still our unreaped, suspended posix_spawn child, so it cannot
        // have been recycled. Do not let an unjournaled process start capturing.
        kill(child, SIGKILL); waitpid(child, NULL, 0);
        if (error) *error = @"Не удалось подтвердить личность созданного процесса Jump."; return NO;
    }
    journal[@"agentIdentity"] = identity;
    journal[@"phase"] = @"agent-suspended";
    if (!QBWriteJSON(journal, directory, @"journal.json")) {
        QBTerminateOwnedChild(identity, nil);
        if (error) *error = @"Не удалось сохранить владельца процесса Jump. Запуск отменён."; return NO;
    }
    return YES;
}
static BOOL QBAutorunDisabled(NSString *directory) {
    NSString *path = [directory stringByAppendingPathComponent:@"agent.log"];
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return NO;
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != getuid() || info.st_size > 4 * 1024 * 1024) { close(fd); return NO; }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)MAX(info.st_size, 0)];
    ssize_t count = read(fd, data.mutableBytes, data.length);
    close(fd);
    if (count < 0) return NO;
    data.length = (NSUInteger)count;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"autorun is disabled[,\\s]+quitting" options:NSRegularExpressionCaseInsensitive error:nil];
    return [pattern firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] != nil;
}
static NSDictionary *QBRecoveryResult(NSString *state, NSString *message, BOOL recovered, BOOL restored) {
    BOOL busy = [state isEqualToString:@"checking"];
    return @{@"schema": @1, @"state": state, @"message": message ?: @"", @"recovered": @(recovered),
             @"restorationConfirmed": @(restored), @"busy": @(busy), @"active": @(busy)};
}

NSDictionary *QBRecoverJumpController(NSString *stateDirectory) {
    @autoreleasepool {
        NSString *error = nil;
        if (!QBValidateDirectory(stateDirectory, &error)) return QBRecoveryResult(@"error", error, NO, NO);
        // Even absent owner/journal files are checked under the controller's
        // global lock. A durable stop marker cancels any delayed launcher.
        int lock = QBGlobalLock();
        if (lock < 0) return QBRecoveryResult(@"checking", @"Другой контроллер Jump ещё работает.", NO, NO);
        NSString *journalPath = [stateDirectory stringByAppendingPathComponent:@"journal.json"];
        NSString *markerPath = [stateDirectory stringByAppendingPathComponent:@"app-owner.json"];
        NSDictionary *stored = QBReadJSON(journalPath);
        if (!stored && QBPathExists(journalPath)) {
            close(lock); return QBRecoveryResult(@"error", @"Журнал Jump повреждён или недоступен. Восстановление не подтверждено.", NO, NO);
        }
        NSDictionary *marker = QBOwnerMarker(stateDirectory, nil, 0, YES, &error);
        if (!marker && (stored || QBPathExists(markerPath))) {
            close(lock); return QBRecoveryResult(@"error", error, NO, NO);
        }
        if (!stored) {
            // No journal means no takeover crossed its durable write-ahead
            // boundary. This also covers interruption before owner creation.
            BOOL stopped = QBWriteJSON(@{@"schema": @1, @"cancelled": @YES}, stateDirectory, @"stop");
            BOOL written = stopped && QBWriteStatus(stateDirectory, @"off", @"Запуск отменён. Настройки Jump не менялись.", nil, CGPreflightScreenCaptureAccess(), AXIsProcessTrusted(), YES, nil);
            close(lock);
            return QBRecoveryResult(written ? @"off" : @"error", written ? @"Запуск отменён. Настройки Jump не менялись." : @"Не удалось сохранить подтверждение отмены Jump.", NO, written);
        }
        NSString *historicalExecutable = marker[@"identity"][@"executablePath"];
        if (!QBJournalValid(stored, stateDirectory, historicalExecutable, marker[@"nonce"]) ||
            !QBIdentitiesMatch(stored[@"ownerIdentity"], marker[@"identity"])) {
            close(lock); return QBRecoveryResult(@"error", @"Журнал сеанса Jump не прошёл проверку владельца.", NO, NO);
        }
        if (QBIdentityAlive(stored[@"controllerIdentity"])) {
            close(lock); return QBRecoveryResult(@"checking", @"Контроллер Jump ещё работает.", NO, NO);
        }
        // A completed journal records a past transaction. A later legitimate
        // Jump update must not cause that completed transaction to run again.
        if ([stored[@"registrationRestored"] boolValue] && !QBIdentityAlive(stored[@"agentIdentity"])) {
            BOOL written = QBWriteStatus(stateDirectory, @"off", @"Прежний запуск Jump уже восстановлен.", stored, CGPreflightScreenCaptureAccess(), AXIsProcessTrusted(), YES, nil);
            close(lock); return QBRecoveryResult(written ? @"off" : @"error", written ? @"Прежний запуск Jump уже восстановлен." : @"Не удалось сохранить подтверждение восстановления Jump.", NO, written);
        }
        NSMutableDictionary *journal = [stored mutableCopy];
        BOOL screen = CGPreflightScreenCaptureAccess(), accessibility = AXIsProcessTrusted();
        QBWriteStatus(stateDirectory, @"stopping", @"Восстанавливаем прежний запуск Jump…", journal, screen, accessibility, NO, nil);
        BOOL restored = QBRestore(journal, stateDirectory, &error);
        if (!QBWriteStatus(stateDirectory, restored ? @"off" : @"error", restored ? @"Прежний запуск Jump восстановлен." : @"Не удалось полностью восстановить Jump.", journal, screen, accessibility, restored, error)) {
            restored = NO; error = @"Не удалось сохранить подтверждение восстановления Jump.";
        }
        close(lock);
        NSMutableDictionary *result = [QBRecoveryResult(restored ? @"off" : @"error", restored ? @"Прежний запуск Jump восстановлен." : error, restored, restored) mutableCopy];
        result[@"restoreError"] = error ?: @"";
        return result;
    }
}

int QBRunJumpController(NSString *stateDirectory, pid_t ownerPID, NSString *nonce) {
    @autoreleasepool {
        NSString *error = nil;
        if (!QBUUID(nonce) || !QBValidateDirectory(stateDirectory, &error)) return 2;
        // Session directories are single use. A delayed duplicate launcher must
        // never overwrite an existing controller's status or recovery journal.
        NSString *journalPath = [stateDirectory stringByAppendingPathComponent:@"journal.json"];
        if (QBPathExists(journalPath)) return 2;
        int lock = QBGlobalLock();
        if (lock < 0) return 2;
        if (QBPathExists(journalPath)) { close(lock); return 2; }
        BOOL screen = CGPreflightScreenCaptureAccess(), accessibility = AXIsProcessTrusted();
        // Recovery can stop-cancel an interrupted directory before its owner
        // marker exists. A late launcher acknowledges it without any takeover.
        if (QBStopRequested(stateDirectory)) {
            QBWriteStatus(stateDirectory, @"off", @"Запуск отменён. Настройки Jump не менялись.", nil, screen, accessibility, YES, nil);
            close(lock); return 0;
        }
        NSDictionary *marker = QBOwnerMarker(stateDirectory, nonce, ownerPID, NO, &error);
        if (!marker) {
            QBWriteStatus(stateDirectory, @"error", error, nil, screen, accessibility, NO, @"Владелец сеанса не подтверждён.");
            close(lock); return 2;
        }
        if (!QBIdentityAlive(marker[@"identity"])) {
            QBWriteStatus(stateDirectory, @"off", @"Запуск отменён. Настройки Jump не менялись.", nil, screen, accessibility, YES, nil);
            close(lock); return 0;
        }
        QBJumpSignal = 0;
        struct sigaction action = {0}, oldTerm = {0}, oldInt = {0}, oldHup = {0}, oldChild = {0};
        action.sa_handler = QBJumpHandleSignal;
        sigemptyset(&action.sa_mask);
        sigaction(SIGTERM, &action, &oldTerm); sigaction(SIGINT, &action, &oldInt); sigaction(SIGHUP, &action, &oldHup);
        // Retain a kernel-owned child until waitpid; never inherit SIGCHLD ignore
        // semantics that could recycle its PID before identity journaling.
        struct sigaction childAction = {0}; childAction.sa_handler = SIG_DFL; sigemptyset(&childAction.sa_mask);
        sigaction(SIGCHLD, &childAction, &oldChild);
        sigset_t managedSignals, previousMask;
        sigemptyset(&managedSignals); sigaddset(&managedSignals, SIGTERM); sigaddset(&managedSignals, SIGINT); sigaddset(&managedSignals, SIGHUP);
        sigprocmask(SIG_UNBLOCK, &managedSignals, &previousMask);
        NSMutableDictionary *journal = nil;
        NSString *finalState = @"off", *finalMessage = @"Прежний запуск Jump восстановлен.";
        BOOL shouldRestore = NO;
        int returnCode = 0;
        @try {
            do {
                if (!QBWriteStatus(stateDirectory, @"checking", @"Проверяем разрешения и установленный Jump…", nil, screen, accessibility, YES, nil)) { returnCode = 2; break; }
                if (!screen) {
                    QBWriteStatus(stateDirectory, @"needsScreenPermission", @"Разрешите Terminal запись экрана в настройках macOS, затем повторите запуск.", nil, screen, accessibility, YES, nil);
                    // This is only the ordinary OS request; it never grants TCC.
                    if (!QBStopRequested(stateDirectory) && !QBJumpSignal && QBIdentityAlive(marker[@"identity"])) CGRequestScreenCaptureAccess();
                    returnCode = 3; break;
                }
                if (!accessibility) {
                    QBWriteStatus(stateDirectory, @"needsAccessibility", @"Разрешите Terminal универсальный доступ в настройках macOS, затем повторите запуск.", nil, screen, accessibility, YES, nil);
                    if (!QBStopRequested(stateDirectory) && !QBJumpSignal && QBIdentityAlive(marker[@"identity"])) {
                        NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
                        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
                    }
                    returnCode = 3; break;
                }
                if (QBPathExists([stateDirectory stringByAppendingPathComponent:@"journal.json"])) {
                    finalState = @"error"; finalMessage = @"Этот сеанс уже имеет журнал. Дождитесь восстановления и начните новый сеанс."; returnCode = 2; break;
                }
                NSData *source = QBSourceData(&error);
                if (!source || !QBVerifyJump(&error)) { finalState = @"error"; finalMessage = error; returnCode = 2; break; }
                if (QBStopRequested(stateDirectory) || QBJumpSignal || !QBIdentityAlive(marker[@"identity"])) break;
                NSDictionary *snapshot = QBJobSnapshot(&error);
                if (!snapshot) { finalState = @"error"; finalMessage = error; returnCode = 2; break; }
                if (QBStopRequested(stateDirectory) || QBJumpSignal || !QBIdentityAlive(marker[@"identity"])) break;
                journal = [@{@"schema": @1, @"stateDirectory": stateDirectory, @"nonce": nonce,
                    @"ownerIdentity": marker[@"identity"], @"controllerIdentity": QBProcessIdentity(getpid()),
                    @"sourcePath": QBJumpPlist, @"sourceSHA256": QBSHA256(source), @"executablePath": QBJumpExecutable,
                    @"originalLoaded": snapshot[@"loaded"], @"originalRunning": snapshot[@"running"],
                    @"mutationStarted": @YES, @"registrationRestored": @NO, @"phase": @"takeover-intent"} mutableCopy];
                if (!QBWriteJSON(journal, stateDirectory, @"journal.json")) {
                    journal = nil; finalState = @"error"; finalMessage = @"Не удалось сохранить журнал восстановления. Настройки Jump не менялись."; returnCode = 2; break;
                }
                shouldRestore = YES;
                if (QBStopRequested(stateDirectory) || QBJumpSignal || !QBIdentityAlive(marker[@"identity"])) break;
                // Recheck the immutable input immediately before the first job mutation.
                NSData *freshSource = QBSourceData(&error);
                if (!QBSourceMatchesJournal(freshSource, journal)) {
                    finalState = @"error"; finalMessage = @"Регистрация Jump изменилась до запуска. Сеанс отменён."; returnCode = 2; break;
                }
                if (!QBWriteStatus(stateDirectory, @"starting", @"Подготавливаем пользовательский агент Jump…", journal, screen, accessibility, NO, nil)) {
                    finalState = @"error"; finalMessage = @"Не удалось сохранить состояние запуска Jump."; returnCode = 2; break;
                }
                if (QBStopRequested(stateDirectory) || QBJumpSignal || !QBIdentityAlive(marker[@"identity"])) break;
                NSDictionary *justBefore = QBJobSnapshot(&error);
                if (!justBefore || ![justBefore[@"loaded"] isEqual:snapshot[@"loaded"]]) {
                    finalState = @"error"; finalMessage = error ?: @"Регистрация Jump изменилась до запуска. Сеанс отменён."; returnCode = 2; break;
                }
                if (QBStopRequested(stateDirectory) || QBJumpSignal || !QBIdentityAlive(marker[@"identity"])) break;
                if ([snapshot[@"loaded"] boolValue]) {
                    NSDictionary *result = QBCommand(@"/bin/launchctl", @[@"bootout", QBUserJob()]);
                    NSDictionary *after = QBJobSnapshot(&error);
                    if ([result[@"code"] intValue] != 0 || !after || [after[@"loaded"] boolValue]) {
                        finalState = @"error"; finalMessage = error ?: @"Не удалось временно остановить пользовательский агент Jump."; returnCode = 2; break;
                    }
                }
                journal[@"phase"] = @"spawn-intent";
                if (!QBWriteJSON(journal, stateDirectory, @"journal.json")) {
                    finalState = @"error"; finalMessage = @"Не удалось сохранить журнал запуска Jump."; returnCode = 2; break;
                }
                if (QBStopRequested(stateDirectory) || QBJumpSignal || !QBIdentityAlive(marker[@"identity"])) break;
                if (!QBSpawnSuspended(stateDirectory, journal, &error)) {
                    finalState = @"error"; finalMessage = error; returnCode = 2; break;
                }
                if (QBStopRequested(stateDirectory) || QBJumpSignal || !QBIdentityAlive(marker[@"identity"])) break;
                if (!QBIdentityAlive(journal[@"agentIdentity"]) || kill([journal[@"agentIdentity"][@"pid"] intValue], SIGCONT) != 0) {
                    finalState = @"error"; finalMessage = @"Не удалось продолжить запуск пользовательского агента Jump."; returnCode = 2; break;
                }
                journal[@"phase"] = @"active";
                if (!QBWriteJSON(journal, stateDirectory, @"journal.json")) {
                    finalState = @"error"; finalMessage = @"Не удалось сохранить состояние агента Jump."; returnCode = 2; break;
                }
                NSDate *preparedAt = [NSDate dateWithTimeIntervalSinceNow:4];
                BOOL prepared = NO;
                while (!QBStopRequested(stateDirectory) && !QBJumpSignal && QBIdentityAlive(marker[@"identity"])) {
                    int childStatus = 0;
                    pid_t exited = waitpid([journal[@"agentIdentity"][@"pid"] intValue], &childStatus, WNOHANG);
                    if (exited > 0 || !QBIdentityAlive(journal[@"agentIdentity"])) {
                        BOOL disabled = QBAutorunDisabled(stateDirectory);
                        finalState = disabled ? @"needsJumpAutostart" : @"error";
                        finalMessage = disabled ? @"Включите автоматический запуск в настройках Jump Desktop Connect и повторите попытку." : @"Пользовательский агент Jump завершился. Прежний запуск восстанавливается.";
                        returnCode = 4; break;
                    }
                    if (!prepared && preparedAt.timeIntervalSinceNow <= 0) {
                        // Prepared means the owned agent is alive. It is not an
                        // assertion about the macOS indicator or a Jump session.
                        if (!QBWriteStatus(stateDirectory, @"prepared", @"Агент Jump подготовлен. Проверьте подключение и индикатор на этом Mac.", journal, screen, accessibility, NO, nil)) {
                            finalState = @"error"; finalMessage = @"Не удалось сохранить состояние агента Jump."; returnCode = 2; break;
                        }
                        prepared = YES;
                    }
                    [NSThread sleepForTimeInterval:0.2];
                }
            } while (NO);
        } @catch (NSException *exception) {
            (void)exception; finalState = @"error"; finalMessage = @"Внутренняя ошибка контроллера Jump. Восстанавливаем прежний запуск."; returnCode = 2;
        }
        // Permission statuses remain visible unless that preflight was cancelled.
        if (returnCode == 3 && (QBStopRequested(stateDirectory) || QBJumpSignal || !QBIdentityAlive(marker[@"identity"]))) {
            returnCode = 0; finalState = @"off"; finalMessage = @"Запуск отменён. Настройки Jump не менялись.";
        }
        if (returnCode != 3) {
            BOOL restored = YES;
            NSString *restoreError = nil;
            if (shouldRestore) {
                QBWriteStatus(stateDirectory, @"stopping", @"Восстанавливаем прежний запуск Jump…", journal, screen, accessibility, NO, nil);
                restored = QBRestore(journal, stateDirectory, &restoreError);
            }
            if (!restored) {
                finalState = @"error"; finalMessage = @"Не удалось полностью восстановить прежний запуск Jump."; returnCode = 5;
            } else if (!shouldRestore && [finalState isEqualToString:@"off"]) {
                finalMessage = @"Запуск отменён. Настройки Jump не менялись.";
            }
            if (!QBWriteStatus(stateDirectory, finalState, finalMessage, journal, screen, accessibility, restored, restoreError)) returnCode = 5;
        }
        sigaction(SIGTERM, &oldTerm, NULL); sigaction(SIGINT, &oldInt, NULL); sigaction(SIGHUP, &oldHup, NULL);
        sigaction(SIGCHLD, &oldChild, NULL);
        sigprocmask(SIG_SETMASK, &previousMask, NULL);
        flock(lock, LOCK_UN); close(lock);
        return returnCode;
    }
}

NSDictionary *QBJumpControllerSelfTest(void) {
    @autoreleasepool {
        NSMutableArray<NSString *> *checks = [NSMutableArray array], *failures = [NSMutableArray array];
        void (^check)(NSString *, BOOL) = ^(NSString *name, BOOL passed) { [checks addObject:name]; if (!passed) [failures addObject:name]; };
        NSString *base = @"/fixture/Library/Application Support/QuietBar/LegacyJump";
        NSString *nonce = @"5999AAB0-D91F-4E4F-9659-44BE0E3977B1";
        NSString *directory = [base stringByAppendingPathComponent:nonce];
        check(@"UUID session path accepted", QBPathShape(directory, base));
        check(@"path traversal rejected", !QBPathShape([base stringByAppendingString:@"/../5999AAB0-D91F-4E4F-9659-44BE0E3977B1"], base));
        check(@"foreign parent rejected", !QBPathShape(directory, @"/other"));
        check(@"non UUID rejected", !QBPathShape([base stringByAppendingPathComponent:@"session"], base));
        NSDictionary *owner = @{@"pid": @12001, @"uid": @(getuid()), @"startSeconds": @1000, @"startMicroseconds": @42, @"executablePath": @"/fixture/QuietBar"};
        NSMutableDictionary *controller = [owner mutableCopy]; controller[@"pid"] = @12002;
        NSDictionary *child = @{@"pid": @12003, @"uid": @(getuid()), @"startSeconds": @1001, @"startMicroseconds": @7, @"executablePath": QBJumpExecutable};
        NSDictionary *journal = @{@"schema": @1, @"stateDirectory": directory, @"nonce": nonce,
            @"ownerIdentity": owner, @"controllerIdentity": controller, @"agentIdentity": child,
            @"sourcePath": QBJumpPlist, @"sourceSHA256": QBSHA256([@"fixture" dataUsingEncoding:NSUTF8StringEncoding]),
            @"executablePath": QBJumpExecutable, @"originalLoaded": @YES, @"originalRunning": @YES,
            @"mutationStarted": @YES, @"registrationRestored": @NO, @"phase": @"active"};
        check(@"valid recovery journal accepted", QBJournalValid(journal, directory, @"/fixture/QuietBar", nonce));
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:journal options:0 error:nil];
        NSDictionary *decoded = [NSJSONSerialization JSONObjectWithData:encoded options:0 error:nil];
        check(@"journal JSON round trip", QBJournalValid(decoded, directory, @"/fixture/QuietBar", nonce));
        check(@"nonce mismatch rejected", !QBJournalValid(journal, directory, @"/fixture/QuietBar", @"2C071AC0-A2CB-4645-B326-DB81534183DD"));
        check(@"owner executable mismatch rejected", !QBJournalValid(journal, directory, @"/fixture/OtherApp", nonce));
        NSMutableDictionary *bad = [journal mutableCopy]; bad[@"originalLoaded"] = @NO;
        check(@"impossible running snapshot rejected", !QBJournalValid(bad, directory, @"/fixture/QuietBar", nonce));
        bad = [journal mutableCopy]; bad[@"agentIdentity"] = owner;
        check(@"foreign child identity rejected", !QBJournalValid(bad, directory, @"/fixture/QuietBar", nonce));
        bad = [journal mutableCopy]; bad[@"sourceSHA256"] = @"wrong";
        check(@"malformed source hash rejected", !QBJournalValid(bad, directory, @"/fixture/QuietBar", nonce));
        check(@"unchanged source fixture accepted", QBSourceMatchesJournal([@"fixture" dataUsingEncoding:NSUTF8StringEncoding], journal));
        check(@"changed source fixture rejected", !QBSourceMatchesJournal([@"changed" dataUsingEncoding:NSUTF8StringEncoding], journal));
        bad = [journal mutableCopy]; bad[@"registrationRestored"] = @YES;
        check(@"restoration phase contradiction rejected", !QBJournalValid(bad, directory, @"/fixture/QuietBar", nonce));
        NSMutableDictionary *reused = [child mutableCopy]; reused[@"startMicroseconds"] = @8;
        check(@"reused PID rejected by start time", !QBIdentitiesMatch(child, reused));
        reused = [child mutableCopy]; reused[@"executablePath"] = @"/fixture/Unrelated";
        check(@"same PID foreign executable rejected", !QBIdentitiesMatch(child, reused));
        reused = [child mutableCopy]; reused[@"uid"] = @([child[@"uid"] unsignedIntValue] + 1);
        check(@"same PID foreign UID rejected", !QBIdentitiesMatch(child, reused));
        check(@"live self identity verified", QBIdentityAlive(QBProcessIdentity(getpid())));
        NSString *printFixture = [NSString stringWithFormat:@"service = {\n path = %@\n program = %@\n arguments = {\n %@\n --minimized\n }\n pid = 12003\n}\n", QBJumpPlist, QBJumpExecutable, QBJumpExecutable];
        check(@"launchctl argument fixture parsed exactly", [QBPrintedArguments(printFixture) isEqualToArray:@[QBJumpExecutable, @"--minimized"]]);
        check(@"unexpected argument not accepted", ![QBPrintedArguments([printFixture stringByReplacingOccurrencesOfString:@"--minimized" withString:@"--other"]) isEqualToArray:@[QBJumpExecutable, @"--minimized"]]);
        return @{@"passed": @(failures.count == 0), @"checks": checks, @"failures": failures,
                 @"serviceMutations": @0, @"preferenceMutations": @0, @"indicatorVerified": @NO};
    }
}
