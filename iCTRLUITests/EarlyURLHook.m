//
//  EarlyURLHook.m
//  Installs the ictrl:// URL capture hooks as early as possible — at bundle
//  load, BEFORE XCTest's setUp runs. This matters on a COLD start: iOS calls
//  the runner's application:didFinishLaunchingWithOptions: (carrying the launch
//  URL) before our Swift setUp executes, so a Swift-side install in setUp would
//  miss it. Here we capture the launch URL and any early openURL into a shared
//  store that the Swift URLSchemeHandler drains once the server is up.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>   // CACurrentMediaTime
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <fcntl.h>
#import <unistd.h>

// Thread-safe stash of early-captured URLs. URLSchemeHandler (Swift) reads these
// via +[EarlyURLHook drainURLs] and merges them into its pending queue.
static NSMutableArray<NSURL *> *sEarlyURLs;
static NSMutableArray<NSString *> *sEarlyLogs;   // events captured before Swift log is ready
static NSLock *sEarlyLock;

// Set to YES by Swift (via +[EarlyURLHook markTestStarted]) once testStartServer
// actually begins. The bootstrap watchdog uses this to decide whether to re-kick
// runTestsInBackground: — the passcode prompt on first launch can interrupt the
// XCTest bootstrap so the test method never runs and the server never comes up.
static BOOL sTestStarted = NO;
static BOOL sEarlyBackgroundArmed = NO;

// Set to YES by Swift (via +[EarlyURLHook markSetUpEntered]) the moment
// setUpWithError runs. This distinguishes the two failure modes:
//   - setUp NEVER entered  → XCTest bootstrap never ran (passcode interrupted
//     runTestsInBackground:). Safe to re-kick — nothing is running to re-enter.
//   - setUp entered but test not "started" → the test IS running, just slow to
//     mark itself. Re-kicking here re-enters XCTest → the symbolication abort
//     crash. So we must NOT re-kick in this case.
static BOOL sSetUpEntered = NO;

// Bootstrap recovery: KEEP retrying runTestsInBackground: until the test starts
// or a total deadline elapses. The passcode ("Enable UI Automation") prompt can
// stay up for MINUTES, and each interrupted launch dies before setUp — so a
// once-only or short-window re-kick misses it entirely (confirmed on-device:
// 6+ minutes of passcode, +load fired repeatedly, but no re-kick could bridge
// it and the user had to tap the icon manually).
//
// Two things make continuous retry safe (avoiding the "symbolication service
// already set" double-bootstrap crash that killed the old aggressive watchdog):
//   1. The guard: only re-kick when NEITHER setUp NOR the test has begun. If a
//      bootstrap actually reached setUp, we never re-kick.
//   2. Serialization: at most one re-kick in flight at a time (sReKickInFlight),
//      cleared on a short delay, so we never stack concurrent runTestsInBackground:.
static double sBootstrapDeadline = 0.0;    // CACurrentMediaTime() past which we give up
static int    sReKickAttempts    = 0;      // diagnostics: how many re-kicks fired
static BOOL   sReKickInFlight     = NO;     // don't overlap re-kicks
static BOOL   sPollArmed          = NO;     // ensure the poll loop is armed once

// Diagnostic observation window (5 min — covers a slow passcode entry).
static const double kBootstrapMaxWindow = 300.0;

@interface EarlyURLHook : NSObject
+ (NSArray<NSURL *> *)drainURLs;
+ (NSArray<NSString *> *)drainLogs;
+ (void)hookDelegateInstance:(id<UIApplicationDelegate>)delegate;
+ (void)tryInstall;
+ (void)hookClass:(Class)cls;
+ (void)markTestStarted;
+ (void)markSetUpEntered;
+ (void)scheduleBootstrapWatchdogForDelegate:(id)delegate;
+ (void)armAbsoluteBootstrapFallback;
+ (void)reKickIfNeeded:(id)delegate;
+ (void)armBootstrapRetryLoop;
+ (void)pollBootstrapOnce;
@end

