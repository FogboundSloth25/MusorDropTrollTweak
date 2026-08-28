#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>

@interface MDRootListController : PSListController
@end

@implementation MDRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSBundle *bundle = [NSBundle bundleForClass:[self class]];
        NSString *plistPath = [bundle pathForResource:@"Root" ofType:@"plist"];

        if (plistPath.length) {
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            NSArray *entries = plist[@"PreferenceSpecifiers"];
            if ([entries isKindOfClass:NSArray.class]) {
                _specifiers = [[self specifiersFromPlist:plist] copy];
            }
        }

        if (!_specifiers) {
            _specifiers = @[];
        }
    }
    return _specifiers;
}

@end
