#import "QBApplicationController.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CommonCrypto/CommonDigest.h>
#import <libproc.h>
#import <spawn.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <sys/xattr.h>
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <limits.h>
#import <math.h>

extern char **environ;
static volatile sig_atomic_t QAStopSignal = 0;
static void QAHandleSignal(int value) { QAStopSignal = value; }
static NSString *QABase(void) {
    return [[NSHomeDirectory() stringByResolvingSymlinksInPath]
        stringByAppendingPathComponent:@"Library/Application Support/QuietBar/Applications"];
}
static BOOL QAInteger(id value, BOOL positive) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    double number = [value doubleValue];
    return isfinite(number) && number == [value longLongValue] && (positive ? number > 0 : number >= 0);
}
static BOOL QAUUID(id value) {
    return [value isKindOfClass:NSString.class] && [[NSUUID alloc] initWithUUIDString:value] != nil;
}
static BOOL QAAbsolute(id value) {
    return [value isKindOfClass:NSString.class] && [value isAbsolutePath]
        && [value isEqualToString:[value stringByStandardizingPath]]
        && [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
static BOOL QAApplicationPath(id value) {
    return QAAbsolute(value) && [[value pathExtension].lowercaseString isEqualToString:@"app"];
}
static BOOL QASessionPath(NSString *path) {
    return QAAbsolute(path) && [path.stringByDeletingLastPathComponent isEqualToString:QABase()]
        && QAUUID(path.lastPathComponent);
}
static BOOL QAPrivateDirectory(NSString *path) {
    struct stat info;
    char resolved[PATH_MAX];
    return lstat(path.fileSystemRepresentation, &info) == 0 && S_ISDIR(info.st_mode)
        && info.st_uid == getuid() && (info.st_mode & 0077) == 0
        && realpath(path.fileSystemRepresentation, resolved)
        && [path isEqualToString:[NSString stringWithUTF8String:resolved]];
}
static BOOL QAValidateDirectory(NSString *path) {
    return QASessionPath(path) && QAPrivateDirectory(QABase()) && QAPrivateDirectory(path);
}
static NSDictionary *QAReadJSON(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != getuid()
        || (info.st_mode & 0077) != 0 || info.st_size < 2 || info.st_size > 1024 * 1024) {
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
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
// Durably record ownership before any suspended child is resumed.
static BOOL QAWriteJSON(NSDictionary *value, NSString *directory, NSString *name) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL];
    if (!data) return NO;
    char *temporary = strdup([directory stringByAppendingPathComponent:@".write-XXXXXX"].fileSystemRepresentation);
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
static BOOL QAExists(NSString *path) { struct stat info; return lstat(path.fileSystemRepresentation, &info) == 0; }
static BOOL QAStop(NSString *directory) { return QAStopSignal || QAExists([directory stringByAppendingPathComponent:@"stop"]); }
static NSDictionary *QAIdentity(pid_t pid) {
    struct proc_bsdinfo info = {0};
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (pid <= 1 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)
        || proc_pidpath(pid, path, sizeof(path)) <= 0) return nil;
    return @{@"pid":@(pid), @"uid":@(info.pbi_uid), @"startSeconds":@(info.pbi_start_tvsec),
        @"startMicroseconds":@(info.pbi_start_tvusec), @"executablePath":[NSString stringWithUTF8String:path]};
}
static BOOL QAValidIdentity(id value, NSString *executable) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *identity = value;
    return QAInteger(identity[@"pid"], YES) && [identity[@"pid"] longLongValue] > 1
        && [identity[@"pid"] longLongValue] <= INT_MAX && QAInteger(identity[@"uid"], NO)
        && [identity[@"uid"] unsignedLongLongValue] <= UINT_MAX && [identity[@"uid"] unsignedIntValue] == getuid() && QAInteger(identity[@"startSeconds"], YES)
        && QAInteger(identity[@"startMicroseconds"], NO) && [identity[@"startMicroseconds"] longLongValue] < 1000000
        && QAAbsolute(identity[@"executablePath"]) && [identity[@"executablePath"] isEqualToString:executable];
}
static BOOL QASameIdentity(NSDictionary *a, NSDictionary *b) {
    if (![a isKindOfClass:NSDictionary.class] || ![b isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in @[@"pid", @"uid", @"startSeconds", @"startMicroseconds", @"executablePath"])
        if (!a[key] || ![a[key] isEqual:b[key]]) return NO;
    return YES;
}
static BOOL QAAlive(NSDictionary *identity) { return QASameIdentity(identity, QAIdentity([identity[@"pid"] intValue])); }
static NSString *QACurrentExecutable(void) { return QAIdentity(getpid())[@"executablePath"]; }
static BOOL QAHistoricalOwnerPath(NSString *path) {
    if (!QAAbsolute(path) || ![path.lastPathComponent isEqualToString:QACurrentExecutable().lastPathComponent]) return NO;
    NSString *macOS = path.stringByDeletingLastPathComponent;
    NSString *contents = macOS.stringByDeletingLastPathComponent;
    return [macOS.lastPathComponent isEqualToString:@"MacOS"] && [contents.lastPathComponent isEqualToString:@"Contents"]
        && QAApplicationPath(contents.stringByDeletingLastPathComponent);
}
static NSDictionary *QAMarker(NSString *directory, NSString *nonce, pid_t ownerPID, BOOL historical) {
    NSDictionary *marker = QAReadJSON([directory stringByAppendingPathComponent:@"app-owner.json"]);
    NSString *executable = marker[@"executablePath"];
    NSDictionary *identity = @{@"pid":marker[@"ownerPID"] ?: @0, @"uid":@(getuid()),
        @"startSeconds":marker[@"ownerStartSeconds"] ?: @0, @"startMicroseconds":marker[@"ownerStartMicroseconds"] ?: @0,
        @"executablePath":executable ?: @""};
    if (![marker[@"schema"] isEqual:@1] || !QAUUID(marker[@"nonce"]) || !QAAbsolute(executable) || !QAApplicationPath(marker[@"applicationPath"])
        || (nonce && ![nonce isEqualToString:marker[@"nonce"]]) || (ownerPID > 0 && [marker[@"ownerPID"] intValue] != ownerPID)
        || !QAValidIdentity(identity, executable) || (historical ? !QAHistoricalOwnerPath(executable) : ![executable isEqualToString:QACurrentExecutable()])) return nil;
    return @{@"identity":identity, @"nonce":marker[@"nonce"], @"applicationPath":marker[@"applicationPath"]};
}
static int QALock(void) {
    int fd = open([QABase() stringByAppendingPathComponent:@"controller.lock"].fileSystemRepresentation,
        O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    struct stat info;
    if (fd < 0) return -1;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != getuid()
        || (info.st_mode & 0077) != 0 || flock(fd, LOCK_EX | LOCK_NB) != 0) { close(fd); return -1; }
    return fd;
}
static BOOL QATrustedMode(struct stat info) {
    return S_ISREG(info.st_mode) && (info.st_uid == 0 || info.st_uid == getuid()) && (info.st_mode & 0022) == 0;
}
static NSDictionary *QAExecutableSnapshot(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat before, after;
    if (fstat(fd, &before) != 0 || !QATrustedMode(before) || before.st_size < 4
        || access(path.fileSystemRepresentation, X_OK) != 0) { close(fd); return nil; }
    // A script would identify as its interpreter after spawn, leaving no exact
    // application identity to journal. Refuse it before creating any process.
    uint32_t magic = 0;
    if (pread(fd, &magic, sizeof(magic), 0) != sizeof(magic)
        || !(magic == 0xfeedface || magic == 0xcefaedfe || magic == 0xfeedfacf || magic == 0xcffaedfe
            || magic == 0xcafebabe || magic == 0xbebafeca || magic == 0xcafebabf || magic == 0xbfbafeca)) {
        close(fd); return nil;
    }
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    unsigned char buffer[65536];
    BOOL success = YES;
    for (;;) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { success = NO; break; }
        if (count == 0) break;
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    }
    success = success && fstat(fd, &after) == 0 && before.st_dev == after.st_dev && before.st_ino == after.st_ino
        && before.st_size == after.st_size && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
        && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec && QATrustedMode(after);
    close(fd);
    if (!success) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &context);
    NSMutableString *hash = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [hash appendFormat:@"%02x", digest[i]];
    return @{@"sha256":hash, @"device":@(after.st_dev), @"inode":@(after.st_ino), @"size":@(after.st_size),
        @"mtimeSeconds":@(after.st_mtimespec.tv_sec), @"mtimeNanoseconds":@(after.st_mtimespec.tv_nsec)};
}
static BOOL QAInsideBundle(NSString *executable, NSString *bundle) {
    return QAAbsolute(executable) && QAApplicationPath(bundle) && [executable hasPrefix:[bundle stringByAppendingString:@"/"]];
}
static NSDictionary *QAApplication(NSString *path, NSString **error) {
    struct stat info;
    char resolved[PATH_MAX];
    if (!QAApplicationPath(path) || !realpath(path.fileSystemRepresentation, resolved)
        || ![path isEqualToString:[NSString stringWithUTF8String:resolved]] || lstat(path.fileSystemRepresentation, &info) != 0
        || !S_ISDIR(info.st_mode) || (info.st_uid != 0 && info.st_uid != getuid()) || (info.st_mode & 0022) != 0) {
        if (error) *error = @"Выберите обычное приложение .app с безопасными правами доступа."; return nil;
    }
    NSBundle *bundle = [NSBundle bundleWithPath:path];
    NSString *identifier = bundle.bundleIdentifier;
    NSString *executable = bundle.executablePath.stringByResolvingSymlinksInPath;
    if (![identifier isKindOfClass:NSString.class] || !identifier.length
        || [identifier rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound
        || [identifier rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound
        || !QAInsideBundle(executable, path)) {
        if (error) *error = @"Не удалось подтвердить bundle ID и исполняемый файл выбранного приложения."; return nil;
    }
    NSDictionary *snapshot = QAExecutableSnapshot(executable);
    if (!snapshot) { if (error) *error = @"Исполняемый файл приложения недоступен или имеет небезопасные права."; return nil; }
    return @{@"applicationPath":path, @"bundleIdentifier":identifier, @"executablePath":executable, @"executableSnapshot":snapshot};
}
static BOOL QAGatekeeperAllows(NSDictionary *application) {
    NSString *path = application[@"applicationPath"], *executable = application[@"executablePath"];
    BOOL quarantined = NO;
    for (NSString *candidate in @[path, executable]) {
        ssize_t size = getxattr(candidate.fileSystemRepresentation, "com.apple.quarantine", NULL, 0, 0, XATTR_NOFOLLOW);
        if (size >= 0) quarantined = YES;
        else if (errno != ENOATTR) return NO; // An unreadable attribute is not proof of absence.
    }
    if (!quarantined) return YES;
    NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/spctl"];
    task.arguments = @[@"--assess", @"--type", @"execute", path];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice; task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:NULL]) return NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:12];
    while (task.running && deadline.timeIntervalSinceNow > 0) [NSThread sleepForTimeInterval:0.05];
    if (task.running) { [task terminate]; return NO; }
    return task.terminationStatus == 0;
}
static BOOL QAAlreadyRunning(NSDictionary *application) {
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications)
        if ([app.bundleIdentifier isEqualToString:application[@"bundleIdentifier"]]
            || [app.bundleURL.path.stringByResolvingSymlinksInPath isEqualToString:application[@"applicationPath"]]) return YES;
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (bytes <= 0) return YES; // Failure cannot establish a cold launch.
    size_t capacity = (size_t)bytes + 4096 * sizeof(pid_t);
    pid_t *pids = calloc(1, capacity);
    if (!pids) return YES;
    int actual = proc_listpids(PROC_ALL_PIDS, 0, pids, (int)capacity);
    BOOL found = actual <= 0 || (size_t)actual >= capacity;
    for (int i = 0; !found && i < actual / (int)sizeof(pid_t); i++) {
        NSDictionary *identity = QAIdentity(pids[i]);
        if ([identity[@"executablePath"] isEqualToString:application[@"executablePath"]]) found = YES;
    }
    free(pids); return found;
}
static BOOL QAHash(id value) {
    return [value isKindOfClass:NSString.class] && [value length] == 64
        && [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
}
static BOOL QAValidSnapshot(id value) {
    if (![value isKindOfClass:NSDictionary.class] || !QAHash(value[@"sha256"])) return NO;
    for (NSString *key in @[@"device", @"inode", @"size", @"mtimeSeconds", @"mtimeNanoseconds"])
        if (!QAInteger(value[key], NO)) return NO;
    return [value[@"mtimeNanoseconds"] longLongValue] < 1000000000;
}
static BOOL QAValidJournal(NSDictionary *journal, NSString *directory, NSDictionary *marker) {
    if (![journal isKindOfClass:NSDictionary.class] || ![journal[@"schema"] isEqual:@1]
        || ![journal[@"stateDirectory"] isEqualToString:directory] || ![journal[@"nonce"] isEqual:marker[@"nonce"]]
        || ![journal[@"applicationPath"] isEqual:marker[@"applicationPath"]]
        || !QAInsideBundle(journal[@"executablePath"], journal[@"applicationPath"])
        || !QASameIdentity(journal[@"ownerIdentity"], marker[@"identity"])
        || !QAValidIdentity(journal[@"controllerIdentity"], marker[@"identity"][@"executablePath"])
        || [journal[@"controllerIdentity"][@"pid"] isEqual:journal[@"ownerIdentity"][@"pid"]]
        || !QAValidSnapshot(journal[@"executableSnapshot"])
        || ![@[@"spawn-intent", @"application-suspended", @"active", @"stopping", @"finished"] containsObject:journal[@"phase"] ?: @""]) return NO;
    NSDictionary *child = journal[@"applicationIdentity"];
    if (child && (!QAValidIdentity(child, journal[@"executablePath"])
        || [child[@"pid"] isEqual:journal[@"ownerIdentity"][@"pid"]]
        || [child[@"pid"] isEqual:journal[@"controllerIdentity"][@"pid"]])) return NO;
    if ([@[@"application-suspended", @"active", @"stopping"] containsObject:journal[@"phase"]] && !child) return NO;
    return YES;
}
static NSDictionary *QAStatus(NSString *state, NSString *message, NSDictionary *journal, NSDictionary *marker, BOOL restored) {
    NSDictionary *controller = journal[@"controllerIdentity"] ?: QAIdentity(getpid());
    NSDictionary *child = journal[@"applicationIdentity"];
    pid_t pid = QAAlive(child) ? [child[@"pid"] intValue] : 0;
    NSMutableDictionary *value = [@{@"schema":@1, @"state":state, @"message":message ?: @"",
        @"controllerIdentity":controller ?: @{}, @"controllerPID":controller[@"pid"] ?: @(getpid()),
        @"agentPID":@(pid), @"applicationPID":@(pid), @"applicationPath":marker[@"applicationPath"] ?: @"",
        @"screenAllowed":@(CGPreflightScreenCaptureAccess()), @"accessibilityAllowed":@NO,
        @"restorationConfirmed":@(restored), @"captureVerified":@NO, @"indicatorVerified":@NO,
        @"busy":@NO, @"active":@NO, @"recovered":@NO} mutableCopy];
    if (marker[@"nonce"]) value[@"nonce"] = marker[@"nonce"];
    if (child) value[@"applicationIdentity"] = child;
    return value;
}
static BOOL QAPublish(NSString *directory, NSString *state, NSString *message, NSDictionary *journal, NSDictionary *marker, BOOL restored) {
    return QAWriteJSON(QAStatus(state, message, journal, marker, restored), directory, @"status.json");
}
// Only this process's exact, unreaped child, before its first SIGCONT, may be
// discarded forcibly. It has never executed application code or opened documents.
// Recovery never calls this function or infers this condition from journal flags.
static BOOL QARollbackAllowed(NSDictionary *expected, NSDictionary *actual, BOOL resumed, pid_t parentPID, pid_t controllerPID) {
    return !resumed && parentPID == controllerPID && controllerPID == getpid()
        && QAValidIdentity(expected, expected[@"executablePath"]) && QASameIdentity(expected, actual);
}
static BOOL QARollbackSuspended(NSDictionary *identity) {
    pid_t child = [identity[@"pid"] intValue];
    int status = 0;
    pid_t result = waitpid(child, &status, WNOHANG);
    if (result == child) return YES;
    if (result != 0) return NO; // ECHILD means that kernel-owned relationship is gone.
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(child, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)
        || !QARollbackAllowed(identity, QAIdentity(child), NO, info.pbi_ppid, getpid())) return NO;
    if (kill(child, SIGKILL) != 0 && errno != ESRCH) return NO;
    do { result = waitpid(child, &status, 0); } while (result < 0 && errno == EINTR);
    return result == child;
}
// 1: journaled suspended child; 0: no child created; -1: ownership/rollback unresolved;
// -2: an unstarted child was safely rolled back after journal failure.
static int QASpawn(NSString *directory, NSMutableDictionary *journal) {
    posix_spawnattr_t attributes;
    if (posix_spawnattr_init(&attributes) != 0) return 0;
    int result = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_START_SUSPENDED);
    NSString *executable = journal[@"executablePath"];
    char *arguments[] = {(char *)executable.fileSystemRepresentation, NULL};
    pid_t child = 0;
    if (!result) result = posix_spawn(&child, executable.fileSystemRepresentation, NULL, &attributes, arguments, environ);
    posix_spawnattr_destroy(&attributes);
    if (result != 0) return 0;
    NSDictionary *identity = QAIdentity(child);
    if (!QAValidIdentity(identity, executable)) {
        // The unreaped suspended child is kernel-owned and has never executed user code.
        // Do not guess ownership or resume it if identity cannot be established.
        return -1;
    }
    journal[@"applicationIdentity"] = identity; journal[@"phase"] = @"application-suspended";
    if (QAWriteJSON(journal, directory, @"journal.json")) return 1;
    return QARollbackSuspended(identity) ? -2 : -1;
}
static BOOL QAGracefulQuit(NSDictionary *identity) {
    if (!QAAlive(identity)) return YES;
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:[identity[@"pid"] intValue]];
    return app && QAAlive(identity) && [app terminate];
}

