#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#define MDJBRPath(path) jbroot(path)
#elif __has_include(<rootless.h>)
#import <rootless.h>
#define MDJBRPath(path) ROOT_PATH_NS(path)
#else
#define MDJBRPath(path) (path)
#endif

static CFStringRef const kMDPreferencesDomain = CFSTR("com.fogboundsloth25.musordroptrolltweak");
static NSString * const kMDPreferencesChanged = @"com.fogboundsloth25.musordroptrolltweak/preferences.changed";
static NSString * const kMDVideoRelativePath = @"/Library/Application Support/MusorDropTrollTweak/video_alpha.mov";
static CGFloat const kMDDimAlpha = 0.72;
static NSTimeInterval const kMDFadeDuration = 0.24;

static NSTimeInterval MDRolloutDelay = 10.0;
static float MDVolume = 1.0f;
static BOOL MDEnabled = YES;
static NSString *MDVideoPath = nil;

static dispatch_block_t MDTimerBlock = nil;
static BOOL MDShowing = NO;
static BOOL MDPendingReschedule = NO;
static UIWindow *MDOverlayWindow = nil;
static UIWindow *MDUnderlyingWindow = nil;
static id MDActiveObserver = nil;
static id MDBackgroundObserver = nil;

static id MDPreference(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, kMDPreferencesDomain));
}

static NSString *MDNormalizedVideoPath(NSString *path) {
    if (![path isKindOfClass:NSString.class] || path.length == 0) return nil;
    path = [path stringByExpandingTildeInPath];
    if ([path hasPrefix:@"file://"]) {
        NSURL *url = [NSURL URLWithString:path];
        return url.isFileURL ? url.path : nil;
    }
    return path;
}

static NSString *MDDefaultVideoPath(void) {
    NSString *path = MDJBRPath(kMDVideoRelativePath);
    if (path.length && [[NSFileManager defaultManager] fileExistsAtPath:path]) return path;
    return nil;
}

static UIWindowScene *MDActiveWindowScene(void) {
    UIApplication *app = UIApplication.sharedApplication;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)scene;
    }
    return nil;
}