/// Append one +load-era line DIRECTLY to today's persisted log file. These lines
/// run before Swift logging exists and are normally only flushed when setUp/URL
/// handling drains the buffer — but if the first-launch passcode interrupts
/// bootstrap, setUp never runs and those lines (incl. the bootstrap watchdog /
/// fallback activity) are lost, creating an observability black hole. So we also
/// write straight to the file here, so the recovery path is always traceable.
static void earlyLogWriteToFile(NSString *msg) {
    @try {
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
        if (dirs.count == 0) { return; }
        NSString *dir = [dirs[0] stringByAppendingPathComponent:@"Logs/iCTRL"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd"; df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        NSString *day = [df stringFromDate:[NSDate date]];
        NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"ictrl-%@.log", day]];
        NSDateFormatter *tf = [[NSDateFormatter alloc] init]; tf.dateFormat = @"HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [tf stringFromDate:[NSDate date]], msg];
        int fd = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0644);
        if (fd >= 0) { write(fd, line.UTF8String, strlen(line.UTF8String)); close(fd); }
    } @catch (__unused NSException *e) {}
}

/// Record an event to the console, the drain buffer (for the in-memory log), AND
/// straight to the persisted file (so it survives a bootstrap that never reaches
/// setUp — see earlyLogWriteToFile).
static void earlyLog(NSString *msg) {
    NSLog(@"%@", msg);
    [sEarlyLock lock];
    if (sEarlyLogs) { [sEarlyLogs addObject:msg]; }
    [sEarlyLock unlock];
    earlyLogWriteToFile(msg);
}

static void stashURL(NSURL *url) {
    if (![[url.scheme lowercaseString] isEqualToString:@"ictrl"]) { return; }
    [sEarlyLock lock];
    [sEarlyURLs addObject:url];
    [sEarlyLock unlock];
    earlyLog([NSString stringWithFormat:@"🔗 early-captured URL %@://%@", url.scheme, url.host ?: @""]);
}

// Replacement for application:didFinishLaunchingWithOptions: — reads launch URL,
// then CHAINS to the original impl (via the exchanged tmp selector) so XCTest's
// own boot logic still runs. If there was no original (we added, not exchanged),
// the tmp selector won't respond and we just return YES.
static BOOL hookedDidFinishLaunching(id self, SEL _cmd, id application, NSDictionary *options) {
    NSURL *url = options[UIApplicationLaunchOptionsURLKey];
    earlyLog([NSString stringWithFormat:@"🔎 didFinishLaunching fired; launchURL=%@; optionKeys=%@",
              url ? url.absoluteString : @"(none)", options.allKeys]);
    if ([url isKindOfClass:[NSURL class]]) { stashURL(url); }
    // Arm the bootstrap watchdog in case the passcode prompt interrupts the test
    // kickoff (self is the _XCTRunnerAppDelegate).
    [EarlyURLHook scheduleBootstrapWatchdogForDelegate:self];
    SEL orig = NSSelectorFromString(@"ictrlearly_application:didFinishLaunchingWithOptions:");
    if ([self respondsToSelector:orig]) {
        BOOL (*imp)(id, SEL, id, NSDictionary *) = (BOOL (*)(id, SEL, id, NSDictionary *))
            [self methodForSelector:orig];
        return imp(self, orig, application, options);
    }
    return YES;
}

// Replacement for application:openURL:options: — reads warm-path URLs, then
// chains to the original if present.
static BOOL hookedOpenURL(id self, SEL _cmd, id application, NSURL *url, NSDictionary *options) {
    earlyLog([NSString stringWithFormat:@"🔎 openURL fired; url=%@", url ? url.absoluteString : @"(none)"]);
    if ([url isKindOfClass:[NSURL class]]) { stashURL(url); }
    SEL orig = NSSelectorFromString(@"ictrlearly_application:openURL:options:");
    if ([self respondsToSelector:orig]) {
        BOOL (*imp)(id, SEL, id, NSURL *, NSDictionary *) = (BOOL (*)(id, SEL, id, NSURL *, NSDictionary *))
            [self methodForSelector:orig];
        return imp(self, orig, application, url, options);
    }
    return YES;
}

