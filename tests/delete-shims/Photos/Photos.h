#pragma once
#import <Foundation/Foundation.h>
@interface PHFetchResult : NSObject
@property (nonatomic) NSUInteger count;
@end
@interface PHAsset : NSObject
@property (nonatomic, copy) NSString *localIdentifier;
@property (nonatomic, copy) NSString *burstIdentifier;
+ (PHFetchResult *)fetchAssetsWithLocalIdentifiers:(NSArray *)ids options:(id)options;
@end
@interface PHAssetChangeRequest : NSObject
+ (void)deleteAssets:(id)assets;
@end