static UIWindow *MDActiveWindow(void) {
    UIWindowScene *scene = MDActiveWindowScene();
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

static void MDCancelTimer(void) {
    if (MDTimerBlock) {
        dispatch_block_cancel(MDTimerBlock);
        MDTimerBlock = nil;
    }
}

static void MDLoadPreferences(void) {
    id enabled = MDPreference(@"enabled");
    id delay = MDPreference(@"delay");
    id volume = MDPreference(@"volume");
    id video = MDPreference(@"videoPath");

    MDEnabled = enabled ? [enabled boolValue] : YES;
    MDRolloutDelay = [delay isKindOfClass:NSNumber.class] ? MAX(0.0, [delay doubleValue]) : 10.0;

    if ([volume isKindOfClass:NSNumber.class]) {
        CGFloat stored = [(NSNumber *)volume doubleValue];
        MDVolume = stored <= 1.0 ? MAX(0.0, MIN(1.0, stored)) : MAX(0.0, MIN(1.0, stored / 100.0));
    } else {
        MDVolume = 1.0f;
    }

    MDVideoPath = ([video isKindOfClass:NSString.class] && [(NSString *)video length] > 0) ? [(NSString *)video copy] : nil;
}

static void MDStartTimer(void);
static void MDPlay(void);

@interface MDOverlayViewController : UIViewController
@property(nonatomic,strong) AVPlayer *player;
@property(nonatomic,strong) AVPlayerLayer *playerLayer;
@property(nonatomic,strong) UIView *videoView;
@property(nonatomic,strong) UIView *dimView;
@property(nonatomic,strong) UIControl *blocker;
@property(nonatomic,strong) id endObserver;
@property(nonatomic,strong) id failedObserver;
@property(nonatomic,assign) BOOL finishing;
@property(nonatomic,assign) BOOL readyToStart;
@end

@implementation MDOverlayViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.opaque = NO;
    self.view.userInteractionEnabled = YES;

    // Dimming is deliberately BELOW the video. Transparent pixels reveal the
    // dimmed underlying app, while opaque video pixels remain at full brightness.
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

    self.blocker = [[UIControl alloc] initWithFrame:self.view.bounds];
    self.blocker.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.blocker.backgroundColor = UIColor.clearColor;
    self.blocker.userInteractionEnabled = YES;
    [self.view addSubview:self.blocker];

    NSString *path = MDNormalizedVideoPath(MDVideoPath);
    if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) path = MDDefaultVideoPath();
    if (!path.length) {
        NSLog(@"[MusorDropTrollTweak] video not found: custom=%@ default=%@", MDVideoPath, MDDefaultVideoPath());
        [self finishWithResult:NO restartTimer:YES];
        return;
    }

    NSURL *url = [NSURL fileURLWithPath:path isDirectory:NO];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    self.player = [AVPlayer playerWithPlayerItem:item];
    self.player.volume = MDVolume;
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
    self.player.automaticallyWaitsToMinimizeStalling = NO;
    self.playerLayer.player = self.player;

    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:NULL];

    __weak typeof(self) weakSelf = self;
    self.endObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:item queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [weakSelf finishWithResult:YES restartTimer:YES];
    }];
    self.failedObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification object:item queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        NSLog(@"[MusorDropTrollTweak] AVPlayer failed: %@", note.userInfo);
        [weakSelf finishWithResult:NO restartTimer:YES];
    }];

    AVAudioSession *audio = [AVAudioSession sharedInstance];
    NSError *audioError = nil;
    [audio setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeMoviePlayback options:AVAudioSessionCategoryOptionMixWithOthers error:&audioError];
    if (audioError) NSLog(@"[MusorDropTrollTweak] audio category error: %@", audioError);
    audioError = nil;
    [audio setActive:YES error:&audioError];
    if (audioError) NSLog(@"[MusorDropTrollTweak] audio session error: %@", audioError);
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (![keyPath isEqualToString:@"status"] || object != self.player.currentItem) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }

    AVPlayerItemStatus status = self.player.currentItem.status;
    if (status == AVPlayerItemStatusReadyToPlay) {
        if (self.readyToStart || self.finishing) return;
        self.readyToStart = YES;
        [self.player play];
        [UIView animateWithDuration:kMDFadeDuration
                              delay:0.0
                            options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            self.dimView.alpha = kMDDimAlpha;
            self.videoView.alpha = 1.0;
        } completion:nil];
    } else if (status == AVPlayerItemStatusFailed) {
        NSLog(@"[MusorDropTrollTweak] item failed: %@", self.player.currentItem.error);
        [self finishWithResult:NO restartTimer:YES];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self setNeedsStatusBarAppearanceUpdate];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.videoView.frame = self.view.bounds;
    self.playerLayer.frame = self.videoView.bounds;
    self.dimView.frame = self.view.bounds;
    self.blocker.frame = self.view.bounds;
}

- (void)finishWithResult:(BOOL)completed restartTimer:(BOOL)restartTimer {
    if (self.finishing) return;
    self.finishing = YES;

    AVPlayerItem *item = self.player.currentItem;
    if (item) {
        @try {
            [item removeObserver:self forKeyPath:@"status"];
        } @catch (__unused NSException *exception) {
        }
    }

    if (self.endObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.endObserver];
        self.endObserver = nil;
    }
    if (self.failedObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.failedObserver];
        self.failedObserver = nil;
    }
    [self.player pause];

    [UIView animateWithDuration:kMDFadeDuration
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        self.videoView.alpha = 0.0;
        self.dimView.alpha = 0.0;
    } completion:^(BOOL finished) {
        UIWindow *overlay = MDOverlayWindow;
        MDOverlayWindow = nil;
        if (overlay) {
            overlay.hidden = YES;
            overlay.rootViewController = nil;
        }
        if (MDUnderlyingWindow) {
            [MDUnderlyingWindow makeKeyAndVisible];
            MDUnderlyingWindow = nil;
        }

        MDShowing = NO;
        if (restartTimer && MDEnabled) {
            MDPendingReschedule = NO;
            dispatch_async(dispatch_get_main_queue(), ^{
                MDLoadPreferences();
                MDStartTimer();
            });
        } else if (MDPendingReschedule && MDEnabled) {
            MDPendingReschedule = NO;
            MDStartTimer();
        }
    }];
    (void)completed;
}