NSDictionary *QBRecoverApplicationController(NSString *stateDirectory) {
    @autoreleasepool {
        if (!QAValidateDirectory(stateDirectory)) return QAStatus(@"error", @"Неверный или небезопасный каталог сеанса приложения.", nil, nil, NO);
        int lock = QALock();
        if (lock < 0) {
            NSMutableDictionary *busy = [QAStatus(@"checking", @"Контроллер приложения ещё работает.", nil, nil, NO) mutableCopy];
            busy[@"busy"] = @YES; busy[@"active"] = @YES; return busy;
        }
        NSDictionary *marker = QAMarker(stateDirectory, nil, 0, YES);
        NSString *journalPath = [stateDirectory stringByAppendingPathComponent:@"journal.json"];
        NSDictionary *journal = QAReadJSON(journalPath);
        NSDictionary *result;
        if (!QAExists(journalPath)) {
            BOOL written = QAWriteJSON(@{}, stateDirectory, @"stop")
                && QAPublish(stateDirectory, @"off", @"Запуск отменён. Настройки других приложений не менялись.", nil, marker, YES);
            result = QAStatus(written ? @"off" : @"error", written ? @"Запуск отменён." : @"Не удалось подтвердить отмену запуска.", nil, marker, written);
        } else if (!marker || !QAValidJournal(journal, stateDirectory, marker)) {
            result = QAStatus(@"error", @"Журнал приложения повреждён или не прошёл проверку владельца. Автоматические действия остановлены.", nil, marker, NO);
        } else if (QAAlive(journal[@"controllerIdentity"])) {
            NSMutableDictionary *busy = [QAStatus(@"checking", @"Контроллер приложения ещё работает.", journal, marker, NO) mutableCopy];
            busy[@"busy"] = @YES; busy[@"active"] = @YES; result = busy;
        } else if (QAAlive(journal[@"applicationIdentity"])) {
            result = QAStatus(@"needsManualClose", @"Завершите выбранное приложение вручную. Восстановление сеанса пока не подтверждено.", journal, marker, NO);
            QAWriteJSON(result, stateDirectory, @"status.json");
        } else if ([journal[@"phase"] isEqualToString:@"spawn-intent"]) {
            result = QAStatus(@"error", @"Запуск прервался до записи личности процесса. Завершение созданного процесса нельзя подтвердить автоматически.", journal, marker, NO);
        } else {
            NSMutableDictionary *finished = [journal mutableCopy]; finished[@"phase"] = @"finished";
            BOOL written = QAWriteJSON(finished, stateDirectory, @"journal.json")
                && QAPublish(stateDirectory, @"off", @"Созданный процесс завершён. Настройки других приложений не менялись.", finished, marker, YES);
            result = QAStatus(written ? @"off" : @"error", written ? @"Сеанс завершён." : @"Не удалось сохранить завершение сеанса.", finished, marker, written);
        }
        NSMutableDictionary *answer = [result mutableCopy]; answer[@"recovered"] = answer[@"restorationConfirmed"];
        flock(lock, LOCK_UN); close(lock); return answer;
    }
}