// The runner uses a SCENE-based lifecycle: warm-path URLs arrive via
// -scene:openURLContexts: (a Set<UIOpenURLContext>). Extract each context's URL.
static void hookedSceneOpenURLContexts(id self, SEL _cmd, id scene, NSSet *contexts) {
    earlyLog([NSString stringWithFormat:@"🔎 scene:openURLContexts fired; count=%lu",
              (unsigned long)contexts.count]);
    for (id ctx in contexts) {
        if ([ctx respondsToSelector:@selector(URL)]) {
            NSURL *url = [ctx performSelector:@selector(URL)];
            if ([url isKindOfClass:[NSURL class]]) { stashURL(url); }
        }
    }
    SEL orig = NSSelectorFromString(@"ictrlearly_scene:openURLContexts:");
    if ([self respondsToSelector:orig]) {
        void (*imp)(id, SEL, id, NSSet *) = (void (*)(id, SEL, id, NSSet *))[self methodForSelector:orig];
        imp(self, orig, scene, contexts);
    }
}

// COLD-path for scene lifecycle: -scene:willConnectToSession:options: carries a
// UISceneConnectionOptions whose .URLContexts holds the launch URL(s).
static void hookedSceneWillConnect(id self, SEL _cmd, id scene, id session, id connectionOptions) {
    NSSet *urlContexts = nil;
    if ([connectionOptions respondsToSelector:@selector(URLContexts)]) {
        urlContexts = [connectionOptions performSelector:@selector(URLContexts)];
    }
    earlyLog([NSString stringWithFormat:@"🔎 scene:willConnect fired; urlContexts=%lu",
              (unsigned long)urlContexts.count]);
    for (id ctx in urlContexts) {
        if ([ctx respondsToSelector:@selector(URL)]) {
            NSURL *url = [ctx performSelector:@selector(URL)];
            if ([url isKindOfClass:[NSURL class]]) { stashURL(url); }
        }
    }
    // Arm the bootstrap watchdog on the actual app delegate (which owns
    // runTestsInBackground:), in case the passcode prompt interrupted kickoff.
    [EarlyURLHook scheduleBootstrapWatchdogForDelegate:[UIApplication sharedApplication].delegate];
    SEL orig = NSSelectorFromString(@"ictrlearly_scene:willConnectToSession:options:");
    if ([self respondsToSelector:orig]) {
        void (*imp)(id, SEL, id, id, id) = (void (*)(id, SEL, id, id, id))[self methodForSelector:orig];
        imp(self, orig, scene, session, connectionOptions);
    }
}

// Swizzled -[UIApplication setDelegate:] — fires the instant the runner installs
// its app delegate, which is GUARANTEED to be before UIApplicationMain calls
// application:didFinishLaunchingWithOptions:. That's the only reliable window to
// hook the delegate early enough to catch the cold-start launch URL.
static void (*original_setDelegate)(id, SEL, id<UIApplicationDelegate>);
static void swizzled_setDelegate(id self, SEL _cmd, id<UIApplicationDelegate> delegate) {
    if (delegate) {
        earlyLog([NSString stringWithFormat:@"🔎 UIApplication delegate set: %@",
                  NSStringFromClass(object_getClass(delegate))]);
        [EarlyURLHook hookDelegateInstance:delegate];
    }
    if (original_setDelegate) { original_setDelegate(self, _cmd, delegate); }
}

/// Private XCTest API: the sanctioned way for a runner to open a URL.
@interface XCTRunnerDaemonSession : NSObject
+ (instancetype)sharedSession;
- (void)openDefaultApplicationForURL:(NSURL *)url
                          completion:(void (^)(BOOL result, NSError *error))completion;
@end

@implementation EarlyURLHook

