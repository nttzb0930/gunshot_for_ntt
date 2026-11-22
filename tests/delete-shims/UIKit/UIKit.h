#pragma once
#import <Foundation/Foundation.h>
typedef NS_ENUM(NSInteger, UISceneActivationState) { UISceneActivationStateForegroundActive = 0 };
typedef NS_ENUM(NSInteger, UIAlertControllerStyle) { UIAlertControllerStyleAlert = 1 };
typedef NS_ENUM(NSInteger, UIAlertActionStyle) {
    UIAlertActionStyleDefault = 0,
    UIAlertActionStyleCancel = 1,
    UIAlertActionStyleDestructive = 2
};
@interface UIViewController : NSObject
@property (nonatomic, strong) UIViewController *presentedViewController;
@property (nonatomic) BOOL isBeingDismissed;
- (void)presentViewController:(UIViewController *)controller
                     animated:(BOOL)animated
                   completion:(void (^)(void))completion;
@end
@interface UIWindow : NSObject
@property (nonatomic) BOOL isKeyWindow;
@property (nonatomic, strong) UIViewController *rootViewController;
@end
@interface UIScene : NSObject
@property (nonatomic) UISceneActivationState activationState;
@end
@interface UIWindowScene : UIScene
@property (nonatomic, strong) NSArray *windows;
@end
@interface UIApplication : NSObject
+ (instancetype)sharedApplication;
@property (nonatomic, strong) NSSet *connectedScenes;
@end
@interface UIAlertAction : NSObject
@property (nonatomic) BOOL enabled;
@property (nonatomic, copy) void (^handler)(UIAlertAction *);
+ (instancetype)actionWithTitle:(NSString *)title
                          style:(UIAlertActionStyle)style
                        handler:(void (^)(UIAlertAction *))handler;
@end
@interface UIAlertController : UIViewController
@property (nonatomic, strong) NSMutableArray *actions;
+ (instancetype)alertControllerWithTitle:(NSString *)title
                                 message:(NSString *)message
                          preferredStyle:(UIAlertControllerStyle)style;
- (void)addAction:(UIAlertAction *)action;
@end
