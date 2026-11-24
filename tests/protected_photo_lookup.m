#import "../Native/GSProtectedPhotoLookup.h"
#import <Photos/Photos.h>
#include <assert.h>

static PHAuthorizationStatus Authorization = PHAuthorizationStatusAuthorized;
static NSUInteger Fetches, FailPage, AuthorizationReads, FailAuthorizationRead;
static BOOL NilResult, RaiseException, ChangePermission, FailMetadata, OmitAll, UnexpectedID;
@implementation PHPhotoLibrary
+ (PHAuthorizationStatus)authorizationStatusForAccessLevel:(PHAccessLevel)level {
    assert(level == PHAccessLevelReadWrite);
    AuthorizationReads++;
    if (AuthorizationReads == FailAuthorizationRead)
        @throw [NSException exceptionWithName:@"private-permission"
                                       reason:@"private-token"
                                     userInfo:nil];
    return Authorization;
}
@end
@implementation PHFetchOptions
@end
@interface PHFetchResult ()
@property (nonatomic, strong) NSArray *items;
@end
@implementation PHFetchResult
- (void)enumerateObjectsUsingBlock:(void (^)(PHAsset *, NSUInteger, BOOL *))block {
    BOOL stop = NO;
    NSUInteger index = 0;
    for (PHAsset *asset in self.items) {
        block(asset, index++, &stop);
        if (stop)
            break;
    }
}
@end
@implementation PHAsset
+ (PHFetchResult *)fetchAssetsWithLocalIdentifiers:(NSArray *)identifiers options:(id)options {
    PHFetchOptions *fetchOptions = options;
    assert(!NSThread.isMainThread && identifiers.count <= 64 && fetchOptions.includeHiddenAssets);
    Fetches++;
    if (NilResult || Fetches == FailPage)
        return nil;
    if (RaiseException)
        @throw [NSException exceptionWithName:@"private-photo-exception"
                                       reason:@"private-path-token"
                                     userInfo:nil];
    NSMutableArray *assets = [NSMutableArray array];
    for (NSString *identifier in identifiers.reverseObjectEnumerator) {
        if (OmitAll || [identifier isEqual:@"private-missing"])
            continue;
        PHAsset *asset = [PHAsset new];
        asset.localIdentifier = UnexpectedID ? @"private-unrequested" : identifier;
        [assets addObject:asset];
    }
    if (ChangePermission)
        Authorization = PHAuthorizationStatusDenied;
    PHFetchResult *result = [PHFetchResult new];
    result.items = assets;
    return result;
}
@end
@implementation PHAssetResource
+ (NSArray *)assetResourcesForAsset:(PHAsset *)asset {
    if (FailMetadata)
        @throw [NSException exceptionWithName:@"private-metadata"
                                       reason:@"private-name.jpg"
                                     userInfo:nil];
    PHAssetResource *resource = [PHAssetResource new];
    resource.originalFilename = @"private-name.jpg";
    return @[ resource ];
}
@end

static NSDictionary *Lookup(NSArray *identifiers) {
    __block NSDictionary *result;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        result = GSLookupProtectedPhotos(identifiers);
        dispatch_semaphore_signal(done);
    });
    assert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
    NSDictionary *report = result[@"report"];
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:report
                                                                                    options:0
                                                                                      error:nil]
                                           encoding:NSUTF8StringEncoding];
    assert(![json containsString:@"private-"] && ![json containsString:@".jpg"]);
    return result;
}
static NSDictionary *CheckSelection(NSString *identifier, NSArray *saved) {
    __block NSDictionary *result;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        result = GSCheckProtectedPhotoSelection(identifier, saved);
        dispatch_semaphore_signal(done);
    });
    assert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:result
                                                                                    options:0
                                                                                      error:nil]
                                           encoding:NSUTF8StringEncoding];
    assert(![json containsString:@"private-"] && ![json containsString:@".jpg"]);
    return result;
}

