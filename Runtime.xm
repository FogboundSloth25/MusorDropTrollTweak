#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#define MDPath(path) jbroot(path)
#elif __has_include(<rootless.h>)
#import <rootless.h>
#define MDPath(path) ROOT_PATH_NS(path)
#else
#define MDPath(path) (path)
#endif

static CFStringRef const kMDDomain = CFSTR("com.fogboundsloth25.musordroptrolltweak");
static NSString * const kMDChanged = @"com.fogboundsloth25.musordroptrolltweak/preferences.changed";
static NSString * const kMDBuiltInVideo = @"/Library/Application Support/MusorDropTrollTweak/video_alpha.mov";

static const CGFloat kMDDimAlpha = 0.72;
static const NSTimeInterval kMDFadeDuration = 0.24;
static const NSTimeInterval kMDRetryDelay = 0.5;

static BOOL MDEnabled = YES;
static NSTimeInterval MDDelay = 10.0;
static float MDVolume = 1.0f;
static NSString *MDVideoPath = nil;
static BOOL MDLocked = NO;
static BOOL MDShowing = NO;
static BOOL MDTimerPaused = NO;
static NSTimeInterval MDRemaining = 0.0;
static CFTimeInterval MDDeadline = 0.0;
static dispatch_block_t MDTimerBlock = nil;
static UIWindow *MDOverlayWindow = nil;
static UIWindow *MDPreviousKeyWindow = nil;

static id MDProtectedUnavailable = nil;
static id MDProtectedAvailable = nil;
static id MDDidBecomeActive = nil;
static id MDWillResignActive = nil;
static id MDAudioInterruption = nil;

static id MDValue(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, kMDDomain));
}

static void MDLoadPreferences(void) {
    id enabled = MDValue(@"enabled");
    id delay = MDValue(@"delay");
    id volume = MDValue(@"volume");
    id path = MDValue(@"videoPath");

    MDEnabled = enabled ? [enabled boolValue] : YES;
    MDDelay = [delay isKindOfClass:NSNumber.class] ? MAX(0.0, MIN(3600.0, [delay doubleValue])) : 10.0;

    if ([volume isKindOfClass:NSNumber.class]) {
        double value = [volume doubleValue];
        MDVolume = value <= 1.0 ? (float)MAX(0.0, MIN(1.0, value)) : (float)MAX(0.0, MIN(1.0, value / 100.0));
    } else {
        MDVolume = 1.0f;
    }

    MDVideoPath = ([path isKindOfClass:NSString.class] && [(NSString *)path length]) ? [(NSString *)path copy] : nil;
}

static NSString *MDResolveVideoPath(void) {
    if (MDVideoPath.length) {
        NSString *custom = [MDVideoPath stringByExpandingTildeInPath];
        if ([custom hasPrefix:@"file://"]) {
            NSURL *url = [NSURL URLWithString:custom];
            custom = url.isFileURL ? url.path : nil;
        }
        if (custom.length && [[NSFileManager defaultManager] fileExistsAtPath:custom]) return custom;
    }

    NSString *builtIn = MDPath(kMDBuiltInVideo);
    if (builtIn.length && [[NSFileManager defaultManager] fileExistsAtPath:builtIn]) return builtIn;
    return nil;
}

static void MDCancelTimer(void) {
    if (MDTimerBlock) {
        dispatch_block_cancel(MDTimerBlock);
        MDTimerBlock = nil;
    }
    MDDeadline = 0.0;
}

static void MDStartTimer(NSTimeInterval delay);
static void MDShowVideo(void);
static void MDPauseTimerForLock(void);
static void MDResumeTimerAfterUnlock(void);

