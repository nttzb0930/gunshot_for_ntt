#pragma once
#import <Foundation/Foundation.h>

// Providers run on the import worker, one item at a time. nil means inaccessible.
typedef id (^GSBatchItemProvider)(NSUInteger index);
typedef void (^GSBatchProgress)(NSDictionary *snapshot);
// Item callbacks run on main. They are not retained in diagnostic snapshots.
typedef void (^GSBatchItemCompletion)(NSUInteger index, NSString *jobID, NSString *failureCode);
FOUNDATION_EXPORT BOOL GSStartBatchImport(NSUInteger count, NSString *source, BOOL assets,
                                          GSBatchItemProvider provider, NSString *account,
                                          NSString *identity, GSBatchProgress progress,
                                          GSBatchProgress completion);
FOUNDATION_EXPORT void GSStopBatchImport(BOOL backgroundExpired);
FOUNDATION_EXPORT NSDictionary *GSBatchImportSnapshot(void);
// Resolve a bounded page of identifiers off main; never load itemProvider media.
FOUNDATION_EXPORT GSBatchItemProvider GSPhotoIdentifierProvider(NSArray *identifiers);
FOUNDATION_EXPORT BOOL GSStartProtectedPhotoImport(NSArray<NSString *> *identifiers,
                                                   NSString *account, NSString *identity,
                                                   GSBatchItemCompletion itemCompletion,
                                                   GSBatchProgress completion);
