#pragma once
#import <Foundation/Foundation.h>

// Worker-only, read-only PhotoKit lookup. Assets/names/reasons are for the local
// UI; only the aggregate "report" may be included in exported diagnostics.
FOUNDATION_EXPORT NSDictionary *GSLookupProtectedPhotos(NSArray<NSString *> *identifiers);
FOUNDATION_EXPORT NSString *GSProtectedPhotoLookupMessage(NSString *reason);
