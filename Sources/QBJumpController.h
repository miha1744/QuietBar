#import <Foundation/Foundation.h>
#import <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs before NSApplication is created. The caller must already have inherited
/// Terminal's responsibility through the user-launched legacy helper.
FOUNDATION_EXPORT int QBRunJumpController(NSString *stateDirectory, pid_t ownerPID, NSString *nonce);

/// Repairs a journal only after its exact controller has exited. This function
/// never stops a live controller and never operates on the system Jump service.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *QBRecoverJumpController(NSString *stateDirectory);

/// Isolated validation/ownership tests. Does not change preferences or services.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *QBJumpControllerSelfTest(void);

NS_ASSUME_NONNULL_END
