#import "../UI/GSAlbumStatus.h"
#include <assert.h>

int main(void) {
    @autoreleasepool {
        assert(!GSAlbumHasIssues(@{}));
        assert(GSAlbumDiagnosticActions(@{}).count == 0);
        NSDictionary *failed = @{
            @"counts" : @{@"failed" : @3, @"unresolved" : @1},
            @"repairableTargets" : @[ @{@"targetID" : @"private-id"} ]
        };
        assert(GSAlbumHasIssues(failed));
        assert([GSAlbumDiagnosticActions(failed) containsObject:@"retry"]);
        assert([GSAlbumDiagnosticActions(failed) containsObject:@"retarget"]);
        NSDictionary *unknownCreate = @{
            @"failedCreates" : @1,
            @"counts" : @{@"failed" : @3},
            @"uncertainCreates" : @[ @{@"name" : @"private-title"} ]
        };
        assert([GSAlbumDiagnosticActions(unknownCreate) containsObject:@"recover"]);
        assert(![GSAlbumDiagnosticActions(unknownCreate) containsObject:@"retry"]);
        assert([GSAlbumDiagnosticActions(
            @{@"counts" : @{@"uncertain" : @1}}) containsObject:@"retry"]);
        assert(GSAlbumDiagnosticActions(@{@"counts" : @{@"unresolved" : @1}}).count == 0);
        assert([GSAlbumDiagnosticActions(@{@"failedCreates" : @1}) containsObject:@"retry"]);

        NSDictionary *snapshot = @{
            @"settings" :
                @{@"enabled" : @YES, @"name" : @"private-title", @"albumKey" : @"private-key"},
            @"account" : @"private-email",
            @"token" : @"private-token",
            @"status" : @"Failed",
            @"counts" : @{@"failed" : @2, @"extra" : @"private-value"},
            @"error" : @"album_access_denied",
            @"uncertainCreates" : @[ @{@"name" : @"private-title"} ],
            @"repairableTargets" : @[ @{@"albumKey" : @"private-key"} ]
        };
        NSDictionary *report = GSAlbumDiagnosticReport(snapshot);
        assert([report[@"counts"][@"failed"] integerValue] == 2);
        NSString *json = [[NSString alloc]
            initWithData:[NSJSONSerialization dataWithJSONObject:report options:0 error:nil]
                encoding:NSUTF8StringEncoding];
        assert([json rangeOfString:@"private-"].location == NSNotFound);
        assert([report[@"uncertainCreations"] integerValue] == 1);
        assert([report[@"error"] isEqual:@"album_access_denied"]);
        // Unknown codes must not become a channel for response bodies or secrets.
        assert(
            [GSAlbumDiagnosticReport(@{@"error" : @"private-secret"})[@"error"] isEqual:@"other"]);
    }
    return 0;
}
