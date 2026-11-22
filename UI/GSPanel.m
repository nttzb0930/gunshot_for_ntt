#import "../Shared/GSLocalization.h"
#import "GSPanel.h"
#import "GSPhotosGlass.h"
#import "GSDeveloperLinks.h"
#import "../Media/GSExporter.h"
#import "../Media/GSBatchImport.h"
#import "GSAlbumPicker.h"
#import "GSAlbumStatus.h"
#import "GSCloudAlbumPicker.h"
#import "../Native/GSNativeAccount.h"
#import "../Native/GSAccountConnection.h"
#if !GS_JAILED
#import "../Native/GSNativeRelay.h"
#else
#import "../Jailed/SideloadIdentity.h"
#endif
#import "../Native/GSNativeRouting.h"
#import "../Native/GSUploadDiagnostics.h"
#import "../Native/GSUnlimitedStorage.h"
#import "../Native/GSBackupRequests.h"
#import "../Native/GSCloudOnlyDeletion.h"
#import "../Native/GSPhotosIntegration.h"
#import "../Native/GSUploadMonitor.h"
#import "../Shared/IPCProtocol.h"
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>
#define GS_BACKUP_TITLE GSL(@"Route manual and automatic backups through GoToHP")
static char GSPanelPresentationKey;

#define GS_ACCOUNT_HELP GSL(@"Connect or refresh your account.")
#if GS_JAILED
#define GS_BACKUP_HELP                                                                             \
    GSL(@"Enable Google Photos backup for automatic uploads. GoToHP controls the quality. Keep "   \
        @"the app in the foreground.")
#define GS_QUEUED_HELP GSL(@"Keep the app open while uploading. Pending uploads resume next time.")
#define GS_AUTH_HELP                                                                               \
    GSL(@"Paste an EmbeddedSetup oauth_token or complete gotohp credential. Stored privately in "  \
        @"this app, sent to Google, and hidden after saving.")
#else
#define GS_BACKUP_HELP                                                                             \
    GSL(@"Enable Google Photos backup for automatic uploads. GoToHP controls the quality. Keep "   \
        @"the app open until the originals are queued; the daemon then uploads while "             \
        @"authorization is available.")
#define GS_QUEUED_HELP                                                                             \
    GSL(@"Queued uploads continue while authorization is available. Reopen Google Photos to "      \
        @"refresh authorization when needed.")
#define GS_AUTH_HELP                                                                               \
    GSL(@"Paste an EmbeddedSetup oauth_token or complete gotohp credential. Sent only to gotohpd " \
        @"and Google, and hidden after saving.")