int main(void) {
    @autoreleasepool {
        NSDictionary *result = Lookup(@[ @"private-a", @"private-missing", @"private-a" ]);
        assert([result[@"report"][@"requested"] intValue] == 2);
        assert([result[@"report"][@"resolved"] intValue] == 1 &&
               [result[@"report"][@"notReturned"] intValue] == 1);
        assert([result[@"reasons"][@"private-missing"] isEqual:@"not_returned"]);
        assert([result[@"report"][@"queryState"] isEqual:@"succeeded"]);
        assert([result[@"assets"][@"private-a"] localIdentifier] &&
               [result[@"names"][@"private-a"] isEqual:@"private-name.jpg"]);
        result = Lookup(@[]);
        assert([result[@"report"][@"queryState"] isEqual:@"not_needed"]);
        Authorization = PHAuthorizationStatusLimited;
        result = Lookup(@[ @"private-a", @"private-missing" ]);
        assert([result[@"reasons"][@"private-missing"] isEqual:@"limited_or_unavailable"]);
        for (NSNumber *status in @[
                 @(PHAuthorizationStatusDenied), @(PHAuthorizationStatusRestricted),
                 @(PHAuthorizationStatusNotDetermined)
             ]) {
            Authorization = status.integerValue;
            NSUInteger before = Fetches;
            result = Lookup(@[ @"private-a" ]);
            assert(Fetches == before && [result[@"assets"] count] == 0);
            assert([result[@"report"][@"permissionBlocked"] intValue] == 1);
        }
        Authorization = PHAuthorizationStatusAuthorized;
        NilResult = YES;
        result = Lookup(@[ @"private-a" ]);
        assert([result[@"reasons"][@"private-a"] isEqual:@"query_failed"] &&
               [result[@"report"][@"notReturned"] intValue] == 0);
        NilResult = NO;
        RaiseException = YES;
        result = Lookup(@[ @"private-a" ]);
        assert([result[@"report"][@"error"] isEqual:@"fetch_exception"]);
        RaiseException = NO;
        FailMetadata = YES;
        result = Lookup(@[ @"private-a" ]);
        assert([result[@"assets"] count] == 1 &&
               [result[@"report"][@"metadataFailures"] intValue] == 1);
        FailMetadata = NO;
        ChangePermission = YES;
        result = Lookup(@[ @"private-a" ]);
        assert([result[@"report"][@"queryState"] isEqual:@"permission_changed"] &&
               [result[@"assets"] count] == 0);
        ChangePermission = NO;
        Authorization = PHAuthorizationStatusAuthorized;
        NSMutableArray *many = [NSMutableArray array];
        for (NSUInteger index = 0; index < 130; index++)
            [many addObject:[NSString stringWithFormat:@"private-%lu", (unsigned long)index]];
        Fetches = 0;
        FailPage = 2;
        result = Lookup(many);
        assert(Fetches == 3 && [result[@"assets"] count] == 66);
        assert([result[@"report"][@"queryFailed"] intValue] == 64 &&
               [result[@"report"][@"queryState"] isEqual:@"partial_failure"]);
        OmitAll = YES;
        Fetches = 0;
        result = Lookup(many);
        assert([result[@"report"][@"resolved"] intValue] == 0 &&
               [result[@"report"][@"notReturned"] intValue] == 66 &&
               [result[@"report"][@"queryState"] isEqual:@"partial_failure"]);
        OmitAll = NO;
        FailPage = 0;
        UnexpectedID = YES;
        result = Lookup(@[ @"private-a" ]);
        assert([result[@"report"][@"error"] isEqual:@"unexpected_result"] &&
               [result[@"assets"] count] == 0);
        UnexpectedID = NO;
        for (NSNumber *read in @[ @1, @2 ]) {
            AuthorizationReads = 0;
            FailAuthorizationRead = read.unsignedIntegerValue;
            result = Lookup(@[ @"private-a" ]);
            assert([result[@"report"][@"error"] isEqual:@"authorization_exception"] &&
                   [result[@"assets"] count] == 0);
        }
        FailAuthorizationRead = 0;
        NSDictionary *selection = CheckSelection(@"private-a", @[ @"private-missing" ]);
        assert([selection[@"outcome"] isEqual:@"not_in_protection"] &&
               ![selection[@"matchesSaved"] boolValue]);
        assert([selection[@"lookup"][@"resolved"] intValue] == 1 &&
               [selection[@"savedCount"] intValue] == 1);
        selection = CheckSelection(@"private-a", @[ @"private-a" ]);
        assert([selection[@"outcome"] isEqual:@"matched_protection"] &&
               [selection[@"matchesSaved"] boolValue]);
        NilResult = YES;
        selection = CheckSelection(@"private-a", @[ @"private-a" ]);
        assert([selection[@"outcome"] isEqual:@"query_failed"] &&
               [selection[@"matchesSaved"] boolValue]);
        NilResult = NO;
        selection = CheckSelection(@"private-missing", @[]);
        assert([selection[@"outcome"] isEqual:@"selected_not_returned"]);
        NSUInteger beforeEmpty = Fetches;
        selection = CheckSelection(nil, @[ @"private-a" ]);
        assert([selection[@"outcome"] isEqual:@"identifier_unavailable"] && Fetches == beforeEmpty);
        result = Lookup(@[ @42 ]);
        assert([result[@"report"][@"error"] isEqual:@"invalid_identifiers"]);
        assert(GSProtectedPhotoLookupMessage(@"not_returned").length &&
               GSProtectedPhotoLookupMessage(@"permission_denied").length);
        NSLog(@"PASS protected-photo lookup permissions, missing IDs, bounded fetches, metadata "
              @"errors, partial failures and redacted reports");
    }
}
