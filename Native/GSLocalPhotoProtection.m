#import "GSLocalPhotoProtection.h"

static BOOL GSValidProtectedID(id value) {
    return
        [value isKindOfClass:NSString.class] && [value length] > 0 && [value length] <= 1024 &&
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
static NSError *GSProtectionError(void) {
    return [NSError errorWithDomain:@"GoToHP.LocalProtection" code:1 userInfo:nil];
}
@implementation GSLocalPhotoProtection {
    NSURL *_url;
    NSSet<NSString *> *_identifiers;
    BOOL _healthy;
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
