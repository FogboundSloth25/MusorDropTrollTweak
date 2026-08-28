#import <Preferences/PSListController.h>

@interface MDRootListController : PSListController
@end

@implementation MDRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSBundle *bundle = [NSBundle bundleForClass:[self class]];
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self bundle:bundle];
    }
    return _specifiers;
}

@end
