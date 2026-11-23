#import "GSProtectedPhotosController.h"
#import "GSPanel.h"
#import "../Native/GSLocalPhotoProtection.h"
#import "../Shared/GSLocalization.h"
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
@property (nonatomic, copy) NSDictionary<NSString *, PHAsset *> *assets;
@property (nonatomic, strong) NSMutableSet<NSString *> *selected;
@property (nonatomic, strong) UIBarButtonItem *allowButton;
@property (nonatomic, strong) id foregroundObserver;
@property (nonatomic) BOOL active, loading, saving, previousToolbarHidden;
@property (nonatomic) NSUInteger generation;
@end

@implementation GSProtectedPhotosController
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _identifiers = @[];
        _assets = @{};
        _selected = [NSMutableSet set];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = GSL(@"Photos kept on this iPhone");
    self.navigationItem.rightBarButtonItem = GSPanelDoneButton(self);
    self.navigationItem.backButtonDisplayMode = UINavigationItemBackButtonDisplayModeMinimal;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 76;
    self.tableView.allowsMultipleSelection = YES;
    [self.tableView registerClass:GSProtectedPhotoCell.class forCellReuseIdentifier:@"protected"];
    self.allowButton = [[UIBarButtonItem alloc] initWithTitle:GSL(@"Allow backup again")
                                                        style:UIBarButtonItemStylePlain
                                                       target:self
                                                       action:@selector(confirmAllowBackup)];
    self.allowButton.enabled = NO;
    UIBarButtonItem *space =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                      target:nil
                                                      action:nil];
    UIBarButtonItem *trailingSpace =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                      target:nil
                                                      action:nil];
    self.toolbarItems = @[ space, self.allowButton, trailingSpace ];
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
                    if (controller.active && !controller.saving &&
                        !controller.presentedViewController)
                        [controller reloadPhotos];
                }];
}
- (void)dealloc {
    if (_foregroundObserver)
        [NSNotificationCenter.defaultCenter removeObserver:_foregroundObserver];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.active = YES;
    self.previousToolbarHidden = self.navigationController.toolbarHidden;
    [self.navigationController setToolbarHidden:NO animated:animated];
    [self reloadPhotos];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.active = NO;
    self.generation++;
    [self.refreshControl endRefreshing];
    [self.navigationController setToolbarHidden:self.previousToolbarHidden animated:animated];
}
- (void)reloadPhotos {
    if (!self.active || self.saving) {
        [self.refreshControl endRefreshing];
        return;
    }
    self.loading = YES;
    self.allowButton.enabled = NO;
    NSUInteger generation = ++self.generation;
    [self updateEmptyState];
    __weak GSProtectedPhotosController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *identifiers = GSLocalPhotoProtectionStore().protectedIdentifiers;
        NSMutableDictionary *assets = [NSMutableDictionary dictionary];
        PHAuthorizationStatus authorization =
            [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
        if (identifiers.count && (authorization == PHAuthorizationStatusAuthorized ||
                                  authorization == PHAuthorizationStatusLimited)) {
            PHFetchResult<PHAsset *> *result = [PHAsset fetchAssetsWithLocalIdentifiers:identifiers
                                                                                options:nil];
            [result enumerateObjectsUsingBlock:^(PHAsset *asset, NSUInteger index, BOOL *stop) {
                assets[asset.localIdentifier] = asset;
            }];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            GSProtectedPhotosController *controller = weakSelf;
            if (!controller.active || generation != controller.generation)
                return;
            controller.loading = NO;
            controller.identifiers = identifiers;
            controller.assets = assets;
            [controller.selected intersectSet:[NSSet setWithArray:identifiers]];
            [controller.refreshControl endRefreshing];
            [controller.tableView reloadData];
            [controller updateEmptyState];
            [controller updateSelection];
        });
    });
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
                 : self.loading ? GSL(@"Loading photos...")
                                : GSL(@"No photos are being kept.");
    self.tableView.backgroundView = label;
}
- (void)updateSelection {
    self.allowButton.enabled = self.selected.count > 0 && !self.loading && !self.saving &&
                               GSLocalPhotoProtectionStore().healthy;
    for (NSIndexPath *path in self.tableView.indexPathsForVisibleRows) {
        if (path.row >= self.identifiers.count)
            continue;
        BOOL selected = [self.selected containsObject:self.identifiers[path.row]];
        [self.tableView cellForRowAtIndexPath:path].accessoryType =
            selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    }
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.identifiers.count;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return GSL(@"Choose photos to allow GoToHP to back them up again. This does not delete photos "
               @"or start an upload. Photos you cannot access may be missing or outside the "
               @"app's photo permission; their protection is kept until you remove it.");
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    GSProtectedPhotoCell *cell = [tableView dequeueReusableCellWithIdentifier:@"protected"
                                                                 forIndexPath:path];
    NSString *identifier = self.identifiers[path.row];
    PHAsset *asset = self.assets[identifier];
    cell.representedIdentifier = identifier;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryType = [self.selected containsObject:identifier]
                             ? UITableViewCellAccessoryCheckmark
                             : UITableViewCellAccessoryNone;
    UIListContentConfiguration *content = cell.defaultContentConfiguration;
    content.imageProperties.maximumSize = CGSizeMake(56, 56);
    content.imageProperties.reservedLayoutSize = CGSizeMake(56, 56);
    content.imageProperties.cornerRadius = 6;
    content.textProperties.numberOfLines = 0;
    content.secondaryTextProperties.numberOfLines = 0;
    content.text = asset
                       ? (asset.mediaType == PHAssetMediaTypeVideo ? GSL(@"Video") : GSL(@"Photo"))
                       : [NSString stringWithFormat:GSL(@"Photo unavailable (%lu)"),
                                                    (unsigned long)path.row + 1];
    content.secondaryText =
        asset.creationDate ? [NSDateFormatter localizedStringFromDate:asset.creationDate
                                                            dateStyle:NSDateFormatterMediumStyle
                                                            timeStyle:NSDateFormatterShortStyle]
                           : GSL(@"Preview unavailable");
    content.image = [UIImage systemImageNamed:asset ? @"photo" : @"photo.badge.exclamationmark"];
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
    return self.loading || self.saving || path.row >= self.identifiers.count ? nil : path;
}
- (NSIndexPath *)tableView:(UITableView *)tableView willDeselectRowAtIndexPath:(NSIndexPath *)path {
    return self.loading || self.saving ? nil : path;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    if (!self.loading && !self.saving && path.row < self.identifiers.count)
        [self.selected addObject:self.identifiers[path.row]];
    [self updateSelection];
}
- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)path {
    if (!self.loading && !self.saving && path.row < self.identifiers.count)
        [self.selected removeObject:self.identifiers[path.row]];
    [self updateSelection];
}
- (void)confirmAllowBackup {
    if (self.saving || self.loading || !self.selected.count || self.presentedViewController)
        return;
    NSArray *identifiers = self.selected.allObjects;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:GSL(@"Allow backup again?")
                         message:GSL(@"The selected photos will follow normal backup and deletion "
                                     @"behavior again. "
                                     @"This does not delete them or start an upload.")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:GSL(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak GSProtectedPhotosController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:GSL(@"Allow backup again")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                                [weakSelf allowBackupFor:identifiers];
                                            }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)allowBackupFor:(NSArray *)identifiers {
    self.saving = YES;
    self.generation++;
    self.allowButton.enabled = NO;
    self.tableView.userInteractionEnabled = NO;
    __weak GSProtectedPhotosController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL saved = [GSLocalPhotoProtectionStore() allowBackupForIdentifiers:identifiers
                                                                        error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            GSProtectedPhotosController *controller = weakSelf;
            controller.saving = NO;
            controller.tableView.userInteractionEnabled = YES;
            if (saved)
                [controller.selected minusSet:[NSSet setWithArray:identifiers]];
            if (!controller.active)
                return;
            [controller reloadPhotos];
            if (!saved) {
                UIAlertController *error =
                    [UIAlertController alertControllerWithTitle:GSL(@"Could not allow backup again")
                                                        message:GSL(@"The saved protection was not "
                                                                    @"changed. Try again later.")
                                                 preferredStyle:UIAlertControllerStyleAlert];
                [error addAction:[UIAlertAction actionWithTitle:GSL(@"OK")
                                                          style:UIAlertActionStyleDefault
                                                        handler:nil]];
                void (^present)(void) = ^{
                    if (controller.active && !controller.presentedViewController)
                        [controller presentViewController:error animated:YES completion:nil];
                };
                if ([controller.presentedViewController isKindOfClass:UIAlertController.class])
                    [controller.presentedViewController dismissViewControllerAnimated:NO
                                                                           completion:present];
                else
                    present();
            }
        });
    });
}
@end
