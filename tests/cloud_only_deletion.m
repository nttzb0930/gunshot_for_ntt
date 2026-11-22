// Synthetic host only: never opens a real Photos library or contacts Google.
#define GSLocalPhotoProtectionStore GSFixtureSharedStore
#import "../Native/GSCloudOnlyDeletion.m"
#include <assert.h>
#include <string.h>

static GSLocalPhotoProtection *FixtureStore;
static UIViewController *FixturePresenter;
static NSArray *DeletedAssets;
static NSUInteger CloudCalls;
static BOOL AccountMatches = YES, QueueBusy, FailCloud;
static NSString *FixtureVersion = @"7.20.2";
GSLocalPhotoProtection *GSFixtureSharedStore(void) {
    return FixtureStore;
}
BOOL GSNativeAccountMatches(id account) {
    return AccountMatches && [account isEqual:@"account"];
}
BOOL GSNativeRoutingEnabled(void) {
    return YES;
}
BOOL GSBackupRequestsAvailable(void) {
    return YES;
}
NSDictionary *GSBackupRequestsSnapshot(void) {
    return @{@"activeTransfers" : @0};
}
NSDictionary *GSBatchImportSnapshot(void) {
    return @{@"active" : @NO};
}
NSDictionary *GSRequest(NSDictionary *request, NSError **error) {
    assert([request[@"op"] isEqual:@"list"]);
    return @{@"jobs" : QueueBusy ? @[ @{@"state" : @"uploading"} ] : @[], @"next" : @-1};
}
@implementation UIViewController
- (void)presentViewController:(UIViewController *)controller
                     animated:(BOOL)animated
                   completion:(void (^)(void))completion {
    self.presentedViewController = controller;
    if (completion)
        completion();
}
@end
@implementation UIWindow
@end
@implementation UIScene
@end
@implementation UIWindowScene
@end
@implementation UIApplication
+ (instancetype)sharedApplication {
    static UIApplication *app;
    if (!app)
        app = [self new];
    return app;
}
@end
@implementation UIAlertAction
+ (instancetype)actionWithTitle:(NSString *)title
                          style:(UIAlertActionStyle)style
                        handler:(void (^)(UIAlertAction *))handler {
    UIAlertAction *action = [self new];
    action.enabled = YES;
    action.handler = handler;
    return action;
}
@end
@implementation UIAlertController
+ (instancetype)alertControllerWithTitle:(NSString *)title
                                 message:(NSString *)message
                          preferredStyle:(UIAlertControllerStyle)style {
    UIAlertController *alert = [self new];
    alert.actions = [NSMutableArray array];
    return alert;
}
- (void)addAction:(UIAlertAction *)action {
    [self.actions addObject:action];
}
@end
@implementation PHAsset
+ (PHFetchResult *)fetchAssetsWithLocalIdentifiers:(NSArray *)ids options:(id)options {
    PHFetchResult *result = [PHFetchResult new];
    result.count = ids.count;
    return result;
}
@end
@implementation PHFetchResult
@end
@implementation PHAssetChangeRequest
+ (void)deleteAssets:(id)assets {
    DeletedAssets = [assets copy];
}
@end

@interface GSFixtureLocalAsset : NSObject
@property (nonatomic, strong) PHAsset *phAsset;
@end
@implementation GSFixtureLocalAsset
@end
@interface GSFixtureMediaItem : NSObject
@property (nonatomic, copy) NSString *localDedupKey;
@property (nonatomic, copy) NSString *assetID;
@end
@implementation GSFixtureMediaItem
@end
@interface GSFixtureStoreResult : NSObject
- (id)localAssetsForLocalDedupKey:(id)key;
- (id)serverPhotosForLocalDedupKey:(id)key;
@end
@implementation GSFixtureStoreResult
- (id)localAssetsForLocalDedupKey:(id)key {
    assert([key isEqual:@"dedup-a"]);
    GSFixtureLocalAsset *local = [GSFixtureLocalAsset new];
    local.phAsset = [PHAsset new];
    local.phAsset.localIdentifier = @"local-a";
    return @[ local ];
}
- (id)serverPhotosForLocalDedupKey:(id)key {
    return @[ @"server-photo" ];
}
@end
@interface GSFixtureDataSource : NSObject
@property (nonatomic, strong) GSFixtureStoreResult *storeResult;
- (id)expandedMediaItemArray:(id)items;
@end
@implementation GSFixtureDataSource
- (id)expandedMediaItemArray:(id)items {
    return items;
}
@end

