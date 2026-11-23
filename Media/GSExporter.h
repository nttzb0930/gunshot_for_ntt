#import <Foundation/Foundation.h>
#import <Photos/Photos.h>
// These methods run on a worker queue. UI callbacks remain on the main queue.
NSArray<NSURL *> *GSExportAsset(PHAsset *asset, NSURL *directory, NSError **error);
// Explicit user-selected rebackup exports originals while keeping the saved
// protection until the queue has copied every resource.
NSArray<NSURL *> *GSExportAssetForRebackup(PHAsset *asset, NSURL *directory, NSError **error);
NSString *GSImportFiles(NSArray<NSURL *> *files, NSString *account, NSString *quality, NSDate *date,
                        NSError **error);
NSString *GSImportRebackupFiles(NSArray<NSURL *> *files, NSString *account, NSString *quality,
                                NSDate *date, NSString *assetIdentifier, BOOL (^beforeSeal)(void),
                                NSError **error);