int QBRunApplicationController(NSString *stateDirectory, pid_t ownerPID, NSString *nonce) {
    @autoreleasepool {
        if (!QAUUID(nonce) || !QAValidateDirectory(stateDirectory)) return 2;
        int lock = QALock(); if (lock < 0) return 2;
        if (QAExists([stateDirectory stringByAppendingPathComponent:@"journal.json"])) { close(lock); return 2; }
        NSDictionary *marker = QAMarker(stateDirectory, nonce, ownerPID, NO);
        if (!marker) { QAPublish(stateDirectory, @"error", @"Не удалось подтвердить владельца запуска.", nil, nil, NO); close(lock); return 2; }
        QAStopSignal = 0;
        if (QAStop(stateDirectory) || !QAAlive(marker[@"identity"])) {
            QAPublish(stateDirectory, @"off", @"Запуск отменён.", nil, marker, YES); close(lock); return 0;
        }
        struct sigaction action = {0}, oldTerm, oldInt, oldHup, oldChild;
        action.sa_handler = QAHandleSignal; sigemptyset(&action.sa_mask);
        sigaction(SIGTERM, &action, &oldTerm); sigaction(SIGINT, &action, &oldInt); sigaction(SIGHUP, &action, &oldHup);
        struct sigaction childAction = {0}; childAction.sa_handler = SIG_DFL; sigemptyset(&childAction.sa_mask);
        sigaction(SIGCHLD, &childAction, &oldChild);
        sigset_t managed, oldMask; sigemptyset(&managed); sigaddset(&managed, SIGTERM); sigaddset(&managed, SIGINT); sigaddset(&managed, SIGHUP);
        sigprocmask(SIG_UNBLOCK, &managed, &oldMask);
        NSMutableDictionary *journal = nil;
        NSString *state = @"off", *message = @"Запуск отменён.";
        BOOL restored = YES;
        int code = 0;
        @try {
            do {
                if (!QAPublish(stateDirectory, @"checking", @"Проверяем выбранное приложение и разрешение записи экрана…", nil, marker, YES)) { code = 2; break; }
                if (!CGPreflightScreenCaptureAccess()) {
                    state = @"needsScreenPermission"; message = @"Разрешите Terminal запись экрана в настройках macOS, затем повторите запуск.";
                    QAPublish(stateDirectory, state, message, nil, marker, YES);
                    if (!QAStop(stateDirectory) && QAAlive(marker[@"identity"])) CGRequestScreenCaptureAccess();
                    code = 3; break;
                }
                NSString *error = nil;
                NSDictionary *application = QAApplication(marker[@"applicationPath"], &error);
                if (!application) { state = @"error"; message = error; code = 2; break; }
                if (!QAGatekeeperAllows(application)) {
                    state = @"error"; message = @"macOS ещё не разрешила открытие приложения. Откройте его через Finder и подтвердите обычный запуск, затем закройте и выберите снова."; code = 3; break;
                }
                if (QAAlreadyRunning(application)) { state = @"needsCloseApplication"; message = @"Сначала полностью завершите выбранное приложение, затем повторите запуск через QuietBar."; code = 3; break; }
                if (QAStop(stateDirectory) || !QAAlive(marker[@"identity"])) break;
                NSDictionary *fresh = QAApplication(marker[@"applicationPath"], &error);
                if (![application isEqualToDictionary:fresh]) { state = @"error"; message = @"Приложение изменилось во время проверки. Выберите его заново."; code = 2; break; }
                if (QAAlreadyRunning(fresh)) { state = @"needsCloseApplication"; message = @"Выбранное приложение уже запускается. Полностью завершите его и повторите запуск."; code = 3; break; }
                journal = [@{@"schema":@1, @"stateDirectory":stateDirectory, @"nonce":nonce,
                    @"ownerIdentity":marker[@"identity"], @"controllerIdentity":QAIdentity(getpid()),
                    @"applicationPath":application[@"applicationPath"], @"executablePath":application[@"executablePath"],
                    @"bundleIdentifier":application[@"bundleIdentifier"], @"executableSnapshot":application[@"executableSnapshot"], @"phase":@"spawn-intent"} mutableCopy];
                if (!QAWriteJSON(journal, stateDirectory, @"journal.json")) { journal = nil; state = @"error"; message = @"Не удалось сохранить журнал запуска."; code = 2; break; }
                restored = NO;
                if (QAStop(stateDirectory) || !QAAlive(marker[@"identity"])) { restored = YES; break; }
                QAPublish(stateDirectory, @"starting", @"Запускаем выбранное приложение…", journal, marker, NO);
                int spawnResult = QASpawn(stateDirectory, journal);
                if (spawnResult != 1) {
                    restored = spawnResult == 0 || spawnResult == -2;
                    state = @"error";
                    message = restored ? @"Не удалось запустить приложение. Пользовательский код не запускался; созданный приостановленный процесс отменён."
                        : @"Не удалось безопасно запустить приложение. Возможный приостановленный процесс требует ручной проверки.";
                    code = 2; break;
                }
                NSDictionary *child = journal[@"applicationIdentity"];
                if (![QAExecutableSnapshot(application[@"executablePath"]) isEqual:application[@"executableSnapshot"]]) {
                    restored = QARollbackSuspended(child); state = restored ? @"error" : @"needsManualClose";
                    message = restored ? @"Приложение изменилось при запуске. Запуск отменён до выполнения пользовательского кода."
                        : @"Приложение изменилось при запуске. Созданный процесс не продолжен; проверьте его завершение вручную."; code = 2; break;
                }
                if (QAStop(stateDirectory) || !QAAlive(marker[@"identity"])) {
                    restored = QARollbackSuspended(child); state = restored ? @"off" : @"needsManualClose";
                    message = restored ? @"Запуск отменён до выполнения пользовательского кода." : @"Не удалось подтвердить отмену приостановленного процесса."; break;
                }
                // Ordinary responsibility is inherited; no LaunchServices or disclamation.
                if (!QAAlive(child) || kill([child[@"pid"] intValue], SIGCONT) != 0) {
                    restored = !QAAlive(child) || QARollbackSuspended(child); state = restored ? @"error" : @"needsManualClose";
                    message = @"Не удалось продолжить созданный процесс. Проверьте его завершение вручную."; code = 2; break;
                }
                journal[@"phase"] = @"active";
                if (!QAWriteJSON(journal, stateDirectory, @"journal.json")) { state = @"error"; message = @"Не удалось сохранить состояние запущенного приложения."; code = 2; }
                NSDate *preparedAt = [NSDate dateWithTimeIntervalSinceNow:4];
                NSDate *quitDeadline = nil;
                BOOL prepared = NO, quitRequested = NO;
                while (QAAlive(child)) {
                    int childStatus = 0;
                    if (waitpid([child[@"pid"] intValue], &childStatus, WNOHANG) > 0) break;
                    if ((code || QAStop(stateDirectory) || !QAAlive(marker[@"identity"])) && !quitRequested) {
                        quitRequested = YES; quitDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
                        journal[@"phase"] = @"stopping"; QAWriteJSON(journal, stateDirectory, @"journal.json");
                        QAPublish(stateDirectory, @"stopping", @"Просим выбранное приложение завершиться. Сохраните открытые документы.", journal, marker, NO);
                        QAGracefulQuit(child);
                    }
                    if (quitRequested && quitDeadline && quitDeadline.timeIntervalSinceNow <= 0) {
                        QAPublish(stateDirectory, @"needsManualClose", @"Завершите выбранное приложение вручную. QuietBar не закрывает его принудительно.", journal, marker, NO);
                        quitDeadline = nil;
                    } else if (!prepared && !quitRequested && preparedAt.timeIntervalSinceNow <= 0) {
                        if (!QAPublish(stateDirectory, @"prepared", @"Приложение запущено. Проверьте захват и отсутствие значка на этом Mac; запуск сам по себе не подтверждает скрытие.", journal, marker, NO)) code = 2;
                        prepared = YES;
                    }
                    [NSThread sleepForTimeInterval:0.2];
                }
                waitpid([child[@"pid"] intValue], NULL, WNOHANG);
                restored = !QAAlive(child);
                state = @"off"; message = @"Созданный процесс завершён. Настройки других приложений не менялись.";
            } while (NO);
        } @catch (NSException *exception) {
            (void)exception; state = @"error"; message = @"Ошибка контроллера приложения. Проверьте выбранное приложение вручную.";
            restored = !journal; code = 2;
        }
        if (journal && restored) { journal[@"phase"] = @"finished"; if (!QAWriteJSON(journal, stateDirectory, @"journal.json")) restored = NO; }
        if (!QAPublish(stateDirectory, state, message, journal, marker, restored)) code = 2;
        sigaction(SIGTERM, &oldTerm, NULL); sigaction(SIGINT, &oldInt, NULL); sigaction(SIGHUP, &oldHup, NULL); sigaction(SIGCHLD, &oldChild, NULL);
        sigprocmask(SIG_SETMASK, &oldMask, NULL); flock(lock, LOCK_UN); close(lock); return code;
    }
}

