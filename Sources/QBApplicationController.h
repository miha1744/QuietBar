#import <Foundation/Foundation.h>
#import <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

/// Early helper: call before creating NSApplication, through Terminal and screen.
/// Launches one selected, closed application. Never manages launchd jobs.
FOUNDATION_EXPORT int QBRunApplicationController(NSString *stateDirectory, pid_t ownerPID, NSString *nonce);

/// Inspects an abandoned session. Never terminates an application during recovery.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *QBRecoverApplicationController(NSString *stateDirectory);

/// Pure format, path and ownership validation checks; no launch or TCC requests.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *QBApplicationControllerSelfTest(void);

NS_ASSUME_NONNULL_END
