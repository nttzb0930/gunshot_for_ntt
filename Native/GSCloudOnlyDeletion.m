#import "GSCloudOnlyDeletion.h"
#import "GSLocalPhotoProtection.h"
#import "GSNativeAccount.h"
#import "GSNativeRouting.h"
#import "GSBackupRequests.h"
#import "../Shared/GSPhotosRuntime.h"
#import "../Shared/GSLocalization.h"
#import "../Shared/IPCProtocol.h"
#import "../Media/GSBatchImport.h"
#import <Photos/Photos.h>
#import <UIKit/UIKit.h>

// These declarations describe audited Objective-C messages, not replacement host classes.
@interface GSAuditedDeleteStrategy : NSObject
- (instancetype)initWithMediaItems:(id)items
                      deletionType:(NSUInteger)type
                      deleteOrigin:(NSUInteger)origin;
@end
@interface GSAuditedDeletePromise : NSObject
- (void)resolve:(id)result;
- (void)reject:(id)error;
- (id)withMainQueueOnSuccess:(id (^)(id))success
                   onFailure:(id (^)(id))failure
                    onCancel:(id (^)(void))cancel;
@end

static BOOL GSDeleteInstalled, GSPhotoKitGuardInstalled;
static char GSDeleteChoiceKey, GSDeletePromiseKey;
static id (*GSDeleteExecuteOriginal)(id, SEL);
static id (*GSDeleteLocalOriginal)(id, SEL);
static id (*GSDeleteItemsOriginal)(id, SEL);
static NSString *const GSLocalDeleteScope = @"dev.tqmane.gunshot.emptyLocalDeleteSelection";
static void (*GSPhotoKitDeleteOriginal)(id, SEL, id);
static NSUInteger GSBlockedLocalDeletes;
static NSUInteger GSUnresolvedSelections;
static NSString *GSDeleteAvailability = @"not_installed";