+ (void)load {
    sEarlyURLs = [NSMutableArray array];
    sEarlyLogs = [NSMutableArray array];
    sEarlyLock = [[NSLock alloc] init];

    // Swizzle UIApplication setDelegate: so we hook the delegate the moment it's
    // set (before didFinishLaunching). Fall back to a direct class hook too.
    Method m = class_getInstanceMethod([UIApplication class], @selector(setDelegate:));
    if (m) {
        original_setDelegate = (void (*)(id, SEL, id<UIApplicationDelegate>))method_getImplementation(m);
        method_setImplementation(m, (IMP)swizzled_setDelegate);
    }

    // Also try the class-based hook now and on the main queue, as a backstop.
    [self tryInstall];
    dispatch_async(dispatch_get_main_queue(), ^{ [EarlyURLHook tryInstall]; });

    earlyLog(@"🟩 +load reached — early hooks + bootstrap fallback arming");

    // DIAGNOSTIC-ONLY bootstrap observer. We do NOT re-kick runTestsInBackground:
    // any more.
    //
    // Why re-kick was removed (crash 2026-07-17-220237, SIGABRT):
    // The crash backtrace showed the ORIGINAL bootstrap was alive and blocked
    // inside `-[XCUIDevice enableAutomationMode:]` (an XCTWaiter waiting on the
    // "Enable UI Automation" authorization) — it hadn't reached setUp, so our
    // `!sSetUpEntered` guard let the re-kick through. Re-invoking
    // runTestsInBackground: then ran a SECOND `_XCTestMain` →
    // `registerSharedServiceWithConfiguration:` → "shared symbolication service
    // already set" → abort(). This is exactly the double-bootstrap crash a9c60da
    // removed the watchdog for.
    //
    // From inside the process there is NO reliable way to tell "bootstrap is
    // BLOCKED on the passcode (alive)" from "bootstrap DIED" — didBecomeActive
    // fires in BOTH cases (the alert appearing/dismissing toggles active). So any
    // in-process re-kick risks re-entering a live bootstrap → crash. We therefore
    // only OBSERVE and log; recovery of a truly-dead bootstrap needs an external
    // relaunch (see notes in the repo).
    [self armBootstrapObserver];
    [self armEarlyBackgrounding];
}

/// Diagnostic observer: logs the bootstrap-relevant lifecycle events (retry
/// window + didBecomeActive) so a passcode repro is fully traceable, but never
/// calls runTestsInBackground:. Idempotent.
/// Clear the pre-setUp stall by backgrounding, once it is safe to.
///
/// XCTest can hang before setUp for 10-18s; backgrounding the runner releases
/// it immediately. The hazard is that on first launch XCTest also puts up its
/// own "enable UI automation" passcode prompt, and suspending into THAT cancels
/// the authorization and kills the launch — which an earlier version did,
/// because a device-lock check doesn't see it (the device is unlocked while it
/// shows).
///
/// The distinguishing signal is scene activation state. The prompt is presented
/// by LocalAuthenticationUIService and deactivates our scene while it is up, so
/// `foregroundInactive` means something is in front of us and we must wait.
/// UIKit maintains this independently of XCTest, so unlike XCUIApplication it is
/// safe to read this early.
+ (BOOL)isCoveredBySystemPrompt {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundInactive) {
            return YES;
        }
    }
    return NO;
}

+ (void)armEarlyBackgrounding {
    // The source-built legacy host must stay in front while XCTest requests
    // automation authorization. Other runner builds keep the existing behavior.
    if ([[NSBundle.mainBundle objectForInfoDictionaryKey:@"ICTRLKeepForegroundDuringBootstrap"] boolValue]) {
        earlyLog(@"legacy host: keeping foreground during XCTest bootstrap");
        return;
    }
    if (sEarlyBackgroundArmed) { return; }
    sEarlyBackgroundArmed = YES;
    earlyLog(@"🏠 early-background armed — will suspend once nothing covers the runner");
    [self attemptEarlyBackgroundingWithRetriesRemaining:60];
}

