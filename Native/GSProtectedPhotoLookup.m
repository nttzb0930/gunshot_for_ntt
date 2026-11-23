#import "GSProtectedPhotoLookup.h"
#import "../Shared/GSLocalization.h"
#import <Photos/Photos.h>

static NSString *GSPhotoAuthorization(PHAuthorizationStatus status) {
    switch (status) {
    case PHAuthorizationStatusNotDetermined:
        return @"not_determined";
    case PHAuthorizationStatusRestricted:
        return @"restricted";
    case PHAuthorizationStatusDenied:
        return @"denied";
    case PHAuthorizationStatusAuthorized:
        return @"authorized";
    case PHAuthorizationStatusLimited:
        return @"limited";
    default:
        return @"unknown";
    }
}
static NSDictionary *GSPhotoLookupResult(NSString *authorization, NSString *queryState,
                                         NSString *error, NSArray *identifiers,
                                         NSDictionary *assets, NSDictionary *names,
                                         NSDictionary *reasons, NSUInteger invalid,
                                         NSUInteger queryFailures, NSUInteger metadataFailures) {
    NSUInteger notReturned = 0, blocked = 0, failed = 0;
    for (NSString *reason in reasons.allValues) {
        if ([reason isEqual:@"not_returned"] || [reason isEqual:@"limited_or_unavailable"])
            notReturned++;
        else if ([reason hasPrefix:@"permission_"] && ![reason isEqual:@"permission_changed"])
            blocked++;
        else if ([reason isEqual:@"query_failed"] || [reason isEqual:@"permission_changed"])
            failed++;
    }
    return @{
        @"assets" : [assets copy],
        @"names" : [names copy],
        @"reasons" : [reasons copy],
        @"report" : @{
            @"authorization" : authorization,
            @"queryState" : queryState,
            @"error" : error,
            @"requested" : @(identifiers.count),
            @"resolved" : @(assets.count),
            @"notReturned" : @(notReturned),
            @"permissionBlocked" : @(blocked),
            @"queryFailed" : @(failed),
            @"queryFailures" : @(queryFailures),
            @"metadataFailures" : @(metadataFailures),
            @"invalidIdentifiers" : @(invalid),
            @"includeHiddenAssets" : @YES
        }
    };
}
NSDictionary *GSLookupProtectedPhotos(NSArray<NSString *> *identifiers) {
    NSCAssert(!NSThread.isMainThread, @"Resolve protected photos on a worker");
    NSMutableOrderedSet *unique = [NSMutableOrderedSet orderedSet];
    NSUInteger invalid = 0;
    if (identifiers && ![identifiers isKindOfClass:NSArray.class])
        invalid++;
    else
        for (id identifier in identifiers) {
            if (![identifier isKindOfClass:NSString.class] || ![identifier length] ||
                [identifier length] > 1024 ||
                [identifier rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location !=
                    NSNotFound)
                invalid++;
            else
                [unique addObject:identifier];
        }
    NSArray *wanted = unique.array;
    NSMutableDictionary *assets = [NSMutableDictionary dictionary],
                        *names = [NSMutableDictionary dictionary],
                        *reasons = [NSMutableDictionary dictionary];
    NSString *authorization = @"unknown", *error = @"", *queryState = @"not_needed";
    @try {
        authorization = GSPhotoAuthorization(
            [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite]);
    } @catch (NSException *exception) {
        error = @"authorization_exception";
    }
    if (invalid || error.length) {
        for (NSString *identifier in wanted)
            reasons[identifier] = @"query_failed";
        return GSPhotoLookupResult(authorization, @"failed",
                                   invalid ? @"invalid_identifiers" : error, wanted, assets, names,
                                   reasons, invalid, 0, 0);
    }
    BOOL allowed = [authorization isEqual:@"authorized"] || [authorization isEqual:@"limited"];
    if (!allowed) {
        for (NSString *identifier in wanted)
            reasons[identifier] = [@"permission_" stringByAppendingString:authorization];
        return GSPhotoLookupResult(authorization, @"access_blocked", @"", wanted, assets, names,
                                   reasons, 0, 0, 0);
    }
    __block NSUInteger metadataFailures = 0;
    NSUInteger queryFailures = 0, successfulPages = 0;
    for (NSUInteger start = 0; start < wanted.count; start += 64) {
        @autoreleasepool {
            NSArray *page = [wanted
                subarrayWithRange:NSMakeRange(start, MIN((NSUInteger)64, wanted.count - start))];
            NSSet *expected = [NSSet setWithArray:page];
            NSMutableDictionary *found = [NSMutableDictionary dictionary],
                                *filenames = [NSMutableDictionary dictionary];
            __block NSString *pageError = nil;
            @try {
                PHFetchOptions *options = [PHFetchOptions new];
                options.includeHiddenAssets = YES;
                PHFetchResult *result = [PHAsset fetchAssetsWithLocalIdentifiers:page
                                                                         options:options];
                if (!result)
                    pageError = @"nil_fetch_result";
                else
                    [result
                        enumerateObjectsUsingBlock:^(PHAsset *asset, NSUInteger index, BOOL *stop) {
                            if (![asset isKindOfClass:PHAsset.class] ||
                                ![expected containsObject:asset.localIdentifier]) {
                                pageError = @"unexpected_result";
                                *stop = YES;
                                return;
                            }
                            found[asset.localIdentifier] = asset;
                            @try {
                                NSString *name = [PHAssetResource assetResourcesForAsset:asset]
                                                     .firstObject.originalFilename;
                                if (name.length)
                                    filenames[asset.localIdentifier] = name;
                            } @catch (NSException *exception) {
                                metadataFailures++;
                            }
                        }];
            } @catch (NSException *exception) {
                pageError = @"fetch_exception";
            }
            if (pageError) {
                error = pageError;
                queryFailures++;
                for (NSString *identifier in page)
                    reasons[identifier] = @"query_failed";
            } else {
                successfulPages++;
                [assets addEntriesFromDictionary:found];
                [names addEntriesFromDictionary:filenames];
                for (NSString *identifier in page)
                    reasons[identifier] = found[identifier] ? @"resolved"
                                          : [authorization isEqual:@"limited"]
                                              ? @"limited_or_unavailable"
                                              : @"not_returned";
            }
        }
    }
    queryState = !wanted.count     ? @"not_needed"
                 : !queryFailures  ? @"succeeded"
                 : successfulPages ? @"partial_failure"
                                   : @"failed";
    // A permission change while reading invalidates negative lookup conclusions.
    @try {
        NSString *current = GSPhotoAuthorization(
            [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite]);
        if (![current isEqual:authorization]) {
            authorization = current;
            queryState = @"permission_changed";
            error = @"authorization_changed";
            [assets removeAllObjects];
            [names removeAllObjects];
            for (NSString *identifier in wanted)
                reasons[identifier] = @"permission_changed";
        }
    } @catch (NSException *exception) {
        queryState = @"failed";
        error = @"authorization_exception";
        [assets removeAllObjects];
        [names removeAllObjects];
        for (NSString *identifier in wanted)
            reasons[identifier] = @"query_failed";
    }
    return GSPhotoLookupResult(authorization, queryState, error, wanted, assets, names, reasons, 0,
                               queryFailures, metadataFailures);
}
NSString *GSProtectedPhotoLookupMessage(NSString *reason) {
    if ([reason isEqual:@"permission_denied"] || [reason isEqual:@"permission_not_determined"])
        return GSL(@"Photo access is not granted. Check Photos permission in Settings.");
    if ([reason isEqual:@"permission_restricted"])
        return GSL(@"Photo access is restricted by iOS.");
    if ([reason isEqual:@"limited_or_unavailable"])
        return GSL(@"Limited Photos access: this ID was not returned. Check the selected photos in "
                   @"Settings.");
    if ([reason isEqual:@"not_returned"])
        return GSL(@"Full Photos access: no photo was returned for the saved ID. This does not "
                   @"confirm deletion.");
    if ([reason isEqual:@"permission_changed"])
        return GSL(@"Photos permission changed during lookup. Pull down to refresh.");
    if ([reason isEqual:@"permission_unknown"])
        return GSL(@"Could not determine Photos permission. Pull down to retry.");
    return GSL(@"Photo lookup failed. Pull down to retry. Protection is unchanged.");
}
