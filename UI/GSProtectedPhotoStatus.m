#import "GSProtectedPhotoStatus.h"
#import "../Shared/GSLocalization.h"

NSDictionary *GSProtectedPhotoUploadPresentation(NSDictionary *job, NSDictionary *conditions) {
    NSString *state = job[@"state"];
    NSDictionary *labels = @{
        @"importing" : GSL(@"Preparing"),
        @"pending" : GSL(@"Pending"),
        @"preparing" : GSL(@"Preparing"),
        @"uploading" : GSL(@"Uploading"),
        @"committing" : GSL(@"Committing"),
        @"completed" : GSL(@"Completed"),
        @"failed" : GSL(@"Failed"),
        @"cancelled" : GSL(@"Cancelled")
    };
    NSString *status = labels[state ?: @""] ?: GSL(@"Checking status");
    if ([state isEqual:@"pending"]) {
        if ([conditions[@"paused"] boolValue])
            status = GSL(@"Uploads paused");
        else if (conditions[@"online"] && ![conditions[@"online"] boolValue])
            status = GSL(@"Waiting for a connection or app launch");
        else if ([conditions[@"wifiOnly"] boolValue] && ![conditions[@"wifi"] boolValue])
            status = GSL(@"Waiting for Wi-Fi");
        else if ([conditions[@"chargingOnly"] boolValue] && ![conditions[@"charging"] boolValue])
            status = GSL(@"Waiting for charging");
    }
    NSString *quality = @{
        @"original" : GSL(@"Original quality · Pixel 1"),
        @"saver" : GSL(@"Storage saver · Pixel 2"),
        @"quota" : GSL(@"Original quality · Uses account storage")
    }[job[@"quality"] ?: @""]
                            ?: GSL(@"Not configured");
    long long uploaded = MAX(0LL, [job[@"uploaded"] longLongValue]);
    long long total = MAX(0LL, [job[@"total"] longLongValue]);
    NSString *bytes =
        [NSString stringWithFormat:@"%@ / %@",
                                   [NSByteCountFormatter
                                       stringFromByteCount:uploaded
                                                countStyle:NSByteCountFormatterCountStyleFile],
                                   [NSByteCountFormatter
                                       stringFromByteCount:total
                                                countStyle:NSByteCountFormatterCountStyleFile]];
    if ([state isEqual:@"uploading"] && total > 0)
        status = [NSString stringWithFormat:@"%@ · %.0f%%", status,
                                            MIN(100.0, 100.0 * (double)uploaded / (double)total)];
    NSString *detail = [NSString stringWithFormat:@"%@ · %@\n%@", status, quality, bytes];
    BOOL failed = [state isEqual:@"failed"], completed = [state isEqual:@"completed"];
    if (failed)
        detail = [detail stringByAppendingString:GSL(@"\nTap to retry")];
    return @{
        @"detail" : detail,
        @"icon" : completed            ? @"checkmark.circle.fill"
        : failed                       ? @"exclamationmark.circle"
        : [state isEqual:@"cancelled"] ? @"xmark.circle"
                                       : @"icloud.and.arrow.up",
        @"color" : completed ? @"green"
        : failed             ? @"red"
                             : @"blue"
    };
}