static void GSDeleteReplace(Class cls, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method)))
        method_setImplementation(class_getInstanceMethod(cls, selector), replacement);
}
static NSError *GSDeleteError(NSString *message) {
    return [NSError errorWithDomain:@"GoToHP.CloudOnlyDeletion"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}
static BOOL GSDeleteEnabledHost(void) {
    return GSPhotosHostSupported() &&
           [[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]
               isEqual:@"7.20.2"];
}
static NSArray *GSDeleteArray(id value) {
    if ([value isKindOfClass:NSArray.class])
        return value;
    if ([value isKindOfClass:NSSet.class])
        return [value allObjects];
    return nil;
}
static BOOL GSDeleteAddLocal(id local, NSMutableSet *identifiers) {
    PHAsset *asset =
        [local isKindOfClass:PHAsset.class] ? local : GSPhotosGetObject(local, @"phAsset");
    if (![asset isKindOfClass:PHAsset.class] || asset.burstIdentifier.length ||
        !asset.localIdentifier.length || asset.localIdentifier.length > 1024)
        return NO;
    [identifiers addObject:asset.localIdentifier];
    return YES;
}
// Resolve every selected item before offering the cloud-only choice. Unknown or
// grouped shapes fail closed; no guessing about native deletionType enum values.
static NSDictionary *GSDeleteTargets(id command) {
    NSArray *items = GSDeleteArray(GSPhotosGetObject(command, @"mediaItems"));
    id source = GSPhotosGetObject(command, @"dataSource");
    if (GSPhotosObjectHasMethod(source, @"expandedMediaItemArray:", "@24@0:8@16"))
        items = GSDeleteArray(((id(*)(id, SEL, id))objc_msgSend)(
            source, NSSelectorFromString(@"expandedMediaItemArray:"), items));
    if (!items.count || items.count > 500)
        return nil;
    NSMutableSet *localIDs = [NSMutableSet set];
    BOOL allBackedUp = YES;
    id storeResult = GSPhotosGetObject(source, @"storeResult");
    Class cls = NSClassFromString(@"PHSPhotoDeletionStrategy");
    for (id item in items) {
        GSAuditedDeleteStrategy *strategy =
            [(GSAuditedDeleteStrategy *)[cls alloc] initWithMediaItems:@[ item ]
                                                          deletionType:0
                                                          deleteOrigin:0];
        NSArray *ids = GSDeleteArray(GSPhotosGetObject(strategy, @"localAssetIDs"));
        NSArray *keys = GSDeleteArray(GSPhotosGetObject(strategy, @"mediaKeys"));
        if (!strategy || !ids || !keys)
            return nil;
        for (id key in keys)
            if (![key isKindOfClass:NSString.class] || ![key length])
                return nil;
        id local = GSPhotosGetObject(item, @"localAsset");
        if (!local && GSPhotosObjectHasMethod(item, @"phAsset", "@16@0:8"))
            local = item;
        if (local && !GSDeleteAddLocal(local, localIDs))
            return nil;
        id mediaKey = GSPhotosGetObject(local, @"mediaKey");
        BOOL backedUp =
            keys.count > 0 || ([mediaKey isKindOfClass:NSString.class] && [mediaKey length]);
        id dedup = GSPhotosGetObject(item, @"localDedupKey");
        if ([dedup isKindOfClass:NSString.class] && [dedup length]) {
            if (!GSPhotosObjectHasMethod(storeResult,
                                         @"localAssetsForLocalDedupKey:", "@24@0:8@16") ||
                !GSPhotosObjectHasMethod(storeResult,
                                         @"serverPhotosForLocalDedupKey:", "@24@0:8@16"))
                return nil;
            NSArray *matches = GSDeleteArray(((id(*)(id, SEL, id))objc_msgSend)(
                storeResult, NSSelectorFromString(@"localAssetsForLocalDedupKey:"), dedup));
            NSArray *serverPhotos = GSDeleteArray(((id(*)(id, SEL, id))objc_msgSend)(
                storeResult, NSSelectorFromString(@"serverPhotosForLocalDedupKey:"), dedup));
            if (!matches || !serverPhotos)
                return nil;
            for (id match in matches)
                if (!GSDeleteAddLocal(match, localIDs))
                    return nil;
            backedUp |= serverPhotos.count > 0;
        }
        allBackedUp &= backedUp;
        for (id identifier in ids) {
            if (![identifier isKindOfClass:NSString.class] || ![identifier length] ||
                [identifier length] > 1024)
                return nil;
            [localIDs addObject:identifier];
        }
    }
    if (!localIDs.count || localIDs.count > 500)
        return nil;
    NSArray *identifiers = localIDs.allObjects;
    if ([PHAsset fetchAssetsWithLocalIdentifiers:identifiers options:nil].count !=
        identifiers.count)
        return nil;
    return @{@"localIDs" : identifiers, @"allBackedUp" : @(allBackedUp)};
}
static UIViewController *GSDeletePresenter(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive)
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isKeyWindow)
                continue;
            UIViewController *presenter = window.rootViewController;
            while (presenter.presentedViewController)
                presenter = presenter.presentedViewController;
            if (presenter && !presenter.isBeingDismissed &&
                ![presenter isKindOfClass:UIAlertController.class])
                return presenter;
        }
    }
    return nil;
}
// A file already exported into the Go queue has no reliable PhotoKit identity.
// Refuse cloud-only deletion until all imports/uploads have settled.
static BOOL GSDeleteQueueSettled(void) {
    if ([GSBatchImportSnapshot()[@"active"] boolValue] ||
        [GSBackupRequestsSnapshot()[@"activeTransfers"] unsignedIntegerValue] > 0)
        return NO;
    NSInteger cursor = 0;
    for (NSUInteger page = 0; page < 1000; page++) {
        NSDictionary *reply = GSRequest(@{@"op" : @"list", @"cursor" : @(cursor)}, nil);
        if (![reply[@"jobs"] isKindOfClass:NSArray.class] ||
            ![reply[@"next"] isKindOfClass:NSNumber.class])
            return NO;
        for (NSDictionary *job in reply[@"jobs"])
            if (![@[ @"completed", @"failed", @"cancelled" ] containsObject:job[@"state"] ?: @""])
                return NO;
        NSInteger next = [reply[@"next"] integerValue];
        if (next < 0)
            return YES;
        if (next <= cursor)
            return NO;
        cursor = next;
    }
    return NO;
}
static void GSDeleteContinue(id command, GSAuditedDeletePromise *proxy, NSArray *identifiers,
                             BOOL cloudOnly, id accountID) {
    if (cloudOnly && !identifiers.count) {
        [proxy reject:GSDeleteError(
                          GSL(@"Could not confirm the deletion context. Nothing was deleted."))];
        return;
    }
    if (!GSNativeAccountMatches(accountID)) {
        [proxy reject:GSDeleteError(GSL(@"The signed-in account changed. Nothing was deleted."))];
        return;
    }
    if (identifiers) {
        NSDictionary *current = GSDeleteTargets(command);
        if (!current ||
            ![[NSSet setWithArray:identifiers] isEqual:[NSSet setWithArray:current[@"localIDs"]]] ||
            (cloudOnly && ![current[@"allBackedUp"] boolValue])) {
            [proxy reject:GSDeleteError(GSL(
                              @"Could not confirm the deletion context. Nothing was deleted."))];
            return;
        }
    }
    if (cloudOnly && (!GSNativeRoutingEnabled() || [GSBatchImportSnapshot()[@"active"] boolValue] ||
                      [GSBackupRequestsSnapshot()[@"activeTransfers"] unsignedIntegerValue] > 0)) {
        [proxy reject:GSDeleteError(GSL(@"Wait for all GoToHP uploads to finish before deleting "
                                        @"only from Google Photos."))];
        return;
    }
    NSError *error = nil;
    if (identifiers && ![GSLocalPhotoProtectionStore() updateIdentifiers:identifiers
                                                                 protect:cloudOnly
                                                                   error:&error]) {
        [proxy reject:GSDeleteError(
                          GSL(@"Could not save local photo protection. Nothing was deleted."))];
        return;
    }
    objc_setAssociatedObject(command, &GSDeleteChoiceKey, cloudOnly ? @"cloud" : @"native",
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id result = GSDeleteExecuteOriginal(command, NSSelectorFromString(@"execute"));
    if (![result isKindOfClass:NSClassFromString(@"GPCPromise")]) {
        [proxy
            reject:GSDeleteError(GSL(
                       @"The deletion result is unknown. Check Google Photos before retrying."))];
        return;
    }
    [(GSAuditedDeletePromise *)result
        withMainQueueOnSuccess:^id(id value) {
            [proxy resolve:value ?: NSNull.null];
            return value;
        }
        onFailure:^id(id failure) {
            [proxy reject:failure];
            return nil;
        }
        onCancel:^id {
            [proxy reject:[NSError errorWithDomain:NSCocoaErrorDomain
                                              code:NSUserCancelledError
                                          userInfo:nil]];
            return nil;
        }];
}
static id GSDeleteExecute(id command, SEL selector) {
    id pending = objc_getAssociatedObject(command, &GSDeletePromiseKey);
    if (pending)
        return pending;
    NSDictionary *targets = GSDeleteTargets(command);
    if (!targets)
        @synchronized(GSLocalPhotoProtectionStore()) {
            GSUnresolvedSelections++;
        }
    GSAuditedDeletePromise *proxy = [NSClassFromString(@"GPCPromise") new];
    objc_setAssociatedObject(command, &GSDeletePromiseKey, proxy,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{
        id accountID = GSPhotosGetObject(command, @"accountID");
        UIViewController *presenter = GSDeletePresenter();
        if (!presenter || !accountID || !GSNativeAccountMatches(accountID)) {
            [proxy reject:GSDeleteError(GSL(
                              @"Could not confirm the deletion context. Nothing was deleted."))];
            return;
        }
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:GSL(@"Choose where to delete")
                             message:GSL(@"Experimental: keep these photos on this iPhone. New "
                                         @"uploads of these local assets are blocked. GoToHP "
                                         @"backup integration must be enabled. Finish all uploads "
                                         @"first. Other devices are not protected.")
                      preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *cloud = [UIAlertAction
            actionWithTitle:GSL(@"Delete only from Google Photos")
                      style:UIAlertActionStyleDestructive
                    handler:^(UIAlertAction *action) {
                        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                            BOOL settled = GSDeleteQueueSettled();
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (!settled) {
                                    [proxy
                                        reject:GSDeleteError(GSL(
                                                   @"Wait for all GoToHP uploads to finish before "
                                                   @"deleting only from Google Photos."))];
                                    return;
                                }
                                GSDeleteContinue(command, proxy, targets[@"localIDs"], YES,
                                                 accountID);
                            });
                        });
                    }];
        cloud.enabled = [targets[@"allBackedUp"] boolValue] &&
                        GSLocalPhotoProtectionStore().healthy && GSNativeRoutingEnabled() &&
                        GSBackupRequestsAvailable();
        [alert addAction:cloud];
        [alert addAction:[UIAlertAction
                             actionWithTitle:GSL(@"Use normal deletion (may delete device copy)")
                                       style:UIAlertActionStyleDestructive
                                     handler:^(UIAlertAction *action) {
                                         GSDeleteContinue(command, proxy, targets[@"localIDs"], NO,
                                                          accountID);
                                     }]];
        BOOL protectedSelection = NO;
        for (NSString *identifier in targets[@"localIDs"])
            protectedSelection |= [GSLocalPhotoProtectionStore() contains:identifier];
        if (protectedSelection)
            [alert
                addAction:[UIAlertAction
                              actionWithTitle:GSL(@"Remove protection without deleting")
                                        style:UIAlertActionStyleDefault
                                      handler:^(UIAlertAction *action) {
                                          NSError *error = nil;
                                          if (!GSNativeAccountMatches(accountID) ||
                                              ![GSLocalPhotoProtectionStore()
                                                  updateIdentifiers:targets[@"localIDs"]
                                                            protect:NO
                                                              error:&error]) {
                                              [proxy
                                                  reject:GSDeleteError(GSL(
                                                             @"Could not save local photo "
                                                             @"protection. Nothing was deleted."))];
                                              return;
                                          }
                                          [proxy
                                              reject:[NSError errorWithDomain:NSCocoaErrorDomain
                                                                         code:NSUserCancelledError
                                                                     userInfo:nil]];
                                      }]];
        [alert addAction:[UIAlertAction
                             actionWithTitle:GSL(@"Cancel")
                                       style:UIAlertActionStyleCancel
                                     handler:^(UIAlertAction *action) {
                                         [proxy reject:[NSError errorWithDomain:NSCocoaErrorDomain
                                                                           code:NSUserCancelledError
                                                                       userInfo:nil]];
                                     }]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
    return proxy;
}
static id GSDeleteLocal(id command, SEL selector) {
    if (![objc_getAssociatedObject(command, &GSDeleteChoiceKey) isEqual:@"cloud"])
        return GSDeleteLocalOriginal(command, selector);
    // Use the native empty-selection branch to produce its own completed promise
    // and void-result sentinel. Never return nil or guess a private promise result.
    NSMutableDictionary *scope = NSThread.currentThread.threadDictionary;
    id previous = scope[GSLocalDeleteScope];
    scope[GSLocalDeleteScope] = command;
    id result;
    @try {
        result = GSDeleteLocalOriginal(command, selector);
    } @finally {
        if (previous)
            scope[GSLocalDeleteScope] = previous;
        else
            [scope removeObjectForKey:GSLocalDeleteScope];
    }
    NSArray *items = GSDeleteItemsOriginal(command, NSSelectorFromString(@"mediaItems"));
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(
        command, NSSelectorFromString(@"setServerPhotoCount:"), items.count);
    return result;
}
static id GSDeleteItems(id command, SEL selector) {
    return NSThread.currentThread.threadDictionary[GSLocalDeleteScope] == command
               ? @[]
               : GSDeleteItemsOriginal(command, selector);
}
static void GSPhotoKitDelete(id cls, SEL selector, id assets) {
    GSLocalPhotoProtection *store = GSLocalPhotoProtectionStore();
    if (!store.count && store.healthy) {
        GSPhotoKitDeleteOriginal(cls, selector, assets);
        return;
    }
    NSMutableArray *allowed = [NSMutableArray array];
    if (![assets conformsToProtocol:@protocol(NSFastEnumeration)])
        return;
    for (id asset in assets) {
        if (![asset isKindOfClass:PHAsset.class] || !((PHAsset *)asset).localIdentifier.length)
            return;
        if ([store contains:((PHAsset *)asset).localIdentifier]) {
            @synchronized(store) {
                GSBlockedLocalDeletes++;
            }
        } else
            [allowed addObject:asset];
    }
    if (allowed.count)
        GSPhotoKitDeleteOriginal(cls, selector, allowed);
}
NSDictionary *GSCloudOnlyDeletionSnapshot(void) {
    GSLocalPhotoProtection *store = GSLocalPhotoProtectionStore();
    @synchronized(store) {
        return @{
            @"available" : @(GSDeleteInstalled),
            @"localGuard" : @(GSPhotoKitGuardInstalled),
            @"storeHealthy" : @(store.healthy),
            @"protectedLocalCount" : @(store.count),
            @"blockedLocalDeletes" : @(GSBlockedLocalDeletes),
            @"unresolvedSelections" : @(GSUnresolvedSelections),
            @"availabilityReason" : GSDeleteAvailability
        };
    }
}
void GSInstallCloudOnlyDeletion(void) {
    if (!GSPhotosHostSupported()) {
        GSDeleteAvailability = @"unsupported_host";
        return;
    }
    // The PhotoKit safeguard is installed independently, including on a later app
    // version where the private command contract is no longer supported.
    Class meta = object_getClass(PHAssetChangeRequest.class);
    if (!GSPhotoKitGuardInstalled && GSPhotosHasMethod(meta, @"deleteAssets:", "v24@0:8@16")) {
        GSPhotoKitDeleteOriginal = (void *)method_getImplementation(
            class_getInstanceMethod(meta, @selector(deleteAssets:)));
        GSDeleteReplace(meta, @selector(deleteAssets:), (IMP)GSPhotoKitDelete);
        GSPhotoKitGuardInstalled = YES;
    }
    if (GSDeleteInstalled)
        return;
    if (!GSPhotoKitGuardInstalled || !GSDeleteEnabledHost()) {
        GSDeleteAvailability =
            GSPhotoKitGuardInstalled ? @"requires_photos_7_20_2" : @"photokit_contract_unavailable";
        return;
    }
    GSDeleteAvailability = @"private_contract_unavailable";
    Class command = NSClassFromString(@"PHSDeletePhotoCommand");
    Class strategy = NSClassFromString(@"PHSPhotoDeletionStrategy");
    Class promise = NSClassFromString(@"GPCPromise");
    if (!GSPhotosHasMethod(command, @"execute", "@16@0:8") ||
        !GSPhotosHasMethod(command, @"deleteLocalAssets", "@16@0:8") ||
        !GSPhotosHasMethod(command, @"accountID", "@16@0:8") ||
        !GSPhotosHasMethod(command, @"mediaItems", "@16@0:8") ||
        !GSPhotosHasMethod(command, @"setServerPhotoCount:", "v24@0:8Q16") ||
        !GSPhotosHasMethod(strategy,
                           @"initWithMediaItems:deletionType:deleteOrigin:", "@40@0:8@16Q24Q32") ||
        !GSPhotosHasMethod(strategy, @"localAssetIDs", "@16@0:8") ||
        !GSPhotosHasMethod(strategy, @"mediaKeys", "@16@0:8") ||
        !GSPhotosHasMethod(promise, @"init", "@16@0:8") ||
        !GSPhotosHasMethod(promise, @"resolve:", "v24@0:8@16") ||
        !GSPhotosHasMethod(promise, @"reject:", "v24@0:8@16") ||
        !GSPhotosHasMethod(promise,
                           @"withMainQueueOnSuccess:onFailure:onCancel:", "@40@0:8@?16@?24@?32"))
        return;
    GSDeleteExecuteOriginal = (void *)method_getImplementation(
        class_getInstanceMethod(command, NSSelectorFromString(@"execute")));
    GSDeleteLocalOriginal = (void *)method_getImplementation(
        class_getInstanceMethod(command, NSSelectorFromString(@"deleteLocalAssets")));
    GSDeleteItemsOriginal = (void *)method_getImplementation(
        class_getInstanceMethod(command, NSSelectorFromString(@"mediaItems")));
    GSDeleteReplace(command, NSSelectorFromString(@"mediaItems"), (IMP)GSDeleteItems);
    GSDeleteReplace(command, NSSelectorFromString(@"deleteLocalAssets"), (IMP)GSDeleteLocal);
    GSDeleteReplace(command, NSSelectorFromString(@"execute"), (IMP)GSDeleteExecute);
    GSDeleteInstalled = YES;
    GSDeleteAvailability = @"ready";
}
