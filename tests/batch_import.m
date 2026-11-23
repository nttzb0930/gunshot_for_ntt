#import "../Media/GSBatchImport.h"
#import "../Media/GSExporter.h"
#import "../Native/GSLocalPhotoProtection.h"
#include <assert.h>

static NSString *Identity = @"identity-A", *Account = @"a@example.com";
static NSUInteger Queued, Exports, Fetches, MaxFetch, LiveAssets, PeakAssets;
static BOOL FailExport, FailQueue, FailAfterConsent, SwitchDuringExport, CancelDuringExport,
    Offline;
static NSString *LastDirectory;
static BOOL AlbumBatchHeld;
@interface PHFetchResult ()
@property (nonatomic, strong) NSArray *items;
@end
@implementation PHFetchResult
- (void)enumerateObjectsUsingBlock:(void (^)(PHAsset *, NSUInteger, BOOL *))block {
    BOOL stop = NO;
    NSUInteger i = 0;
    for (PHAsset *asset in self.items) {
        block(asset, i++, &stop);
        if (stop)
            break;
    }
}
@end
@implementation PHAsset
- (instancetype)init {
    if ((self = [super init])) {
        LiveAssets++;
        PeakAssets = MAX(PeakAssets, LiveAssets);
    }
    return self;
}
- (void)dealloc {
    LiveAssets--;
}
+ (PHFetchResult *)fetchAssetsWithLocalIdentifiers:(NSArray *)ids options:(id)options {
    assert(!NSThread.isMainThread);
    Fetches++;
    MaxFetch = MAX(MaxFetch, ids.count);
    NSMutableArray *items = [NSMutableArray array];
    // PhotoKit need not preserve requested order and may omit inaccessible IDs.
    for (NSString *identifier in ids.reverseObjectEnumerator) {
        if ([identifier isEqual:@"missing"])
            continue;
        PHAsset *asset = [PHAsset new];
        asset.localIdentifier = identifier;
        asset.creationDate = [NSDate dateWithTimeIntervalSince1970:123];
        [items addObject:asset];
    }
    PHFetchResult *result = [PHFetchResult new];
    result.items = items;
    return result;
}
@end
BOOL GSNativeIdentityMatches(NSString *identifier) {
    assert(NSThread.isMainThread);
    return [identifier isEqual:Identity];
}
NSDictionary *GSRequest(NSDictionary *request, NSError **error) {
    assert(!NSThread.isMainThread);
    if (Offline)
        return nil;
    if ([request[@"op"] isEqual:@"accounts"])
        return @{@"selected" : Account};
    if ([request[@"op"] isEqual:@"options"])
        return @{@"quality" : @"original"};
    if ([request[@"op"] isEqual:@"album_batch"]) {
        AlbumBatchHeld = [request[@"confirm"] boolValue];
        return @{};
    }
    assert(NO);
    return nil;
}
NSArray *GSExportAsset(PHAsset *asset, NSURL *directory, NSError **error) {
    assert(!NSThread.isMainThread);
    Exports++;
    LastDirectory = directory.path;
    NSURL *photo = [directory URLByAppendingPathComponent:@"original.heic"];
    [@"original" writeToURL:photo atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (SwitchDuringExport)
        dispatch_sync(dispatch_get_main_queue(), ^{
            Identity = @"identity-B";
        });
    if (CancelDuringExport)
        dispatch_sync(dispatch_get_main_queue(), ^{
            GSStopBatchImport(YES);
        });
    if (FailExport && [asset.localIdentifier isEqual:@"500"]) {
        if (error)
            *error = [NSError errorWithDomain:@"private filename/token must not escape"
                                         code:7
                                     userInfo:nil];
        return nil;
    }
    if ([asset.localIdentifier isEqual:@"1000"]) {
        NSURL *movie = [directory URLByAppendingPathComponent:@"paired.mov"];
        [@"paired" writeToURL:movie atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return @[ photo, movie ];
    }
    return @[ photo ];
}
NSString *GSImportFiles(NSArray *files, NSString *account, NSString *quality, NSDate *date,
                        NSError **error) {
    assert(AlbumBatchHeld);
    assert(!NSThread.isMainThread && [account isEqual:@"a@example.com"] &&
           [quality isEqual:@"original"]);
    assert(date.timeIntervalSince1970 == 123);
    if (FailQueue)
        return nil;
    Queued++;
    for (NSURL *file in files)
        assert([NSFileManager.defaultManager fileExistsAtPath:file.path]);
    return @"job";
}
NSArray *GSExportAssetForRebackup(PHAsset *asset, NSURL *directory, NSError **error) {
    assert([GSLocalPhotoProtectionStore() contains:asset.localIdentifier]);
    return GSExportAsset(asset, directory, error);
}
NSString *GSImportRebackupFiles(NSArray *files, NSString *account, NSString *quality, NSDate *date,
                                NSString *assetIdentifier, BOOL (^beforeSeal)(void),
                                NSError **error) {
    if (FailQueue || !beforeSeal() || FailAfterConsent)
        return nil;
    assert(![GSLocalPhotoProtectionStore() contains:assetIdentifier]);
    return GSImportFiles(files, account, quality, date, error);
}
static NSDictionary *RunProtected(NSArray *ids, NSUInteger expectedResults) {
    __block NSDictionary *done = nil;
    __block NSUInteger results = 0;
    assert(GSStartProtectedPhotoImport(
        ids, @"a@example.com", @"identity-A",
        ^(NSUInteger index, NSString *jobID, NSString *failureCode) {
            assert(NSThread.isMainThread && index < ids.count);
            assert((jobID != nil) != (failureCode != nil));
            results++;
        },
        ^(NSDictionary *state) {
            done = state;
        }));
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!done && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    assert(done && results == expectedResults && !AlbumBatchHeld);
    NSData *json = [NSJSONSerialization dataWithJSONObject:GSBatchImportSnapshot()
                                                   options:0
                                                     error:nil];
    assert(![[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]
        containsString:@"protected-local-secret"]);
    return done;
}
static NSDictionary *Run(NSArray *ids) {
    __block NSDictionary *done = nil;
    BOOL started = GSStartBatchImport(ids.count, @"picker", YES, GSPhotoIdentifierProvider(ids),
                                      @"a@example.com", @"identity-A", nil, ^(NSDictionary *state) {
                                          assert(NSThread.isMainThread);
                                          done = state;
                                      });
    assert(started);
    assert(!GSStartBatchImport(
        1, @"picker", YES,
        ^id(NSUInteger i) {
            return nil;
        },
        @"a@example.com", nil, nil, nil));
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
    while (!done && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    assert(done && ![done[@"active"] boolValue] && !AlbumBatchHeld);
    if (LastDirectory)
        assert(![NSFileManager.defaultManager fileExistsAtPath:LastDirectory]);
    return done;
}
int main(void) {
    @autoreleasepool {
        NSMutableArray *ids = [NSMutableArray array];
        for (NSUInteger i = 0; i < 2000; i++)
            [ids addObject:[NSString stringWithFormat:@"%lu", (unsigned long)i]];
        ids[99] = @"missing";
        ids[777] = NSNull.null;
        FailExport = YES;
        NSDictionary *result = Run(ids);
        assert(Queued == 1997 && [result[@"queued"] unsignedIntegerValue] == 1997 &&
               [result[@"failed"] unsignedIntegerValue] == 3 &&
               [result[@"remaining"] unsignedIntegerValue] == 0);
        assert(Fetches == 32 && MaxFetch <= 64 && PeakAssets <= 128);
        assert([result[@"stage"] isEqual:@"finished"] && ![result[@"stopReason"] length]);
        NSString *json = [[NSString alloc]
            initWithData:[NSJSONSerialization dataWithJSONObject:result options:0 error:nil]
                encoding:NSUTF8StringEncoding];
        assert(![json containsString:@"identity-A"] && ![json containsString:@"example.com"] &&
               ![json containsString:@"original.heic"] &&
               ![json containsString:@"private filename"]);
        FailExport = NO;
        FailQueue = YES;
        NSUInteger before = Queued;
        result = Run(@[ @"0", @"1" ]);
        assert(Queued == before && [result[@"stopReason"] isEqual:@"queue_rejected"] &&
               [result[@"remaining"] intValue] == 2);
        FailQueue = NO;
        SwitchDuringExport = YES;
        result = Run(@[ @"0", @"1" ]);
        assert(Queued == before && [result[@"stopReason"] isEqual:@"account_changed"]);
        SwitchDuringExport = NO;
        Identity = @"identity-A";
        CancelDuringExport = YES;
        result = Run(@[ @"0", @"1" ]);
        assert(Queued == before && [result[@"stopReason"] isEqual:@"background_expired"]);
        CancelDuringExport = NO;
        Offline = YES;
        result = Run(@[ @"0" ]);
        assert([result[@"stopReason"] isEqual:@"service_unavailable"]);
        Offline = NO;
        result = Run(@[ @"0", @"1" ]);
        assert(Queued == before + 2 && [result[@"queued"] intValue] == 2);
        GSLocalPhotoProtection *store = GSLocalPhotoProtectionStore();
        assert([store updateIdentifiers:@[ @"protected-local-secret", @"missing", @"500" ]
                                protect:YES
                                  error:nil]);
        result = RunProtected(@[ @"protected-local-secret", @"missing" ], 2);
        assert([result[@"queued"] intValue] == 1 && [result[@"failed"] intValue] == 1);
        assert(![store contains:@"protected-local-secret"] && [store contains:@"missing"]);
        FailExport = YES;
        result = RunProtected(@[ @"500" ], 1);
        assert([result[@"failed"] intValue] == 1 && [store contains:@"500"]);
        FailExport = NO;
        assert([store updateIdentifiers:@[ @"protected-local-secret" ] protect:YES error:nil]);
        FailAfterConsent = YES;
        result = RunProtected(@[ @"protected-local-secret" ], 1);
        assert([result[@"stopReason"] isEqual:@"queue_rejected"] &&
               [store contains:@"protected-local-secret"]);
        FailAfterConsent = NO;
        SwitchDuringExport = YES;
        result = RunProtected(@[ @"protected-local-secret" ], 1);
        assert([result[@"stopReason"] isEqual:@"account_changed"] &&
               [store contains:@"protected-local-secret"]);
        SwitchDuringExport = NO;
        Identity = @"identity-A";
        assert([store updateIdentifiers:@[ @"protected-local-secret", @"missing", @"500" ]
                                protect:NO
                                  error:nil]);
        NSLog(@"PASS 2000 selections, bounded PhotoKit pages, missing IDs, individual export "
              @"failure, Live Photo resources, account switch, cancellation, queue/IPC failure, "
              @"retry and private batch diagnostics");
    }
}