@interface GPCPromise : NSObject
@property (nonatomic, strong) id value;
@property (nonatomic, strong) id failure;
- (void)resolve:(id)value;
- (void)reject:(id)error;
- (id)withMainQueueOnSuccess:(id (^)(id))success
                   onFailure:(id (^)(id))failure
                    onCancel:(id (^)(void))cancel;
@end
@implementation GPCPromise
- (instancetype)init {
    return [super init];
}
- (void)resolve:(id)value {
    self.value = value;
}
- (void)reject:(id)error {
    self.failure = error;
}
- (id)withMainQueueOnSuccess:(id (^)(id))success
                   onFailure:(id (^)(id))failure
                    onCancel:(id (^)(void))cancel {
    if (self.failure)
        failure(self.failure);
    else
        success(self.value);
    return self;
}
@end
@interface PHSPhotoDeletionStrategy : NSObject
@property (nonatomic, strong) NSArray *localAssetIDs;
@property (nonatomic, strong) NSArray *mediaKeys;
- (instancetype)initWithMediaItems:(id)items
                      deletionType:(NSUInteger)type
                      deleteOrigin:(NSUInteger)origin;
@end
@implementation PHSPhotoDeletionStrategy
- (instancetype)initWithMediaItems:(id)items
                      deletionType:(NSUInteger)type
                      deleteOrigin:(NSUInteger)origin {
    if ((self = [super init])) {
        // Backed-up photos use media/dedup keys, NOT the strategy's local-only IDs.
        self.localAssetIDs = @[];
        self.mediaKeys = @[ @"cloud-key" ];
    }
    return self;
}
@end
@interface PHSDeletePhotoCommand : NSObject
@property (nonatomic, strong) NSArray *mediaItems;
@property (nonatomic, copy) NSString *accountID;
@property (nonatomic) NSUInteger serverPhotoCount;
@property (nonatomic, strong) GSFixtureDataSource *dataSource;
- (id)fixtureExecute;
- (id)deleteLocalAssets;
@end
// Installed dynamically so the ABI rejection fixture can supply a different encoding.
@interface PHSDeletePhotoCommand (RuntimeExecution)
- (id)execute;
@end
@implementation PHSDeletePhotoCommand
- (id)fixtureExecute {
    CloudCalls++;
    [self deleteLocalAssets];
    assert(self.mediaItems.count == 1); // Temporary masking must not change the cloud selection.
    GPCPromise *result = [GPCPromise new];
    if (FailCloud)
        [result reject:[NSError errorWithDomain:@"fixture.cloud" code:503 userInfo:nil]];
    else
        [result resolve:@"native-result"];
    return result;
}
- (id)deleteLocalAssets {
    NSMutableArray *assets = [NSMutableArray array];
    for (GSFixtureMediaItem *item in self.mediaItems) {
        PHAsset *asset = [PHAsset new];
        asset.localIdentifier = item.assetID;
        [assets addObject:asset];
    }
    if (assets.count)
        [PHAssetChangeRequest deleteAssets:assets];
    GPCPromise *promise = [GPCPromise new];
    [promise resolve:NSNull.null];
    return promise;
}
@end

