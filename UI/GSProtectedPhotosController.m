#import "GSProtectedPhotosController.h"
#import "GSPanel.h"
#import "GSProtectedPhotoStatus.h"
#import "../Media/GSBatchImport.h"
#import "../Native/GSLocalPhotoProtection.h"
#import "../Native/GSNativeAccount.h"
#import "../Native/GSNativeRouting.h"
#import "../Shared/GSLocalization.h"
#import "../Shared/IPCProtocol.h"
#import <Photos/Photos.h>

@interface GSProtectedPhotoCell : UITableViewCell
@property (nonatomic, copy) NSString *representedIdentifier;
@property (nonatomic) PHImageRequestID imageRequest;
@end
@implementation GSProtectedPhotoCell
- (void)prepareForReuse {
    [super prepareForReuse];
    if (self.imageRequest != PHInvalidImageRequestID)
        [PHImageManager.defaultManager cancelImageRequest:self.imageRequest];
    self.imageRequest = PHInvalidImageRequestID;
    self.representedIdentifier = nil;
}
@end

@interface GSProtectedPhotosController ()
@property (nonatomic, copy) NSArray<NSString *> *identifiers;
@property (nonatomic, copy) NSSet<NSString *> *protectedIDs;
@property (nonatomic, copy) NSDictionary<NSString *, PHAsset *> *assets;
@property (nonatomic, copy) NSDictionary *names, *jobs, *conditions;
@property (nonatomic, copy) NSString *account, *submittedAccount, *refreshError;
@property (nonatomic, strong) NSMutableSet<NSString *> *selected;
@property (nonatomic, strong) NSMutableDictionary *preparation, *submitted;
@property (nonatomic, strong) UIBarButtonItem *backupButton;
@property (nonatomic, strong) id foregroundObserver;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) BOOL active, loading, refreshing, saving, previousToolbarHidden,
    needsAssetRefresh;
@property (nonatomic) NSUInteger generation;
@end

