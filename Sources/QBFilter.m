#import "QBFilter.h"
#import <dlfcn.h>
#import <objc/message.h>

// Private API activation is adapted from brentc22/stash (MIT).
// See THIRD-PARTY-NOTICES.txt. No code is injected into other processes.
@interface QBFilter ()
@property(nonatomic, readwrite) BOOL available;
@property(nonatomic, readwrite) BOOL enabled;
@property(nonatomic, readwrite) QBFilterState state;
@property(nonatomic, readwrite, copy) NSString *errorMessage;
@property(nonatomic) NSMutableArray *tokens;
@property(nonatomic, copy) NSArray<NSString *> *appliedIDs;
@property(nonatomic, copy) NSArray<NSString *> *pendingIDs;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger refreshGeneration;
@property(nonatomic) BOOL atClock;
@property(nonatomic) NSTimer *hoverTimer;
@property(nonatomic) NSMutableArray *observers;
@end

@implementation QBFilter
- (BOOL)loadBackend {
    // Probe the actual API instead of inferring its presence from the OS number.
    // An installable app on macOS 14+ does not imply that filtering is supported.
    if (!dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW)) return NO;
    Class configClass = NSClassFromString(@"MBAssessmentModeConfiguration");
    Class tokenClass = NSClassFromString(@"MBAssessmentModeAssertion");
    return configClass && tokenClass
        && [configClass instancesRespondToSelector:NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:")]
        && [tokenClass instancesRespondToSelector:NSSelectorFromString(@"activateWithConfiguration:completionHandler:")]
        && [tokenClass instancesRespondToSelector:NSSelectorFromString(@"invalidate")];
}
- (instancetype)initWithClockTracking:(BOOL)clockTracking {
    if (!(self = [super init])) return nil;
    _tokens = [NSMutableArray array];
    _observers = [NSMutableArray array];
    _errorMessage = @"";
    _available = [self loadBackend];
    _state = _available ? QBFilterStateOff : QBFilterStateUnsupported;
    __weak QBFilter *weakSelf = self;
    NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
    for (NSString *name in @[NSWorkspaceDidLaunchApplicationNotification, NSWorkspaceDidTerminateApplicationNotification,
                             NSWorkspaceDidWakeNotification, NSWorkspaceSessionDidBecomeActiveNotification]) {
        id observer = [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note;
            [weakSelf scheduleRefresh];
        }];
        [_observers addObject:observer];
    }
    if (clockTracking) {
        _hoverTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            QBFilter *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.enabled) return;
            NSPoint pointer = NSEvent.mouseLocation;
            BOOL atClock = NO;
            for (NSScreen *screen in NSScreen.screens) {
                NSRect f = screen.frame;
                // No Accessibility or screen capture permission is needed for this region.
                if (NSPointInRect(pointer, NSMakeRect(NSMaxX(f)-180, NSMaxY(f)-36, 180, 36))) {
                    atClock = YES; break;
                }
            }
            if (strongSelf.atClock != atClock) {
                strongSelf.atClock = atClock;
                if (atClock) [strongSelf refresh]; else [strongSelf scheduleRefresh];
            }
        }];
        _hoverTimer.tolerance = 0.10;
    }
    return self;
}
- (void)publishState:(QBFilterState)state {
    self.state = state;
    if (self.onChange) self.onChange();
}
- (void)invalidateToken:(id)token {
    if (!token) return;
    @try { ((void (*)(id, SEL))objc_msgSend)(token, NSSelectorFromString(@"invalidate")); }
    @catch (NSException *exception) { NSLog(@"QuietBar: could not invalidate token: %@", exception.name); }
}
- (void)releaseAll {
    self.generation++;
    for (id token in [self.tokens copy]) [self invalidateToken:token];
    [self.tokens removeAllObjects];
    self.appliedIDs = nil;
    self.pendingIDs = nil;
}
- (NSArray<NSString *> *)runningIDs {
    NSMutableSet *ids = [NSMutableSet setWithArray:@[@"com.apple.systemuiserver", @"com.apple.controlcenter", @"com.p5sys.jump.connect"]];
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications)
        if (app.bundleIdentifier) [ids addObject:app.bundleIdentifier];
    if (NSBundle.mainBundle.bundleIdentifier) [ids addObject:NSBundle.mainBundle.bundleIdentifier];
    return [ids.allObjects sortedArrayUsingSelector:@selector(compare:)];
}
- (void)fail:(NSString *)message {
    [self releaseAll];
    self.enabled = NO;
    self.errorMessage = message;
    [self publishState:QBFilterStateError];
}
- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled && self.available;
    self.errorMessage = @"";
    if (!self.available) { [self releaseAll]; [self publishState:QBFilterStateUnsupported]; return; }
    [self refresh];
}
- (void)refresh {
    if (!self.enabled || self.atClock) {
        [self releaseAll];
        [self publishState:self.enabled ? QBFilterStateAtClock : QBFilterStateOff];
        return;
    }
    NSArray *ids = [self runningIDs];
    if (self.pendingIDs) {
        if ([ids isEqualToArray:self.pendingIDs]) return;
    } else if ([ids isEqualToArray:self.appliedIDs]) return;
    NSUInteger generation = ++self.generation;
    @try {
        NSMutableArray *systemIDs = [NSMutableArray arrayWithCapacity:256];
        for (NSInteger i=0; i<=255; i++) [systemIDs addObject:@(i)];
        Class configClass = NSClassFromString(@"MBAssessmentModeConfiguration");
        Class tokenClass = NSClassFromString(@"MBAssessmentModeAssertion");
        SEL initSelector = NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id config = [[configClass alloc] performSelector:initSelector withObject:systemIDs withObject:ids];
#pragma clang diagnostic pop
        id token = [[tokenClass alloc] init];
        if (!config || !token) { [self fail:@"Системный фильтр недоступен. Значки оставлены видимыми."]; return; }
        [self.tokens addObject:token];
        self.pendingIDs = ids;
        __weak QBFilter *weakSelf = self;
        __weak id weakToken = token;
        void (^handler)(NSError *) = ^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                QBFilter *strongSelf = weakSelf;
                id completedToken = weakToken;
                if (!strongSelf || !completedToken) return;
                if (strongSelf.generation != generation || !strongSelf.enabled || strongSelf.atClock) {
                    [strongSelf invalidateToken:completedToken];
                    [strongSelf.tokens removeObjectIdenticalTo:completedToken];
                    return;
                }
                if (error) { [strongSelf fail:@"macOS не включила фильтр. Значки оставлены видимыми. Попробуйте снова."]; return; }
                for (id old in [strongSelf.tokens copy]) if (old != completedToken) {
                    [strongSelf invalidateToken:old];
                    [strongSelf.tokens removeObjectIdenticalTo:old];
                }
                strongSelf.appliedIDs = ids;
                strongSelf.pendingIDs = nil;
                [strongSelf publishState:QBFilterStateActive];
            });
        };
        SEL activate = NSSelectorFromString(@"activateWithConfiguration:completionHandler:");
        NSInvocation *call = [NSInvocation invocationWithMethodSignature:[token methodSignatureForSelector:activate]];
        call.target = token; call.selector = activate;
        [call setArgument:&config atIndex:2];
        id completion = [handler copy]; [call setArgument:&completion atIndex:3];
        [self publishState:QBFilterStateStarting];
        [call invoke];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            QBFilter *strongSelf = weakSelf;
            if (strongSelf && strongSelf.generation == generation && strongSelf.pendingIDs)
                [strongSelf fail:@"macOS не ответила на запрос. Значки возвращены. Попробуйте снова."];
        });
    } @catch (NSException *exception) {
        [self fail:@"Эта версия macOS не принимает фильтр. Значки оставлены видимыми."];
    }
}
- (void)scheduleRefresh {
    if (!self.enabled) return;
    NSUInteger generation = ++self.refreshGeneration;
    __weak QBFilter *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        QBFilter *strongSelf = weakSelf;
        if (strongSelf && generation == strongSelf.refreshGeneration) [strongSelf refresh];
    });
}
- (void)stop {
    _enabled = NO;
    self.refreshGeneration++;
    [self releaseAll];
    [self publishState:self.available ? QBFilterStateOff : QBFilterStateUnsupported];
}
- (void)dealloc {
    [_hoverTimer invalidate];
    for (id observer in _observers) [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:observer];
    for (id token in _tokens) {
        @try { ((void (*)(id, SEL))objc_msgSend)(token, NSSelectorFromString(@"invalidate")); }
        @catch (NSException *exception) { }
    }
}
@end