static PHSDeletePhotoCommand *Command(void) {
    PHSDeletePhotoCommand *command = [PHSDeletePhotoCommand new];
    command.accountID = @"account";
    GSFixtureMediaItem *item = [GSFixtureMediaItem new];
    item.assetID = @"local-a";
    item.localDedupKey = @"dedup-a";
    command.mediaItems = @[ item ];
    command.dataSource = [GSFixtureDataSource new];
    command.dataSource.storeResult = [GSFixtureStoreResult new];
    return command;
}
static void PumpUntil(BOOL (^ready)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!ready() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    assert(ready());
}
static void Choose(NSUInteger index) {
    PumpUntil(^BOOL {
        return FixturePresenter.presentedViewController != nil;
    });
    UIAlertController *alert = (id)FixturePresenter.presentedViewController;
    UIAlertAction *action = alert.actions[index];
    assert(action.enabled);
    FixturePresenter.presentedViewController = nil;
    action.handler(action);
}
int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL incompatibleABI = argc > 1 && !strcmp(argv[1], "abi");
        if (argc > 1 && !incompatibleABI)
            FixtureVersion = @"8.0.0";
        // class_replaceMethod ignores new type encodings for existing methods.
        // Add execute for the first time, then verify the actual runtime contract.
        const char *executionABI = incompatibleABI ? "v16@0:8" : "@16@0:8";
        IMP execution = method_getImplementation(
            class_getInstanceMethod(PHSDeletePhotoCommand.class, @selector(fixtureExecute)));
        BOOL added = class_addMethod(PHSDeletePhotoCommand.class, @selector(execute), execution,
                                     executionABI);
        assert(added);
        Method execute = class_getInstanceMethod(PHSDeletePhotoCommand.class, @selector(execute));
        assert(!strcmp(method_getTypeEncoding(execute), executionABI));
        Method info =
            class_getInstanceMethod(NSBundle.class, @selector(objectForInfoDictionaryKey:));
        IMP original = method_getImplementation(info);
        method_setImplementation(info, imp_implementationWithBlock(^id(id bundle, NSString *key) {
                                     if ([key isEqual:@"CFBundleExecutable"])
                                         return @"GooglePhotos";
                                     if ([key isEqual:@"CFBundleShortVersionString"])
                                         return FixtureVersion;
                                     return ((id(*)(id, SEL, id))original)(
                                         bundle, @selector(objectForInfoDictionaryKey:), key);
                                 }));
        NSURL *root =
            [NSURL fileURLWithPath:[NSTemporaryDirectory()
                                       stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
        FixtureStore = [[GSLocalPhotoProtection alloc]
            initWithURL:[root URLByAppendingPathComponent:@"state.json"]];
        FixturePresenter = [UIViewController new];
        UIWindow *window = [UIWindow new];
        window.isKeyWindow = YES;
        window.rootViewController = FixturePresenter;
        UIWindowScene *scene = [UIWindowScene new];
        scene.windows = @[ window ];
        UIApplication.sharedApplication.connectedScenes = [NSSet setWithObject:scene];
        GSInstallCloudOnlyDeletion();
        assert(GSPhotoKitGuardInstalled);
        if (argc > 1) {
            assert(!GSDeleteInstalled);
            assert(method_getImplementation(execute) == execution);
            assert([GSCloudOnlyDeletionSnapshot()[@"availabilityReason"]
                isEqual:incompatibleABI ? @"private_contract_unavailable"
                                        : @"requires_photos_7_20_2"]);
            assert(CloudCalls == 0 && DeletedAssets == nil && FixtureStore.count == 0);
            NSLog(@"PASS %@ rejection preserves the native command and PhotoKit safeguard",
                  incompatibleABI ? @"incompatible ABI" : @"unsupported version");
            return 0;
        }
        assert(GSDeleteInstalled);

        PHSDeletePhotoCommand *unknown = Command();
        unknown.mediaItems = @[];
        GPCPromise *unknownPromise = [unknown execute];
        Choose(2);
        assert(unknownPromise.failure && CloudCalls == 0);

        PHSDeletePhotoCommand *command = Command();
        GPCPromise *proxy = [command execute];
        assert([command execute] == proxy); // Repeated execution cannot enqueue a second delete.
        Choose(2);
        assert(proxy.failure && CloudCalls == 0 && FixtureStore.count == 0);

        command = Command();
        proxy = [command execute];
        Choose(0);
        PumpUntil(^BOOL {
            return proxy.value || proxy.failure;
        });
        assert(!proxy.failure && [proxy.value isEqual:@"native-result"]);
        assert(CloudCalls == 1 && FixtureStore.count == 1 && DeletedAssets == nil);
        assert(command.mediaItems.count == 1);
        assert(command.serverPhotoCount == 1);
        GSLocalPhotoProtection *reloaded = [[GSLocalPhotoProtection alloc]
            initWithURL:[root URLByAppendingPathComponent:@"state.json"]];
        assert([reloaded contains:@"local-a"]);
        PHAsset *a = [PHAsset new];
        a.localIdentifier = @"local-a";
        PHAsset *b = [PHAsset new];
        b.localIdentifier = @"local-b";
        [PHAssetChangeRequest deleteAssets:@[ a, b ]];
        assert(DeletedAssets.count == 1 && DeletedAssets[0] == b); // Simulated later deletion sync.
        proxy = [Command() execute];
        Choose(2);
        assert(proxy.failure && CloudCalls == 1 && ![FixtureStore contains:@"local-a"]);
        assert([FixtureStore updateIdentifiers:@[ @"local-a" ] protect:YES error:nil]);

        QueueBusy = YES;
        command = Command();
        proxy = [command execute];
        Choose(0);
        PumpUntil(^BOOL {
            return proxy.failure != nil;
        });
        assert(CloudCalls == 1);
        QueueBusy = NO;
        AccountMatches = NO;
        proxy = [Command() execute];
        PumpUntil(^BOOL {
            return proxy.failure != nil;
        });
        assert(CloudCalls == 1);
        AccountMatches = YES;

        command = Command();
        proxy = [command execute];
        Choose(1);
        assert(!proxy.failure && CloudCalls == 2 && ![FixtureStore contains:@"local-a"]);
        assert(DeletedAssets.count == 1 &&
               [((PHAsset *)DeletedAssets[0]).localIdentifier isEqual:@"local-a"]);
        NSDictionary *snapshot = GSCloudOnlyDeletionSnapshot();
        assert([snapshot[@"blockedLocalDeletes"] unsignedIntegerValue] == 1);
        assert([snapshot[@"protectedLocalCount"] unsignedIntegerValue] == 0);
        assert([snapshot[@"unresolvedSelections"] unsignedIntegerValue] == 1);
        FailCloud = YES;
        DeletedAssets = nil;
        proxy = [Command() execute];
        Choose(0);
        PumpUntil(^BOOL {
            return proxy.failure != nil;
        });
        assert([[(NSError *)proxy.failure domain] isEqual:@"fixture.cloud"]);
        assert(CloudCalls == 3 && DeletedAssets == nil && [FixtureStore contains:@"local-a"]);
        FailCloud = NO;
        GSLocalPhotoProtection *savedStore = FixtureStore;
        FixtureStore = [[GSLocalPhotoProtection alloc]
            initWithURL:[NSURL URLWithString:@"https://invalid.example/state"]];
        proxy = [GPCPromise new];
        GSDeleteContinue(Command(), (id)proxy, @[ @"local-a" ], YES, @"account");
        assert(proxy.failure &&
               CloudCalls == 3); // No destructive command after persistence failure.
        FixtureStore = savedStore;
        [NSFileManager.defaultManager removeItemAtURL:root error:nil];
        NSLog(@"PASS synthetic cloud-only choice, cancellation, native promise forwarding, local "
              @"protection, sync filtering, queue/account guards and normal deletion");
    }
}
