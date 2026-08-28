#import <Preferences/PSListController.h>

@interface MDRootListController : PSListController
@end

@implementation MDRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

@end
