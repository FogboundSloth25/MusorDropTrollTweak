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
static NSString * const kMDVideo = @"/Library/Application Support/MusorDropTrollTweak/video_alpha.mov";
static const CGFloat kMDDimAlpha = 0.72;
static const NSTimeInterval kMDFade = 0.24;

static BOOL MDEnabled = YES;
static NSTimeInterval MDDelay = 10.0;
static float MDVolume = 1.0f;
static NSString *MDVideoPath = nil;

static dispatch_block_t MDTimerBlock = nil;
static CFTimeInterval MDTimerDeadline = 0;
static NSTimeInterval MDRemaining = 0;
static BOOL MDTimerPaused = NO;
static BOOL MDShowing = NO;
static UIWindow *MDOverlayWindow = nil;
static id MDActiveObserver = nil;
static id MDResignObserver = nil;
static id MDProtectedUnavailableObserver = nil;
static id MDProtectedAvailableObserver = nil;

static id MDValue(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, kMDDomain));
}

static void MDCancelTimer(void) {
    if (MDTimerBlock) {
        dispatch_block_cancel(MDTimerBlock);
        MDTimerBlock = nil;
    }
    MDTimerDeadline = 0;
}

static void MDLoadPreferences(void) {
    id enabled = MDValue(@"enabled");
    id delay = MDValue(@"delay");
    id volume = MDValue(@"volume");
    id path = MDValue(@"videoPath");

    MDEnabled = enabled ? [enabled boolValue] : YES;
    MDDelay = [delay isKindOfClass:NSNumber.class] ? MAX(0.0, MIN(60.0, [delay doubleValue])) : 10.0;

    if ([volume isKindOfClass:NSNumber.class]) {
        double value = [volume doubleValue];
        MDVolume = value <= 1.0 ? MAX(0.0, MIN(1.0, value)) : MAX(0.0, MIN(1.0, value / 100.0));
    } else {
        MDVolume = 1.0f;
    }

    MDVideoPath = ([path isKindOfClass:NSString.class] && [(NSString *)path length]) ? [(NSString *)path copy] : nil;
}

static NSString *MDResolveVideoPath(void) {
    if ([MDVideoPath isKindOfClass:NSString.class] && MDVideoPath.length) {
        NSString *custom = [MDVideoPath stringByExpandingTildeInPath];
        if ([custom hasPrefix:@"file://"]) {
            NSURL *url = [NSURL URLWithString:custom];
            custom = url.isFileURL ? url.path : nil;
        }
        if (custom.length && [[NSFileManager defaultManager] fileExistsAtPath:custom]) return custom;
    }

    NSString *builtIn = MDPath(kMDVideo);
    if (builtIn.length && [[NSFileManager defaultManager] fileExistsAtPath:builtIn]) return builtIn;
    return nil;
}

static UIWindowScene *MDScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)scene;
    }
    return nil;
}

static UIWindow *MDUnderlyingWindow(void) {
    UIWindowScene *scene = MDScene();
    if (!scene) return nil;

    for (UIWindow *window in scene.windows) {
        if (window.hidden || window.alpha <= 0.0 || window == MDOverlayWindow) continue;
        if (window.isKeyWindow) return window;
    }
    for (UIWindow *window in scene.windows) {
        if (window.hidden || window.alpha <= 0.0 || window == MDOverlayWindow) continue;
        if (window.rootViewController) return window;
    }
    return nil;
}

@interface MDVideoController : UIViewController
@property(nonatomic,strong) AVPlayer *player;
@property(nonatomic,strong) AVPlayerLayer *playerLayer;
@property(nonatomic,strong) UIView *dimView;
@property(nonatomic,strong) UIView *videoView;
@property(nonatomic,strong) UIControl *touchBlocker;
@property(nonatomic,strong) id endObserver;
@property(nonatomic,strong) id failObserver;
@property(nonatomic,assign) BOOL finishing;
@property(nonatomic,assign) BOOL started;
- (void)finishAndRepeat;
@end

static void MDStartTimer(NSTimeInterval delay);
static void MDPlayVideo(void);

