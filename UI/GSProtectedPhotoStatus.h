#pragma once
#import <Foundation/Foundation.h>

// Presentation only. Full bytes sent is not a successful server commit.
FOUNDATION_EXPORT NSDictionary *GSProtectedPhotoUploadPresentation(NSDictionary *job,
                                                                   NSDictionary *conditions);
