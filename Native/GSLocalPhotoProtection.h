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
// Explicit user action: permits future backup/deletion; never enqueues an upload.
- (BOOL)allowBackupForIdentifiers:(NSArray<NSString *> *)identifiers error:(NSError **)error;
- (void)recordBlockedUpload;
@property (nonatomic, readonly, copy) NSArray<NSString *> *protectedIdentifiers;
// Redacted session counters; identifiers are intentionally excluded.
@property (nonatomic, readonly, copy) NSDictionary *diagnostics;
@property (nonatomic, readonly) BOOL healthy;
@property (nonatomic, readonly) NSUInteger count;
@end

FOUNDATION_EXPORT GSLocalPhotoProtection *GSLocalPhotoProtectionStore(void);