@implementation MDVideoController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.clearColor;
    self.view.opaque = NO;

    self.dimView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.dimView.backgroundColor = UIColor.blackColor;
    self.dimView.alpha = 0.0;
    self.dimView.userInteractionEnabled = NO;
    [self.view addSubview:self.dimView];

    self.videoView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.videoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.videoView.backgroundColor = UIColor.clearColor;
    self.videoView.opaque = NO;
    self.videoView.alpha = 0.0;
    [self.view addSubview:self.videoView];

    self.playerLayer = [AVPlayerLayer layer];
    self.playerLayer.frame = self.videoView.bounds;
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.playerLayer.backgroundColor = UIColor.clearColor.CGColor;
    [self.videoView.layer addSublayer:self.playerLayer];

    self.touchBlocker = [[UIControl alloc] initWithFrame:self.view.bounds];
    self.touchBlocker.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.touchBlocker.userInteractionEnabled = YES;
    self.touchBlocker.backgroundColor = UIColor.clearColor;
    [self.view addSubview:self.touchBlocker];

    NSString *path = MDResolveVideoPath();
    if (!path.length) {
        NSLog(@"[MusorDropTrollTweak] no playable video");
        [self finishAndRepeat];
        return;
    }

    NSURL *url = [NSURL fileURLWithPath:path isDirectory:NO];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    self.player = [AVPlayer playerWithPlayerItem:item];
    self.player.volume = MDVolume;
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
    self.player.automaticallyWaitsToMinimizeStalling = NO;
    self.playerLayer.player = self.player;

    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:NULL];

    __weak typeof(self) weakSelf = self;
    self.endObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:item queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
        [weakSelf finishAndRepeat];
    }];
    self.failObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification object:item queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        NSLog(@"[MusorDropTrollTweak] player failed: %@", note.userInfo);
        [weakSelf finishAndRepeat];
    }];

    AVAudioSession *audio = [AVAudioSession sharedInstance];
    NSError *error = nil;
    [audio setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeMoviePlayback options:AVAudioSessionCategoryOptionMixWithOthers error:&error];
    if (error) NSLog(@"[MusorDropTrollTweak] audio category: %@", error);
    error = nil;
    [audio setActive:YES error:&error];
    if (error) NSLog(@"[MusorDropTrollTweak] audio session: %@", error);
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (![keyPath isEqualToString:@"status"] || object != self.player.currentItem) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }

    AVPlayerItemStatus status = self.player.currentItem.status;
    if (status == AVPlayerItemStatusReadyToPlay && !self.started && !self.finishing) {
        self.started = YES;
        [self.player play];

        [UIView animateWithDuration:kMDFade delay:0.0 options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState animations:^{
            self.dimView.alpha = kMDDimAlpha;
            self.videoView.alpha = 1.0;
        } completion:nil];
    } else if (status == AVPlayerItemStatusFailed) {
        NSLog(@"[MusorDropTrollTweak] item error: %@", self.player.currentItem.error);
        [self finishAndRepeat];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.dimView.frame = self.view.bounds;
    self.videoView.frame = self.view.bounds;
    self.playerLayer.frame = self.videoView.bounds;
    self.touchBlocker.frame = self.view.bounds;
}

- (void)finishAndRepeat {
    if (self.finishing) return;
    self.finishing = YES;

    AVPlayerItem *item = self.player.currentItem;
    if (item) {
        @try { [item removeObserver:self forKeyPath:@"status"]; } @catch (__unused NSException *e) {}
    }
    if (self.endObserver) { [[NSNotificationCenter defaultCenter] removeObserver:self.endObserver]; self.endObserver = nil; }
    if (self.failObserver) { [[NSNotificationCenter defaultCenter] removeObserver:self.failObserver]; self.failObserver = nil; }
    [self.player pause];

    [UIView animateWithDuration:kMDFade delay:0.0 options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.videoView.alpha = 0.0;
        self.dimView.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        UIWindow *window = MDOverlayWindow;
        MDOverlayWindow = nil;
        MDShowing = NO;
        if (window) {
            window.hidden = YES;
            window.rootViewController = nil;
        }
        if (MDEnabled && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
            MDLoadPreferences();
            MDStartTimer(MDDelay);
        }
    }];
}

