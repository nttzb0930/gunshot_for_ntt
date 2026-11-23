#import "GSLocalPhotoProtection.h"

static BOOL GSValidProtectedID(id value) {
    return
        [value isKindOfClass:NSString.class] && [value length] > 0 && [value length] <= 1024 &&
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
static NSError *GSProtectionError(void) {
    return [NSError errorWithDomain:@"GoToHP.LocalProtection" code:1 userInfo:nil];
}
static NSString *GSProtectionDiagnosticCode(id value, NSArray *allowed, NSString *fallback) {
    return [value isKindOfClass:NSString.class] && [allowed containsObject:value] ? value
                                                                                  : fallback;
}
@implementation GSLocalPhotoProtection {
    NSURL *_url;
    NSSet<NSString *> *_identifiers;
    BOOL _healthy;
    NSUInteger _blockedUploads, _unprotectAttempts, _unprotectSucceeded, _unprotectFailed;
    NSString *_lastUnprotectResult;
    NSInteger _lastUnprotectErrorCode;
    NSDictionary *_photoLookup;
    NSMutableDictionary *_previewResults;
}
- (instancetype)initWithURL:(NSURL *)url {
    if (!(self = [super init]))
        return nil;
    _url = url;
    _identifiers = [NSSet set];
    _healthy = url.isFileURL;
    if (!_healthy)
        return self;
    NSError *readError = nil;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path
                                                                              error:&readError];
    if (!attributes && [readError.domain isEqual:NSCocoaErrorDomain] &&
        (readError.code == NSFileNoSuchFileError || readError.code == NSFileReadNoSuchFileError))
        return self;
    if (!attributes || [attributes[NSFileSize] unsignedLongLongValue] > 32 * 1024 * 1024) {
        _healthy = NO;
        return self;
    }
    NSData *data = [NSData dataWithContentsOfURL:url];
    id state = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    id ids = [state isKindOfClass:NSDictionary.class] ? state[@"localIDs"] : nil;
    if (![state isKindOfClass:NSDictionary.class] || ![state[@"schema"] isEqual:@1] ||
        ![ids isKindOfClass:NSArray.class] || [ids count] > 100000) {
        _healthy = NO;
        return self;
    }
    for (id value in ids)
        if (!GSValidProtectedID(value)) {
            _healthy = NO;
            return self;
        }
    _identifiers = [NSSet setWithArray:ids];
    return self;
}
- (BOOL)healthy {
    @synchronized(self) {
        return _healthy;
    }
}
- (NSUInteger)count {
    @synchronized(self) {
        return _identifiers.count;
    }
}
- (BOOL)contains:(NSString *)identifier {
    @synchronized(self) {
        // Never silently discard a damaged protection database and resume deletions.
        return !_healthy || [_identifiers containsObject:identifier ?: @""];
    }
}
- (NSArray<NSString *> *)protectedIdentifiers {
    @synchronized(self) {
        return _healthy ? [_identifiers.allObjects sortedArrayUsingSelector:@selector(compare:)]
                        : @[];
    }
}
- (NSDictionary *)diagnostics {
    @synchronized(self) {
        return @{
            @"storeHealthy" : @(_healthy),
            @"protectedCount" : @(_identifiers.count),
            @"blockedUploads" : @(_blockedUploads),
            @"unprotectAttempts" : @(_unprotectAttempts),
            @"unprotectSucceeded" : @(_unprotectSucceeded),
            @"unprotectFailed" : @(_unprotectFailed),
            @"lastUnprotectResult" : _lastUnprotectResult ?: @"not_requested",
            @"lastUnprotectErrorCode" : @(_lastUnprotectErrorCode),
            @"photoLookup" : _photoLookup
                ?: @{@"authorization" : @"unknown", @"queryState" : @"not_checked"},
            @"previewThisLaunch" : [_previewResults copy] ?: @{}
        };
    }
}
- (void)recordPhotoLookup:(NSDictionary *)report {
    if (![report isKindOfClass:NSDictionary.class])
        return;
    NSMutableDictionary *safe = [NSMutableDictionary dictionary];
    safe[@"authorization"] = GSProtectionDiagnosticCode(
        report[@"authorization"],
        @[ @"unknown", @"not_determined", @"restricted", @"denied", @"authorized", @"limited" ],
        @"unknown");
    safe[@"queryState"] = GSProtectionDiagnosticCode(
        report[@"queryState"],
        @[
            @"not_checked", @"not_needed", @"access_blocked", @"succeeded", @"partial_failure",
            @"failed", @"permission_changed"
        ],
        @"failed");
    safe[@"error"] = GSProtectionDiagnosticCode(
        report[@"error"],
        @[
            @"", @"invalid_identifiers", @"authorization_exception", @"authorization_changed",
            @"nil_fetch_result", @"fetch_exception", @"unexpected_result"
        ],
        @"unexpected_result");
    for (NSString *key in @[
             @"requested", @"resolved", @"notReturned", @"permissionBlocked", @"queryFailed",
             @"queryFailures", @"metadataFailures", @"invalidIdentifiers"
         ])
        safe[key] = [report[key] isKindOfClass:NSNumber.class] && [report[key] longLongValue] >= 0
                        ? @([report[key] unsignedLongLongValue])
                        : @0;
    safe[@"includeHiddenAssets"] =
        @([report[@"includeHiddenAssets"] isKindOfClass:NSNumber.class] &&
          [report[@"includeHiddenAssets"] boolValue]);
    @synchronized(self) {
        _photoLookup = [safe copy];
    }
}
- (void)recordPreviewResult:(NSString *)outcome {
    if (![@[ @"requested", @"available", @"cloud_only", @"failed", @"cancelled" ]
            containsObject:outcome ?: @""])
        return;
    @synchronized(self) {
        if (!_previewResults)
            _previewResults = [NSMutableDictionary dictionary];
        _previewResults[outcome] = @([_previewResults[outcome] unsignedIntegerValue] + 1);
    }
}
- (void)recordBlockedUpload {
    @synchronized(self) {
        _blockedUploads++;
    }
}
- (BOOL)allowBackupForIdentifiers:(NSArray<NSString *> *)identifiers error:(NSError **)error {
    @synchronized(self) {
        _unprotectAttempts++;
        if (![identifiers isKindOfClass:NSArray.class] || !identifiers.count) {
            _unprotectFailed++;
            _lastUnprotectResult = @"invalid_selection";
            _lastUnprotectErrorCode = 1;
            if (error)
                *error = GSProtectionError();
            return NO;
        }
        NSError *failure = nil;
        BOOL saved = [self updateIdentifiers:identifiers protect:NO error:&failure];
        if (saved)
            _unprotectSucceeded++;
        else
            _unprotectFailed++;
        _lastUnprotectResult = saved ? @"succeeded" : @"update_failed";
        _lastUnprotectErrorCode = saved ? 0 : (failure ? failure.code : 1);
        if (!saved && error)
            *error = failure ?: GSProtectionError();
        return saved;
    }
}
- (BOOL)updateIdentifiers:(NSArray<NSString *> *)identifiers
                  protect:(BOOL)protect
                    error:(NSError **)error {
    @synchronized(self) {
        if (!_healthy || ![identifiers isKindOfClass:NSArray.class] || identifiers.count > 100000) {
            if (error)
                *error = GSProtectionError();
            return NO;
        }
        for (id value in identifiers)
            if (!GSValidProtectedID(value)) {
                if (error)
                    *error = GSProtectionError();
                return NO;
            }
        NSMutableSet *next = [_identifiers mutableCopy];
        for (NSString *identifier in identifiers)
            if (protect)
                [next addObject:identifier];
            else
                [next removeObject:identifier];
        if (next.count > 100000) {
            if (error)
                *error = GSProtectionError();
            return NO;
        }
        NSDictionary *state = @{
            @"schema" : @1,
            @"localIDs" : [next.allObjects sortedArrayUsingSelector:@selector(compare:)]
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:error];
        if (data.length > 32 * 1024 * 1024) {
            if (error)
                *error = GSProtectionError();
            return NO;
        }
        NSURL *parent = [_url URLByDeletingLastPathComponent];
        if (!data ||
            ![NSFileManager.defaultManager createDirectoryAtURL:parent
                                    withIntermediateDirectories:YES
                                                     attributes:@{NSFilePosixPermissions : @0700}
                                                          error:error] ||
            ![data writeToURL:_url options:NSDataWritingAtomic error:error])
            return NO;
        [_url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
        _identifiers = [next copy];
        return YES;
    }
}
@end

GSLocalPhotoProtection *GSLocalPhotoProtectionStore(void) {
    static GSLocalPhotoProtection *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *support =
            [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                 inDomains:NSUserDomainMask]
                .firstObject;
        store = [[GSLocalPhotoProtection alloc]
            initWithURL:[[support URLByAppendingPathComponent:@"GoToHP" isDirectory:YES]
                            URLByAppendingPathComponent:@"protected-local-photos.json"]];
    });
    return store;
}