@implementation GSProtectedPhotosController
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _identifiers = @[];
        _protectedIDs = [NSSet set];
        _assets = @{};
        _names = @{};
        _jobs = @{};
        _conditions = @{};
        _selected = [NSMutableSet set];
        _preparation = [NSMutableDictionary dictionary];
        _submitted = [NSMutableDictionary dictionary];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = GSL(@"Photos kept on this iPhone");
    self.navigationItem.rightBarButtonItem = GSPanelDoneButton(self);
    self.navigationItem.backButtonDisplayMode = UINavigationItemBackButtonDisplayModeMinimal;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 100;
    self.tableView.allowsMultipleSelection = YES;
    [self.tableView registerClass:GSProtectedPhotoCell.class forCellReuseIdentifier:@"protected"];
    self.backupButton = [[UIBarButtonItem alloc] initWithTitle:GSL(@"Back up again")
                                                         style:UIBarButtonItemStylePlain
                                                        target:self
                                                        action:@selector(confirmBackup)];
    self.backupButton.enabled = NO;
    self.toolbarItems = @[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                      target:nil
                                                      action:nil],
        self.backupButton,
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                      target:nil
                                                      action:nil]
    ];
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self
                            action:@selector(reloadPhotos)
                  forControlEvents:UIControlEventValueChanged];
    __weak GSProtectedPhotosController *weakSelf = self;
    self.foregroundObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
                    GSProtectedPhotosController *controller = weakSelf;
                    if (controller.active && !controller.presentedViewController)
                        [controller reloadPhotos];
                }];
}
- (void)dealloc {
    [_timer invalidate];
    if (_foregroundObserver)
        [NSNotificationCenter.defaultCenter removeObserver:_foregroundObserver];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.active = YES;
    self.previousToolbarHidden = self.navigationController.toolbarHidden;
    [self.navigationController setToolbarHidden:NO animated:animated];
    [self reloadPhotos];
    __weak GSProtectedPhotosController *weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.5
                                                 repeats:YES
                                                   block:^(NSTimer *timer) {
                                                       [weakSelf refreshState:NO];
                                                   }];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.active = NO;
    self.generation++;
    [self.timer invalidate];
    self.timer = nil;
    [self.refreshControl endRefreshing];
    [self.navigationController setToolbarHidden:self.previousToolbarHidden animated:animated];
}
- (BOOL)isInteracting {
    return self.tableView.dragging || self.tableView.decelerating || self.tableView.tracking;
}
- (void)reloadPhotos {
    self.needsAssetRefresh = YES;
    [self refreshState:YES];
}
- (void)refreshState:(BOOL)reloadAssets {
    self.needsAssetRefresh = self.needsAssetRefresh || reloadAssets;
    if (!self.active || self.refreshing || self.presentedViewController || [self isInteracting]) {
        [self.refreshControl endRefreshing];
        return;
    }
    self.refreshing = YES;
    reloadAssets = self.needsAssetRefresh;
    self.needsAssetRefresh = NO;
    self.loading = !self.identifiers.count;
    NSUInteger generation = self.generation;
    NSArray *previousIDs = self.identifiers;
    NSDictionary *cachedAssets = self.assets, *cachedNames = self.names;
    NSDictionary *submitted = [self.submitted copy], *preparation = [self.preparation copy];
    NSString *submittedAccount = self.submittedAccount;
    [self updateEmptyState];
    __weak GSProtectedPhotosController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray *protected = GSLocalPhotoProtectionStore().protectedIdentifiers;
        NSDictionary *accounts = GSRequest(@{@"op" : @"accounts"}, nil);
        NSString *account = accounts[@"selected"];
        NSMutableDictionary *jobs = [NSMutableDictionary dictionary];
        NSDictionary *options = accounts ? GSRequest(@{@"op" : @"options"}, nil) : nil;
        NSMutableDictionary *conditions = [options mutableCopy] ?: [NSMutableDictionary dictionary];
        NSInteger cursor = 0;
        BOOL complete = accounts != nil && options != nil;
        if (complete && account.length) {
            do {
                NSDictionary *page = GSRequest(@{@"op" : @"list", @"cursor" : @(cursor)}, nil);
                if (!page) {
                    complete = NO;
                    break;
                }
                for (NSString *key in @[ @"online", @"wifi", @"charging" ])
                    if (page[key])
                        conditions[key] = page[key];
                for (NSDictionary *job in page[@"jobs"]) {
                    NSString *assetID = job[@"rebackupAssetID"];
                    if (assetID.length && [job[@"account"] isEqual:account])
                        jobs[assetID] = job;
                }
                cursor = [page[@"next"] integerValue];
            } while (cursor >= 0);
        }
        BOOL sameAccount = [account isEqual:submittedAccount];
        NSMutableSet *all = [NSMutableSet setWithArray:protected];
        [all addObjectsFromArray:jobs.allKeys];
        [all addObjectsFromArray:preparation.allKeys];
        if (sameAccount)
            [all addObjectsFromArray:submitted.allKeys];
        NSMutableArray *identifiers = [NSMutableArray array];
        for (NSString *identifier in previousIDs)
            if ([all containsObject:identifier]) {
                [identifiers addObject:identifier];
                [all removeObject:identifier];
            }
        [identifiers
            addObjectsFromArray:[all.allObjects sortedArrayUsingSelector:@selector(compare:)]];
        NSDictionary *assets = cachedAssets, *names = cachedNames;
        if (reloadAssets || ![previousIDs isEqual:identifiers]) {
            NSMutableDictionary *resolved = [NSMutableDictionary dictionary],
                                *filenames = [NSMutableDictionary dictionary];
            PHAuthorizationStatus authorization =
                [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
            if (identifiers.count && (authorization == PHAuthorizationStatusAuthorized ||
                                      authorization == PHAuthorizationStatusLimited)) {
                PHFetchOptions *fetchOptions = [PHFetchOptions new];
                fetchOptions.includeHiddenAssets = YES;
                PHFetchResult<PHAsset *> *result =
                    [PHAsset fetchAssetsWithLocalIdentifiers:identifiers options:fetchOptions];
                [result enumerateObjectsUsingBlock:^(PHAsset *asset, NSUInteger index, BOOL *stop) {
                    resolved[asset.localIdentifier] = asset;
                    NSString *name =
                        [PHAssetResource assetResourcesForAsset:asset].firstObject.originalFilename;
                    if (name.length)
                        filenames[asset.localIdentifier] = name;
                }];
            }
            assets = resolved;
            names = filenames;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            GSProtectedPhotosController *controller = weakSelf;
            controller.refreshing = NO;
            controller.loading = NO;
            [controller.refreshControl endRefreshing];
            if (!controller.active || generation != controller.generation ||
                [controller isInteracting]) {
                controller.needsAssetRefresh = controller.needsAssetRefresh || reloadAssets;
                return;
            }
            if (!complete) {
                controller.refreshError =
                    GSL(@"Could not refresh backup status. Pull down to retry.");
                // Protection remains readable even when the upload service is offline.
                controller.account = nil;
                controller.identifiers = identifiers;
                controller.protectedIDs = [NSSet setWithArray:protected];
                controller.assets = assets;
                controller.names = names;
                [controller redraw];
                [controller updateEmptyState];
                [controller updateSelection];
                return;
            }
            // Import callbacks can advance while IPC is in flight. Keep those
            // rows without discarding every progress poll during a large batch.
            NSMutableSet *recent = [NSMutableSet setWithArray:controller.preparation.allKeys];
            if ([account isEqual:controller.submittedAccount])
                [recent addObjectsFromArray:controller.submitted.allKeys];
            for (NSString *identifier in recent)
                if (![identifiers containsObject:identifier]) {
                    [identifiers addObject:identifier];
                    controller.needsAssetRefresh = YES;
                }
            NSSet *protectedIDs = [NSSet setWithArray:protected];
            BOOL changed = ![controller.identifiers isEqual:identifiers] ||
                           ![controller.jobs isEqual:jobs] || ![controller.assets isEqual:assets] ||
                           ![controller.protectedIDs isEqual:protectedIDs] ||
                           ![controller.conditions isEqual:conditions] ||
                           controller.refreshError != nil;
            controller.refreshError = nil;
            controller.account = account;
            controller.identifiers = identifiers;
            controller.protectedIDs = protectedIDs;
            controller.assets = assets;
            controller.names = names;
            controller.jobs = jobs;
            controller.conditions = conditions;
            if (!sameAccount)
                [controller.submitted removeAllObjects];
            else
                for (NSString *identifier in submitted)
                    if (![protectedIDs containsObject:identifier] &&
                        [submitted[identifier] isEqual:jobs[identifier][@"id"]])
                        [controller.submitted removeObjectForKey:identifier];
            NSMutableSet *selectable = [protectedIDs mutableCopy];
            for (NSString *identifier in jobs)
                if ([jobs[identifier][@"state"] isEqual:@"cancelled"] && assets[identifier])
                    [selectable addObject:identifier];
            [controller.selected intersectSet:selectable];
            if (changed)
                [controller redraw];
            [controller updateEmptyState];
            [controller updateSelection];
        });
    });
}
- (void)redraw {
    if (!self.active || [self isInteracting])
        return;
    __block CGPoint offset = self.tableView.contentOffset;
    [UIView performWithoutAnimation:^{
        [self.tableView reloadData];
        [self.tableView layoutIfNeeded];
        CGFloat maximum =
            MAX(-self.tableView.adjustedContentInset.top,
                self.tableView.contentSize.height - self.tableView.bounds.size.height +
                    self.tableView.adjustedContentInset.bottom);
        offset.y = MAX(-self.tableView.adjustedContentInset.top, MIN(offset.y, maximum));
        [self.tableView setContentOffset:offset animated:NO];
    }];
}
- (void)updateEmptyState {
    if (self.identifiers.count) {
        self.tableView.backgroundView = nil;
        return;
    }
    UILabel *label = [UILabel new];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = UIColor.secondaryLabelColor;
    label.text = !GSLocalPhotoProtectionStore().healthy
        ? GSL(@"Photo protection data is unavailable. No protection was removed.")
        : self.loading ? GSL(@"Loading photos...") : self.refreshError ?: GSL(@"No photos are being kept.");
    self.tableView.backgroundView = label;
}
- (void)updateSelection {
    self.backupButton.enabled = self.selected.count > 0 && !self.loading && !self.saving &&
                                GSLocalPhotoProtectionStore().healthy && self.account.length > 0;
    for (NSIndexPath *path in self.tableView.indexPathsForVisibleRows) {
        if (path.row >= self.identifiers.count)
            continue;
        NSString *identifier = self.identifiers[path.row];
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
        cell.accessoryType = [self.selected containsObject:identifier]
                                 ? UITableViewCellAccessoryCheckmark
                             : [[self jobForIdentifier:identifier][@"state"] isEqual:@"failed"]
                                 ? UITableViewCellAccessoryDisclosureIndicator
                                 : UITableViewCellAccessoryNone;
    }
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.identifiers.count;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.refreshError
               ?: GSL(@"Select photos to back them up again. Progress and results stay here and in "
                      @"Upload history. Keep the app open while uploading. Unavailable photos keep "
                      @"their protection and are not queued.");
}
- (NSDictionary *)jobForIdentifier:(NSString *)identifier {
    // A later cloud-only deletion invalidates this asset's previous upload result.
    NSString *submitted = self.submitted[identifier];
    if (submitted && ![submitted isEqual:self.jobs[identifier][@"id"]])
        return nil;
    if ([self.protectedIDs containsObject:identifier] && !submitted)
        return nil;
    return self.jobs[identifier];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    GSProtectedPhotoCell *cell = [tableView dequeueReusableCellWithIdentifier:@"protected"
                                                                 forIndexPath:path];
    if (cell.imageRequest != PHInvalidImageRequestID)
        [PHImageManager.defaultManager cancelImageRequest:cell.imageRequest];
    cell.imageRequest = PHInvalidImageRequestID;
    NSString *identifier = self.identifiers[path.row];
    PHAsset *asset = self.assets[identifier];
    NSDictionary *job = [self jobForIdentifier:identifier];
    NSString *preparing = self.preparation[identifier];
    cell.representedIdentifier = identifier;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryType =
        [self.selected containsObject:identifier] ? UITableViewCellAccessoryCheckmark
        : [job[@"state"] isEqual:@"failed"]       ? UITableViewCellAccessoryDisclosureIndicator
                                                  : UITableViewCellAccessoryNone;
    UIListContentConfiguration *content = cell.defaultContentConfiguration;
    content.imageProperties.maximumSize = CGSizeMake(56, 56);
    content.imageProperties.reservedLayoutSize = CGSizeMake(56, 56);
    content.imageProperties.cornerRadius = 6;
    content.textProperties.numberOfLines = 0;
    content.secondaryTextProperties.numberOfLines = 0;
    NSArray *resources = job[@"resources"];
    content.text = self.names[identifier] ?: resources.firstObject[@"name"] ?:
        (asset ? (asset.mediaType == PHAssetMediaTypeVideo ? GSL(@"Video") : GSL(@"Photo")) :
            [NSString stringWithFormat:GSL(@"Photo unavailable (%lu)"), (unsigned long)path.row + 1]);
    NSString *date = asset.creationDate
                         ? [NSDateFormatter localizedStringFromDate:asset.creationDate
                                                          dateStyle:NSDateFormatterMediumStyle
                                                          timeStyle:NSDateFormatterShortStyle]
                         : GSL(@"Preview unavailable");
    NSDictionary *presentation =
        job ? GSProtectedPhotoUploadPresentation(job, self.conditions) : nil;
    if (preparing)
        presentation = nil;
    NSString *stateText = preparing ? ([preparing isEqual:@"preparing"] ? GSL(@"Preparing") : GSL(@"Preparation failed. Tap to try again.")) :
        presentation[@"detail"] ?: (self.submitted[identifier] ? GSL(@"Checking status") : asset ? GSL(@"Kept on this iPhone") : GSL(@"Local photo not accessible"));
    content.secondaryText = [NSString stringWithFormat:@"%@\n%@", stateText, date];
    // Match upload history status icons while retaining the local thumbnail.
    NSString *symbol =
        presentation[@"icon"]
            ?: (preparing && ![preparing isEqual:@"preparing"] ? @"exclamationmark.circle"
                : preparing || self.submitted[identifier]      ? @"icloud.and.arrow.up"
                                                               : @"lock.shield");
    UIColor *tint = [presentation[@"color"] isEqual:@"green"] ? UIColor.systemGreenColor
                    : [presentation[@"color"] isEqual:@"red"] ||
                            (preparing && ![preparing isEqual:@"preparing"])
                        ? UIColor.systemRedColor
                        : UIColor.systemBlueColor;
    NSTextAttachment *attachment = [NSTextAttachment new];
    attachment.image =
        [[UIImage systemImageNamed:symbol] imageWithTintColor:tint
                                                renderingMode:UIImageRenderingModeAlwaysOriginal];
    attachment.bounds = CGRectMake(0, -2, 16, 16);
    NSMutableAttributedString *title = [[NSMutableAttributedString alloc]
        initWithAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
    [title appendAttributedString:[[NSAttributedString alloc]
                                      initWithString:[@"  " stringByAppendingString:content.text]]];
    content.attributedText = title;
    content.image = [UIImage systemImageNamed:asset ? @"photo" : @"photo.badge.exclamationmark"]
                        ?: [UIImage systemImageNamed:@"photo"];
    cell.contentConfiguration = content;
    if ([self.selected containsObject:identifier])
        [tableView selectRowAtIndexPath:path
                               animated:NO
                         scrollPosition:UITableViewScrollPositionNone];
    else
        [tableView deselectRowAtIndexPath:path animated:NO];
    if (asset) {
        PHImageRequestOptions *options = [PHImageRequestOptions new];
        options.networkAccessAllowed = NO;
        options.deliveryMode = PHImageRequestOptionsDeliveryModeOpportunistic;
        __weak GSProtectedPhotoCell *weakCell = cell;
        cell.imageRequest = [PHImageManager.defaultManager
            requestImageForAsset:asset
                      targetSize:CGSizeMake(168, 168)
                     contentMode:PHImageContentModeAspectFill
                         options:options
                   resultHandler:^(UIImage *image, NSDictionary *info) {
                       dispatch_async(dispatch_get_main_queue(), ^{
                           GSProtectedPhotoCell *visible = weakCell;
                           if (!image || ![visible.representedIdentifier isEqual:identifier])
                               return;
                           UIListContentConfiguration *updated =
                               [(id)visible.contentConfiguration copy];
                           updated.image = image;
                           visible.contentConfiguration = updated;
                       });
                   }];
    }
    return cell;
}
- (NSIndexPath *)tableView:(UITableView *)tableView willSelectRowAtIndexPath:(NSIndexPath *)path {
    if (self.loading || self.saving || path.row >= self.identifiers.count)
        return nil;
    NSString *identifier = self.identifiers[path.row];
    NSDictionary *job = [self jobForIdentifier:identifier];
    if ([job[@"state"] isEqual:@"failed"])
        return path;
    return self.assets[identifier] && ([self.protectedIDs containsObject:identifier] ||
                                       [job[@"state"] isEqual:@"cancelled"])
               ? path
               : nil;
}
- (NSIndexPath *)tableView:(UITableView *)tableView willDeselectRowAtIndexPath:(NSIndexPath *)path {
    return self.loading || self.saving ? nil : path;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    NSString *identifier = self.identifiers[path.row];
    NSDictionary *job = [self jobForIdentifier:identifier];
    if ([job[@"state"] isEqual:@"failed"]) {
        [tableView deselectRowAtIndexPath:path animated:NO];
        [self confirmRetry:job];
        return;
    }
    [self.selected addObject:identifier];
    [self updateSelection];
}
- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)path {
    if (path.row < self.identifiers.count)
        [self.selected removeObject:self.identifiers[path.row]];
    [self updateSelection];
}
- (void)confirmBackup {
    if (self.saving || !self.selected.count || self.presentedViewController)
        return;
    if ([GSBatchImportSnapshot()[@"active"] boolValue]) {
        self.refreshError = GSL(@"Wait for the operation to finish, then retry.");
        [self redraw];
        return;
    }
    NSArray *identifiers = [self.selected.allObjects sortedArrayUsingSelector:@selector(compare:)];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:GSL(@"Back up selected photos again?")
                         message:GSL(@"The selected photos will be unprotected and queued using "
                                     @"the current account, upload quality, and album destination. "
                                     @"Progress and results appear here.")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:GSL(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak GSProtectedPhotosController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:GSL(@"Back up again")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                                [weakSelf startBackup:identifiers];
                                            }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)startBackup:(NSArray<NSString *> *)identifiers {
    NSString *identity = GSNativeAccountSummary()[@"identifier"];
    if (!self.account.length || (GSIsGooglePhotos() && !identity.length)) {
        self.refreshError = GSL(@"Reconnect to Google Photos before backing up again.");
        [self redraw];
        return;
    }
    self.saving = YES;
    self.submittedAccount = self.account;
    for (NSString *identifier in identifiers)
        self.preparation[identifier] = @"preparing";
    [self updateSelection];
    [self redraw];
    __weak GSProtectedPhotosController *weakSelf = self;
    __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
    task = [UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{
        if (task == UIBackgroundTaskInvalid)
            return;
        GSStopBatchImport(YES);
        if (task != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:task];
            task = UIBackgroundTaskInvalid;
        }
    }];
    BOOL started = GSStartProtectedPhotoImport(
        identifiers, self.account, identity,
        ^(NSUInteger index, NSString *jobID, NSString *failureCode) {
            GSProtectedPhotosController *controller = weakSelf;
            NSString *identifier = identifiers[index];
            if (jobID) {
                controller.submitted[identifier] = jobID;
                [controller.preparation removeObjectForKey:identifier];
            } else
                controller.preparation[identifier] = failureCode ?: @"queue_rejected";
            [controller refreshState:NO];
        },
        ^(NSDictionary *state) {
            if (task != UIBackgroundTaskInvalid) {
                [UIApplication.sharedApplication endBackgroundTask:task];
                task = UIBackgroundTaskInvalid;
            }
            GSProtectedPhotosController *controller = weakSelf;
            controller.saving = NO;
            for (NSString *identifier in identifiers)
                if ([controller.preparation[identifier] isEqual:@"preparing"])
                    controller.preparation[identifier] = state[@"stopReason"] ?: @"queue_rejected";
            [controller.selected minusSet:[NSSet setWithArray:identifiers]];
            [controller redraw];
            [controller reloadPhotos];
        });
    if (!started) {
        self.saving = NO;
        for (NSString *identifier in identifiers)
            [self.preparation removeObjectForKey:identifier];
        if (task != UIBackgroundTaskInvalid)
            [UIApplication.sharedApplication endBackgroundTask:task];
        self.refreshError = GSL(@"Wait for the operation to finish, then retry.");
        [self redraw];
        [self updateSelection];
    }
}
- (void)confirmRetry:(NSDictionary *)job {
    if (self.presentedViewController)
        return;
    NSString *identity = GSNativeAccountSummary()[@"identifier"];
    if (GSIsGooglePhotos() && !identity.length)
        return;
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:GSL(@"Failed")
                                            message:GSL(@"Retry this upload?")
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:GSL(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak GSProtectedPhotosController *weakSelf = self;
    [alert addAction:[UIAlertAction
                         actionWithTitle:GSL(@"Retry")
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction *action) {
                                     dispatch_async(
                                         dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                                             __block BOOL valid = YES;
                                             if (identity.length)
                                                 dispatch_sync(dispatch_get_main_queue(), ^{
                                                     valid = GSNativeIdentityMatches(identity);
                                                 });
                                             NSDictionary *accounts =
                                                 GSRequest(@{@"op" : @"accounts"}, nil);
                                             BOOL success =
                                                 valid &&
                                                 [accounts[@"selected"] isEqual:job[@"account"]] &&
                                                 GSRequest(@{@"op" : @"retry", @"id" : job[@"id"]},
                                                           nil) != nil;
                                             dispatch_async(dispatch_get_main_queue(), ^{
                                                 if (!success)
                                                     weakSelf.refreshError =
                                                         GSL(@"Could not refresh backup status. "
                                                             @"Pull down to retry.");
                                                 [weakSelf redraw];
                                                 [weakSelf refreshState:NO];
                                             });
                                         });
                                 }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