#endif
@interface GSPanel () <PHPickerViewControllerDelegate>
@property (nonatomic, strong) NSArray *jobs;
@property (nonatomic, strong) NSDictionary *accounts;
@property (nonatomic, strong) NSDictionary *albumSnapshot;
@property (nonatomic, copy) NSString *albumAccount;
@property (nonatomic) BOOL albumSnapshotStale;
@property (nonatomic, copy) NSDictionary *pendingOptions;
@property (nonatomic, copy) NSDictionary *confirmedOptions;
@property (nonatomic) BOOL configuringOptions;
@property (nonatomic) BOOL displayRefreshScheduled;
@property (nonatomic) NSTimeInterval switchAnimationUntil;
@property (nonatomic, strong) NSMutableDictionary *options;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) BOOL busy;
@property (nonatomic) BOOL refreshing;
@property (nonatomic) BOOL exportingDiagnostics;
@property (nonatomic) NSUInteger stateGeneration;
@property (nonatomic) BOOL nativeAuthorizationFailed;
@property (nonatomic, strong) NSArray *sharedItems;
@property (nonatomic, copy) void (^activityCompletion)(void);
@property (nonatomic, copy) NSString *statusText;
@property (nonatomic, copy) NSString *statusLanguage;
@property (nonatomic, copy) NSString *tableLanguage;
@property (nonatomic, strong) NSIndexPath *sheetSourcePath;
@end
@implementation GSPanel
- (void)viewDidLoad {
    [super viewDidLoad];
    GSInstallPhotosGlass();
    GSInstallNativeRouting();
    GSInstallUploadDiagnostics();
    GSInstallUnlimitedStorage();
    self.title = @"GoToHP";
    self.jobs = @[];
    self.statusText = GSL(@"Checking the connection…");
    self.statusLanguage = GSLanguage();
    [self updateNavigationLabels];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72;
    if (self.settingsMode)
        self.tableView.tableHeaderView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.tintColor = [UIColor colorWithRed:0.10 green:0.45 blue:0.91 alpha:1];
    self.navigationController.navigationBar.tintColor = self.tableView.tintColor;
    [self refresh];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateNavigationLabels];
    self.albumSnapshotStale = YES;
    self.stateGeneration++;
    [self reloadTablePreservingPosition];
    [self refresh];
}
- (void)updateNavigationLabels {
    BOOL root = self.navigationController.viewControllers.firstObject == self;
    self.title = root ? @"GoToHP" : (self.settingsMode ? GSL(@"Settings") : GSL(@"Uploads"));
    // UIKit supplies Back only when this page has a predecessor.
    self.navigationItem.leftBarButtonItem = nil;
    self.navigationItem.hidesBackButton = root;
    self.navigationItem.backButtonDisplayMode = UINavigationItemBackButtonDisplayModeMinimal;
    self.navigationItem.rightBarButtonItems = nil;
    self.navigationItem.rightBarButtonItem = GSPanelDoneButton(self);
}
- (void)saveAlbumDestination:(NSDictionary *)settings account:(NSString *)account {
    if (self.busy || ![self.accounts[@"selected"] isEqual:account])
        return;
    self.albumSnapshotStale = YES;
    [self request:@{@"op" : @"album_configure", @"account" : account, @"album" : settings}];
}
- (void)chooseAlbumDestination {
    NSString *account = self.accounts[@"selected"];
    if (!account.length) {
        [self message:GSL(@"Connect an account to continue")];
        return;
    }
    if (!self.albumSnapshot) {
        [self message:GSL(@"Album status is unavailable. Tap to view details.")];
        return;
    }
    NSDictionary *settings = self.albumSnapshot[@"settings"];
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:GSL(@"Album destination")
                         message:
                             GSL(@"New destinations apply to newly queued media. Disabling album "
                                 @"assignment pauses pending album tasks; uploads continue.")
                  preferredStyle:UIAlertControllerStyleActionSheet];
    __weak GSPanel *weakSelf = self;
    [sheet addAction:[UIAlertAction
                         actionWithTitle:GSL(@"Do not add to an album")
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction *action) {
                                     NSMutableDictionary *disabled = [settings mutableCopy];
                                     disabled[@"enabled"] = @NO;
                                     [weakSelf saveAlbumDestination:disabled account:account];
                                 }]];
    [sheet addAction:[UIAlertAction
                         actionWithTitle:GSL(@"Existing Album")
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction *action) {
                                     GSPanel *panel = weakSelf;
                                     if (!panel)
                                         return;
                                     NSString *selectedKey = settings[@"albumKey"];
                                     if (!selectedKey.length)
                                         selectedKey =
                                             panel.albumSnapshot[@"resolvedAlbumKey"] ?: @"";
                                     GSCloudAlbumPicker *picker = [[GSCloudAlbumPicker alloc]
                                         initWithAccount:account
                                              selectedID:selectedKey
                                               selection:^(NSString *key, NSString *name) {
                                                   [weakSelf saveAlbumDestination:@{
                                                       @"enabled" : @YES,
                                                       @"mode" : @"existing",
                                                       @"albumKey" : key,
                                                       @"name" : name ?: @""
                                                   }
                                                                          account:account];
                                               }];
                                     [panel.navigationController pushViewController:picker
                                                                           animated:YES];
                                 }]];
    [sheet addAction:[UIAlertAction actionWithTitle:GSL(@"Create New Album")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                                [weakSelf createAlbumDestinationForAccount:account];
                                            }]];
    [sheet addAction:[UIAlertAction actionWithTitle:GSL(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self sheet:sheet];
}
- (void)createAlbumDestinationForAccount:(NSString *)account {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:GSL(@"Create New Album")
                                            message:GSL(@"Will be created after uploads finish.")
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = GSL(@"New album name");
    }];
    [alert addAction:[UIAlertAction actionWithTitle:GSL(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak GSPanel *weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert
        addAction:
            [UIAlertAction
                actionWithTitle:GSL(@"Save")
                          style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *save) {
                            NSString *name =
                                [weakAlert.textFields.firstObject.text
                                    stringByTrimmingCharactersInSet:
                                        NSCharacterSet.whitespaceAndNewlineCharacterSet]
                                    ?: @"";
                            NSMutableCharacterSet *invalid =
                                [NSMutableCharacterSet characterSetWithCharactersInString:@"\n\r"];
                            [invalid addCharactersInRange:NSMakeRange(0, 1)];
                            if (!name.length ||
                                [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 200 ||
                                [name rangeOfCharacterFromSet:invalid].location != NSNotFound) {
                                [weakSelf
                                    message:GSL(@"Enter a short album name without line breaks.")];
                                return;
                            }
                            [weakSelf saveAlbumDestination:@{
                                @"enabled" : @YES,
                                @"mode" : @"create",
                                @"name" : name
                            }
                                                   account:account];
                        }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)chooseLanguage {
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:GSL(@"Language")
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *codes = @[ @"system", @"ja", @"zh-hans", @"vi", @"en" ], *names = @[
        GSL(@"System default"), GSL(@"Japanese"), GSL(@"Simplified Chinese"), GSL(@"Vietnamese"),
        @"English"
    ];
    for (NSUInteger i = 0; i < codes.count; i++) {
        NSString *code = codes[i];
        NSString *title = [code isEqual:GSLanguageOverride()]
                              ? [@"✓ " stringByAppendingString:names[i]]
                              : names[i];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
                                                    GSSetLanguage(code);
                                                    [self updateNavigationLabels];
                                                    [self reloadTablePreservingPosition];
                                                    [self refresh];
                                                }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:GSL(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self sheet:sheet];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    __weak GSPanel *weak = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2
                                                 repeats:YES
                                                   block:^(NSTimer *t) {
                                                       [weak refresh];
                                                   }];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
}
- (void)openUploadPanel {
    if (self.busy)
        return;
    GSPanel *panel = [[GSPanel alloc] initWithStyle:UITableViewStyleInsetGrouped];
    [self.navigationController pushViewController:panel animated:YES];
}
- (void)openEmbeddedSettings {
    if (self.busy)
        return;
    GSPanel *settings = [[GSPanel alloc] initWithStyle:UITableViewStyleInsetGrouped];
    settings.settingsMode = YES;
    [self.navigationController pushViewController:settings animated:YES];
}
- (void)close {
    // Closing the screen does not cancel queued work or wait for authentication.
    GSPanel *root = (GSPanel *)self.navigationController.viewControllers.firstObject;
    if (root != self && [root isKindOfClass:GSPanel.class]) {
        [root close];
        return;
    }
    if (self.activityCompletion)
        self.activityCompletion();
    else
        [self dismissViewControllerAnimated:YES completion:nil];
}
- (BOOL)isInteractingWithTable {
    return self.tableView.tracking || self.tableView.dragging || self.tableView.decelerating ||
           NSProcessInfo.processInfo.systemUptime < self.switchAnimationUntil;
}
- (BOOL)switchEnabledForControl:(NSInteger)control {
    if (control == 19)
        return GSPhotosGlassAvailable();
    if (control == 16)
        return GSUnlimitedStorageAvailable();
    if (self.busy)
        return NO;
    if (control == 10)
        return GSNativeRoutingAvailable();
    if (control == 11)
        return GSUploadDiagnosticsAvailable();
    return self.options != nil;
}
- (NSArray *)presentationAtPath:(NSIndexPath *)path {
    NSString *language = GSLanguage();
    if (path.section == 0)
        return @[
            language, self.accounts[@"selected"] ?: @"", self.statusText ?: @"",
            self.statusLanguage ?: @"", @(self.busy)
        ];
    if (path.section == self.queueSection)
        return @[ language, path.row < self.jobs.count ? self.jobs[path.row] : @{} ];
    NSInteger control = [self controlAtPath:path];
    id state = @"";
    if ((control >= 3 && control <= 5) || control == 10 || control == 11 || control == 16 ||
        control == 19) {
        state = @[
            @([self switchValueForControl:control]), @([self switchEnabledForControl:control]),
            control == 19 ? @([GSPhotosGlassSnapshot()[@"restartRequired"] boolValue]) : @NO
        ];
    } else if (control >= 0 && control < 3) {
        state = self.options[@[ @"quality", @"concurrent", @"retries" ][control]] ?: @"";
    } else if (control == 6)
        state = self.accounts[@"selected"] ?: @"";
    else if (control == 13)
        state = @[ @(self.busy), self.accounts[@"selected"] ?: @"" ];
    else if (control == 14)
        state = @[ @(self.busy), @(self.sharedItems.count) ];
    else if (control == 15)
        state = GSLanguageOverride();
    else if (control == 18)
        state = @([GSBatchImportSnapshot()[@"active"] boolValue]);
    else if (control == 20)
        state = @[
            self.albumSnapshot[@"settings"] ?: @{}, self.albumSnapshot[@"resolvedAlbumKey"] ?: @""
        ];
    else if (control == 22)
        state = @(self.busy);
    return @[ language, @(control), state ];
}
- (void)reloadTablePreservingPosition {
    // Do not relayout underneath a finger, a switch animation, or a sheet anchor.
    if ([self isInteractingWithTable] || self.presentedViewController) {
        if (!self.displayRefreshScheduled) {
            self.displayRefreshScheduled = YES;
            __weak GSPanel *weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                               GSPanel *panel = weakSelf;
                               if (!panel)
                                   return;
                               panel.displayRefreshScheduled = NO;
                               if (panel.viewIfLoaded.window &&
                                   panel.navigationController.topViewController == panel)
                                   [panel reloadTablePreservingPosition];
                           });
        }
        return;
    }
    UITableView *table = self.tableView;
    NSIndexPath *anchor = table.indexPathsForVisibleRows.firstObject;
    CGFloat delta =
        anchor ? table.contentOffset.y - [table rectForRowAtIndexPath:anchor].origin.y : 0;
    CGPoint offset = table.contentOffset;
    if (![self.tableLanguage isEqual:GSLanguage()] ||
        table.numberOfSections != [self numberOfSectionsInTableView:table]) {
        [table reloadData];
        self.tableLanguage = GSLanguage();
    } else {
        NSInteger queue = self.queueSection;
        BOOL resized = [table numberOfRowsInSection:queue] != [self tableView:table
                                                                  numberOfRowsInSection:queue];
        if (resized)
            [UIView performWithoutAnimation:^{
                [table reloadSections:[NSIndexSet indexSetWithIndex:queue]
                     withRowAnimation:UITableViewRowAnimationNone];
            }];
        NSMutableArray *paths = [NSMutableArray array];
        for (NSIndexPath *path in table.indexPathsForVisibleRows) {
            if (path.section >= table.numberOfSections ||
                path.row >= [table numberOfRowsInSection:path.section])
                continue;
            UITableViewCell *cell = [table cellForRowAtIndexPath:path];
            if (!cell)
                continue;
            if (![objc_getAssociatedObject(cell, &GSPanelPresentationKey)
                    isEqual:[self presentationAtPath:path]])
                [paths addObject:path];
        }
        if (!resized && !paths.count)
            return;
        if (paths.count)
            [UIView performWithoutAnimation:^{
                [table reconfigureRowsAtIndexPaths:paths];
            }];
        [table headerViewForSection:queue].textLabel.text = [self tableView:table
                                                    titleForHeaderInSection:queue];
    }
    [table layoutIfNeeded];
    if (anchor && anchor.section < table.numberOfSections &&
        anchor.row < [table numberOfRowsInSection:anchor.section])
        offset.y = [table rectForRowAtIndexPath:anchor].origin.y + delta;
    CGFloat minimum = -table.adjustedContentInset.top;
    CGFloat maximum = MAX(minimum, table.contentSize.height - table.bounds.size.height +
                                       table.adjustedContentInset.bottom);
    [table setContentOffset:CGPointMake(offset.x, MIN(MAX(offset.y, minimum), maximum))
                   animated:NO];
}
- (void)acknowledgeSwitch:(UISwitch *)toggle {
    // The sender already animates itself. Record it instead of reconfiguring its cell.
    for (NSIndexPath *path in self.tableView.indexPathsForVisibleRows) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
        if (cell.accessoryView != toggle)
            continue;
        if (toggle.tag == 19) {
            // Its explanatory text can change height; update only this row after the animation.
            [self reloadTablePreservingPosition];
            return;
        }
        objc_setAssociatedObject(cell, &GSPanelPresentationKey, [self presentationAtPath:path],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        break;
    }
}
- (void)message:(NSString *)message {
    BOOL changed =
        ![self.statusText isEqual:message] || ![self.statusLanguage isEqual:GSLanguage()];
    self.statusText = message;
    self.statusLanguage = GSLanguage();
    if (changed && !self.presentedViewController)
        [self reloadTablePreservingPosition];
}
- (void)refresh {
    // Presented sheets keep their popover anchor; reloading the table under them can drop the source view (issue #50).
    if (self.busy || self.configuringOptions || self.refreshing || self.nativeAuthorizationFailed ||
        [self isInteractingWithTable] || self.presentedViewController)
        return;
    self.refreshing = YES;
    NSUInteger generation = self.stateGeneration;
    NSDictionary *cachedAlbum = self.albumSnapshot;
    NSString *cachedAlbumAccount = self.albumAccount;
    BOOL reloadAlbum = self.albumSnapshotStale;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        NSDictionary *accounts = GSRequest(@{@"op" : @"accounts"}, &error);
        NSDictionary *options = accounts ? GSRequest(@{@"op" : @"options"}, &error) : nil;
        NSMutableArray *jobs = [NSMutableArray array];
        NSInteger cursor = 0;
        NSDictionary *page = nil;
        if (options)
            do {
                page = GSRequest(@{@"op" : @"list", @"cursor" : @(cursor)}, &error);
                if (!page)
                    break;
                [jobs addObjectsFromArray:page[@"jobs"] ?: @[]];
                cursor = [page[@"next"] integerValue];
            } while (cursor >= 0);
        // Album status is optional: a failed album query must not hide upload status.
        NSString *account = accounts[@"selected"];
        NSDictionary *album = nil;
        if (!self.settingsMode && account.length)
            album = !reloadAlbum && cachedAlbum && [cachedAlbumAccount isEqual:account]
                        ? cachedAlbum
                        : GSRequest(@{@"op" : @"album_status", @"account" : account}, nil);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.refreshing = NO;
            // A poll completing during a gesture is superseded by the next idle poll.
            // Do not change the data source count or invalidate self-sizing rows mid-scroll.
            if ([self isInteractingWithTable])
                return;
            if (generation != self.stateGeneration) {
                [self refresh];
                return;
            }
            if (error) {
                [self message:error.localizedDescription];
                return;
            }
            BOOL changed = ![self.accounts isEqual:accounts] || ![self.options isEqual:options] ||
                           ![self.jobs isEqual:jobs] ||
                           (self.albumSnapshot != album && ![self.albumSnapshot isEqual:album]);
            NSString *previousStatus = self.statusText, *previousLanguage = self.statusLanguage;
            self.accounts = accounts;
            self.albumSnapshot = album;
            self.albumAccount = account;
            self.albumSnapshotStale = album == nil;
            self.options = [options mutableCopy];
            self.jobs = jobs;
            NSString *readiness = GSL(@"Ready to upload");
            if ([options[@"paused"] boolValue])
                readiness = GSL(@"Uploads paused");
            else if (![page[@"online"] boolValue])
                readiness = GSL(@"Waiting for a connection or app launch");
            else if ([options[@"wifiOnly"] boolValue] && ![page[@"wifi"] boolValue])
                readiness = GSL(@"Waiting for Wi-Fi");
            else if ([options[@"chargingOnly"] boolValue] && ![page[@"charging"] boolValue])
                readiness = GSL(@"Waiting for charging");
            NSString *authorization = GSL(@"Account configured");
#if !GS_JAILED
            if ([accounts[@"nativeAuthorization"] isEqual:@"ready"])
                authorization = GSL(@"Authenticated");
            else if ([accounts[@"nativeAuthorization"] isEqual:@"waiting"])
                readiness = GSL(@"Open Google Photos and reconnect to refresh authorization.");
#endif
#if GS_JAILED
            NSDictionary *runtime = GSEmbeddedRuntimeSnapshot();
            if ([runtime[@"authorization"] isEqual:@"validated"])
                authorization = GSL(@"Authenticated");
            if (![options[@"paused"] boolValue]) {
                if (![runtime[@"conditionsAccepted"] boolValue])
                    readiness = GSL(@"Could not apply upload conditions (check diagnostics)");
                else if (![runtime[@"foreground"] boolValue])
                    readiness = GSL(@"Waiting for the app to enter the foreground");
                else if ([runtime[@"path"] isEqual:@"unknown"])
                    readiness = GSL(@"Checking network status");
                else if (![runtime[@"networkOnline"] boolValue])
                    readiness = GSL(@"Waiting for a network connection");
            }
#endif
            self.statusText = [accounts[@"selected"] length]
                                  ? [NSString stringWithFormat:@"%@ · %@", authorization, readiness]
                                  : GSL(@"Connect an account to continue");
            NSString *importError = GSNativeRoutingSnapshot()[@"lastError"];
            if (importError)
                self.statusText = importError;
            self.statusLanguage = GSLanguage();
            NSDictionary *batch = GSBatchImportSnapshot();
            if ([batch[@"total"] unsignedIntegerValue])
                self.statusText =
                    [self.statusText stringByAppendingFormat:@"\n%@", [self batchStatus:batch]];
            if ((changed || ![previousStatus isEqual:self.statusText] ||
                 ![previousLanguage isEqual:self.statusLanguage]) &&
                !self.presentedViewController)
                [self reloadTablePreservingPosition];
        });
    });
}
- (NSArray<NSDictionary *> *)controlSections {
    if (!self.settingsMode) {
        NSMutableArray *sections = [NSMutableArray arrayWithArray:@[
            @{
                @"title" : GSL(@"Album"),
                @"rows" : @[ @20 ],
                @"footer" : GSL(@"The destination applies to newly queued media. Existing tasks "
                                @"keep their original album.")
            },
            @{
                @"title" : GSL(@"Choose content"),
                @"rows" : @[ @14, @17, @18 ],
                @"footer" :
                    [GSL(@"For large batches, choose an album. The photo picker is limited to "
                         @"100 items per selection.\n") stringByAppendingString:GS_QUEUED_HELP]
            }
        ]];
        if (self.navigationController.viewControllers.firstObject == self)
            [sections addObject:@{@"title" : GSL(@"Settings"), @"rows" : @[ @23 ]}];
        return sections;
    }
    NSMutableArray *groups = [NSMutableArray array];
    if (!GSIsGooglePhotos())
        [groups addObject:@{@"title" : GSL(@"Account"), @"rows" : @[ @6, @7 ]}];
    [groups addObject:@{@"title" : GSL(@"Uploads"), @"rows" : @[ @22 ]}];
    [groups addObject:@{
        @"title" : GSL(@"Upload settings"),
        @"rows" : @[ @0, @1, @2, @3, @4, @5 ],
        @"footer" :
            [GSL(@"Pixel 1 requests original quality without storage usage (Pixel XL). Quality is "
                 @"fixed when queued. Verify storage usage and original data in Google Photos.\n")
                stringByAppendingString:GS_QUEUED_HELP]
    }];
    if (GSIsGooglePhotos())
        [groups addObject:@{
            @"title" : GSL(@"Google Photos integration"),
            @"rows" : @[ @10 ],
            @"footer" : GS_BACKUP_HELP
        }];
    [groups addObject:@{@"title" : GSL(@"Queue management"), @"rows" : @[ @8, @9 ]}];
    if (GSIsGooglePhotos())
        [groups addObject:@{
            @"title" : GSL(@"Diagnostics"),
            @"rows" : @[ @11, @12 ],
            @"footer" : GSL(@"Export one report for upload and album issues. Tokens and media are "
                            @"never recorded.")
        }];
    [groups addObject:@{
        @"title" : GSL(@"Appearance"),
        @"rows" : GSIsGooglePhotos() ? @[ @15, @16, @19 ] : @[ @15 ],
        @"footer" : GSIsGooglePhotos()
            ? GSL(@"Reopen the profile menu to apply changes. Unlimited storage affects only the "
                  @"display; account limits and upload quality stay unchanged.")
            : GSL(@"Reopen the profile menu to update its language.")
    }];
    return groups;
}
- (NSInteger)queueSection {
    return self.controlSections.count + 1;
}
- (NSInteger)controlAtPath:(NSIndexPath *)path {
    NSArray *sections = self.controlSections;
    if (path.section < 1 || path.section > sections.count)
        return -1;
    NSArray *rows = sections[path.section - 1][@"rows"];
    return path.row < rows.count ? [rows[path.row] integerValue] : -1;
}
- (NSString *)qualityTitle:(NSString *)quality {
    return @{
        @"original" : GSL(@"Original quality · Pixel 1"),
        @"saver" : GSL(@"Storage saver · Pixel 2"),
        @"quota" : GSL(@"Original quality · Uses account storage")
    }[quality ?: @""]
               ?: GSL(@"Not configured");
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.queueSection + 1 + (self.settingsMode ? 1 : 0);
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.settingsMode && section == self.queueSection + 1)
        return 3;
    if (section == 0)
        return 1;
    if (section == self.queueSection)
        return MAX(self.jobs.count, 1);
    return [self.controlSections[section - 1][@"rows"] count];
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.settingsMode && section == self.queueSection + 1)
        return GSL(@"Developer");
    if (section == 0)
        return GSL(@"Connection status");
    if (section == self.queueSection)
        return [NSString
            stringWithFormat:GSL(@"Upload history (%lu)"), (unsigned long)self.jobs.count];
    return self.controlSections[section - 1][@"title"];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0 || section >= self.queueSection)
        return nil;
    return self.controlSections[section - 1][@"footer"];
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (!self.settingsMode)
        return UITableViewAutomaticDimension;
    // Keep grouped headings compact while respecting the user's text size.
    CGFloat lineHeight = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote].lineHeight;
    return MAX(section == 0 ? 28 : 36, lineHeight + (section == 0 ? 12 : 20));
}
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    if (self.settingsMode && ![self tableView:tableView titleForFooterInSection:section].length)
        return 8;
    return UITableViewAutomaticDimension;
}
- (BOOL)switchValueForControl:(NSInteger)control {
    if (control == 10)
        return GSNativeRoutingEnabled();
    if (control == 11)
        return GSUploadDiagnosticsEnabled();
    if (control == 16)
        return GSUnlimitedStorageEnabled();
    if (control == 19)
        return GSPhotosGlassEnabled();
    return [self.options[@[ @"wifiOnly", @"chargingOnly", @"paused" ][control - 3]] boolValue];
}
- (void)controlSwitchChanged:(UISwitch *)toggle {
    self.switchAnimationUntil = NSProcessInfo.processInfo.systemUptime + 0.35;
    NSInteger control = toggle.tag;
    BOOL desired = toggle.on;
    if (control == 19) {
        GSSetPhotosGlass(desired);
        [self acknowledgeSwitch:toggle];
        return;
    }
    if (control == 16) {
        GSSetUnlimitedStorage(desired);
        [self acknowledgeSwitch:toggle];
        return;
    }
    if (self.busy) {
        [toggle setOn:[self switchValueForControl:control] animated:YES];
        return;
    }
    if (control == 10) {
        // Enabling backup routing requires confirmation before changing the saved value.
        if (desired)
            [toggle setOn:[self switchValueForControl:control] animated:YES];
        [self toggleNativeRouting];
        return;
    }
    if (control == 11) {
        GSSetUploadDiagnostics(desired);
        [self acknowledgeSwitch:toggle];
        return;
    }
    NSMutableDictionary *options = [self.options mutableCopy];
    if (!options) {
        [toggle setOn:[self switchValueForControl:control] animated:YES];
        return;
    }
    options[@[ @"wifiOnly", @"chargingOnly", @"paused" ][control - 3]] = @(desired);
    [self request:@{@"op" : @"configure", @"options" : options}];
    [self acknowledgeSwitch:toggle];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    if (self.settingsMode && path.section == self.queueSection + 1) {
        UITableViewCell *developer = [self developerCellForRow:path.row];
        objc_setAssociatedObject(developer, &GSPanelPresentationKey, [self presentationAtPath:path],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return developer;
    }
    NSInteger control = [self controlAtPath:path];
    NSString *identifier = path.section == 0 ? @"status"
                           : control >= 0
                               ? [NSString stringWithFormat:@"control-%ld", (long)control]
                               : @"job";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    objc_setAssociatedObject(cell, &GSPanelPresentationKey, [self presentationAtPath:path],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [[cell.contentView viewWithTag:6020] removeFromSuperview];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.text = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (![cell.accessoryView isKindOfClass:UISwitch.class])
        cell.accessoryView = nil;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.imageView.tintColor = tableView.tintColor;
    if (path.section == 0) {
        cell.textLabel.text = [self.accounts[@"selected"] length] ? self.accounts[@"selected"]
                                                                  : GSL(@"Google Photos account");
        cell.detailTextLabel.text = GSLocalizedStatus(self.statusText, self.statusLanguage);
        cell.imageView.image = [UIImage systemImageNamed:@"person.crop.circle"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (self.busy) {
            UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
                initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            [spinner startAnimating];
            UIView *indicator = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
            spinner.center = CGPointMake(22, 22);
            [indicator addSubview:spinner];
            cell.accessoryView = indicator;
        } else {
            UIButton *refresh = [UIButton buttonWithType:UIButtonTypeSystem];
            refresh.frame = CGRectMake(0, 0, 44, 44);
            [refresh setImage:[UIImage systemImageNamed:@"arrow.clockwise"]
                     forState:UIControlStateNormal];
            refresh.accessibilityLabel =
                [self.accounts[@"selected"] length] ? GSL(@"Reconnect") : GSL(@"Connect account");
            [refresh addTarget:self
                          action:@selector(refreshAccount:)
                forControlEvents:UIControlEventTouchUpInside];
            cell.accessoryView = refresh;
        }
        return cell;
    }
    if (control >= 0) {
        NSArray *titles = @[
            GSL(@"Quality"),
            GSL(@"Concurrent uploads"),
            GSL(@"Retry limit"),
            GSL(@"Wi-Fi only"),
            GSL(@"Charging only"),
            GSL(@"Pause uploads"),
            GSL(@"Destination account"),
            GSL(@"Remove account from GoToHP"),
            GSL(@"Retry failed uploads"),
            GSL(@"Clear completed history"),
            GS_BACKUP_TITLE,
            GSL(@"Upload diagnostics"),
            GSL(@"Export diagnostics"),
            GSL(@"Connect or refresh account"),
            GSL(@"Choose photos and videos"),
            GSL(@"Language"),
            GSL(@"Show unlimited storage"),
            GSL(@"Choose album on this device"),
            GSL(@"Stop preparing"),
            @"Google Photos · Liquid Glass",
            GSL(@"Album destination"),
            GSL(@"Album status"),
            GSL(@"Upload photos and videos"),
            GSL(@"Settings")
        ];
        NSArray *icons = @[
            @"photo",
            @"square.stack.3d.up",
            @"arrow.clockwise",
            @"wifi",
            @"battery.100.bolt",
            @"pause.circle",
            @"person.crop.circle.badge.checkmark",
            @"person.crop.circle.badge.minus",
            @"arrow.clockwise.circle",
            @"checkmark.circle",
            @"arrow.triangle.branch",
            @"waveform.path.ecg",
            @"square.and.arrow.up",
            @"person.crop.circle.badge.checkmark",
            @"plus.circle",
            @"globe",
            @"cloud",
            @"rectangle.stack",
            @"stop.circle",
            @"rectangle.bottomhalf.inset.filled",
            @"rectangle.stack.badge.plus",
            @"waveform.path.ecg",
            @"square.and.arrow.up",
            @"gearshape"
        ];
        cell.textLabel.text = titles[control];
        cell.imageView.image = [UIImage systemImageNamed:icons[control]];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (control == 22)
            cell.detailTextLabel.text =
                GSL(@"Choose photos, an album destination, and view progress");
        if (control == 13 || control == 14) {
            NSString *title =
                control == 13 ? ([self.accounts[@"selected"] length] ? GSL(@"Reconnect")
                                                                     : GSL(@"Connect account"))
                : control == 14 && self.sharedItems.count ? GSL(@"Upload selected items")
                                                          : titles[control];
            UIButtonConfiguration *configuration =
                control == 13 ? [UIButtonConfiguration grayButtonConfiguration]
                              : [UIButtonConfiguration filledButtonConfiguration];
            configuration.title = title;
            configuration.image = [UIImage systemImageNamed:icons[control]];
            configuration.imagePadding = 10;
            configuration.cornerStyle = UIButtonConfigurationCornerStyleMedium;
            configuration.contentInsets = NSDirectionalEdgeInsetsMake(14, 16, 14, 16);
            __weak GSPanel *weakSelf = self;
            UIButton *button =
                [UIButton buttonWithConfiguration:configuration
                                    primaryAction:[UIAction actionWithHandler:^(UIAction *action) {
                                        GSPanel *panel = weakSelf;
                                        if (!panel || panel.busy)
                                            return;
                                        panel.sheetSourcePath = path;
                                        if (control == 13)
                                            [panel addAccount];
                                        else
                                            [panel primary];
                                    }]];
            button.tag = 6020;
            button.enabled = !self.busy;
            button.titleLabel.adjustsFontForContentSizeCategory = YES;
            button.titleLabel.numberOfLines = 0;
            button.translatesAutoresizingMaskIntoConstraints = NO;
            cell.textLabel.text = nil;
            cell.imageView.image = nil;
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            [cell.contentView addSubview:button];
            [NSLayoutConstraint activateConstraints:@[
                [button.leadingAnchor
                    constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
                [button.trailingAnchor
                    constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
                [button.topAnchor
                    constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.topAnchor],
                [button.bottomAnchor
                    constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.bottomAnchor],
                [button.heightAnchor constraintGreaterThanOrEqualToConstant:48]
            ]];
            return cell;
        }
        if (control == 20) {
            NSDictionary *settings = self.albumSnapshot[@"settings"];
            cell.detailTextLabel.text =
                !self.albumSnapshot ? GSL(@"Album status is unavailable. Try again shortly.")
                : ![settings[@"enabled"] boolValue]
                    ? GSL(@"Do not add to an album")
                    : [NSString stringWithFormat:@"%@ - %@",
                                                 ([settings[@"mode"] isEqual:@"create"] &&
                                                  ![self.albumSnapshot[@"resolvedAlbumKey"] length])
                                                     ? GSL(@"Create New Album")
                                                     : GSL(@"Existing Album"),
                                                 [settings[@"name"] length]
                                                     ? settings[@"name"]
                                                     : GSL(@"Selected album")];
        }
        if (control == 17)
            cell.detailTextLabel.text =
                GSL(@"Choose an album on this device as the upload source.");
        if (control == 18) {
            BOOL active = [GSBatchImportSnapshot()[@"active"] boolValue];
            cell.textLabel.textColor =
                active ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.detailTextLabel.text =
                GSL(@"Stop after the current item. Queued uploads continue.");
        }
        if (control == 15) {
            NSString *code = GSLanguageOverride();
            NSDictionary *names = @{
                @"system" : GSL(@"System default"),
                @"ja" : GSL(@"Japanese"),
                @"zh-hans" : GSL(@"Simplified Chinese"),
                @"vi" : GSL(@"Vietnamese"),
                @"en" : @"English"
            };
            cell.detailTextLabel.text = names[code] ?: @"English";
        }
        if (control == 0)
            cell.detailTextLabel.text = [self qualityTitle:self.options[@"quality"]];
        if (control == 1)
            cell.detailTextLabel.text = [NSString
                stringWithFormat:GSL(@"Concurrent uploads: %@"), self.options[@"concurrent"] ?: @1];
        if (control == 2)
            cell.detailTextLabel.text =
                [NSString stringWithFormat:GSL(@"Retry limit: %@"), self.options[@"retries"] ?: @3];
        if (control == 6)
            cell.detailTextLabel.text = self.accounts[@"selected"];
        if (control == 13)
            cell.detailTextLabel.text = GSL(@"Check the connection for the signed-in account");
        if (control == 7)
            cell.textLabel.textColor = UIColor.systemRedColor;
        if ((control >= 3 && control <= 5) || control == 10 || control == 11 || control == 16 ||
            control == 19) {
            UISwitch *toggle = (UISwitch *)cell.accessoryView;
            if (!toggle) {
                toggle = [UISwitch new];
                toggle.on = [self switchValueForControl:control];
                [toggle addTarget:self
                              action:@selector(controlSwitchChanged:)
                    forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = toggle;
            } else if (toggle.on != [self switchValueForControl:control])
                [toggle setOn:[self switchValueForControl:control] animated:toggle.window != nil];
            toggle.tag = control;
            toggle.accessibilityLabel = titles[control];
            toggle.onTintColor = tableView.tintColor;
            toggle.enabled = [self switchEnabledForControl:control];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        if (control == 19) {
            NSDictionary *glass = GSPhotosGlassSnapshot();
            cell.detailTextLabel.text =
                !GSPhotosGlassAvailable() ? GSL(@"Unavailable in this version")
                : [glass[@"restartRequired"] boolValue]
                    ? GSL(@"Restart Google Photos to apply the Liquid Glass change.")
                    : GSL(@"Liquid Glass for the bottom bar and search button. Requires iOS 26 or "
                          @"later.");
        }
        if (control == 16 && !GSUnlimitedStorageAvailable())
            cell.detailTextLabel.text = GSL(@"Unavailable in this version");
        if (control == 10 && !GSNativeRoutingAvailable())
            cell.detailTextLabel.text = GSL(@"Unavailable in this version");
        return cell;
    }
    if (!self.jobs.count) {
        cell.textLabel.text = GSL(@"No uploads yet");
        cell.detailTextLabel.text = GSL(@"Use Choose photos and videos to add items.");
        cell.imageView.image = [UIImage systemImageNamed:@"tray"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSDictionary *job = self.jobs[path.row];
    NSArray *resources = job[@"resources"];
    NSString *state = job[@"state"];
    NSDictionary *states = @{
        @"pending" : GSL(@"Pending"),
        @"preparing" : GSL(@"Preparing"),
        @"uploading" : GSL(@"Uploading"),
        @"committing" : GSL(@"Committing"),
        @"completed" : GSL(@"Completed"),
        @"failed" : GSL(@"Failed"),
        @"cancelled" : GSL(@"Cancelled")
    };
    cell.textLabel.text = resources.firstObject[@"name"] ?: GSL(@"Media");
    long long uploaded = [job[@"uploaded"] longLongValue], total = [job[@"total"] longLongValue];
    NSString *sizes =
        [NSString stringWithFormat:@"%@ / %@",
                                   [NSByteCountFormatter
                                       stringFromByteCount:uploaded
                                                countStyle:NSByteCountFormatterCountStyleFile],
                                   [NSByteCountFormatter
                                       stringFromByteCount:total
                                                countStyle:NSByteCountFormatterCountStyleFile]];
    cell.detailTextLabel.text =
        [NSString stringWithFormat:@"%@ · %@\n%@", states[state ?: @""] ?: GSL(@"Checking status"),
                                   [self qualityTitle:job[@"quality"]], sizes];
    cell.imageView.image =
        [UIImage systemImageNamed:[state isEqual:@"completed"] ? @"checkmark.circle.fill"
                                  : [state isEqual:@"failed"]  ? @"exclamationmark.circle"
                                                               : @"icloud.and.arrow.up"];
    if ([state isEqual:@"failed"]) {
        cell.imageView.tintColor = UIColor.systemRedColor;
        cell.detailTextLabel.text =
            [cell.detailTextLabel.text stringByAppendingString:GSL(@"\nTap to retry")];
    } else if ([state isEqual:@"completed"])
        cell.imageView.tintColor = UIColor.systemGreenColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)chooseValueForControl:(NSInteger)control {
    NSString *key = @[ @"quality", @"concurrent", @"retries" ][control];
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:@[
            GSL(@"Quality"), GSL(@"Concurrent uploads"), GSL(@"Retry limit")
        ][control]
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *values = control == 0   ? @[ @"original", @"saver", @"quota" ]
                      : control == 1 ? @[ @1, @2, @3, @4 ]
                                     : @[ @0, @1, @2, @3, @4, @5, @6, @7, @8, @9, @10 ];
    for (id value in values) {
        NSString *title = control == 0 ? [self qualityTitle:value]
                                       : [NSString stringWithFormat:@"%@ %@", value,
                                                                    control == 1 ? GSL(@"uploads")
                                                                                 : GSL(@"retries")];
        if ([value isEqual:self.options[key]])
            title = [@"✓ " stringByAppendingString:title];
        [sheet addAction:[UIAlertAction
                             actionWithTitle:title
                                       style:UIAlertActionStyleDefault
                                     handler:^(UIAlertAction *action) {
                                         NSMutableDictionary *options = [self.options mutableCopy];
                                         if (!options)
                                             return;
                                         options[key] = value;
                                         [self
                                             request:@{@"op" : @"configure", @"options" : options}];
                                     }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:GSL(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self sheet:sheet];
}
- (void)savePendingOptions {
    NSDictionary *sent = self.pendingOptions;
    self.pendingOptions = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        GSRequest(@{@"op" : @"configure", @"options" : sent}, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!error)
                self.confirmedOptions = sent;
            if (self.pendingOptions) {
                [self savePendingOptions];
                return;
            }
            self.configuringOptions = NO;
            if (error) {
                self.options = [self.confirmedOptions mutableCopy];
                [self message:error.localizedDescription];
            }
            self.confirmedOptions = nil;
            [self reloadTablePreservingPosition];
            [self refresh];
        });
    });
}
- (void)configureOptions:(NSDictionary *)options {
    if (self.busy || !options)
        return;
    if (!self.configuringOptions)
        self.confirmedOptions = [self.options copy];
    self.stateGeneration++;
    self.options = [options mutableCopy];
    self.pendingOptions = [options copy];
    if (self.configuringOptions)
        return;
    self.configuringOptions = YES;
    [self savePendingOptions];
}
- (void)request:(NSDictionary *)request {
    if ([request[@"op"] isEqual:@"configure"]) {
        [self configureOptions:request[@"options"]];
        return;
    }
    if (self.busy)
        return;
    self.stateGeneration++;
    self.busy = YES;
    [self message:GSL(@"Applying settings…")];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        GSRequest(request, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            if (error) {
                [self message:error.localizedDescription];
                [self reloadTablePreservingPosition];
            } else
                [self refresh];
        });
    });
}
- (BOOL)isValidSheetAnchorPath:(NSIndexPath *)path {
    if (!path)
        return NO;
    NSInteger sections = self.tableView.numberOfSections;
    if (path.section < 0 || path.section >= sections || path.row < 0)
        return NO;
    return path.row < [self.tableView numberOfRowsInSection:path.section];
}
- (void)configureSheetPopover:(UIViewController *)controller {
    UIPopoverPresentationController *popover = controller.popoverPresentationController;
    // UIKit only creates a popover controller once modalPresentationStyle is Popover; action
    // sheets default to a managed style, so popover stays nil and the anchor below was never
    // applied. Opt action sheets into Popover on iOS 26+, where Liquid Glass anchors them to
    // sourceView/sourceRect; earlier systems keep the stock bottom sheet untouched.
    if (!popover && [controller isKindOfClass:UIAlertController.class] &&
        ((UIAlertController *)controller).preferredStyle == UIAlertControllerStyleActionSheet) {
        if (@available(iOS 26.0, *)) {
            controller.modalPresentationStyle = UIModalPresentationPopover;
            popover = controller.popoverPresentationController;
        }
    }
    if (!popover)
        return;
    // iOS 26/27 Liquid Glass anchors action sheets to sourceView/sourceRect. A fixed top
    // offset made menus appear above the tapped row and let tall sheets (Language) fail to show.
    UIView *source = nil;
    CGRect rect = CGRectZero;
    NSIndexPath *path = self.sheetSourcePath;
    if ([self isValidSheetAnchorPath:path]) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
        if (cell) {
            source = cell;
            rect = cell.bounds;
        } else {
            CGRect row = [self.tableView rectForRowAtIndexPath:path];
            if (!CGRectIsNull(row) && !CGRectIsEmpty(row) && CGRectGetHeight(row) > 1) {
                source = self.tableView;
                rect = CGRectMake(CGRectGetMidX(row), CGRectGetMaxY(row) - 2, 1, 1);
            }
        }
    }
    if (!source || CGRectIsEmpty(rect) || CGRectIsNull(rect)) {
        source = self.tableView;
        CGRect bounds = source.bounds;
        if (CGRectIsEmpty(bounds) || CGRectIsNull(bounds)) {
            source = self.view;
            bounds = self.view.bounds;
        }
        rect = CGRectMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds), 1, 1);
    }
    popover.sourceView = source;
    popover.sourceRect = rect;
    popover.permittedArrowDirections = UIPopoverArrowDirectionAny;
}
- (void)sheet:(UIAlertController *)sheet {
    [self configureSheetPopover:sheet];
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)primary {
    if (self.busy)
        return;
    if (self.settingsMode)
        [self addAccount];
    else if (self.sharedItems.count) {
        NSArray *items = self.sharedItems;
        self.sharedItems = nil;
        if ([items.firstObject isKindOfClass:PHAsset.class])
            [self importAssets:items];
        else
            [self importURLs:items];
    } else
        [self choose];
}
- (void)connectNativeAccount {
    NSDictionary *account = GSNativeAccountSummary();
    if (!account) {
        [self
            message:GSL(@"Could not retrieve the Google Photos account. Reopen the profile menu.")];
        return;
    }
    self.stateGeneration++;
    self.nativeAuthorizationFailed = NO;
    self.busy = YES;
    [self message:GSL(@"Checking the signed-in Google Photos account…")];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
#if GS_JAILED
        GSRequest(@{
            @"op" : @"account_native",
            @"account" : account[@"email"],
            @"nativeID" : account[@"identifier"]
        },
                  &error);
#else
  GSConnectDaemonAccount(account,&error);
#endif
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            if (error) {
                self.nativeAuthorizationFailed = YES;
                [self message:GSL(@"Google Photos authorization failed. Check your sign-in, then "
                                  @"tap Reconnect.")];
                return;
            }
            [self refresh];
        });
    });
}
- (void)refreshAccount:(UIButton *)sender {
    if (self.busy || self.presentedViewController)
        return;
    self.sheetSourcePath = [NSIndexPath indexPathForRow:0 inSection:0];
    [self addAccount];
}
- (void)addAccount {
    if (GSIsGooglePhotos()) {
        [self connectNativeAccount];
        return;
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:GSL(@"Add Google account")
                                                               message:GS_AUTH_HELP
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.secureTextEntry = YES;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.placeholder = @"oauth_token / credential";
    }];
    [a addAction:[UIAlertAction actionWithTitle:GSL(@"Cancel")
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];
    [a addAction:[UIAlertAction
                     actionWithTitle:GSL(@"Connect")
                               style:UIAlertActionStyleDefault
                             handler:^(UIAlertAction *action) {
                                 NSString *secret = a.textFields.firstObject.text;
                                 a.textFields.firstObject.text = @"";
                                 [self
                                     request:@{@"op" : @"account_add", @"secret" : secret ?: @""}];
                             }]];
    [self sheet:a];
}
- (void)exportUploadDiagnostics {
    if (self.exportingDiagnostics)
        return;
    self.exportingDiagnostics = YES;
    NSMutableDictionary *snapshot = [GSUploadDiagnosticsSnapshot() mutableCopy];
    snapshot[@"manualRouting"] = GSNativeRoutingSnapshot();
    snapshot[@"batchImport"] = GSBatchImportSnapshot();
    snapshot[@"unlimitedStorage"] = GSUnlimitedStorageSnapshot();
    snapshot[@"bottomBarGlass"] = GSPhotosGlassSnapshot();
    snapshot[@"accountConnection"] = GSAccountConnectionSnapshot();
    snapshot[@"backupRouting"] = GSBackupRequestsSnapshot();
    snapshot[@"cloudOnlyDeletion"] = GSCloudOnlyDeletionSnapshot();
    snapshot[@"photosIntegration"] = GSPhotosIntegrationSnapshot();
    snapshot[@"completionMonitor"] = GSUploadMonitorSnapshot();
#if !GS_JAILED
    snapshot[@"ipc"] = GSIPCDiagnosticsSnapshot();
    snapshot[@"nativeAuthentication"] = GSNativeRelaySnapshot();
#endif
#if GS_JAILED
    snapshot[@"runtime"] = GSEmbeddedRuntimeSnapshot();
    snapshot[@"sideloadIdentity"] = GSSideloadIdentitySnapshot();
#endif
    NSString *account = [self.accounts[@"selected"] copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *album =
            account.length ? GSRequest(@{@"op" : @"album_status", @"account" : account}, nil) : nil;
        snapshot[@"album"] =
            album
                ? @{@"available" : @YES,
                    @"report" : GSAlbumDiagnosticReport(album)}
                : @{@"available" : @NO};
        dispatch_async(dispatch_get_main_queue(), ^{
            self.exportingDiagnostics = NO;
            if (self.viewIfLoaded.window && !self.presentedViewController)
                [self shareUploadDiagnostics:snapshot];
        });
    });
}
- (void)shareUploadDiagnostics:(NSDictionary *)snapshot {
    NSData *json = [NSJSONSerialization dataWithJSONObject:snapshot
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    NSURL *file = [NSURL
        fileURLWithPath:[NSTemporaryDirectory()
                            stringByAppendingPathComponent:@"gotohp-upload-diagnostics.json"]];
    if (!json || ![json writeToURL:file options:NSDataWritingAtomic error:nil]) {
        [self message:GSL(@"Could not export diagnostics.")];
        return;
    }
    UIActivityViewController *share =
        [[UIActivityViewController alloc] initWithActivityItems:@[ file ]
                                          applicationActivities:nil];
    [self configureSheetPopover:share];
    [self presentViewController:share animated:YES completion:nil];
}
- (void)toggleNativeRouting {
    if (GSNativeRoutingEnabled()) {
        GSSetNativeRouting(NO, nil);
        [self reloadTablePreservingPosition];
        return;
    }
    if (!GSBackupRequestsAvailable()) {
        [self message:GSL(@"Backup integration is unavailable in this version. Choose photos from "
                          @"Uploads.")];
        return;
    }
    if (!GSNativeRoutingAvailable()) {
        [self message:GSL(@"Backup integration is unavailable in this version. Choose photos from "
                          @"Uploads.")];
        return;
    }
    NSString *account = self.accounts[@"selected"];
    if (!account.length) {
        [self message:GS_ACCOUNT_HELP];
        return;
    }
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:GS_BACKUP_TITLE
                         message:[NSString
                                     stringWithFormat:
                                         GSL(@"Destination: %@\n%@\nCheck failures and retries in "
                                             @"the GoToHP queue. No native upload fallback."),
                                         account, GS_BACKUP_HELP]
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:GSL(@"Cancel")
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:GSL(@"Enable")
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *action) {
                                            GSSetNativeRouting(YES, account);
                                            [self reloadTablePreservingPosition];
                                        }]];
    [self sheet:a];
}
- (void)accountAction:(BOOL)remove {
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:remove ? GSL(@"Remove account") : GSL(@"Destination account")
                         message:remove ? GSL(@"Cancel this account's unfinished jobs first.") : nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *account in self.accounts[@"accounts"]) {
        NSString *email = account[@"email"];
        [a addAction:[UIAlertAction
                         actionWithTitle:email
                                   style:remove ? UIAlertActionStyleDestructive
                                                : UIAlertActionStyleDefault
                                 handler:^(UIAlertAction *action) {
                                     [self request:@{
                                         @"op" : remove ? @"account_remove" : @"account_select",
                                         @"account" : email
                                     }];
                                 }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:GSL(@"Cancel")
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];
    [self sheet:a];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (self.settingsMode && path.section == self.queueSection + 1) {
        [self openDeveloperProfileAtRow:path.row];
        return;
    }
    self.sheetSourcePath = path;
    NSInteger control = [self controlAtPath:path];
    if (control == 22) {
        [self openUploadPanel];
        return;
    }
    if (control == 23) {
        [self openEmbeddedSettings];
        return;
    }
    if (control == 20) {
        if (self.busy)
            return;
        [self chooseAlbumDestination];
        return;
    }
    if (control == 12) {
        [self exportUploadDiagnostics];
        return;
    }
    if (control == 16 || control == 19)
        return;
    if (control == 18) {
        GSStopBatchImport(NO);
        return;
    }
    if (self.busy)
        return;
    if (control >= 0) {
        if (control == 15) {
            [self chooseLanguage];
            return;
        }
        if (control == 14) {
            [self primary];
            return;
        }
        if (control == 17) {
            [self chooseAlbum];
            return;
        }
        if (control == 13) {
            [self addAccount];
            return;
        }
        if (control == 10) {
            [self toggleNativeRouting];
            return;
        }
        if (control == 11) {
            GSSetUploadDiagnostics(!GSUploadDiagnosticsEnabled());
            [self reloadTablePreservingPosition];
            return;
        }
        if (control < 3) {
            [self chooseValueForControl:control];
            return;
        }
        if (control < 6)
            return; // Use the visible switch; no hidden value cycling.
        if (control == 6 || control == 7)
            [self accountAction:control == 7];
        else
            [self request:@{@"op" : control == 8 ? @"retry_failed" : @"clear_completed"}];
    } else if (path.section == self.queueSection && path.row < self.jobs.count) {
        NSDictionary *j = self.jobs[path.row];
        NSString *state = j[@"state"];
        UIAlertController *a =
            [UIAlertController alertControllerWithTitle:j[@"resources"][0][@"name"]
                                                message:j[@"error"]
                                         preferredStyle:UIAlertControllerStyleActionSheet];
        if ([state isEqual:@"failed"])
            [a addAction:[UIAlertAction
                             actionWithTitle:GSL(@"Retry")
                                       style:UIAlertActionStyleDefault
                                     handler:^(UIAlertAction *action) {
                                         [self request:@{@"op" : @"retry", @"id" : j[@"id"]}];
                                     }]];
        if (![state isEqual:@"completed"] && ![state isEqual:@"cancelled"])
            [a addAction:[UIAlertAction
                             actionWithTitle:GSL(@"Cancel upload")
                                       style:UIAlertActionStyleDestructive
                                     handler:^(UIAlertAction *action) {
                                         [self request:@{@"op" : @"cancel", @"id" : j[@"id"]}];
                                     }]];
        [a addAction:[UIAlertAction actionWithTitle:GSL(@"Close")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
        [self sheet:a];
    }
}
- (void)choose {
    if (![self.accounts[@"selected"] length]) {
        [self message:GS_ACCOUNT_HELP];
        return;
    }
    if (![NSBundle.mainBundle objectForInfoDictionaryKey:@"NSPhotoLibraryUsageDescription"]) {
        [self message:GSL(@"This app cannot request access to your photos.")];
        return;
    }
    [PHPhotoLibrary
        requestAuthorizationForAccessLevel:PHAccessLevelReadWrite
                                   handler:^(PHAuthorizationStatus status) {
                                       dispatch_async(dispatch_get_main_queue(), ^{
                                           if (status != PHAuthorizationStatusAuthorized &&
                                               status != PHAuthorizationStatusLimited) {
                                               [self
                                                   message:
                                                       GSL(@"Allow access to your photo library.")];
                                               return;
                                           }
                                           PHPickerConfiguration *c = [[PHPickerConfiguration alloc]
                                               initWithPhotoLibrary:PHPhotoLibrary
                                                                        .sharedPhotoLibrary];
                                           c.selectionLimit = 100;
                                           c.preferredAssetRepresentationMode =
                                               PHPickerConfigurationAssetRepresentationModeCurrent;
                                           PHPickerViewController *picker =
                                               [[PHPickerViewController alloc]
                                                   initWithConfiguration:c];
                                           picker.delegate = self;
                                           [self presentViewController:picker
                                                              animated:YES
                                                            completion:nil];
                                       });
                                   }];
}
- (void)chooseAlbum {
    if (![self.accounts[@"selected"] length]) {
        [self message:GS_ACCOUNT_HELP];
        return;
    }
    if (![NSBundle.mainBundle objectForInfoDictionaryKey:@"NSPhotoLibraryUsageDescription"]) {
        [self message:GSL(@"This app cannot request access to your photos.")];
        return;
    }
    [PHPhotoLibrary
        requestAuthorizationForAccessLevel:PHAccessLevelReadWrite
                                   handler:^(PHAuthorizationStatus status) {
                                       dispatch_async(dispatch_get_main_queue(), ^{
                                           if (status != PHAuthorizationStatusAuthorized &&
                                               status != PHAuthorizationStatusLimited) {
                                               [self
                                                   message:
                                                       GSL(@"Allow access to your photo library.")];
                                               return;
                                           }
                                           GSAlbumPicker *albums = [[GSAlbumPicker alloc]
                                               initWithStyle:UITableViewStyleInsetGrouped];
                                           __weak GSPanel *weak = self;
                                           albums.selection = ^(PHFetchResult<PHAsset *> *assets) {
                                               [weak startImportCount:assets.count
                                                               source:@"album"
                                                               assets:YES
                                                             provider:^id(NSUInteger index) {
                                                                 return
                                                                     [assets objectAtIndex:index];
                                                             }];
                                           };
                                           [self presentViewController:
                                                     [[UINavigationController alloc]
                                                         initWithRootViewController:albums]
                                                              animated:YES
                                                            completion:nil];
                                       });
                                   }];
}
- (void)picker:(PHPickerViewController *)picker
    didFinishPicking:(NSArray<PHPickerResult *> *)results {
    // Retain identifiers only. PHPicker's item providers need not load any media.
    NSMutableArray *ids = [NSMutableArray arrayWithCapacity:results.count];
    for (PHPickerResult *result in results)
        [ids addObject:result.assetIdentifier ?: NSNull.null];
    [picker dismissViewControllerAnimated:YES
                               completion:^{
                                   if (ids.count)
                                       [self startImportCount:ids.count
                                                       source:@"picker"
                                                       assets:YES
                                                     provider:GSPhotoIdentifierProvider(ids)];
                               }];
}
- (NSString *)batchStatus:(NSDictionary *)state {
    NSString *counts = [NSString
        stringWithFormat:GSL(@"Queued %lu / %lu · Failed %lu · Remaining %lu"),
                         [state[@"queued"] unsignedLongValue], [state[@"total"] unsignedLongValue],
                         [state[@"failed"] unsignedLongValue],
                         [state[@"remaining"] unsignedLongValue]];
    NSString *reason = state[@"stopReason"], *help = nil;
    if ([state[@"active"] boolValue])
        help = GSL(@"Preparing originals. Keep the app open.");
    else if ([reason isEqual:@"account_changed"])
        help = GSL(@"Preparation stopped because the account changed. Reconnect and select the "
                   @"remaining items.");
    else if ([reason isEqual:@"queue_rejected"] || [reason isEqual:@"service_unavailable"] ||
             [reason isEqual:@"local_storage"])
        help = GSL(@"Preparation stopped. Check the connection, free space and queue, then select "
                   @"the remaining items.");
    else if (reason)
        help = GSL(@"Preparation stopped. Items already queued are kept.");
    else
        help = [state[@"failed"] unsignedIntegerValue]
                   ? GSL(@"Some originals could not be read. Check photo access and iCloud "
                         @"downloads, then retry the selection.")
                   : GS_QUEUED_HELP;
    return [NSString stringWithFormat:@"%@\n%@", counts, help];
}
- (void)importAssets:(NSArray<PHAsset *> *)assets {
    NSArray *selection = [assets copy];
    [self startImportCount:selection.count
                    source:@"share"
                    assets:YES
                  provider:^id(NSUInteger index) {
                      return selection[index];
                  }];
}
- (void)importURLs:(NSArray<NSURL *> *)urls {
    NSArray *selection = [urls copy];
    [self startImportCount:selection.count
                    source:@"share"
                    assets:NO
                  provider:^id(NSUInteger index) {
                      return selection[index];
                  }];
}
- (void)startImportCount:(NSUInteger)count
                  source:(NSString *)source
                  assets:(BOOL)assets
                provider:(GSBatchItemProvider)provider {
    if (!count)
        return;
    if (self.busy || [GSBatchImportSnapshot()[@"active"] boolValue]) {
        [self message:GSL(@"Wait for the operation to finish, then retry.")];
        return;
    }
    NSString *account = self.accounts[@"selected"],
             *identity = GSNativeAccountSummary()[@"identifier"];
    if (!account.length || (GSIsGooglePhotos() && !identity.length)) {
        [self message:GS_ACCOUNT_HELP];
        return;
    }
    self.stateGeneration++;
    self.busy = YES;
    __weak GSPanel *weak = self;
    __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
    task = [UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{
        GSStopBatchImport(YES);
        if (task != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:task];
            task = UIBackgroundTaskInvalid;
        }
    }];
    BOOL started = GSStartBatchImport(
        count, source, assets, provider, account, identity,
        ^(NSDictionary *state) {
            [weak message:[weak batchStatus:state]];
        },
        ^(NSDictionary *state) {
            if (task != UIBackgroundTaskInvalid) {
                [UIApplication.sharedApplication endBackgroundTask:task];
                task = UIBackgroundTaskInvalid;
            }
            weak.busy = NO;
            [weak message:[weak batchStatus:state]];
        });
    if (!started) {
        self.busy = NO;
        if (task != UIBackgroundTaskInvalid)
            [UIApplication.sharedApplication endBackgroundTask:task];
        [self message:GSL(@"Wait for the operation to finish, then retry.")];
    } else
        [self message:[self batchStatus:GSBatchImportSnapshot()]];
}
@end

UIBarButtonItem *GSPanelDoneButton(UIViewController *controller) {
    // All these pages share the GSPanel root; Done closes the whole flow,
    // while UIKit's Back pops just the current page.
    return [[UIBarButtonItem alloc]
        initWithTitle:GSL(@"Done")
                style:UIBarButtonItemStyleDone
               target:controller.navigationController.viewControllers.firstObject
               action:@selector(close)];
}
void GSPresent(UIViewController *host) {
    if (!host)
        return;
    GSPanel *panel = [[GSPanel alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:panel];
    [host presentViewController:nav animated:YES completion:nil];
}
static UIViewController *GSTopPresenter(UIViewController *hint) {
    UIViewController *host = hint;
    if (![host isKindOfClass:UIViewController.class] || !host.viewIfLoaded.window ||
        host.isBeingDismissed) {
        host = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive ||
                ![scene isKindOfClass:UIWindowScene.class])
                continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows)
                if (window.isKeyWindow && window.windowLevel == UIWindowLevelNormal)
                    host = window.rootViewController;
        }
    }
    while (host.presentedViewController && !host.presentedViewController.isBeingDismissed)
        host = host.presentedViewController;
    return host;
}
void GSPresentSettings(UIViewController *hint) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *host = GSTopPresenter(hint);
        UIViewController *visible = [host isKindOfClass:UINavigationController.class]
                                        ? ((UINavigationController *)host).topViewController
                                        : host;
        if (!host || [visible isKindOfClass:GSPanel.class])
            return; // Repeated taps never stack settings.
        id<UIViewControllerTransitionCoordinator> transition = host.transitionCoordinator;
        if (transition && transition.isAnimated) {
            BOOL queued = [transition
                animateAlongsideTransition:nil
                                completion:^(
                                    id<UIViewControllerTransitionCoordinatorContext> context) {
                                    GSPresentSettings(nil);
                                }];
            if (queued)
                return;
        }
        GSPanel *panel = [[GSPanel alloc] initWithStyle:UITableViewStyleInsetGrouped];
        panel.settingsMode = YES;
        UINavigationController *nav =
            [[UINavigationController alloc] initWithRootViewController:panel];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [host presentViewController:nav animated:YES completion:nil];
    });
}
@interface GSLauncher : NSObject
+ (void)open:(UIButton *)button;
@end
@implementation GSLauncher
+ (void)open:(UIButton *)button {
    UIViewController *host = button.window.rootViewController;
    while (host.presentedViewController)
        host = host.presentedViewController;
    GSPresent(host);
}
@end
static char GSLauncherKey;
void GSInstallButton(UIWindow *window) {
    if (GSIsGooglePhotos())
        return;
    if (window.windowLevel != UIWindowLevelNormal || !window.rootViewController ||
        objc_getAssociatedObject(window, &GSLauncherKey))
        return;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@"GoToHP" forState:UIControlStateNormal];
    button.backgroundColor = UIColor.secondarySystemBackgroundColor;
    button.layer.cornerRadius = 18;
    button.accessibilityLabel = GSL(@"Open the GoToHP upload queue");
    [button addTarget:GSLauncher.class
                  action:@selector(open:)
        forControlEvents:UIControlEventTouchUpInside];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [window addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.trailingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor
                                              constant:-12],
        [button.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor
                                            constant:-65],
        [button.widthAnchor constraintEqualToConstant:84],
        [button.heightAnchor constraintEqualToConstant:40]
    ]];
    objc_setAssociatedObject(window, &GSLauncherKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@interface GSUploadActivity ()
@property (nonatomic, strong) NSArray *items;
@end
@implementation GSUploadActivity
- (NSString *)activityType {
    return @"dev.tqmane.gunshot.upload";
}
- (NSString *)activityTitle {
    return GSL(@"Upload with GoToHP");
}
- (UIImage *)activityImage {
    return [UIImage systemImageNamed:@"icloud.and.arrow.up"];
}
- (BOOL)canPerformWithActivityItems:(NSArray *)items {
    if (!items.count)
        return NO;
    BOOL assets = [items.firstObject isKindOfClass:PHAsset.class];
    for (id i in items)
        if (assets ? ![i isKindOfClass:PHAsset.class]
                   : !([i isKindOfClass:NSURL.class] && [i isFileURL]))
            return NO;
    return YES;
}
- (void)prepareWithActivityItems:(NSArray *)items {
    self.items = items;
}
- (UIViewController *)activityViewController {
    GSPanel *panel = [[GSPanel alloc] initWithStyle:UITableViewStyleInsetGrouped];
    panel.sharedItems = self.items;
    __weak GSUploadActivity *weak = self;
    panel.activityCompletion = ^{
        [weak activityDidFinish:YES];
    };
    // Use an explicit button so opening the activity does not upload automatically.
    panel.navigationItem.prompt = GSL(@"Choose the destination, then upload your selection.");
    return [[UINavigationController alloc] initWithRootViewController:panel];
}
@end
