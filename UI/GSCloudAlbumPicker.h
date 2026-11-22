#pragma once
#import <UIKit/UIKit.h>

// Google Photos cloud destinations; GSAlbumPicker selects local PhotoKit sources.
@interface GSCloudAlbumPicker : UITableViewController
- (instancetype)initWithAccount:(NSString *)account
                     selectedID:(NSString *)selectedID
                      selection:(void (^)(NSString *albumKey, NSString *name))selection;
@end
