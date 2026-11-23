// Source-built iOS 16 host for iCTRL. This replaces Apple's prebuilt iOS 17 stub.
// The device must already have its matching developer disk image mounted.
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
// Link to the legacy XCTest binary. Weak linking keeps the missing-DDI error
// screen available while allowing dyld to initialize XCTest before main().
extern void _XCTestMain(id configuration) __attribute__((weak_import));
static NSString *sBootstrapError;
static void (*sXCTestMain)(id);

static NSString *StatusText(NSString *english, NSString *chinese) {
    return [NSLocale.preferredLanguages.firstObject.lowercaseString hasPrefix:@"zh"] ? chinese : english;
}

static void PrepareXCTest(void) {
    sXCTestMain = _XCTestMain;
    if (!sXCTestMain) {
        sBootstrapError = StatusText(@"Mount a compatible Developer Disk Image (DDI), then reopen iCTRL.",
                                    @"请先挂载与设备系统匹配的开发者磁盘映像（DDI），然后重新打开。");
        return;
    }
    NSBundle *bundle = [NSBundle bundleWithPath:[[NSBundle mainBundle].bundlePath
                          stringByAppendingPathComponent:@"PlugIns/iCTRLUITests.xctest"]];
    NSError *error = nil;
    if (![bundle loadAndReturnError:&error]) {
        sBootstrapError = [NSString stringWithFormat:StatusText(@"Test bundle could not load: %@", @"测试模块加载失败：%@"), error.localizedDescription];
        NSLog(@"[iCTRL iOS16] %@", sBootstrapError);
    }
}

@interface _XCTRunnerAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic) BOOL scheduled;
@property(nonatomic) UIBackgroundTaskIdentifier backgroundTask;
@property(nonatomic, strong) NSTimer *statusTimer;
@property(nonatomic, strong) NSDate *bootstrapStarted;
@property(nonatomic) BOOL probeInFlight;
- (void)runTestsInBackground:(BOOL)background;
@end

@implementation _XCTRunnerAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.backgroundTask = UIBackgroundTaskInvalid;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *label = [UILabel new];
    self.statusLabel = label;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.text = sBootstrapError ?: StatusText(@"Starting iCTRL…\nAllow Notifications and Local Network access.",
                                              @"iCTRL 正在启动…\n请允许通知和本地网络访问。");
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:controller.view.leadingAnchor constant:24],
        [label.trailingAnchor constraintEqualToAnchor:controller.view.trailingAnchor constant:-24],
        [label.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor]]];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    if (!sBootstrapError) {
        self.bootstrapStarted = NSDate.date;
        self.statusTimer = [NSTimer timerWithTimeInterval:2 target:self selector:@selector(checkServerStatus:) userInfo:nil repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:self.statusTimer forMode:NSRunLoopCommonModes];
        [self runTestsInBackground:application.applicationState == UIApplicationStateBackground];
    }
    return YES;
}
- (void)checkServerStatus:(NSTimer *)timer {
    if (self.probeInFlight) return;
    if (-self.bootstrapStarted.timeIntervalSinceNow > 15) {
        self.statusLabel.text = StatusText(@"XCTest automation is not ready yet.\nIf UI Automation is enabled, keep the device unlocked for diagnosis.\nThis message does not mean the setting is off.",
                                          @"XCTest 自动化初始化尚未完成。\n若 UI 自动化已经开启，请保持解锁并等待诊断；\n此提示不代表设置开关处于关闭状态。");
    }
    self.probeInFlight = YES;
    NSInteger port = [NSUserDefaults.standardUserDefaults integerForKey:@"serverPort"];
    if (port <= 0 || port > 65535) port = 8200;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld/schema", (long)port]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 1;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.probeInFlight = NO;
            if (!error && [(NSHTTPURLResponse *)response statusCode] == 200 && data.length > 0) {
                [timer invalidate];
                self.statusLabel.text = [NSString stringWithFormat:StatusText(
                    @"iCTRL service is running\n127.0.0.1:%ld\nYou can return to the Home Screen.\nUse notifications to manage pairing and remote access.",
                    @"iCTRL 服务已启动\n本机地址：127.0.0.1:%ld\n现在可以返回主屏幕。\n通过通知管理配对和远程访问。"), (long)port];
            }
        });
    }] resume];
}
- (void)runTestsInBackground:(BOOL)background {
    (void)background; // Keep the selector compatible with EarlyURLHook.
    // _XCTestMain initializes a process singleton; never enter it twice.
    if (self.scheduled || !sXCTestMain || sBootstrapError) return;
    self.scheduled = YES;
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        @try {
            NSLog(@"[iCTRL iOS16] Entering device _XCTestMain(nil)");
            // Same environment/default configuration path used by Apple's runner.
            // Supports testmanagerd-provided configuration without replacing it.
            sXCTestMain(nil);
        } @catch (NSException *exception) {
            NSLog(@"[iCTRL iOS16] XCTest bootstrap exception: %@", exception);
            [self.statusTimer invalidate];
            self.statusLabel.text = [NSString stringWithFormat:StatusText(
                @"iCTRL startup failed: %@\nClose and reopen the app; keep this error for diagnosis.",
                @"iCTRL 启动失败：%@\n请关闭后重新打开，并保留这条错误信息。"), exception.reason];
            // XCTest may already have initialized process-wide singleton state.
            // Leave the guard set; retrying in the same process can abort it.
        }
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
}
- (void)applicationWillResignActive:(UIApplication *)application {
    if (self.backgroundTask != UIBackgroundTaskInvalid) return;
    self.backgroundTask = [application beginBackgroundTaskWithName:@"iCTRL XCTest" expirationHandler:^{
        UIBackgroundTaskIdentifier task = self.backgroundTask;
        self.backgroundTask = UIBackgroundTaskInvalid;
        if (task != UIBackgroundTaskInvalid) [application endBackgroundTask:task];
    }];
}
- (void)applicationDidBecomeActive:(UIApplication *)application {
    if (self.backgroundTask != UIBackgroundTaskInvalid) {
        [application endBackgroundTask:self.backgroundTask];
        self.backgroundTask = UIBackgroundTaskInvalid;
    }
}
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url options:(NSDictionary *)options {
    return [url.scheme isEqualToString:@"ictrl"];
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        PrepareXCTest();
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(_XCTRunnerAppDelegate.class));
    }
}
