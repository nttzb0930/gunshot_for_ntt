#pragma once
#import <Foundation/Foundation.h>

FOUNDATION_EXPORT BOOL GSAlbumHasIssues(NSDictionary *snapshot);
FOUNDATION_EXPORT NSSet<NSString *> *GSAlbumDiagnosticActions(NSDictionary *snapshot);
FOUNDATION_EXPORT NSDictionary *GSAlbumDiagnosticReport(NSDictionary *snapshot);