- (void)dealloc {
    AVPlayerItem *item = self.player.currentItem;
    if (item) {
        @try {
            [item removeObserver:self forKeyPath:@"status"];
        } @catch (__unused NSException *exception) {
        }
    }
    if (self.endObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.endObserver];
    if (self.failedObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.failedObserver];
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
@end

static void MDPlay(void) {
    if (!MDEnabled || MDShowing) return;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!MDEnabled || MDShowing) return;

        UIWindowScene *scene = MDActiveWindowScene();
        UIWindow *underlying = MDActiveWindow();
        if (!scene || !underlying) {
            MDStartTimer();
            return;
        }

        NSString *path = MDNormalizedVideoPath(MDVideoPath);
        if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) path = MDDefaultVideoPath();
        if (!path.length) {
            NSLog(@"[MusorDropTrollTweak] no usable video path");
            MDStartTimer();
            return;
        }

        MDUnderlyingWindow = underlying;
        MDShowing = YES;
        MDCancelTimer();

        MDOverlayViewController *controller = [MDOverlayViewController new];
        UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
        window.rootViewController = controller;
        window.windowLevel = UIWindowLevelAlert + 1.0;
        window.backgroundColor = UIColor.clearColor;
        window.opaque = NO;
        window.frame = scene.coordinateSpace.bounds;
        MDOverlayWindow = window;
        [window makeKeyAndVisible];
    });
}

static void MDStartTimer(void) {
    MDCancelTimer();
    if (!MDEnabled || MDShowing) return;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;

    NSTimeInterval delay = MAX(0.0, MDRolloutDelay);
    MDTimerBlock = dispatch_block_create(DISPATCH_BLOCK_INHERIT_QOS_CLASS, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            MDTimerBlock = nil;
            MDPlay();
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), MDTimerBlock);
}

static void MDPreferencesChanged(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        MDCancelTimer();
        MDLoadPreferences();

        if (!MDEnabled) {
            MDPendingReschedule = NO;
            if (MDShowing) {
                MDOverlayViewController *controller = (MDOverlayViewController *)MDOverlayWindow.rootViewController;
                [controller finishWithResult:NO restartTimer:NO];
            }
            return;
        }

        // Apply sends this notification explicitly. The countdown therefore
        // does not react while the user is still editing the Settings pane.
        if (MDShowing) {
            MDPendingReschedule = YES;
            return;
        }
        MDStartTimer();
    });
}

static void MDDarwinPreferenceCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    MDPreferencesChanged();
}

%ctor {
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *bundleID = bundle.bundleIdentifier ?: @"";
    if (bundleID.length == 0 || [bundleID hasPrefix:@"com.apple."]) return;
    if ([bundle.bundleURL.pathExtension.lowercaseString isEqualToString:@"appex"]) return;

    MDLoadPreferences();

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        MDDarwinPreferenceCallback,
        (__bridge CFStringRef)kMDPreferencesChanged,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    MDActiveObserver = [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        MDLoadPreferences();
        MDStartTimer();
    }];
    MDBackgroundObserver = [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        MDCancelTimer();
    }];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (MDEnabled && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) MDStartTimer();
    });
}
