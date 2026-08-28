#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

static NSTimeInterval MDRolloutDelay = 10.0;
static BOOL MDEnabled = YES;
static BOOL MDMuted = NO;
static NSString *MDVideoPath = nil;

@interface MDOverlayViewController : UIViewController
@property(nonatomic,strong) AVPlayer *player;
@property(nonatomic,strong) AVPlayerLayer *playerLayer;
@property(nonatomic,strong) UIControl *blocker;
@property(nonatomic,strong) UIView *dimView;
@property(nonatomic,strong) id endObserver;
@end

@implementation MDOverlayViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.userInteractionEnabled = YES;

    self.dimView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.dimView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.25];
    [self.view addSubview:self.dimView];

    self.blocker = [[UIControl alloc] initWithFrame:self.view.bounds];
    self.blocker.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.blocker.backgroundColor = UIColor.clearColor;
    [self.view addSubview:self.blocker];

    NSString *path = MDVideoPath;
    if (!path.length) {
        path = [[NSBundle bundleForClass:self.class] pathForResource:@"video_alpha" ofType:@"mov"];
    }
    if (!path.length) {
        path = [[NSBundle mainBundle] pathForResource:@"video" ofType:@"mp4"];
    }
    if (!path.length) {
        [self finish];
        return;
    }

    NSURL *url = [NSURL fileURLWithPath:path];
    self.player = [AVPlayer playerWithURL:url];
    self.player.volume = MDMute d ? 0.0 : 1.0;
    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    self.playerLayer.frame = self.view.bounds;
    [self.view.layer insertSublayer:self.playerLayer atIndex:0];

    __weak typeof(self) weakSelf = self;
    self.endObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:self.player.currentItem queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [weakSelf finish];
    }];
    [self.player play];
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
    [self.player pause];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
@end

static UIViewController *MDTopViewController(UIViewController *root) {
    UIViewController *current = root;
    while (current.presentedViewController) current = current.presentedViewController;
    if ([current isKindOfClass:UINavigationController.class]) return MDTopViewController([(UINavigationController *)current topViewController]);
    if ([current isKindOfClass:UITabBarController.class]) return MDTopViewController([(UITabBarController *)current selectedViewController]);
    return current;
}

static void MDPlay(void) {
    if (!MDEnabled) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene.delegate respondsToSelector:@selector(window)]) {
                window = [scene.delegate window];
                if (window) break;
            }
            if ([scene isKindOfClass:UIWindowScene.class]) {
                for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                    if (candidate.isKeyWindow) { window = candidate; break; }
                }
                if (window) break;
            }
        }
        if (!window) return;
        UIViewController *top = MDTopViewController(window.rootViewController);
        if (!top) return;
        MDOverlayViewController *overlay = [MDOverlayViewController new];
        overlay.modalPresentationStyle = UIModalPresentationOverFullScreen;
        overlay.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        [top presentViewController:overlay animated:YES completion:nil];
    });
}

static void MDLoadPreferences(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.fogboundsloth25.musordroptrolltweak.plist"];
    if (![prefs isKindOfClass:NSDictionary.class]) return;
    NSNumber *enabled = prefs[@"enabled"];
    NSNumber *delay = prefs[@"delay"];
    NSNumber *muted = prefs[@"muted"];
    NSString *video = prefs[@"videoPath"];
    if (enabled) MDEnabled = enabled.boolValue;
    if (delay) MDRolloutDelay = MAX(0.0, delay.doubleValue);
    if (muted) MDMute d = muted.boolValue;
    if ([video isKindOfClass:NSString.class] && video.length) MDVideoPath = [video copy];
}

%ctor {
    MDLoadPreferences();
    if (!MDEnabled) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MDRolloutDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        MDPlay();
    });
}
