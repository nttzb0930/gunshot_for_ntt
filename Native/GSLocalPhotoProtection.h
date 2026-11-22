#pragma once
#import <Foundation/Foundation.h>

// Device-local protection, deliberately independent of Google account selection.
// A cloud deletion must persist protection before invoking any native delete command.
@interface GSLocalPhotoProtection : NSObject
- (instancetype)initWithURL:(NSURL *)url;
- (BOOL)contains:(NSString *)identifier;
- (BOOL)updateIdentifiers:(NSArray<NSString *> *)identifiers
                  protect:(BOOL)protect
                    error:(NSError **)error;
@property (nonatomic, readonly) BOOL healthy;
@property (nonatomic, readonly) NSUInteger count;
@end

FOUNDATION_EXPORT GSLocalPhotoProtection *GSLocalPhotoProtectionStore(void);