@interface MDGlobalVideoController : UIViewController <UIGestureRecognizerDelegate>
@property(nonatomic,strong) AVPlayer *player;
@property(nonatomic,strong) AVPlayerLayer *playerLayer;
@property(nonatomic,strong) UIView *dimmingView;
@property(nonatomic,strong) UIView *videoView;
@property(nonatomic,strong) UIControl *touchBlocker;
@property(nonatomic,strong) UITapGestureRecognizer *exitGesture;
@property(nonatomic,strong) id endObserver;
@property(nonatomic,strong) id failObserver;
@property(nonatomic,strong) id stalledObserver;
@property(nonatomic,assign) BOOL ready;
@property(nonatomic,assign) BOOL finishing;
@property(nonatomic,assign) BOOL exitRequested;
@property(nonatomic,assign) BOOL interrupted;
- (void)requestExit;
- (void)finishAndScheduleNext;
@end

@implementation MDGlobalVideoController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.clearColor;
    self.view.opaque = NO;
    self.view.userInteractionEnabled = YES;

    self.dimmingView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.dimmingView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.dimmingView.backgroundColor = UIColor.blackColor;
    self.dimmingView.alpha = 0.0;
    self.dimmingView.userInteractionEnabled = NO;
    [self.view addSubview:self.dimmingView];

    self.videoView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.videoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.videoView.backgroundColor = UIColor.clearColor;
    self.videoView.opaque = NO;
    self.videoView.alpha = 0.0;
    [self.view addSubview:self.videoView];

    self.playerLayer = [AVPlayerLayer layer];
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.playerLayer.backgroundColor = UIColor.clearColor.CGColor;
    [self.videoView.layer addSublayer:self.playerLayer];

    self.touchBlocker = [[UIControl alloc] initWithFrame:self.view.bounds];
    self.touchBlocker.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.touchBlocker.backgroundColor = UIColor.clearColor;
    self.touchBlocker.userInteractionEnabled = YES;
    [self.view addSubview:self.touchBlocker];

    self.exitGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(requestExit)];
    self.exitGesture.numberOfTouchesRequired = 2;
    self.exitGesture.numberOfTapsRequired = 2;
    self.exitGesture.cancelsTouchesInView = YES;
    self.exitGesture.delegate = self;
    [self.touchBlocker addGestureRecognizer:self.exitGesture];

    NSString *path = MDResolveVideoPath();
    if (!path.length) {
        NSLog(@"[MusorDropTrollTweak] global video not found");
        [self finishAndScheduleNext];
        return;
    }

    NSURL *url = [NSURL fileURLWithPath:path isDirectory:NO];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    self.player = [AVPlayer playerWithPlayerItem:item];
    self.player.volume = MDVolume;
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
    self.player.automaticallyWaitsToMinimizeStalling = YES;
    self.playerLayer.player = self.player;
    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:NULL];

    __weak typeof(self) weakSelf = self;
    self.endObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:item queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        [weakSelf finishAndScheduleNext];
    }];
    self.failObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification object:item queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        NSLog(@"[MusorDropTrollTweak] AVPlayer failed: %@", note.userInfo);
        if (!weakSelf.finishing) {
            [weakSelf.player seekToTime:kCMTimeZero completionHandler:^(__unused BOOL finished) {
                if (!weakSelf.finishing) [weakSelf.player play];
            }];
        }
    }];
    self.stalledObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemPlaybackStalledNotification object:item queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        if (!weakSelf.finishing) [weakSelf.player play];
    }];

    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *error = nil;
    [session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeMoviePlayback options:AVAudioSessionCategoryOptionMixWithOthers error:&error];
    if (error) NSLog(@"[MusorDropTrollTweak] audio category error: %@", error);
    error = nil;
    [session setActive:YES error:&error];
    if (error) NSLog(@"[MusorDropTrollTweak] audio activation error: %@", error);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.dimmingView.frame = self.view.bounds;
    self.videoView.frame = self.view.bounds;
    self.playerLayer.frame = self.videoView.bounds;
    self.touchBlocker.frame = self.view.bounds;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer { return NO; }

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (![keyPath isEqualToString:@"status"] || object != self.player.currentItem) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }

    AVPlayerItemStatus status = self.player.currentItem.status;
    if (status == AVPlayerItemStatusReadyToPlay && !self.ready && !self.finishing) {
        self.ready = YES;
        [self.player play];
        [UIView animateWithDuration:kMDFadeDuration delay:0.0 options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState animations:^{
            self.dimmingView.alpha = kMDDimAlpha;
            self.videoView.alpha = 1.0;
        } completion:nil];
    } else if (status == AVPlayerItemStatusFailed && !self.finishing) {
        NSLog(@"[MusorDropTrollTweak] AVPlayerItem error: %@", self.player.currentItem.error);
        [self finishAndScheduleNext];
    }
}

