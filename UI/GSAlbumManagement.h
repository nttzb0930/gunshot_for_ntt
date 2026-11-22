#pragma once
#import <UIKit/UIKit.h>

@interface GSAlbumManagement : UITableViewController
- (instancetype)initWithAccount:(NSString *)account;
+ (instancetype)diagnosticsForAccount:(NSString *)account;
@end
