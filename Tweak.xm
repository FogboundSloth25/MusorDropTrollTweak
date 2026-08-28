#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

static CFStringRef const kMDPreferencesDomain = CFSTR("com.fogboundsloth25.musordroptrolltweak");
static NSString * const kMDPreferencesChanged = @"com.fogboundsloth25.musordroptrolltweak/preferences.changed";

static NSTimeInterval MDRolloutDelay = 10.0;
static float MDVolume = 1.0f;
static BOOL MDEnabled = YES;
static NSString *MDVideoPath = nil;

static BOOL MDTimerScheduled = NO;
static BOOL MDShowing = NO;
static BOOL MDPendingReschedule = NO;
static dispatch_block_t MDTimerBlock = nil;
static UIWindow *MDOverlayWindow = nil;
static UIWindow *MDUnderlyingWindow = nil;
static id MDActiveObserver = nil;
static id MDBackgroundObserver = nil;
static id MDPreferencesObserver = nil;

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
    NSString *jbroot = @"/var/jb/Library/Application Support/MusorDropTrollTweak/video_alpha.mov";
    NSString *rootful = @"/Library/Application Support/MusorDropTrollTweak/video_alpha.mov";
    if ([fm fileExistsAtPath:jbroot]) return jbroot;
    if ([fm fileExistsAtPath:rootful]) return rootful;
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
    MDTimerScheduled = NO;
}

static void MDLoadPreferences(void) {
    id enabled = MDPreference(@"enabled");
    id delay = MDPreference(@"delay");
    id volume = MDPreference(@"volume");
    id video = MDPreference(@"videoPath");

    MDEnabled = enabled ? [enabled boolValue] : YES;
    MDRolloutDelay = [delay isKindOfClass:NSNumber.class] ? MAX(0.0, [delay doubleValue]) : 10.0;
    MDVolume = [volume isKindOfClass:NSNumber.class] ? MAX(0.0f, MIN(1.0f, [volume floatValue])) : 1.0f;
    MDVideoPath = ([video isKindOfClass:NSString.class] && [video length] > 0) ? [video copy] : nil;
}

static void MDStartTimer(void);
static void MDPlay(void);

@interface MDOverlayViewController : UIViewController
@property(nonatomic,strong) AVPlayer *player;
@property(nonatomic,strong) AVPlayerLayer *playerLayer;
@property(nonatomic,strong) UIControl *blocker;
@property(nonatomic,strong) UIView *dimView;
@property(nonatomic,strong) id endObserver;
@property(nonatomic,strong) id failedObserver;
@property(nonatomic,strong) id statusObserver;
@property(nonatomic,assign) BOOL finishing;
@end

@implementation MDOverlayViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.opaque = NO;
    self.view.userInteractionEnabled = YES;

    self.dimView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.25];
    self.dimView.userInteractionEnabled = NO;
    [self.view addSubview:self.dimView];

    self.blocker = [[UIControl alloc] initWithFrame:self.view.bounds];
    self.blocker.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.blocker.backgroundColor = UIColor.clearColor;
    self.blocker.userInteractionEnabled = YES;
    [self.view addSubview:self.blocker];

    NSString *path = MDNormalizedVideoPath(MDVideoPath);
    if (![path length] || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        path = MDDefaultVideoPath();
    }

    if (![path length]) {
        NSLog(@"[MusorDropTrollTweak] no video file found");
        [self finishWithResult:NO];
        return;
    }

    NSURL *url = [NSURL fileURLWithPath:path isDirectory:NO];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    self.player = [AVPlayer playerWithPlayerItem:item];
    self.player.volume = MDVolume;
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndPause;

    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    self.playerLayer.frame = self.view.bounds;
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [self.view.layer insertSublayer:self.playerLayer below:self.dimView.layer];

    __weak typeof(self) weakSelf = self;
    self.endObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:item queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [weakSelf finishWithResult:YES];
    }];
    self.failedObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification object:item queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        NSLog(@"[MusorDropTrollTweak] AVPlayer failed: %@", note.userInfo);
        [weakSelf finishWithResult:NO];
    }];
    self.statusObserver = [item observeValueForKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:NULL], nil;

    if (@available(iOS 10.0, *)) {
        [asset loadValuesAsynchronouslyForKeys:@[@"playable"] completionHandler:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                if (weakSelf.finishing) return;
                NSError *error = nil;
                AVKeyValueStatus status = [asset statusOfValueForKey:@"playable" error:&error];
                if (status == AVKeyValueStatusLoaded && asset.playable) {
                    [weakSelf.player play];
                } else {
                    NSLog(@"[MusorDropTrollTweak] video asset is not playable: %@", error);
                    [weakSelf finishWithResult:NO];
                }
            });
        }];
    } else {
        [self.player play];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.player play];
    [self setNeedsStatusBarAppearanceUpdate];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.playerLayer.frame = self.view.bounds;
    self.dimView.frame = self.view.bounds;
    self.blocker.frame = self.view.bounds;
}