- (void)requestExit {
    if (self.finishing) return;
    self.exitRequested = YES;
    [self finishAndScheduleNext];
}

- (void)finishAndScheduleNext {
    if (self.finishing) return;
    self.finishing = YES;

    AVPlayerItem *item = self.player.currentItem;
    if (item) {
        @try { [item removeObserver:self forKeyPath:@"status"]; } @catch (__unused NSException *e) {}
    }
    if (self.endObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.endObserver];
    if (self.failObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.failObserver];
    if (self.stalledObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.stalledObserver];
    self.endObserver = nil;
    self.failObserver = nil;
    self.stalledObserver = nil;
    [self.player pause];

    [UIView animateWithDuration:kMDFadeDuration delay:0.0 options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.videoView.alpha = 0.0;
        self.dimmingView.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        UIWindow *window = MDOverlayWindow;
        MDOverlayWindow = nil;
        MDShowing = NO;
        if (window) {
            window.hidden = YES;
            window.rootViewController = nil;
        }
        if (MDPreviousKeyWindow && !MDPreviousKeyWindow.hidden) [MDPreviousKeyWindow makeKeyAndVisible];
        MDPreviousKeyWindow = nil;
        if (MDEnabled && !MDLocked) {
            MDLoadPreferences();
            MDStartTimer(MDDelay);
        }
    }];
}

- (void)dealloc {
    AVPlayerItem *item = self.player.currentItem;
    if (item) { @try { [item removeObserver:self forKeyPath:@"status"]; } @catch (__unused NSException *e) {} }
    if (self.endObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.endObserver];
    if (self.failObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.failObserver];
    if (self.stalledObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.stalledObserver];
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
@end

static UIWindowScene *MDActiveWindowScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateForegroundActive || windowScene.activationState == UISceneActivationStateUnattached) return windowScene;
    }
    return nil;
}

static UIWindow *MDCreateOverlayWindow(void) {
    UIWindowScene *scene = MDActiveWindowScene();
    UIWindow *window = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    window.frame = UIScreen.mainScreen.bounds;
    window.backgroundColor = UIColor.clearColor;
    window.opaque = NO;
    window.windowLevel = UIWindowLevelAlert + 100.0;
    return window;
}

static void MDShowVideo(void) {
    if (!MDEnabled || MDLocked || MDShowing) return;

    NSString *path = MDResolveVideoPath();
    if (!path.length) {
        NSLog(@"[MusorDropTrollTweak] playable video path unavailable");
        MDStartTimer(kMDRetryDelay);
        return;
    }

    MDCancelTimer();
    MDShowing = YES;

    UIWindowScene *scene = MDActiveWindowScene();
    if (scene) {
        for (UIWindow *window in scene.windows) {
            if (window.hidden || window.alpha <= 0.0 || window == MDOverlayWindow) continue;
            if (window.isKeyWindow) {
                MDPreviousKeyWindow = window;
                break;
            }
        }
    }

    MDGlobalVideoController *controller = [MDGlobalVideoController new];
    UIWindow *window = MDCreateOverlayWindow();
    window.rootViewController = controller;
    MDOverlayWindow = window;
    [window makeKeyAndVisible];
}

