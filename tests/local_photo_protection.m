#import "../Native/GSLocalPhotoProtection.h"
#include <assert.h>

int main(void) {
    @autoreleasepool {
        NSURL *root =
            [NSURL fileURLWithPath:[NSTemporaryDirectory()
                                       stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                       isDirectory:YES];
        NSURL *file = [root URLByAppendingPathComponent:@"protection.json"];
        GSLocalPhotoProtection *store = [[GSLocalPhotoProtection alloc] initWithURL:file];
        assert(store.healthy && store.count == 0 && ![store contains:@"a"]);
        NSError *error = nil;
        assert(([store updateIdentifiers:@[ @"a", @"b", @"a" ] protect:YES error:&error]));
        assert(error == nil && store.count == 2 && [store contains:@"a"]);
        NSArray *snapshot = store.protectedIdentifiers;
        assert(([snapshot isEqual:@[ @"a", @"b" ]]));
        assert([store allowBackupForIdentifiers:@[ @"a" ] error:nil]);
        assert(![store contains:@"a"] && [store contains:@"b"]);
        assert(snapshot.count == 2); // An earlier UI snapshot remains immutable.
        assert([store.diagnostics[@"unprotectSucceeded"] unsignedIntegerValue] == 1);
        assert([store.diagnostics[@"lastUnprotectErrorCode"] integerValue] == 0);
        assert(![store allowBackupForIdentifiers:@[] error:nil]);
        assert([store.diagnostics[@"unprotectFailed"] unsignedIntegerValue] == 1);
        assert([store.diagnostics[@"lastUnprotectErrorCode"] integerValue] == 1);
        [store recordBlockedUpload];
        assert([store.diagnostics[@"blockedUploads"] unsignedIntegerValue] == 1);
        assert([store updateIdentifiers:@[ @"a" ] protect:YES error:nil]);
        store = [[GSLocalPhotoProtection alloc] initWithURL:file];
        assert(store.healthy && store.count == 2 && [store contains:@"b"]);
        assert(![store contains:@"different-asset"]);
        assert([store updateIdentifiers:@[ @"private-local-identifier" ] protect:YES error:nil]);
        assert(![store.diagnostics.description containsString:@"private-local-identifier"]);
        assert([store allowBackupForIdentifiers:@[ @"private-local-identifier" ] error:nil]);
        assert(![store updateIdentifiers:@[ @"" ] protect:YES error:&error]);
        assert(![store updateIdentifiers:(id) @[ @42 ] protect:YES error:&error]);
        assert(store.count == 2);
        assert([store updateIdentifiers:@[ @"a" ] protect:NO error:nil]);
        store = [[GSLocalPhotoProtection alloc] initWithURL:file];
        assert(![store contains:@"a"] && [store contains:@"b"]);

        // Diagnostic writes are in-memory and cannot remove saved protection.
        NSData *saved = [NSData dataWithContentsOfURL:file];
        [store recordPhotoLookup:@{
            @"authorization" : @"authorized",
            @"queryState" : @"succeeded",
            @"error" : @"",
            @"requested" : @2,
            @"resolved" : @1,
            @"notReturned" : @1,
            @"queryFailed" : @(-1),
            @"metadataFailures" : @"private-photo.jpg",
            @"includeHiddenAssets" : @YES,
            @"localIDs" : @[ @"private-local-id" ]
        }];
        NSDictionary *lookup = store.diagnostics[@"photoLookup"];
        assert([lookup[@"authorization"] isEqual:@"authorized"] &&
               [lookup[@"requested"] intValue] == 2);
        assert([lookup[@"resolved"] intValue] == 1 && [lookup[@"notReturned"] intValue] == 1);
        assert([lookup[@"queryFailed"] intValue] == 0 &&
               [lookup[@"metadataFailures"] intValue] == 0);
        assert([lookup[@"includeHiddenAssets"] boolValue] && !lookup[@"localIDs"]);
        NSDictionary *earlier = store.diagnostics;
        [store recordPhotoLookup:@{
            @"authorization" : @"private-token",
            @"queryState" : @"private-path",
            @"error" : @"private-exception-text"
        }];
        assert([store.diagnostics[@"photoLookup"][@"authorization"] isEqual:@"unknown"]);
        assert([store.diagnostics[@"photoLookup"][@"queryState"] isEqual:@"failed"]);
        assert([store.diagnostics[@"photoLookup"][@"error"] isEqual:@"unexpected_result"]);
        assert([earlier[@"photoLookup"][@"authorization"] isEqual:@"authorized"]);
        for (NSString *outcome in @[
                 @"requested", @"available", @"cloud_only", @"failed", @"cancelled",
                 @"private-preview-id"
             ])
            [store recordPreviewResult:outcome];
        NSDictionary *previews = store.diagnostics[@"previewThisLaunch"];
        assert(previews.count == 5 && [previews[@"requested"] intValue] == 1);
        NSString *json =
            [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:store.diagnostics
                                                                           options:0
                                                                             error:nil]
                                  encoding:NSUTF8StringEncoding];
        assert(![json containsString:@"private-"]);
        assert(store.count == 1 && [store contains:@"b"] &&
               [[NSData dataWithContentsOfURL:file] isEqual:saved]);
        GSLocalPhotoProtection *reopened = [[GSLocalPhotoProtection alloc] initWithURL:file];
        assert([reopened contains:@"b"] &&
               [reopened.diagnostics[@"photoLookup"][@"queryState"] isEqual:@"not_checked"]);
        assert([reopened.diagnostics[@"previewThisLaunch"] count] == 0);
        [store recordPhotoSelectionCheck:@{
            @"outcome" : @"not_in_protection",
            @"matchesSaved" : @NO,
            @"savedCount" : @1,
            @"lookup" : @{
                @"authorization" : @"authorized",
                @"queryState" : @"succeeded",
                @"error" : @"",
                @"resolved" : @1,
                @"privateID" : @"private-local-id"
            },
            @"identifier" : @"private-local-id"
        }];
        assert([store.diagnostics[@"selectionCheck"][@"outcome"] isEqual:@"not_in_protection"]);
        assert([store.diagnostics[@"selectionCheck"][@"lookup"][@"resolved"] intValue] == 1);
        assert(![store.diagnostics.description containsString:@"private-"]);
        [store recordPhotoSelectionCheck:@{
            @"outcome" : @"private-message",
            @"savedCount" : @(-1),
            @"lookup" : @"private-message"
        }];
        assert([store.diagnostics[@"selectionCheck"][@"outcome"] isEqual:@"query_failed"]);
        assert([store.diagnostics[@"selectionCheck"][@"savedCount"] intValue] == 0);
        assert(![store.diagnostics.description containsString:@"private-"]);
        assert(store.count == 1 && [store contains:@"b"] &&
               [[NSData dataWithContentsOfURL:file] isEqual:saved]);

        NSURL *invalidParent = [root URLByAppendingPathComponent:@"not-a-directory"];
        assert([[@"file" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:invalidParent
                                                                 atomically:YES]);
        GSLocalPhotoProtection *unwritable = [[GSLocalPhotoProtection alloc]
            initWithURL:[invalidParent URLByAppendingPathComponent:@"state.json"]];
        assert(![unwritable updateIdentifiers:@[ @"new" ] protect:YES error:&error]);
        assert(![unwritable allowBackupForIdentifiers:@[ @"new" ] error:&error]);
        assert([unwritable.diagnostics[@"unprotectFailed"] unsignedIntegerValue] == 1);
        assert(unwritable.count == 0);

        for (NSString *corrupt in @[
                 @"not-json", @"[]", @"{\"schema\":2,\"localIDs\":[]}",
                 @"{\"schema\":1,\"localIDs\":[42]}"
             ]) {
            assert([[corrupt dataUsingEncoding:NSUTF8StringEncoding] writeToURL:file
                                                                     atomically:YES]);
            store = [[GSLocalPhotoProtection alloc] initWithURL:file];
            assert(!store.healthy && [store contains:@"a"] && [store contains:@"unknown"]);
            assert(store.protectedIdentifiers.count == 0);
            assert(![store updateIdentifiers:@[ @"a" ] protect:NO error:nil]);
        }
        [NSFileManager.defaultManager removeItemAtURL:root error:nil];
        NSLog(@"PASS local protection persistence, immutable snapshots, redacted counters, "
              @"explicit removal, invalid data and failed writes");
    }
}
