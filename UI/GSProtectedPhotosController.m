#import "GSProtectedPhotosController.h"
#import "GSPanel.h"
#import "GSProtectedPhotoStatus.h"
#import "../Media/GSBatchImport.h"
#import "../Native/GSLocalPhotoProtection.h"
#import "../Native/GSProtectedPhotoLookup.h"
#import "../Native/GSNativeAccount.h"
#import "../Native/GSNativeRouting.h"
#import "../Shared/GSLocalization.h"
#import "../Shared/IPCProtocol.h"
#import <Photos/Photos.h>
#import <PhotosUI/PhotosUI.h>

@interface GSProtectedPreviewRequest : NSObject
@property (nonatomic) BOOL finished;
- (void)finish:(NSString *)outcome;
@end
@implementation GSProtectedPreviewRequest
- (instancetype)init {
    if ((self = [super init]))
        [GSLocalPhotoProtectionStore() recordPreviewResult:@"requested"];
    return self;
}
- (void)finish:(NSString *)outcome {
    @synchronized(self) {
        if (self.finished)
            return;
        self.finished = YES;
        [GSLocalPhotoProtectionStore() recordPreviewResult:outcome];
    }
}
- (void)dealloc {
    [self finish:@"cancelled"];
}
@end

@interface GSProtectedPhotoCell : UITableViewCell
@property (nonatomic, copy) NSString *representedIdentifier;
@property (nonatomic) PHImageRequestID imageRequest;
@property (nonatomic, strong) GSProtectedPreviewRequest *previewRequest;
- (void)cancelPreview;
@end
@implementation GSProtectedPhotoCell
- (void)cancelPreview {
    [self.previewRequest finish:@"cancelled"];
    self.previewRequest = nil;
    if (self.imageRequest != PHInvalidImageRequestID)
        [PHImageManager.defaultManager cancelImageRequest:self.imageRequest];
    self.imageRequest = PHInvalidImageRequestID;
}
- (void)prepareForReuse {
    [super prepareForReuse];
    [self cancelPreview];
    self.representedIdentifier = nil;
}
@end

@interface GSProtectedPhotosController () <PHPickerViewControllerDelegate,
                                           UIAdaptivePresentationControllerDelegate>
@property (nonatomic, copy) NSArray<NSString *> *identifiers;
@property (nonatomic, copy) NSSet<NSString *> *protectedIDs;
@property (nonatomic, copy) NSSet<NSString *> *backupBlockedIDs;
@property (nonatomic, copy) NSDictionary<NSString *, PHAsset *> *assets;
@property (nonatomic, copy) NSDictionary *names, *jobs, *conditions;
@property (nonatomic, copy) NSDictionary *lookupReasons;
@property (nonatomic, strong) NSMutableDictionary *previewReasons;
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *previews;
@property (nonatomic, copy) NSString *account, *submittedAccount, *refreshError;
@property (nonatomic, strong) NSMutableSet<NSString *> *selected;
@property (nonatomic, strong) NSMutableDictionary *preparation, *submitted;
@property (nonatomic, strong) UIBarButtonItem *backupButton;
@property (nonatomic, strong) PHPickerViewController *photoCheckPicker;
@property (nonatomic, strong) id foregroundObserver;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) BOOL active, loading, refreshing, saving, previousToolbarHidden,
    needsAssetRefresh, checkingPhoto;
@property (nonatomic) NSUInteger generation, assetGeneration;
@end

