#import "../UI/GSProtectedPhotoStatus.h"
#include <assert.h>

int main(void) {
    @autoreleasepool {
        NSMutableDictionary *job = [@{
            @"state" : @"committing",
            @"uploaded" : @100,
            @"total" : @100,
            @"quality" : @"original"
        } mutableCopy];
        NSDictionary *status = GSProtectedPhotoUploadPresentation(job, @{});
        assert(![status[@"icon"] isEqual:@"checkmark.circle.fill"]);
        job[@"state"] = @"completed";
        assert([GSProtectedPhotoUploadPresentation(job, @{})[@"color"] isEqual:@"green"]);
        job[@"state"] = @"failed";
        assert([GSProtectedPhotoUploadPresentation(job, @{})[@"color"] isEqual:@"red"]);
        job[@"state"] = @"uploading";
        job[@"uploaded"] = @25;
        assert([GSProtectedPhotoUploadPresentation(job, @{})[@"detail"] containsString:@"25%"]);
        job[@"total"] = @0;
        assert(![GSProtectedPhotoUploadPresentation(job, @{})[@"detail"] containsString:@"%"]);
        job[@"state"] = @"pending";
        NSString *waiting = GSProtectedPhotoUploadPresentation(
            job,
            @{@"wifiOnly" : @YES,
              @"wifi" : @NO})[@"detail"];
        assert(waiting.length && ![GSProtectedPhotoUploadPresentation(job, @{})[@"icon"]
                                     isEqual:@"checkmark.circle.fill"]);
        NSLog(@"PASS rebackup presentation, commit confirmation, progress and unknown totals");
    }
}
