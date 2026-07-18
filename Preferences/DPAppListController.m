#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>

@interface DPAppListController : PSListController
@property (nonatomic, copy) NSString *listType; // @"favorites" or @"blacklist"
@property (nonatomic, strong) NSMutableArray<NSString *> *bundleIDs;
@end

@implementation DPAppListController

- (void)viewDidLoad {
    [super viewDidLoad];
    // listType comes from the specifier that pushed us
    self.listType = [self.specifier propertyForKey:@"listType"] ?: @"favorites";
    self.title = [self.listType isEqualToString:@"favorites"] ? @"Favorites" : @"Blacklist";

    NSArray *stored = (NSArray *)CFBridgingRelease(CFPreferencesCopyAppValue(
        (__bridge CFStringRef)self.listType, CFSTR("com.dualpane.tweak")));
    self.bundleIDs = [stored isKindOfClass:[NSArray class]] ? [stored mutableCopy] : [NSMutableArray array];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(addBundleID)];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:
                              ([self.listType isEqualToString:@"favorites"]
                               ? @"Favorite apps appear first in the picker.\n收藏应用会优先显示在选择器中。"
                               : @"Blacklisted apps cannot be opened in DualPane.\n黑名单中的应用无法在 DualPane 中打开。")
                                                            target:self
                                                               set:NULL
                                                               get:NULL
                                                            detail:Nil
                                                              cell:PSGroupCell
                                                              edit:Nil];
        [specs addObject:group];

        for (NSString *bid in self.bundleIDs) {
            PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:bid
                                                               target:self
                                                                  set:NULL
                                                                  get:NULL
                                                               detail:Nil
                                                                 cell:PSTitleValueCell
                                                                 edit:Nil];
            [spec setProperty:bid forKey:@"bundleID"];
            [specs addObject:spec];
        }

        if (self.bundleIDs.count == 0) {
            PSSpecifier *empty = [PSSpecifier preferenceSpecifierNamed:@"(empty — tap + to add)"
                                                                target:self
                                                                   set:NULL
                                                                   get:NULL
                                                                detail:Nil
                                                                  cell:PSStaticTextCell
                                                                  edit:Nil];
            [specs addObject:empty];
        }

        _specifiers = specs;
    }
    return _specifiers;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (indexPath.row < (NSInteger)self.bundleIDs.count) {
        return UITableViewCellEditingStyleDelete;
    }
    return UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (editingStyle == UITableViewCellEditingStyleDelete && indexPath.row < (NSInteger)self.bundleIDs.count) {
        [self.bundleIDs removeObjectAtIndex:indexPath.row];
        [self persist];
        [self reloadSpecifiers];
    }
}

- (void)addBundleID {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add Bundle ID"
                                                                   message:@"Enter an app bundle identifier\n输入应用 Bundle ID\n(e.g. com.apple.mobilesafari)"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"com.example.app";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.keyboardType = UIKeyboardTypeURL;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        NSString *bid = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (bid.length == 0) return;
        if (![self.bundleIDs containsObject:bid]) {
            [self.bundleIDs addObject:bid];
            [self persist];
            [self reloadSpecifiers];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)persist {
    CFPreferencesSetAppValue((__bridge CFStringRef)self.listType,
                             (__bridge CFPropertyListRef)self.bundleIDs,
                             CFSTR("com.dualpane.tweak"));
    CFPreferencesAppSynchronize(CFSTR("com.dualpane.tweak"));
    notify_post("com.dualpane.tweak/settings.changed");
}

@end