NSDictionary *QBApplicationControllerSelfTest(void) {
    NSMutableArray *checks = [NSMutableArray array], *failures = [NSMutableArray array];
    void (^check)(NSString *, BOOL) = ^(NSString *name, BOOL passed) { [checks addObject:name]; if (!passed) [failures addObject:name]; };
    NSString *uuid = @"173A1A38-1490-4A73-A3CD-56871734B104";
    NSString *directory = [QABase() stringByAppendingPathComponent:uuid];
    check(@"canonical session path", QASessionPath(directory));
    check(@"reject path traversal", !QASessionPath([QABase() stringByAppendingPathComponent:[@"../Applications/" stringByAppendingString:uuid]]));
    check(@"reject non-UUID session", !QASessionPath([QABase() stringByAppendingPathComponent:@"session"]));
    check(@"reject relative application", !QAApplicationPath(@"Example.app"));
    check(@"reject control character path", !QAApplicationPath(@"/Applications/Bad\n.app"));
    check(@"reject executable escape", !QAInsideBundle(@"/Applications/Other.app/Contents/MacOS/Other", @"/Applications/Example.app"));
    check(@"reject sibling prefix", !QAInsideBundle(@"/Applications/Example.app.backup/main", @"/Applications/Example.app"));
    NSString *ownerPath = @"/Applications/QuietBar.app/Contents/MacOS/QuietBar";
    NSString *application = @"/Applications/Example.app", *executable = @"/Applications/Example.app/Contents/MacOS/Example";
    NSDictionary *owner = @{@"pid":@123, @"uid":@(getuid()), @"startSeconds":@100, @"startMicroseconds":@200, @"executablePath":ownerPath};
    NSDictionary *controller = @{@"pid":@124, @"uid":@(getuid()), @"startSeconds":@101, @"startMicroseconds":@200, @"executablePath":ownerPath};
    NSDictionary *child = @{@"pid":@125, @"uid":@(getuid()), @"startSeconds":@102, @"startMicroseconds":@200, @"executablePath":executable};
    check(@"valid owned identity", QAValidIdentity(child, executable));
    NSMutableDictionary *badIdentity = [child mutableCopy]; badIdentity[@"uid"] = @(getuid()+1);
    check(@"reject other UID", !QAValidIdentity(badIdentity, executable));
    badIdentity = [child mutableCopy]; badIdentity[@"startMicroseconds"] = @1000000;
    check(@"reject invalid start time", !QAValidIdentity(badIdentity, executable));
    badIdentity = [child mutableCopy]; badIdentity[@"startSeconds"] = @103;
    check(@"reject PID reuse", !QASameIdentity(child, badIdentity));
    NSDictionary *marker = @{@"identity":owner, @"nonce":uuid, @"applicationPath":application};
    NSDictionary *journal = @{@"schema":@1, @"stateDirectory":directory, @"nonce":uuid, @"ownerIdentity":owner,
        @"controllerIdentity":controller, @"applicationPath":application, @"executablePath":executable,
        @"executableSnapshot":@{@"sha256":[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0],
            @"device":@1, @"inode":@2, @"size":@100, @"mtimeSeconds":@100, @"mtimeNanoseconds":@0},
        @"applicationIdentity":child, @"phase":@"active"};
    check(@"valid active journal", QAValidJournal(journal, directory, marker));
    NSMutableDictionary *bad = [journal mutableCopy]; bad[@"nonce"] = NSUUID.UUID.UUIDString;
    check(@"reject foreign nonce", !QAValidJournal(bad, directory, marker));
    bad = [journal mutableCopy]; bad[@"applicationIdentity"] = owner;
    check(@"reject owner as child", !QAValidJournal(bad, directory, marker));
    bad = [journal mutableCopy]; [bad removeObjectForKey:@"applicationIdentity"];
    check(@"reject active without child", !QAValidJournal(bad, directory, marker));
    bad = [journal mutableCopy]; bad[@"phase"] = @"unknown";
    check(@"reject unknown journal phase", !QAValidJournal(bad, directory, marker));
    bad = [journal mutableCopy]; bad[@"executableSnapshot"] = @"bad";
    check(@"reject malformed snapshot type", !QAValidJournal(bad, directory, marker));
    check(@"allow exact unstarted child rollback", QARollbackAllowed(child, child, NO, getpid(), getpid()));
    check(@"reject resumed child rollback", !QARollbackAllowed(child, child, YES, getpid(), getpid()));
    check(@"reject foreign child rollback", !QARollbackAllowed(child, child, NO, getpid()+1, getpid()));
    check(@"reject changed identity rollback", !QARollbackAllowed(child, badIdentity, NO, getpid(), getpid()));
    struct stat mode = {0}; mode.st_mode = S_IFREG | 0755; mode.st_uid = getuid();
    check(@"allow current-user executable", QATrustedMode(mode));
    mode.st_mode |= 0020; check(@"reject group writable executable", !QATrustedMode(mode));
    mode.st_mode = S_IFREG | 0755; mode.st_uid = 0; check(@"allow root-owned executable", QATrustedMode(mode));
    return @{@"passed":@(failures.count == 0), @"checks":checks, @"failures":failures,
        @"liveLaunchPerformed":@NO, @"permissionRequestPerformed":@NO};
}
