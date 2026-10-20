#import "QBFilter.h"

/// Terminal-attributed Jump launcher for macOS 14+. Prepared is not proof of hiding.
@interface QBJumpBackend : NSObject <QBHidingBackend>
@property(nonatomic, readonly, copy) NSDictionary *diagnostics;
- (instancetype)init;
- (instancetype)initWithRecovery:(BOOL)recovery;
- (void)openSetup;
- (void)recoverPreviousSession;
+ (NSDictionary *)selfTest;
@end