static void MDStartTimer(NSTimeInterval delay) {
    MDCancelTimer();
    if (!MDEnabled || MDLocked || MDShowing) return;

    MDRemaining = MAX(0.0, delay);
    MDDeadline = CACurrentMediaTime() + MDRemaining;
    MDTimerBlock = dispatch_block_create(DISPATCH_BLOCK_INHERIT_QOS_CLASS, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            MDTimerBlock = nil;
            MDDeadline = 0.0;
            MDRemaining = 0.0;
            if (MDEnabled && !MDLocked && !MDShowing) MDShowVideo();
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MDRemaining * NSEC_PER_SEC)), dispatch_get_main_queue(), MDTimerBlock);
}

static void MDPauseTimerForLock(void) {
    if (MDShowing || !MDTimerBlock) return;
    CFTimeInterval now = CACurrentMediaTime();
    MDRemaining = MDDeadline > now ? (MDDeadline - now) : 0.0;
    MDTimerPaused = YES;
    MDCancelTimer();
}

static void MDResumeTimerAfterUnlock(void) {
    if (!MDEnabled || MDShowing || MDLocked) return;
    if (MDTimerPaused) {
        NSTimeInterval remaining = MDRemaining;
        MDTimerPaused = NO;
        MDStartTimer(remaining);
    } else if (!MDTimerBlock) {
        MDStartTimer(MDDelay);
    }
}

static void MDApplyPreferences(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        MDCancelTimer();
        MDLoadPreferences();
        MDTimerPaused = NO;

        if (!MDEnabled) {
            if (MDShowing && [MDOverlayWindow.rootViewController isKindOfClass:MDGlobalVideoController.class]) {
                [(MDGlobalVideoController *)MDOverlayWindow.rootViewController finishAndScheduleNext];
            }
            return;
        }

        if (MDShowing && [MDOverlayWindow.rootViewController isKindOfClass:MDGlobalVideoController.class]) {
            ((MDGlobalVideoController *)MDOverlayWindow.rootViewController).player.volume = MDVolume;
        } else if (!MDLocked) {
            MDStartTimer(MDDelay);
        }
    });
}

static void MDHandleAudioInterruption(NSNotification *notification) {
    NSNumber *type = notification.userInfo[AVAudioSessionInterruptionTypeKey];
    if (![type isKindOfClass:NSNumber.class]) return;

    MDGlobalVideoController *controller = [MDOverlayWindow.rootViewController isKindOfClass:MDGlobalVideoController.class] ? (MDGlobalVideoController *)MDOverlayWindow.rootViewController : nil;
    if (!controller || controller.finishing) return;

    if (type.integerValue == AVAudioSessionInterruptionTypeBegan) {
        controller.interrupted = YES;
        [controller.player pause];
    } else if (type.integerValue == AVAudioSessionInterruptionTypeEnded && controller.interrupted) {
        controller.interrupted = NO;
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
        [controller.player play];
    }
}

static void MDChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    MDApplyPreferences();
}

%ctor {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    if (![bundleID isEqualToString:@"com.apple.springboard"]) return;

    MDLoadPreferences();
    MDLocked = !UIApplication.sharedApplication.protectedDataAvailable;

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, MDChangedCallback, (__bridge CFStringRef)kMDChanged, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;

    MDProtectedUnavailable = [nc addObserverForName:UIApplicationProtectedDataWillBecomeUnavailableNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        MDLocked = YES;
        MDPauseTimerForLock();
    }];

    MDProtectedAvailable = [nc addObserverForName:UIApplicationProtectedDataDidBecomeAvailableNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        MDLocked = NO;
        MDResumeTimerAfterUnlock();
    }];

    MDWillResignActive = [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        if (!UIApplication.sharedApplication.protectedDataAvailable) {
            MDLocked = YES;
            MDPauseTimerForLock();
        }
    }];

    MDDidBecomeActive = [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        if (UIApplication.sharedApplication.protectedDataAvailable) {
            MDLocked = NO;
            MDResumeTimerAfterUnlock();
        }
    }];

    MDAudioInterruption = [nc addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        MDHandleAudioInterruption(note);
    }];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (MDEnabled && !MDLocked) MDStartTimer(MDDelay);
    });
}