- (void)finishWithResult:(BOOL)completed {
    if (self.finishing) return;
    self.finishing = YES;

    if (self.endObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.endObserver];
        self.endObserver = nil;
    }
    if (self.failedObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.failedObserver];
        self.failedObserver = nil;
    }
    [self.player pause];

    if (MDOverlayWindow == self.view.window) {
        MDOverlayWindow.hidden = YES;
        MDOverlayWindow.rootViewController = nil;
        MDOverlayWindow = nil;
    }
    if (MDUnderlyingWindow) {
        [MDUnderlyingWindow makeKeyAndVisible];
        MDUnderlyingWindow = nil;
    }
    MDShowing = NO;
    MDTimerScheduled = NO;

    if (MDPendingReschedule || completed || MDEnabled) {
        MDPendingReschedule = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            MDLoadPreferences();
            if (MDEnabled) MDStartTimer();
        });
    }
}

- (void)dealloc {
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
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        MDTimerScheduled = NO;
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!MDEnabled || MDShowing) return;

        UIWindowScene *scene = MDActiveWindowScene();
        UIWindow *underlying = MDActiveWindow();
        if (!scene || !underlying) {
            MDStartTimer();
            return;
        }

        NSString *path = MDNormalizedVideoPath(MDVideoPath);
        if (![path length] || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            path = MDDefaultVideoPath();
        }
        if (![path length]) {
            NSLog(@"[MusorDropTrollTweak] default/custom video path does not exist");
            MDStartTimer();
            return;
        }

        MDUnderlyingWindow = underlying;
        MDShowing = YES;
        MDTimerScheduled = NO;

        MDOverlayViewController *controller = [MDOverlayViewController new];
        UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
        window.rootViewController = controller;
        window.windowLevel = UIWindowLevelAlert + 1.0;
        window.backgroundColor = UIColor.clearColor;
        window.opaque = NO;
        window.hidden = NO;
        window.frame = scene.screen.bounds;
        MDOverlayWindow = window;
        [window makeKeyAndVisible];
    });
}

static void MDStartTimer(void) {
    MDCancelTimer();
    if (!MDEnabled || MDShowing) return;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;

    NSTimeInterval delay = MAX(0.0, MDRolloutDelay);
    MDTimerScheduled = YES;

    __weak typeof(MDTimerBlock) weakBlock = MDTimerBlock;
    MDTimerBlock = dispatch_block_create(DISPATCH_BLOCK_INHERIT_QOS_CLASS, ^{
        (void)weakBlock;
        dispatch_async(dispatch_get_main_queue(), ^{
            MDTimerScheduled = NO;
            MDPlay();
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), MDTimerBlock);
}

static void MDPreferencesChanged(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL wasShowing = MDShowing;
        MDCancelTimer();
        MDLoadPreferences();

        if (!MDEnabled) {
            MDPendingReschedule = NO;
            return;
        }

        if (wasShowing) {
            MDPendingReschedule = YES;
            return;
        }

        // A delay change starts a completely new countdown from the moment the preference changes.
        MDStartTimer();
    });
}

%ctor {
    NSBundle *bundle = [NSBundle mainBundle];
    NSDictionary *info = bundle.infoDictionary ?: @{};
    NSString *bundleID = bundle.bundleIdentifier ?: @"";
    NSString *packageType = info[@"CFBundlePackageType"];

    if (![packageType isEqualToString:@"APPL"]) return;
    if (bundleID.length == 0 || [bundleID hasPrefix:@"com.apple."]) return;
    if ([bundleID hasSuffix:@".appex"]) return;

    MDLoadPreferences();
    if (!MDEnabled) return;

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    MDActiveObserver = [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        MDLoadPreferences();
        MDStartTimer();
    }];
    MDBackgroundObserver = [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        MDCancelTimer();
    }];
    MDPreferencesObserver = [nc addObserverForName:kMDPreferencesChanged object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        MDPreferencesChanged();
    }];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
            MDStartTimer();
        }
    });
}
