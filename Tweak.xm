#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

static CFStringRef const kMDPreferencesDomain = CFSTR("com.fogboundsloth25.musordroptrolltweak");
static NSTimeInterval MDRolloutDelay = 10.0;
static float MDVolume = 1.0f;
static BOOL MDEnabled = YES;
static NSString *MDVideoPath = nil;
static BOOL MDTriggered = NO;
static BOOL MDShowing = NO;
static UIWindow *MDOverlayWindow = nil;
static UIWindow *MDUnderlyingWindow = nil;
static id MDActiveObserver = nil;

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
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *paths = @[
        @"/var/jb/Library/Application Support/MusorDropTrollTweak/video_alpha.mov",
        @"/Library/Application Support/MusorDropTrollTweak/video_alpha.mov"
    ];
    for (NSString *path in paths) {
        if ([fm fileExistsAtPath:path]) return path;
    }
    return nil;
}

static UIWindowScene *MDActiveWindowScene(void) {
    UIApplication *app = UIApplication.sharedApplication;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

static UIWindow *MDActiveWindow(void) {
    UIWindowScene *scene = MDActiveWindowScene();
    if (!scene) return nil;

    for (UIWindow *window in scene.windows) {
        if (window.isKeyWindow && !window.hidden && window != MDOverlayWindow) return window;
    }
    for (UIWindow *window in scene.windows) {
        if (!window.hidden && window != MDOverlayWindow && window.alpha > 0.0) return window;
    }
    return nil;
}

@interface MDOverlayViewController : UIViewController
@property(nonatomic,strong) AVPlayer *player;
@property(nonatomic,strong) AVPlayerLayer *playerLayer;
@property(nonatomic,strong) UIControl *blocker;
@property(nonatomic,strong) UIView *dimView;
@property(nonatomic,strong) id endObserver;
@property(nonatomic,strong) id failedObserver;
@property(nonatomic,strong) id statusObserver;
@end

@implementation MDOverlayViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.opaque = NO;
    self.view.userInteractionEnabled = YES;

    self.dimView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.dimView.backgroundColor = UIColor.clearColor;
    self.dimView.userInteractionEnabled = NO;
    [self.view addSubview:self.dimView];

    NSString *path = MDNormalizedVideoPath(MDVideoPath);
    if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        path = MDDefaultVideoPath();
    }

    if (!path.length) {
        NSLog(@"[MusorDropTrollTweak] video file not found");
        [self finish];
        return;
    }

    NSURL *url = [NSURL fileURLWithPath:path];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    self.player = [AVPlayer playerWithPlayerItem:item];
    self.player.volume = MAX(0.0f, MIN(1.0f, MDVolume));
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndPause;

    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    self.playerLayer.frame = self.view.bounds;
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [self.view.layer addSublayer:self.playerLayer];

    self.blocker = [[UIControl alloc] initWithFrame:self.view.bounds];
    self.blocker.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.blocker.backgroundColor = UIColor.clearColor;
    self.blocker.userInteractionEnabled = YES;
    [self.view addSubview:self.blocker];

    __weak typeof(self) weakSelf = self;
    self.endObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:item queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [weakSelf finish];
    }];
    self.failedObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification object:item queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        NSLog(@"[MusorDropTrollTweak] AVPlayer failed: %@", note.userInfo);
        [weakSelf finish];
    }];
    self.statusObserver = [item observeKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew changeHandler:^(AVPlayerItem *observedItem, NSDictionary<NSKeyValueChangeKey,id> *change) {
        AVPlayerStatus status = observedItem.status;
        if (status == AVPlayerStatusFailed) {
            NSLog(@"[MusorDropTrollTweak] AVPlayerItem status failed: %@", observedItem.error);
            [weakSelf finish];
        } else if (status == AVPlayerStatusReadyToPlay) {
            [weakSelf.player playImmediatelyAtRate:1.0];
        }
    }];

    [UIView animateWithDuration:0.35 animations:^{
        weakSelf.dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.25];
    }];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.player playImmediatelyAtRate:1.0];
    [self setNeedsStatusBarAppearanceUpdate];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.playerLayer.frame = self.view.bounds;
    self.dimView.frame = self.view.bounds;
    self.blocker.frame = self.view.bounds;
}

