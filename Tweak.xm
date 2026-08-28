#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <rootless.h>

static CFStringRef const kMDPreferencesDomain = CFSTR("com.fogboundsloth25.musordroptrolltweak");
static NSString * const kMDPreferencesChanged = @"com.fogboundsloth25.musordroptrolltweak/preferences.changed";
static NSString * const kMDVideoRelativePath = @"/Library/Application Support/MusorDropTrollTweak/video_alpha.mov";

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
    NSString *path = ROOT_PATH_NS(kMDVideoRelativePath);
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
        CGFloat stored = [volume doubleValue];
        // Keep compatibility with older releases that stored volume as 0.0-1.0.
        MDVolume = stored <= 1.0 ? MAX(0.0, MIN(1.0, stored)) : MAX(0.0, MIN(1.0, stored / 100.0));
    } else {
        MDVolume = 1.0f;
    }

    MDVideoPath = ([video isKindOfClass:NSString.class] && video.length > 0) ? [video copy] : nil;
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
@property(nonatomic,assign) BOOL finishing;
@end

@implementation MDOverlayViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.opaque = NO;
    self.view.userInteractionEnabled = YES;

    self.playerLayer = [AVPlayerLayer layer];
    self.playerLayer.frame = self.view.bounds;
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [self.view.layer addSublayer:self.playerLayer];

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
    if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) path = MDDefaultVideoPath();
    if (!path.length) {
        NSLog(@"[MusorDropTrollTweak] video not found: custom=%@ default=%@", MDVideoPath, MDDefaultVideoPath());
        [self finishWithResult:NO restartTimer:NO];
        return;
    }

    NSURL *url = [NSURL fileURLWithPath:path isDirectory:NO];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    self.player = [AVPlayer playerWithPlayerItem:item];
    self.player.volume = MDVolume;
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
    self.playerLayer.player = self.player;

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
    [audio setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeMoviePlayback options:0 error:&audioError];
    if (audioError) NSLog(@"[MusorDropTrollTweak] audio category error: %@", audioError);
    audioError = nil;
    [audio setActive:YES error:&audioError];
    if (audioError) NSLog(@"[MusorDropTrollTweak] audio session error: %@", audioError);

    if (@available(iOS 10.0, *)) {
        [asset loadValuesAsynchronouslyForKeys:@[@"playable"] completionHandler:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                if (weakSelf.finishing) return;
                NSError *error = nil;
                AVKeyValueStatus status = [asset statusOfValueForKey:@"playable" error:&error];
                if (status == AVKeyValueStatusLoaded && asset.playable) {
                    [weakSelf.player play];
                } else {
                    NSLog(@"[MusorDropTrollTweak] asset not playable: status=%ld error=%@", (long)status, error);
                    [weakSelf finishWithResult:NO restartTimer:YES];
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

- (void)finishWithResult:(BOOL)completed restartTimer:(BOOL)restartTimer {
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
    (void)completed;
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

        // Any settings change restarts the countdown from zero.
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
