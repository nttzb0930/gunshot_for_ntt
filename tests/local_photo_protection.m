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
