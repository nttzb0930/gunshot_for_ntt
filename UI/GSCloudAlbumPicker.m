#import "GSCloudAlbumPicker.h"
#import "GSPanel.h"
#import "../Shared/GSLocalization.h"
#import "../Shared/IPCProtocol.h"

@interface GSCloudAlbumPicker () <UISearchResultsUpdating>
@property (nonatomic, copy) NSString *account;
@property (nonatomic, copy) NSString *selectedID;
@property (nonatomic, copy) void (^selection)(NSString *, NSString *);
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *albums;
@property (nonatomic, strong) NSArray<NSDictionary *> *filtered;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, copy) NSString *state;
@property (nonatomic) BOOL requesting;
@property (nonatomic) BOOL refreshPending;
@property (nonatomic) BOOL active;
@property (nonatomic) NSInteger cursor;
@property (nonatomic) NSUInteger generation;
@end

@implementation GSCloudAlbumPicker
- (instancetype)initWithAccount:(NSString *)account
                     selectedID:(NSString *)selectedID
                      selection:(void (^)(NSString *, NSString *))selection {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _account = [account copy];
        _selectedID = [selectedID copy];
        _selection = [selection copy];
        _albums = [NSMutableArray array];
        _filtered = @[];
        _state = @"idle";
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = GSL(@"Choose album");
    self.navigationItem.prompt = nil;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;
    self.tableView.alwaysBounceVertical = YES;
    self.refreshControl = [UIRefreshControl new];
    self.refreshControl.accessibilityLabel = GSL(@"Refresh albums");
    [self.refreshControl addTarget:self
                            action:@selector(reloadAlbums)
                  forControlEvents:UIControlEventValueChanged];
    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = GSL(@"Search album names");
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.navigationItem.rightBarButtonItem = GSPanelDoneButton(self);
    self.navigationItem.backButtonDisplayMode = UINavigationItemBackButtonDisplayModeMinimal;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.active = YES;
    [self load:NO];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.active = NO;
    self.refreshPending = NO;
    [self.refreshControl endRefreshing];
    self.generation++;
}
- (void)reloadAlbums {
    if (!self.active) {
        [self.refreshControl endRefreshing];
        return;
    }
    if (self.requesting) {
        self.refreshPending = YES;
        return;
    }
    self.refreshPending = NO;
    self.generation++;
    self.state = @"loading";
    self.cursor = 0;
    [self.albums removeAllObjects];
    [self updateSearchResultsForSearchController:self.search];
    [self load:YES];
}
- (void)load:(BOOL)refresh {
    if (!self.active || self.requesting)
        return;
    self.requesting = YES;
    NSUInteger generation = self.generation;
    NSInteger cursor = self.cursor;
    NSDictionary *request = @{
        @"op" : @"album_catalog",
        @"account" : self.account,
        @"confirm" : @(refresh),
        @"cursor" : @(cursor)
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *result = GSRequest(request, nil);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.requesting = NO;
            if (self.active && self.refreshPending) {
                [self reloadAlbums];
                return;
            }
            if (!self.active || generation != self.generation) {
                if (self.active)
                    [self load:NO];
                return;
            }
            self.state = result[@"state"] ?: @"failed";
            if ([self.state isEqual:@"failed"]) {
                self.cursor = 0;
                [self.albums removeAllObjects];
            }
            if ([self.state isEqual:@"ready"]) {
                if (cursor == 0)
                    [self.albums removeAllObjects];
                [self.albums addObjectsFromArray:result[@"albums"] ?: @[]];
                NSInteger next = [result[@"next"] integerValue];
                if (result[@"next"] && next > cursor) {
                    self.cursor = next;
                    [self load:NO];
                } else {
                    self.cursor = 0;
                    [self.albums sortUsingComparator:^NSComparisonResult(NSDictionary *a,
                                                                         NSDictionary *b) {
                        NSComparisonResult order = [a[@"name"] localizedStandardCompare:b[@"name"]];
                        return order == NSOrderedSame ? [a[@"albumKey"] compare:b[@"albumKey"]]
                                                      : order;
                    }];
                }
            } else if ([self.state isEqual:@"loading"] || [self.state isEqual:@"idle"]) {
                __weak GSCloudAlbumPicker *weakSelf = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                               dispatch_get_main_queue(), ^{
                                   if (weakSelf.active && generation == weakSelf.generation)
                                       [weakSelf load:NO];
                               });
            }
            if (!self.requesting && ![self.state isEqual:@"loading"] &&
                ![self.state isEqual:@"idle"])
                [self.refreshControl endRefreshing];
            [self updateSearchResultsForSearchController:self.search];
        });
    });
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [searchController.searchBar.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!query.length)
        self.filtered = [self.albums copy];
    else
        self.filtered = [self.albums
            filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(
                                                         NSDictionary *album,
                                                         NSDictionary *bindings) {
                return [album[@"name"]
                           rangeOfString:query
                                 options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch]
                           .location != NSNotFound;
            }]];
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0)
        return 1;
    if (self.filtered.count)
        return self.filtered.count;
    return [self.state isEqual:@"failed"] ? 2 : 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 1 ? GSL(@"Shared albums may require permission to add photos.") : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                   reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    if (path.section == 0) {
        cell.textLabel.text = GSL(@"Enter Album ID manually");
        cell.textLabel.textColor = tableView.tintColor;
        cell.imageView.image = [UIImage systemImageNamed:@"rectangle.and.pencil.and.ellipsis"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (!self.filtered.count) {
        if (path.row == 1 && [self.state isEqual:@"failed"]) {
            cell.textLabel.text = GSL(@"Retry");
            cell.textLabel.textColor = tableView.tintColor;
            cell.imageView.image = [UIImage systemImageNamed:@"arrow.clockwise"];
            return cell;
        }
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if ([self.state isEqual:@"failed"]) {
            cell.textLabel.text = GSL(@"Could not load albums");
            cell.detailTextLabel.text =
                GSL(@"Refresh to try again. If access has expired, reconnect the account. You can "
                    @"also enter an Album ID manually.");
        } else if ([self.state isEqual:@"ready"] && !self.requesting) {
            cell.textLabel.text =
                self.albums.count ? GSL(@"No matching albums") : GSL(@"No accessible albums");
        } else {
            cell.textLabel.text = GSL(@"Loading albums…");
        }
    } else {
        NSDictionary *album = self.filtered[path.row];
        cell.textLabel.text = [album[@"name"] length] ? album[@"name"] : GSL(@"Untitled album");
        cell.detailTextLabel.text =
            [NSString stringWithFormat:GSL(@"%@ items"), album[@"count"] ?: @0];
        cell.accessoryType = [album[@"albumKey"] isEqual:self.selectedID]
                                 ? UITableViewCellAccessoryCheckmark
                                 : UITableViewCellAccessoryNone;
    }
    return cell;
}
- (void)choose:(NSString *)key name:(NSString *)name {
    void (^selection)(NSString *, NSString *) = [self.selection copy];
    UINavigationController *navigation = self.navigationController;
    [navigation popViewControllerAnimated:YES];
    // Recovery presents a confirmation on the previous screen. Invoke selection
    // after the pop finishes so it never presents from an offscreen controller.
    if (navigation.transitionCoordinator)
        [navigation.transitionCoordinator
            animateAlongsideTransition:nil
                            completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
                                if (!context.isCancelled && selection)
                                    selection(key, name);
                            }];
    else if (selection)
        selection(key, name);
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section == 1) {
        if ([self.state isEqual:@"failed"] && path.row == 1)
            [self reloadAlbums];
        else if (path.row < self.filtered.count) {
            NSDictionary *album = self.filtered[path.row];
            [self choose:album[@"albumKey"] name:album[@"name"]];
        }
        return;
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:GSL(@"Album ID")
                         message:
                             GSL(@"Use this only if the album cannot be selected from the list.")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.spellCheckingType = UITextSpellCheckingTypeNo;
        field.placeholder = @"AF1Qip…";
    }];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:GSL(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert
        addAction:
            [UIAlertAction
                actionWithTitle:GSL(@"Choose album")
                          style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *action) {
                            NSString *key = [weakAlert.textFields.firstObject.text
                                stringByTrimmingCharactersInSet:
                                    NSCharacterSet.whitespaceAndNewlineCharacterSet];
                            NSCharacterSet *invalid =
                                [[NSCharacterSet characterSetWithCharactersInString:
                                                     @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqr"
                                                     @"stuvwxyz0123456789_-"] invertedSet];
                            if (![key hasPrefix:@"AF1Qip"] || key.length < 10 || key.length > 512 ||
                                [key rangeOfCharacterFromSet:invalid].location != NSNotFound) {
                                UIAlertController *error = [UIAlertController
                                    alertControllerWithTitle:GSL(@"Invalid Album ID")
                                                     message:
                                                         GSL(@"Enter the album ID beginning with "
                                                             @"AF1Qip, without the website URL.")
                                              preferredStyle:UIAlertControllerStyleAlert];
                                [error addAction:[UIAlertAction
                                                     actionWithTitle:GSL(@"OK")
                                                               style:UIAlertActionStyleDefault
                                                             handler:nil]];
                                [self presentViewController:error animated:YES completion:nil];
                                return;
                            }
                            [self choose:key name:@""];
                        }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
