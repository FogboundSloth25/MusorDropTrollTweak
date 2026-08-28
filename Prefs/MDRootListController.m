#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <CoreFoundation/CoreFoundation.h>

static CFStringRef const kMDPreferencesDomain = CFSTR("com.fogboundsloth25.musordroptrolltweak");
static CFStringRef const kMDPreferencesChanged = CFSTR("com.fogboundsloth25.musordroptrolltweak/preferences.changed");
static NSInteger const kMDSchemaVersion = 2;

@interface MDRootListController : PSListController
@end

@implementation MDRootListController

- (id)init {
    self = [super init];
    if (self) {
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:(__bridge NSString *)kMDPreferencesDomain];
        NSInteger version = [defaults integerForKey:@"schemaVersion"];
        if (version < kMDSchemaVersion) {
            id oldVolume = [defaults objectForKey:@"volume"];
            if ([oldVolume isKindOfClass:NSNumber.class]) {
                double value = [oldVolume doubleValue];
                // Older builds stored volume as 0.0-1.0. Version 2 uses 0-100%.
                if (value > 0.0 && value <= 1.0) {
                    [defaults setDouble:(value * 100.0) forKey:@"volume"];
                }
            }
            [defaults setInteger:kMDSchemaVersion forKey:@"schemaVersion"];
            [defaults synchronize];
        }
    }
    return self;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)applySettings {
    CFPreferencesAppSynchronize(kMDPreferencesDomain);
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        kMDPreferencesChanged,
        NULL,
        NULL,
        true
    );
}

@end