/// Poll until nothing is covering us, then suspend once.
///
/// 60 x 0.5s = 30s, budgeted for a person typing a passcode rather than machine
/// latency. Giving up leaves the runner in front — a stall the user can clear,
/// which is much cheaper than a launch that dies.
+ (void)attemptEarlyBackgroundingWithRetriesRemaining:(NSInteger)retries {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (sSetUpEntered || sTestStarted) {
            earlyLog(@"🏠 early-background skipped — bootstrap already progressed");
            return;
        }
        if ([self isCoveredBySystemPrompt]) {
            // Log the state once, not every 0.5s. If this signal turns out not to
            // track the passcode sheet, that fact needs to be visible in the log
            // rather than inferred from the outcome — this whole area has already
            // cost several rounds of guessing.
            // Every 2s rather than every tick: often enough to show progress,
            // rare enough not to bury the rest of the log.
            if (retries % 4 == 0) {
                earlyLog([NSString stringWithFormat:
                          @"🏠 early-background waiting — a system prompt covers the runner (%.0fs left)",
                          retries * 0.5]);
            }
            if (retries > 0) {
                [self attemptEarlyBackgroundingWithRetriesRemaining:retries - 1];
            } else {
                earlyLog(@"🏠 early-background gave up — a prompt is still up");
            }
            return;
        }
        // Device lock is a separate case: the runner can be launched from the
        // lock screen, and backgrounding then discards the launch in progress.
        static int lockToken = -1;
        uint64_t lockState = 0;
        if (lockToken == -1 &&
            notify_register_check("com.apple.springboard.lockstate", &lockToken) != NOTIFY_STATUS_OK) {
            lockToken = -2;
        }
        if (lockToken >= 0 && notify_get_state(lockToken, &lockState) == NOTIFY_STATUS_OK && lockState != 0) {
            if (retries % 4 == 0) {
                earlyLog([NSString stringWithFormat:
                          @"🏠 early-background waiting — device is locked (%.0fs left)", retries * 0.5]);
            }
            if (retries > 0) {
                [self attemptEarlyBackgroundingWithRetriesRemaining:retries - 1];
            } else {
                earlyLog(@"🏠 early-background gave up — device still locked");
            }
            return;
        }

        UIApplication *app = UIApplication.sharedApplication;
        SEL sus = NSSelectorFromString(@"suspend");
        if (![app respondsToSelector:sus]) {
            earlyLog(@"🏠 early-background unavailable — no suspend selector");
            return;
        }
        @try {
            ((void (*)(id, SEL))objc_msgSend)(app, sus);
            earlyLog(@"🏠 early-background: suspended (pre-setUp)");
        } @catch (NSException *e) {
            earlyLog([NSString stringWithFormat:@"🏠 early-background raised: %@", e.reason]);
        }
    });
}

+ (void)armBootstrapObserver {
    if (sPollArmed) { return; }
    sPollArmed = YES;
    sBootstrapDeadline = CACurrentMediaTime() + kBootstrapMaxWindow;
    earlyLog(@"👀 bootstrap observer armed (diagnostic-only, no re-kick)");

    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification * _Nonnull note) {
        if (sTestStarted || sSetUpEntered) { return; }
        earlyLog(@"🟢 didBecomeActive — bootstrap not yet at setUp (observing, NOT re-kicking)");
    }];
}

/// Kept for source compatibility — the delegate callbacks still call this. Now a
/// no-op-ish arming of the diagnostic observer.
+ (void)armAbsoluteBootstrapFallback {
    [self armBootstrapObserver];
}
+ (void)armBootstrapRetryLoop {
    [self armBootstrapObserver];
}
+ (void)pollBootstrapOnce { /* removed — no in-process re-kick */ }

/// Retained as a guarded no-op so any caller that still references it can't
/// accidentally re-introduce the double-bootstrap crash. Intentionally does
/// NOT call runTestsInBackground:.
+ (void)reKickIfNeeded:(id)delegate {
    (void)delegate;
    // Deliberately does nothing. In-process re-kick of runTestsInBackground: was
    // removed after it re-entered a live (passcode-blocked) bootstrap and
    // abort()ed on "shared symbolication service already set". Kept as a symbol
    // so existing call sites compile.
    (void)sReKickInFlight; (void)sReKickAttempts;   // silence unused-static warnings
    earlyLog(@"🔁 re-kick suppressed — in-process re-kick removed (double-bootstrap crash risk)");
}

/// Hook a concrete delegate INSTANCE's class (covers cases where the runner's
/// delegate is a subclass we didn't know the name of).
+ (void)hookDelegateInstance:(id<UIApplicationDelegate>)delegate {
    Class cls = object_getClass(delegate);
    if (!cls) { return; }
    [self hookClass:cls];
}

static BOOL sInstalled = NO;

+ (void)tryInstall {
    if (sInstalled) { return; }
    Class cls = NSClassFromString(@"_XCTRunnerAppDelegate");
    if (!cls) { return; }
    [self hookClass:cls];
}

