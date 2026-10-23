#import "AppDelegate.h"
#import "NFCViewController.h"

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[NFCViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end
