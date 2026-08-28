#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

static CFStringRef const kMDPreferencesDomain = CFSTR("com.fogboundsloth25.musordroptrolltweak");
static NSTimeInterval MDRolloutDelay = 10.0;
static float MDVolume = 1.0f;
static BOOL MDEnabled = YES;
static NSString *MDVideoPath = nil;
static BOOL MDShowing = NO;

static id MDPreference(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, kMDPreferencesDomain));
}

static NSString *MDDefaultVideoPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *paths = @[
        @"/Library/Application Support/MusorDropTrollTweak/video_alpha.mov",
        @"/var/jb/Library/Application Support/MusorDropTrollTweak/video_alpha.mov"
    ];
    for (NSString *path in paths) {
        if ([fm fileExistsAtPath:path]) return path;
    }
    return [[NSBundle bundleForClass:NSClassFromString(@"MDOverlayViewController")] pathForResource:@"video_alpha" ofType:@"mov"];
}

@interface MDOverlayViewController : UIViewController
@property(nonatomic,strong) AVPlayer *player;
@property(nonatomic,strong) AVPlayerLayer *playerLayer;
@property(nonatomic,strong) UIControl *blocker;
@property(nonatomic,strong) UIView *dimView;
@property(nonatomic,strong) id endObserver;
@property(nonatomic,strong) id failedObserver;
@end

@implementation MDOverlayViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.userInteractionEnabled = YES;

    self.dimView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.0];
    self.dimView.userInteractionEnabled = NO;
    [self.view addSubview:self.dimView];

    self.blocker = [[UIControl alloc] initWithFrame:self.view.bounds];
    self.blocker.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.blocker.backgroundColor = UIColor.clearColor;
    self.blocker.exclusiveTouch = YES;
    [self.view addSubview:self.blocker];

    NSString *path = nil;
    if (MDVideoPath.length && [[NSFileManager defaultManager] fileExistsAtPath:MDVideoPath]) {
        path = MDVideoPath;
    } else {
        path = MDDefaultVideoPath();
    }

    if (!path.length) {
        [self finish];
        return;
    }

    NSURL *url = [NSURL fileURLWithPath:path];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    self.player = [AVPlayer playerWithPlayerItem:item];
    self.player.volume = MAX(0.0f, MIN(1.0f, MDVolume));

    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    self.playerLayer.frame = self.view.bounds;
    [self.view.layer insertSublayer:self.playerLayer atIndex:0];

    __weak typeof(self) weakSelf = self;
    self.endObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:item queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [weakSelf finish];
    }];
    self.failedObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification object:item queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [weakSelf finish];
    }];

    [self.player play];
    [UIView animateWithDuration:0.35 animations:^{
        weakSelf.dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.25];
    }];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.playerLayer.frame = self.view.bounds;
    self.dimView.frame = self.view.bounds;
    self.blocker.frame = self.view.bounds;
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
    [self.player pause];
    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.2 animations:^{
        weakSelf.dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.0];
    } completion:^(BOOL finished) {
        MDShowing = NO;
        [weakSelf dismissViewControllerAnimated:YES completion:nil];
    }];
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
@end

static UIViewController *MDTopViewController(UIViewController *root) {
    if (!root) return nil;
    UIViewController *current = root;
    while (current.presentedViewController) current = current.presentedViewController;
    if ([current isKindOfClass:UINavigationController.class]) {
        return MDTopViewController([(UINavigationController *)current topViewController]);
    }
    if ([current isKindOfClass:UITabBarController.class]) {
        return MDTopViewController([(UITabBarController *)current selectedViewController]);
    }
    return current;
}

static UIWindow *MDActiveWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    for (UIScene *scene in app.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow && !window.hidden) return window;
        }
    }
    return nil;
}

static void MDPlay(void) {
    if (!MDEnabled || MDShowing) return;
    MDShowing = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = MDActiveWindow();
        if (!window) {
            MDShowing = NO;
            return;
        }
        UIViewController *top = MDTopViewController(window.rootViewController);
        if (!top || top.presentedViewController) {
            MDShowing = NO;
            return;
        }

        MDOverlayViewController *overlay = [MDOverlayViewController new];
        overlay.modalPresentationStyle = UIModalPresentationOverFullScreen;
        overlay.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        [top presentViewController:overlay animated:YES completion:nil];
    });
}

static void MDLoadPreferences(void) {
    id enabled = MDPreference(@"enabled");
    id delay = MDPreference(@"delay");
    id volume = MDPreference(@"volume");
    id video = MDPreference(@"videoPath");

    if ([enabled isKindOfClass:NSNumber.class]) MDEnabled = [enabled boolValue];
    if ([delay isKindOfClass:NSNumber.class]) MDRolloutDelay = MAX(0.0, [delay doubleValue]);
    if ([volume isKindOfClass:NSNumber.class]) MDVolume = MAX(0.0f, MIN(1.0f, [volume floatValue]));
    if ([video isKindOfClass:NSString.class] && [video length] > 0) MDVideoPath = [video copy];
}

%ctor {
    if ([[NSBundle mainBundle].bundleIdentifier hasPrefix:@"com.apple."]) return;

    MDLoadPreferences();
    if (!MDEnabled) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MDRolloutDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        MDPlay();
    });
}