- (void)dealloc {
    if (self.endObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.endObserver];
    if (self.failedObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.failedObserver];
}

- (void)finish {
    if (self.endObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.endObserver];
        self.endObserver = nil;
    }
    if (self.failedObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.failedObserver];
        self.failedObserver = nil;
    }
    self.statusObserver = nil;
    [self.player pause];

    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.2 animations:^{
        weakSelf.dimView.backgroundColor = UIColor.clearColor;
    } completion:^(BOOL finished) {
        if (MDOverlayWindow == weakSelf.view.window) {
            MDOverlayWindow.hidden = YES;
            MDOverlayWindow.rootViewController = nil;
            MDOverlayWindow = nil;
        }
        if (MDUnderlyingWindow) {
            [MDUnderlyingWindow makeKeyAndVisible];
            MDUnderlyingWindow = nil;
        }
        MDShowing = NO;
    }];
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
@end

static void MDPlay(void);

static void MDScheduleFromActiveState(void) {
    if (!MDEnabled || MDTriggered || MDShowing) return;

    UIApplication *app = UIApplication.sharedApplication;
    if (app.applicationState != UIApplicationStateActive) return;

    MDTriggered = YES;
    if (MDActiveObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:MDActiveObserver];
        MDActiveObserver = nil;
    }

    NSTimeInterval delay = MAX(0.0, MDRolloutDelay);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        MDPlay();
    });
}

static void MDPlay(void) {
    if (!MDEnabled || MDShowing) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (MDShowing) return;

        UIWindowScene *scene = MDActiveWindowScene();
        UIWindow *underlying = MDActiveWindow();
        if (!scene || !underlying) {
            MDTriggered = NO;
            return;
        }

        NSString *path = MDNormalizedVideoPath(MDVideoPath);
        if (path.length == 0 && MDDefaultVideoPath() == nil) {
            NSLog(@"[MusorDropTrollTweak] no playable video path");
            return;
        }

        MDUnderlyingWindow = underlying;
        MDShowing = YES;

        MDOverlayViewController *controller = [MDOverlayViewController new];
        MDOverlayWindow = [[UIWindow alloc] initWithWindowScene:scene];
        MDOverlayWindow.frame = scene.coordinateSpace.bounds;
        MDOverlayWindow.rootViewController = controller;
        MDOverlayWindow.windowLevel = UIWindowLevelAlert + 1.0;
        MDOverlayWindow.backgroundColor = UIColor.clearColor;
        MDOverlayWindow.opaque = NO;
        MDOverlayWindow.hidden = NO;
        [MDOverlayWindow makeKeyAndVisible];
    });
}

static void MDLoadPreferences(void) {
    id enabled = MDPreference(@"enabled");
    id delay = MDPreference(@"delay");
    id volume = MDPreference(@"volume");
    id video = MDPreference(@"videoPath");

    MDEnabled = enabled ? [enabled boolValue] : YES;
    if ([delay isKindOfClass:NSNumber.class]) MDRolloutDelay = MAX(0.0, [delay doubleValue]);
    if ([volume isKindOfClass:NSNumber.class]) MDVolume = MAX(0.0f, MIN(1.0f, [volume floatValue]));
    if ([video isKindOfClass:NSString.class] && video.length) MDVideoPath = [video copy];
}

%ctor {
    NSBundle *bundle = [NSBundle mainBundle];
    NSDictionary *info = bundle.infoDictionary ?: @{};
    NSString *bundleID = bundle.bundleIdentifier ?: @"";
    NSString *packageType = info[@"CFBundlePackageType"];

    if (bundleID.length == 0 || [bundleID hasPrefix:@"com.apple."]) return;
    if (![packageType isEqualToString:@"APPL"]) return;
    if ([bundleID hasSuffix:@".appex"]) return;

    MDLoadPreferences();
    if (!MDEnabled) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = UIApplication.sharedApplication;
        if (app.applicationState == UIApplicationStateActive) {
            MDScheduleFromActiveState();
        } else {
            MDActiveObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
                MDScheduleFromActiveState();
            }];
        }
    });
}
