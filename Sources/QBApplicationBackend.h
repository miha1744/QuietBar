#import "QBFilter.h"

NS_ASSUME_NONNULL_BEGIN

/// Experimental cold launcher. A running application is not proof of hiding.
@interface QBApplicationBackend : NSObject <QBHidingBackend>
@property(nonatomic, readonly, copy) NSDictionary *diagnostics;
@property(nonatomic, readonly, copy, nullable) NSURL *selectedApplicationURL;
@property(nonatomic, readonly, copy) NSString *selectedApplicationName;
- (instancetype)initWithRecovery:(BOOL)recovery;
- (BOOL)selectApplicationURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;
- (void)chooseApplicationForWindow:(nullable NSWindow *)window;
- (void)openSetup;
- (void)openAccessibilitySettings;
+ (NSDictionary *)selfTest;
@end

NS_ASSUME_NONNULL_END