- (void)dealloc {
    AVPlayerItem *item = self.player.currentItem;
    if (item) {
        @try { [item removeObserver:self forKeyPath:@"status"]; } @catch (__unused NSException *e) {}
    }
    if (self.endObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.endObserver];
    if (self.failObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.failObserver];
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
@end

static void MDPlayVideo(void) {
    if (!MDEnabled || MDShowing) return;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;

    UIWindowScene *scene = MDScene();
    UIWindow *underlying = MDUnderlyingWindow();
    if (!scene || !underlying) {
        MDStartTimer(MDDelay);
        return;
    }

    if (!MDResolveVideoPath().length) {
        NSLog(@"[MusorDropTrollTweak] playable video path missing");
        MDStartTimer(MDDelay);
        return;
    }

    MDCancelTimer();
    MDShowing = YES;

    MDVideoController *controller = [MDVideoController new];
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.rootViewController = controller;
    window.windowLevel = UIWindowLevelAlert + 1.0;
    window.backgroundColor = UIColor.clearColor;
    window.opaque = NO;
    window.frame = scene.coordinateSpace.bounds;
    MDOverlayWindow = window;
    [window makeKeyAndVisible];
}

static void MDStartTimer(NSTimeInterval delay) {
    MDCancelTimer();
    MDTimerPaused = NO;

    if (!MDEnabled || MDShowing) return;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;

    MDRemaining = MAX(0.0, delay);
    MDTimerDeadline = CACurrentMediaTime() + MDRemaining;

    MDTimerBlock = dispatch_block_create(DISPATCH_BLOCK_INHERIT_QOS_CLASS, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            MDTimerBlock = nil;
            MDTimerDeadline = 0;
            MDRemaining = 0;
            if (MDEnabled && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) MDPlayVideo();
        });
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MDRemaining * NSEC_PER_SEC)), dispatch_get_main_queue(), MDTimerBlock);
}

static void MDPauseTimerForInactiveState(void) {
    if (MDShowing || !MDTimerBlock) return;

    CFTimeInterval now = CACurrentMediaTime();
    MDTimerPaused = YES;
    MDRemaining = MDTimerDeadline > now ? (MDTimerDeadline - now) : 0.0;
    MDCancelTimer();
}

static void MDResumeTimerAfterInactiveState(void) {
    if (!MDEnabled || MDShowing) return;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;

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
        BOOL wasEnabled = MDEnabled;
        MDCancelTimer();
        MDLoadPreferences();

        if (!MDEnabled) {
            MDTimerPaused = NO;
            if (MDShowing) {
                MDVideoController *controller = (MDVideoController *)MDOverlayWindow.rootViewController;
                [controller finishAndRepeat];
            }
            return;
        }

        if (!wasEnabled || wasEnabled) {
            MDTimerPaused = NO;
            if (!MDShowing && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
                MDStartTimer(MDDelay);
            }
        }
    });
}

static void MDChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    MDApplyPreferences();
}

%ctor {
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier ?: @"";
    if (!bundleID.length || [bundleID hasPrefix:@"com.apple."]) return;
    if ([[NSBundle mainBundle].bundleURL.pathExtension.lowercaseString isEqualToString:@"appex"]) return;

    MDLoadPreferences();

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, MDChangedCallback, (__bridge CFStringRef)kMDChanged, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    MDResignObserver = [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
        MDPauseTimerForInactiveState();
    }];

    MDProtectedUnavailableObserver = [nc addObserverForName:UIApplicationProtectedDataWillBecomeUnavailableNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
        MDPauseTimerForInactiveState();
    }];

    MDProtectedAvailableObserver = [nc addObserverForName:UIApplicationProtectedDataDidBecomeAvailableNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) MDResumeTimerAfterInactiveState();
    }];

    MDActiveObserver = [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
        MDLoadPreferences();
        MDResumeTimerAfterInactiveState();
    }];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (MDEnabled && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) MDStartTimer(MDDelay);
    });
}