+ (void)hookClass:(Class)cls {
    if (sInstalled) { return; }
    sInstalled = YES;

    // application:didFinishLaunchingWithOptions:  (cold path)
    SEL dfl = NSSelectorFromString(@"application:didFinishLaunchingWithOptions:");
    if (!class_addMethod(cls, dfl, (IMP)hookedDidFinishLaunching, "B@:@@")) {
        SEL tmp = NSSelectorFromString(@"ictrlearly_application:didFinishLaunchingWithOptions:");
        if (class_addMethod(cls, tmp, (IMP)hookedDidFinishLaunching, "B@:@@")) {
            Method a = class_getInstanceMethod(cls, dfl);
            Method b = class_getInstanceMethod(cls, tmp);
            if (a && b) { method_exchangeImplementations(a, b); }
        }
    }

    // application:openURL:options:  (warm path, app-delegate lifecycle)
    SEL ou = NSSelectorFromString(@"application:openURL:options:");
    if (!class_addMethod(cls, ou, (IMP)hookedOpenURL, "B@:@@@")) {
        SEL tmp = NSSelectorFromString(@"ictrlearly_application:openURL:options:");
        if (class_addMethod(cls, tmp, (IMP)hookedOpenURL, "B@:@@@")) {
            Method a = class_getInstanceMethod(cls, ou);
            Method b = class_getInstanceMethod(cls, tmp);
            if (a && b) { method_exchangeImplementations(a, b); }
        }
    }

    // scene:openURLContexts:  (warm path, SCENE lifecycle — what the runner uses)
    SEL sou = NSSelectorFromString(@"scene:openURLContexts:");
    if (!class_addMethod(cls, sou, (IMP)hookedSceneOpenURLContexts, "v@:@@")) {
        SEL tmp = NSSelectorFromString(@"ictrlearly_scene:openURLContexts:");
        if (class_addMethod(cls, tmp, (IMP)hookedSceneOpenURLContexts, "v@:@@")) {
            Method a = class_getInstanceMethod(cls, sou);
            Method b = class_getInstanceMethod(cls, tmp);
            if (a && b) { method_exchangeImplementations(a, b); }
        }
    }

    // scene:willConnectToSession:options:  (COLD path, SCENE lifecycle)
    SEL swc = NSSelectorFromString(@"scene:willConnectToSession:options:");
    if (!class_addMethod(cls, swc, (IMP)hookedSceneWillConnect, "v@:@@@")) {
        SEL tmp = NSSelectorFromString(@"ictrlearly_scene:willConnectToSession:options:");
        if (class_addMethod(cls, tmp, (IMP)hookedSceneWillConnect, "v@:@@@")) {
            Method a = class_getInstanceMethod(cls, swc);
            Method b = class_getInstanceMethod(cls, tmp);
            if (a && b) { method_exchangeImplementations(a, b); }
        }
    }

    earlyLog(@"🔗 early URL hooks installed (app + scene lifecycle)");
}

+ (void)markTestStarted {
    sTestStarted = YES;
    earlyLog(@"✅ testStartServer began — bootstrap OK");
}

+ (void)markSetUpEntered {
    sSetUpEntered = YES;
}

// Bootstrap watchdog — recovers from the first-launch passcode prompt
// interrupting XCTest bootstrap (so runTestsInBackground: never ran and the test
// method never executes → silent, no setUp, no crash), WITHOUT reintroducing the
// symbolication re-entrancy crash.
//
// The crash happened when we re-kicked while the test was ALREADY running (just
// slow to mark itself started) — re-entering XCTest aborts with "shared
// symbolication service ... already set". The fix is to only re-kick when the
// test truly never began: setUp has NOT entered AND the test has NOT started. In
// the passcode-interrupted case neither ever fires (bootstrap never reached the
// test), so a single re-kick is safe; in the "running but slow" case sSetUpEntered
// is YES, so we DON'T re-kick and can't crash. Re-kick at most once, after a long
// delay (well past a normal cold start), guarded by @try.
+ (void)scheduleBootstrapWatchdogForDelegate:(id)delegate {
    if (!delegate) { return; }
    if (![delegate respondsToSelector:NSSelectorFromString(@"runTestsInBackground:")]) { return; }
    // The delegate callbacks (didFinishLaunching / scene:willConnect) just make
    // sure the continuous retry loop is armed — the loop itself owns re-kicking.
    [EarlyURLHook armBootstrapRetryLoop];
}

+ (NSArray<NSURL *> *)drainURLs {
    [sEarlyLock lock];
    NSArray *urls = [sEarlyURLs copy];
    [sEarlyURLs removeAllObjects];
    [sEarlyLock unlock];
    return urls;
}

+ (NSArray<NSString *> *)drainLogs {
    [sEarlyLock lock];
    NSArray *logs = [sEarlyLogs copy];
    [sEarlyLogs removeAllObjects];
    [sEarlyLock unlock];
    return logs;
}

@end
