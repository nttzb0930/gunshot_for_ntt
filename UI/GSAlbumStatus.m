#import "GSAlbumStatus.h"

NSSet<NSString *> *GSAlbumDiagnosticActions(NSDictionary *snapshot) {
    NSMutableSet *actions = [NSMutableSet set];
    NSDictionary *counts = snapshot[@"counts"];
    BOOL recovering = [snapshot[@"uncertainCreates"] count] > 0;
    if (recovering)
        [actions addObject:@"recover"];
    if (!recovering &&
        ([counts[@"failed"] integerValue] > 0 || [counts[@"uncertain"] integerValue] > 0 ||
         [snapshot[@"failedCreates"] integerValue] > 0))
        [actions addObject:@"retry"];
    if ([snapshot[@"repairableTargets"] count])
        [actions addObject:@"retarget"];
    return actions;
}
BOOL GSAlbumHasIssues(NSDictionary *snapshot) {
    NSDictionary *counts = snapshot[@"counts"];
    return GSAlbumDiagnosticActions(snapshot).count > 0 || [counts[@"unresolved"] integerValue] > 0;
}
NSDictionary *GSAlbumDiagnosticReport(NSDictionary *snapshot) {
    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    for (NSString *key in
         @[ @"pending", @"adding", @"completed", @"failed", @"uncertain", @"unresolved" ])
        counts[key] = @([snapshot[@"counts"][key] integerValue]);
    // Export only fixed codes and counters, never the snapshot's names, IDs or auth.
    NSSet *codes = [NSSet setWithArray:@[
        @"", @"album_access_denied", @"album_not_found_or_inaccessible",
        @"album_invalid_request_or_id", @"album_authorization_unavailable",
        @"album_authorization_expired", @"album_rate_limited", @"album_paused", @"album_rejected",
        @"album_request_invalid", @"album_outcome_unknown", @"create_outcome_unknown",
        @"add_outcome_unknown"
    ]];
    NSString *code = snapshot[@"error"] ?: @"";
    NSSet *statuses = [NSSet setWithArray:@[
        @"Disabled", @"Waiting", @"Uploading", @"Adding to album", @"Completed", @"Failed"
    ]];
    NSString *status = snapshot[@"status"] ?: @"Waiting";
    return @{
        @"schemaVersion" : @1,
        @"kind" : @"album-diagnostics",
        @"enabled" : @([snapshot[@"settings"][@"enabled"] boolValue]),
        @"status" : [statuses containsObject:status] ? status : @"other",
        @"counts" : counts,
        @"error" : [codes containsObject:code] ? code : @"other",
        @"failedCreations" : @([snapshot[@"failedCreates"] integerValue]),
        @"uncertainCreations" : @([snapshot[@"uncertainCreates"] count]),
        @"repairableDestinations" : @([snapshot[@"repairableTargets"] count])
    };
}
