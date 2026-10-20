#import <AppKit/AppKit.h>

typedef NS_ENUM(NSInteger, QBFilterState) {
    QBFilterStateOff,
    QBFilterStateStarting,
    QBFilterStateActive,
    QBFilterStateAtClock,
    QBFilterStateUnsupported,
    QBFilterStateError,
    QBFilterStateNeedsSetup,
    QBFilterStatePrepared,
    QBFilterStateStopping
};

@protocol QBHidingBackend <NSObject>
@property(nonatomic, readonly) BOOL available;
@property(nonatomic, readonly) BOOL enabled;
@property(nonatomic, readonly) QBFilterState state;
@property(nonatomic, readonly, copy) NSString *errorMessage;
@property(nonatomic, copy) void (^onChange)(void);
- (void)setEnabled:(BOOL)enabled;
- (void)stop;
@end

@interface QBFilter : NSObject <QBHidingBackend>
@property(nonatomic, readonly) BOOL available;
@property(nonatomic, readonly) BOOL enabled;
@property(nonatomic, readonly) QBFilterState state;
@property(nonatomic, readonly, copy) NSString *errorMessage;
@property(nonatomic, copy) void (^onChange)(void);
- (instancetype)initWithClockTracking:(BOOL)clockTracking;
- (void)setEnabled:(BOOL)enabled;
- (void)stop;
@end