@implementation GSProtectedPhotosController
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _identifiers = @[];
        _protectedIDs = [NSSet set];
        _backupBlockedIDs = [NSSet set];
        _assets = @{};
        _names = @{};
        _jobs = @{};
        _conditions = @{};
        _lookupReasons = @{};
        _previewReasons = [NSMutableDictionary dictionary];
        _previews = [NSCache new];
        _previews.countLimit = 128;
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
    if (!self.active || self.refreshing || self.checkingPhoto || self.presentedViewController ||
        [self isInteracting]) {
        [self.refreshControl endRefreshing];
        return;
    }
    self.refreshing = YES;
    reloadAssets = self.needsAssetRefresh;
    self.needsAssetRefresh = NO;
    self.loading = !self.identifiers.count;
    NSUInteger generation = self.generation;
    NSArray *previousIDs = self.identifiers;
    NSDictionary *cachedAssets = self.assets, *cachedNames = self.names,
                 *cachedReasons = self.lookupReasons;
    NSDictionary *submitted = [self.submitted copy], *preparation = [self.preparation copy];
    NSString *submittedAccount = self.submittedAccount;
    [self updateEmptyState];
    __weak GSProtectedPhotosController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        GSLocalPhotoProtection *store = GSLocalPhotoProtectionStore();
        NSArray *protected;
        NSSet *backupBlockedIDs;
        @synchronized(store) {
            protected = store.protectedIdentifiers;
            backupBlockedIDs = [NSSet setWithArray:store.backupBlockedIdentifiers];
        }
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
        NSDictionary *assets = cachedAssets, *names = cachedNames, *reasons = cachedReasons;
        BOOL lookedUp = reloadAssets || ![previousIDs isEqual:identifiers];
        if (lookedUp) {
            NSDictionary *lookup = GSLookupProtectedPhotos(identifiers);
            assets = lookup[@"assets"];
            names = lookup[@"names"];
            reasons = lookup[@"reasons"];
            [GSLocalPhotoProtectionStore() recordPhotoLookup:lookup[@"report"]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            GSProtectedPhotosController *controller = weakSelf;
            controller.refreshing = NO;
            controller.loading = NO;
            [controller.refreshControl endRefreshing];
            if (!controller.active || generation != controller.generation ||
                [controller isInteracting]) {
                controller.needsAssetRefresh = controller.needsAssetRefresh || lookedUp;
                return;
            }
            controller.lookupReasons = reasons;
            if (lookedUp) {
                controller.assetGeneration++;
                [controller.previewReasons removeAllObjects];
                [controller.previews removeAllObjects];
            }
            if (!complete) {
                controller.refreshError =
                    GSL(@"Could not refresh backup status. Pull down to retry.");
                // Protection remains readable even when the upload service is offline.
                controller.account = nil;
                controller.identifiers = identifiers;
                controller.protectedIDs = [NSSet setWithArray:protected];
                controller.backupBlockedIDs = backupBlockedIDs;
                controller.assets = assets;
                controller.names = names;
                [controller.selected intersectSet:[NSSet setWithArray:assets.allKeys]];
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
            BOOL changed = lookedUp || ![controller.identifiers isEqual:identifiers] ||
                           ![controller.jobs isEqual:jobs] || ![controller.assets isEqual:assets] ||
                           ![controller.protectedIDs isEqual:protectedIDs] ||
                           ![controller.backupBlockedIDs isEqual:backupBlockedIDs] ||
                           ![controller.conditions isEqual:conditions] ||
                           controller.refreshError != nil;
            controller.refreshError = nil;
            controller.account = account;
            controller.identifiers = identifiers;
            controller.protectedIDs = protectedIDs;
            controller.backupBlockedIDs = backupBlockedIDs;
            controller.assets = assets;
            controller.names = names;
            controller.jobs = jobs;
            controller.conditions = conditions;
            if (!sameAccount)
                [controller.submitted removeAllObjects];
            else
                for (NSString *identifier in submitted)
                    if (![backupBlockedIDs containsObject:identifier] &&
                        [submitted[identifier] isEqual:jobs[identifier][@"id"]])
                        [controller.submitted removeObjectForKey:identifier];
            NSMutableSet *selectable = [backupBlockedIDs mutableCopy];
            [selectable intersectSet:[NSSet setWithArray:assets.allKeys]];
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
                                !self.checkingPhoto && GSLocalPhotoProtectionStore().healthy &&
                                self.account.length > 0;
    for (NSIndexPath *path in self.tableView.indexPathsForVisibleRows) {
        if (path.section != 0 || path.row >= self.identifiers.count)
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
    return section == 0 ? self.identifiers.count : 1;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    for (NSString *identifier in self.identifiers)
        if (!self.assets[identifier])
            return 2;
    return 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1)
        return GSL(@"Select the photo that is still in Apple Photos. Only its ID is compared. This "
                   @"does not upload it or change protection.");
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
    if ([self.backupBlockedIDs containsObject:identifier] && !submitted)
        return nil;
    return self.jobs[identifier];
}
- (NSString *)detailForIdentifier:(NSString *)identifier {
    PHAsset *asset = self.assets[identifier];
    NSDictionary *job = [self jobForIdentifier:identifier];
    NSString *preparing = self.preparation[identifier];
    NSString *state = preparing ? ([preparing isEqual:@"preparing"]
                                       ? GSL(@"Preparing")
                                       : GSL(@"Preparation failed. Tap to try again."))
                      : job ? GSProtectedPhotoUploadPresentation(job, self.conditions)[@"detail"]
                      : self.submitted[identifier] ? GSL(@"Checking status")
                      : asset                      ? GSL(@"Kept on this iPhone")
                                                   : nil;
    NSMutableArray *lines = [NSMutableArray array];
    if (state.length)
        [lines addObject:state];
    if ([self.protectedIDs containsObject:identifier] &&
        ![self.backupBlockedIDs containsObject:identifier])
        [lines addObject:GSL(@"Backup allowed; iPhone copy protected")];
    if (asset.creationDate)
        [lines addObject:[NSDateFormatter localizedStringFromDate:asset.creationDate
                                                        dateStyle:NSDateFormatterMediumStyle
                                                        timeStyle:NSDateFormatterShortStyle]];
    if (!asset)
        [lines addObject:GSProtectedPhotoLookupMessage(self.lookupReasons[identifier])];
    else if ([self.previewReasons[identifier] isEqual:@"cloud_only"])
        [lines addObject:GSL(@"Photo found; preview requires an iCloud download.")];
    else if ([self.previewReasons[identifier] isEqual:@"failed"])
        [lines addObject:GSL(@"Photo found; preview could not be loaded. Pull down to retry.")];
    return [lines componentsJoinedByString:@"\n"];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    if (path.section == 1) {
        UITableViewCell *check =
            [tableView dequeueReusableCellWithIdentifier:@"photo-check"]
                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:@"photo-check"];
        UIListContentConfiguration *content = check.defaultContentConfiguration;
        content.text = self.checkingPhoto ? GSL(@"Checking photo...")
                                          : GSL(@"Check a photo still on this iPhone");
        content.textProperties.numberOfLines = 0;
        content.textProperties.color = self.checkingPhoto || self.saving
                                           ? UIColor.secondaryLabelColor
                                           : UIColor.systemBlueColor;
        content.image = [UIImage systemImageNamed:@"magnifyingglass"];
        check.contentConfiguration = content;
        check.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return check;
    }
    GSProtectedPhotoCell *cell = [tableView dequeueReusableCellWithIdentifier:@"protected"
                                                                 forIndexPath:path];
    [cell cancelPreview];
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
    NSDictionary *presentation =
        job ? GSProtectedPhotoUploadPresentation(job, self.conditions) : nil;
    if (preparing)
        presentation = nil;
    content.secondaryText = [self detailForIdentifier:identifier];
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
    UIImage *cached = asset ? [self.previews objectForKey:identifier] : nil;
    content.image = cached ?: [UIImage systemImageNamed:asset ? @"photo" : @"photo.badge.exclamationmark"]
                        ?: [UIImage systemImageNamed:@"photo"];
    cell.contentConfiguration = content;
    if ([self.selected containsObject:identifier])
        [tableView selectRowAtIndexPath:path
                               animated:NO
                         scrollPosition:UITableViewScrollPositionNone];
    else
        [tableView deselectRowAtIndexPath:path animated:NO];
    if (asset && !cached && !self.previewReasons[identifier]) {
        PHImageRequestOptions *options = [PHImageRequestOptions new];
        options.networkAccessAllowed = NO;
        options.deliveryMode = PHImageRequestOptionsDeliveryModeOpportunistic;
        __weak GSProtectedPhotoCell *weakCell = cell;
        __weak GSProtectedPhotosController *weakSelf = self;
        NSUInteger assetGeneration = self.assetGeneration;
        GSProtectedPreviewRequest *request = [GSProtectedPreviewRequest new];
        cell.previewRequest = request;
        cell.imageRequest = [PHImageManager.defaultManager
            requestImageForAsset:asset
                      targetSize:CGSizeMake(168, 168)
                     contentMode:PHImageContentModeAspectFill
                         options:options
                   resultHandler:^(UIImage *image, NSDictionary *info) {
                       dispatch_async(dispatch_get_main_queue(), ^{
                           GSProtectedPhotoCell *visible = weakCell;
                           GSProtectedPhotosController *controller = weakSelf;
                           if (!controller || visible.previewRequest != request ||
                               assetGeneration != controller.assetGeneration ||
                               ![visible.representedIdentifier isEqual:identifier] ||
                               [info[PHImageCancelledKey] boolValue]) {
                               [request finish:@"cancelled"];
                               return;
                           }
                           if (image) {
                               [request finish:@"available"];
                               [controller.previews setObject:image forKey:identifier];
                               // A degraded image is already useful. A later empty result
                               // must not replace it with an unavailable-preview warning.
                               [controller.previewReasons removeObjectForKey:identifier];
                           } else {
                               if ([controller.previews objectForKey:identifier] ||
                                   ([info[PHImageResultIsDegradedKey] boolValue] &&
                                    !info[PHImageErrorKey]))
                                   return;
                               NSString *outcome = [info[PHImageResultIsInCloudKey] boolValue]
                                                       ? @"cloud_only"
                                                       : @"failed";
                               [request finish:outcome];
                               controller.previewReasons[identifier] = outcome;
                           }
                           UIListContentConfiguration *updated =
                               [(id)visible.contentConfiguration copy];
                           if (image)
                               updated.image = image;
                           updated.secondaryText = [controller detailForIdentifier:identifier];
                           visible.contentConfiguration = updated;
                       });
                   }];
    }
    return cell;
}
- (NSIndexPath *)tableView:(UITableView *)tableView willSelectRowAtIndexPath:(NSIndexPath *)path {
    if (path.section == 1)
        return !self.loading && !self.saving && !self.checkingPhoto && !self.presentedViewController
                   ? path
                   : nil;
    if (self.loading || self.saving || self.checkingPhoto || path.row >= self.identifiers.count)
        return nil;
    NSString *identifier = self.identifiers[path.row];
    NSDictionary *job = [self jobForIdentifier:identifier];
    if ([job[@"state"] isEqual:@"failed"])
        return path;
    return self.assets[identifier] && ([self.backupBlockedIDs containsObject:identifier] ||
                                       [job[@"state"] isEqual:@"cancelled"])
               ? path
               : nil;
}
- (BOOL)canForgetProtectionForIdentifier:(NSString *)identifier {
    // Queue history has its own cleanup. This action removes only an unavailable
    // saved protection entry, never a queued job or an accessible photo's guard.
    return !self.loading && !self.saving && !self.checkingPhoto &&
           GSLocalPhotoProtectionStore().healthy && [self.protectedIDs containsObject:identifier] &&
           !self.assets[identifier] && [self.lookupReasons[identifier] isEqual:@"not_returned"] &&
           !self.jobs[identifier] && !self.preparation[identifier] && !self.submitted[identifier];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)path {
    if (path.section != 0 || path.row >= self.identifiers.count || self.presentedViewController)
        return nil;
    NSString *identifier = self.identifiers[path.row];
    if (![self canForgetProtectionForIdentifier:identifier])
        return nil;
    __weak GSProtectedPhotosController *weakSelf = self;
    UIContextualAction *action =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                title:GSL(@"Remove protection")
                                              handler:^(UIContextualAction *action, UIView *view,
                                                        void (^complete)(BOOL)) {
                                                  complete(NO);
                                                  [weakSelf.tableView setEditing:NO animated:YES];
                                                  [weakSelf confirmForgetProtection:identifier];
                                              }];
    action.image = [UIImage systemImageNamed:@"lock.open"];
    UISwipeActionsConfiguration *configuration =
        [UISwipeActionsConfiguration configurationWithActions:@[ action ]];
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}
- (void)confirmForgetProtection:(NSString *)identifier {
    if (self.presentedViewController || ![self canForgetProtectionForIdentifier:identifier])
        return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:GSL(@"Remove saved protection?")
                         message:GSL(@"This removes only the saved protection entry, without "
                                     @"deleting photos or starting an upload. If the old ID "
                                     @"becomes accessible again, GoToHP will no longer block its "
                                     @"backup or local deletion.")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:GSL(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak GSProtectedPhotosController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:GSL(@"Remove protection")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
                                                [weakSelf forgetProtection:identifier];
                                            }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)forgetProtection:(NSString *)identifier {
    if (![self canForgetProtectionForIdentifier:identifier])
        return;
    self.saving = YES;
    [self updateSelection];
    __weak GSProtectedPhotosController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *result =
            GSForgetUnavailablePhotoProtection(identifier, GSLocalPhotoProtectionStore());
        dispatch_async(dispatch_get_main_queue(), ^{
            GSProtectedPhotosController *page = weakSelf;
            page.saving = NO;
            BOOL removed = [result isEqual:@"removed"] || [result isEqual:@"already_removed"];
            if (removed) {
                // Discard any poll that captured the flag before this explicit write.
                page.generation++;
                page.protectedIDs =
                    [NSSet setWithArray:GSLocalPhotoProtectionStore().protectedIdentifiers];
                page.backupBlockedIDs =
                    [NSSet setWithArray:GSLocalPhotoProtectionStore().backupBlockedIdentifiers];
                if (![page.protectedIDs containsObject:identifier] && !page.jobs[identifier]) {
                    NSMutableArray *identifiers = [page.identifiers mutableCopy];
                    [identifiers removeObject:identifier];
                    page.identifiers = identifiers;
                    [page.selected removeObject:identifier];
                }
            }
            [page updateSelection];
            [page updateEmptyState];
            [page redraw];
            [page reloadPhotos];
            if (removed || !page.active || page.presentedViewController)
                return;
            NSString *message =
                [result isEqual:@"photo_available"]
                    ? GSL(@"This photo is accessible again. Its protection was kept.")
                : [result isEqual:@"write_failed"] || [result isEqual:@"store_unavailable"]
                    ? GSL(@"The saved protection was not changed. Try again later.")
                    : GSL(@"Could not confirm that this saved ID is unavailable. Protection is "
                          @"unchanged. Refresh and try again.");
            UIAlertController *failure =
                [UIAlertController alertControllerWithTitle:GSL(@"Could not remove protection")
                                                    message:message
                                             preferredStyle:UIAlertControllerStyleAlert];
            [failure addAction:[UIAlertAction actionWithTitle:GSL(@"Done")
                                                        style:UIAlertActionStyleDefault
                                                      handler:nil]];
            [page presentViewController:failure animated:YES completion:nil];
        });
    });
}
- (NSIndexPath *)tableView:(UITableView *)tableView willDeselectRowAtIndexPath:(NSIndexPath *)path {
    return self.loading || self.saving ? nil : path;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    if (path.section == 1) {
        [tableView deselectRowAtIndexPath:path animated:NO];
        [self checkCurrentPhoto];
        return;
    }
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
    if (path.section == 0 && path.row < self.identifiers.count)
        [self.selected removeObject:self.identifiers[path.row]];
    [self updateSelection];
}
- (void)checkCurrentPhoto {
    if (self.saving || self.checkingPhoto || self.presentedViewController)
        return;
    // Passing the system library is required for PHPicker assetIdentifier.
    // Do not ask the item provider to load/export any media.
    PHPickerConfiguration *configuration =
        [[PHPickerConfiguration alloc] initWithPhotoLibrary:PHPhotoLibrary.sharedPhotoLibrary];
    configuration.selectionLimit = 1;
    PHPickerViewController *picker =
        [[PHPickerViewController alloc] initWithConfiguration:configuration];
    picker.delegate = self;
    self.photoCheckPicker = picker;
    self.checkingPhoto = YES;
    [self updateSelection];
    [self redraw];
    [self presentViewController:picker animated:YES completion:nil];
    picker.presentationController.delegate = self;
}
- (void)finishPhotoCheck {
    self.checkingPhoto = NO;
    self.photoCheckPicker = nil;
    // Reset visible controls even if refreshing is deferred, offline or unchanged.
    [self updateSelection];
    [self redraw];
}
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    if (presentationController.presentedViewController != self.photoCheckPicker)
        return;
    // Interactive dismissal need not deliver PHPicker's result callback.
    [self finishPhotoCheck];
    [self reloadPhotos];
}
- (void)picker:(PHPickerViewController *)picker
    didFinishPicking:(NSArray<PHPickerResult *> *)results {
    if (picker != self.photoCheckPicker)
        return;
    self.photoCheckPicker = nil;
    NSString *identifier = [results.firstObject.assetIdentifier copy];
    __weak GSProtectedPhotosController *weakSelf = self;
    if (!results.count) {
        [self finishPhotoCheck];
        [self dismissViewControllerAnimated:YES
                                 completion:^{
                                     [weakSelf reloadPhotos];
                                 }];
        return;
    }
    [self
        dismissViewControllerAnimated:YES
                           completion:^{
                               dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                                   NSDictionary *report = GSCheckProtectedPhotoSelection(
                                       identifier,
                                       GSLocalPhotoProtectionStore().protectedIdentifiers);
                                   [GSLocalPhotoProtectionStore() recordPhotoSelectionCheck:report];
                                   dispatch_async(dispatch_get_main_queue(), ^{
                                       GSProtectedPhotosController *page = weakSelf;
                                       [page finishPhotoCheck];
                                       if (!page.active || page.presentedViewController)
                                           return;
                                       NSString *outcome = report[@"outcome"];
                                       NSString *message =
                                           [outcome isEqual:@"matched_protection"]
                                               ? GSL(@"Photo found. Its ID matches a saved "
                                                     @"protection entry. Refresh the list to check "
                                                     @"again.")
                                           : [outcome isEqual:@"not_in_protection"]
                                               ? GSL(@"Photo found. Its current ID does not match "
                                                     @"any saved protection entry. No photos were "
                                                     @"linked.")
                                           : [outcome isEqual:@"selected_not_returned"]
                                               ? GSL(@"The picker returned an ID, but PhotoKit did "
                                                     @"not return the selected photo.")
                                           : [outcome isEqual:@"identifier_unavailable"]
                                               ? GSL(@"The picker did not return a photo ID. "
                                                     @"Protection is unchanged.")
                                               : GSL(@"Could not check the selected photo. See "
                                                     @"upload diagnostics for details.");
                                       UIAlertController *alert = [UIAlertController
                                           alertControllerWithTitle:GSL(@"Photo check")
                                                            message:message
                                                     preferredStyle:UIAlertControllerStyleAlert];
                                       [alert
                                           addAction:[UIAlertAction
                                                         actionWithTitle:GSL(@"Done")
                                                                   style:UIAlertActionStyleDefault
                                                                 handler:^(UIAlertAction *action) {
                                                                     [weakSelf reloadPhotos];
                                                                 }]];
                                       [page presentViewController:alert
                                                          animated:YES
                                                        completion:nil];
                                   });
                               });
                           }];
}
- (void)confirmBackup {
    if (self.saving || self.checkingPhoto || !self.selected.count || self.presentedViewController)
        return;
    if ([GSBatchImportSnapshot()[@"active"] boolValue]) {
        self.refreshError = GSL(@"Wait for the operation to finish, then retry.");
        [self redraw];
        return;
    }
    NSArray *identifiers = [self.selected.allObjects sortedArrayUsingSelector:@selector(compare:)];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:GSL(@"Back up selected photos again?")
                         message:GSL(@"The selected photos will be queued using the current "
                                     @"account, upload quality, and album destination. Their "
                                     @"iPhone copies stay protected from deletion sync. Progress "
                                     @"and results appear here.")
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
