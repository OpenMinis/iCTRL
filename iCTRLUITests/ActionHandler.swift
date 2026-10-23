import XCTest
import UIKit
import Vision

extension XCUIElement {
    /// `exists`, without the ability to kill the runner.
    ///
    /// The property looks like a field read but is a query XCTest resolves in
    /// the target app across IPC, and it raises an Obj-C NSException when that
    /// resolution fails. Swift can't intercept that — `try?` catches only Swift
    /// `throws` — so it unwinds into XCTest's terminate handler and the process
    /// dies with SIGABRT.
    ///
    /// Observed on iOS 16.1 (iPhone 8 Plus): `exists` threw from inside
    /// `-[XCTActivityRecordStack didFinishActivity:]` on a background queue and
    /// took the runner down mid-`find_element`. Older XCTest records an activity
    /// per query and is stricter about that stack being balanced, so every one
    /// of these reads is a crash risk on older systems even though the same code
    /// has run for months on iOS 26.
    var safeExists: Bool {
        ForegroundApp.safeBoolProperty("exists", ofElement: self, fallback: false)
    }

    /// `isHittable`, guarded the same way and for the same reason.
    var safeIsHittable: Bool {
        ForegroundApp.safeBoolProperty("isHittable", ofElement: self, fallback: false)
    }
}

class ActionHandler {
    private let app: XCUIApplication
    private let fastHandler: FastActionHandler

    /// A resolvable element reference. Re-queries the LIVE tree each time it's
    /// used, so it stays valid across small layout changes (unlike a coordinate).
    struct ElementRef {
        let bundleId: String?
        let match: Match
        enum Match {
            case identifier(String)          // exact accessibility id
            case exactLabel(String)          // label == value
            case containsLabel(String)       // label CONTAINS[c] value
        }
        let elementType: String?             // optional type filter (button/…)
        let index: Int                       // which match (usually 0)
        let createdAt: TimeInterval          // monotonic creation time
    }

    /// Refs expire after this many seconds; also capped to `refMaxCount`.
    private static let refTTL: TimeInterval = 3600      // 1 hour
    private static let refMaxCount = 500

    private var refStore: [String: ElementRef] = [:]
    private var refCounter = 0

    private var nowMonotonic: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func makeRef(_ ref: ElementRef) -> String {
        pruneRefs()
        refCounter += 1
        let id = "el_\(refCounter)"
        refStore[id] = ref
        // A button of a system alert: remember which alert. Alerts chain
        // (e.g. tracking → notifications → location), share button labels,
        // and a ref re-resolves by label — so it would press the NEXT
        // alert's "Allow"/"Don't Allow". Checked before the tap.
        if ref.bundleId == "com.apple.springboard", let title = alertTitle() { refAlertTitle[id] = title }
        return id
    }
    private var refAlertTitle: [String: String] = [:]

    /// Drop expired refs (TTL) and enforce the count cap (oldest-first).
    private func pruneRefs() {
        let cutoff = nowMonotonic - Self.refTTL
        refStore = refStore.filter { $0.value.createdAt >= cutoff }
        if refStore.count > Self.refMaxCount {
            // Remove the oldest overflow (createdAt ascending).
            let overflow = refStore.count - Self.refMaxCount
            let oldest = refStore.sorted { $0.value.createdAt < $1.value.createdAt }
                                 .prefix(overflow).map { $0.key }
            for k in oldest { refStore.removeValue(forKey: k) }
        }
    }

    /// Resolve a stored ref back to a live XCUIElement, or say precisely why it
    /// can't be — every failure here means the action was NOT performed.
    ///
    /// Checks the ref's app is still in front BEFORE querying it. A live query
    /// against a backgrounded app doesn't fail fast: XCTest waits out its own
    /// snapshot timeout (~16s, repeatedly), and the serial UI queue is stuck
    /// behind it the whole time. That is exactly how one tap on App Store's
    /// UPDATE — with App Store already sent to the background — ran for 97.9s,
    /// timed out tap/screenshot/launch_app/device_info behind it, and then
    /// reported the misleading "element gone". page_source and find_element had
    /// this guard (snapshotPrecheck); refs did not.
    private func resolveRef(_ refId: String) -> (XCUIElement?, JSONRPCError?) {
        guard let ref = refStore[refId], nowMonotonic - ref.createdAt <= Self.refTTL else {
            refStore.removeValue(forKey: refId)
            return (nil, JSONRPCError(code: -32602, message:
                "ref '\(refId)' is unknown or expired (refs live 1 hour) — nothing was tapped. " +
                "Re-find it with find_element/scroll_to_element.", data: nil))
        }

        // Unlike snapshotPrecheck this does NOT fall through to whatever else is
        // in front: a ref names one element in one app, and acting on a
        // look-alike in another app would be worse than refusing.
        if let bid = ref.bundleId, bid != "com.apple.springboard" {
            let state = AppState(rawValue: ForegroundApp.appState(forBundleID: bid)) ?? .unknown
            if state == .background || state == .backgroundSuspended || state == .notRunning {
                let live = ForegroundApp.currentBundleID()
                let what = state == .notRunning ? "not running" : "in the background"
                return (nil, JSONRPCError(code: -32004, message:
                    "ref '\(refId)' belongs to \(bid), which is now \(what)" +
                    (live.map { " (in front: \($0))" } ?? "") + " — the action was NOT performed. " +
                    "Something moved it off screen (a system sheet, a switch to another app). " +
                    "Check with screenshot or page_source; to continue in \(bid), activate_app{bundle_id:\"\(bid)\"} " +
                    "and find_element again.", data: nil))
            }
        }

        let target: XCUIApplication = ref.bundleId.map { XCUIApplication(bundleIdentifier: $0) } ?? app
        let base = elementQuery(in: target, type: ref.elementType)
        let query: XCUIElementQuery
        switch ref.match {
        case .identifier(let v):    query = base.matching(identifier: v)
        case .exactLabel(let v):    query = base.matching(NSPredicate(format: "label == %@", v))
        case .containsLabel(let v): query = base.matching(NSPredicate(format: "label CONTAINS[c] %@", v))
        }
        let el = query.element(boundBy: ref.index)
        var reason: NSString?
        switch ForegroundApp.boolPropertyState("exists", ofElement: el, reason: &reason) {
        case 1:
            return (el, nil)
        case 0:
            return (nil, JSONRPCError(code: -32602, message:
                "ref '\(refId)' no longer matches anything — the view changed since it was found. " +
                "Nothing was tapped. Re-find it with find_element/scroll_to_element.", data: nil))
        default:
            // XCTest couldn't answer at all. Not the same as "gone", and saying
            // "gone" is what misled the last post-mortem.
            return (nil, .serverError(
                "Couldn't resolve ref '\(refId)': the accessibility query failed (\(reason as String? ?? "no reason given")). " +
                "The app is probably busy or changing screens — the action was NOT performed, so it is safe " +
                "to retry once it settles (check with screenshot)."))
        }
    }

    private func elementQuery(in target: XCUIApplication, type: String?) -> XCUIElementQuery {
        // Same names as the bounded walk's filter, so a live re-resolve
        // counts ordinals over exactly the types the walk matched.
        guard let raws = Self.typeFilterRaws(type), !raws.isEmpty else { return target.descendants(matching: .any) }
        let types = raws.map { $0.uintValue }
        if types.count == 1, let t = XCUIElement.ElementType(rawValue: types[0]) {
            return target.descendants(matching: t)
        }
        return target.descendants(matching: .any).matching(NSPredicate(format: "elementType IN %@", raws))
    }

    init(app: XCUIApplication) {
        self.app = app
        self.fastHandler = FastActionHandler(app: app)
    }

    /// The app actually in front, or nil if it can't be told.
    ///
    /// There is no "target app" any more: reads and actions follow the screen.
    /// A sticky binding to the last launched app kept pointing at it after the
    /// app jumped elsewhere or the user switched, and pulled it back in front
    /// on the next tap — undoing exactly what had just happened on screen.
    ///
    /// Older iOS names the front app directly. iOS 27 doesn't (Xcode 27's
    /// XCTest lost the pid → bundle id lookup), but still gives its pid: that
    /// is matched against apps known to this runner by asking each whether it
    /// is in front (testmanagerd answers in milliseconds), and cached by pid.
    /// The last front app named, and when — for the static precheck.
    private static var lastFront: (bid: String, at: TimeInterval)?

    private func resolveForegroundBundleId() -> String? {
        let bid = resolveForegroundBundleIdUncached()
        if let bid = bid { Self.lastFront = (bid, nowMonotonic) }
        return bid
    }

    private func resolveForegroundBundleIdUncached() -> String? {
        // On iOS 27 currentBundleID is always nil, and asking still costs
        // a few hundred ms — paid several times per call. After a few nils
        // in a row, stop asking.
        if currentBundleIDMisses < 3 {
            if let bid = ForegroundApp.currentBundleID(), !bid.isEmpty { currentBundleIDMisses = 0; return bid }
            currentBundleIDMisses += 1
        }
        let pid = ForegroundApp.frontmostPID()
        guard pid > 0 else { return nil }
        let springboard = "com.apple.springboard"
        if springboardPID == 0 { springboardPID = ForegroundApp.processID(forBundleID: springboard) }
        if pid == springboardPID { return springboard }
        // A pid names one process for its whole life, so a learned mapping
        // needs no re-check. Re-checking asked XCTest for the app's state,
        // which can block for seconds, on every call that names the front
        // app (several per screen_text — most of the call's time).
        if let cached = frontByPID[pid] { return cached }
        var candidates: [String] = recentApps
        for e in AppMemory.shared.openedApps().prefix(12) {
            if let b = e["bundle_id"] as? String, !candidates.contains(b) { candidates.append(b) }
        }
        // Apps the user or a link opened never pass through launch_app; the
        // usual system ones are worth a probe each before giving up.
        for b in Self.commonSystemApps where !candidates.contains(b) { candidates.append(b) }
        for b in candidates.prefix(30) where b != springboard {
            if AppState(rawValue: ForegroundApp.appState(forBundleID: b)) == .foreground {
                frontByPID[pid] = b
                return b
            }
        }
        // Opened before a runner restart, or by a link: not among the 12
        // most recent, and reads would otherwise fall back to SpringBoard's
        // tree with no warning. iOS 26+ won't list installed apps, so ask
        // every app this runner ever opened, then the built-in catalog. The
        // answer is cached by pid: paid once per process.
        let t0 = nowMonotonic
        var tried = Set(candidates.prefix(30))
        var more: [String] = AppMemory.shared.openedApps().compactMap { $0["bundle_id"] as? String }
        more += Self.builtInApps.compactMap { $0["bundle_id"] }
        for b in more where b != springboard && tried.insert(b).inserted {
            if AppState(rawValue: ForegroundApp.appState(forBundleID: b)) == .foreground {
                frontByPID[pid] = b
                iCTRLUITests.logBuffer.append(String(format: "🔍 front app %@ found by asking known apps (%.0fms)",
                                                     b, (nowMonotonic - t0) * 1000))
                return b
            }
        }
        iCTRLUITests.logBuffer.append(String(format: "🔍 front pid %d matched no known app (%.0fms)",
                                             pid, (nowMonotonic - t0) * 1000))
        return nil
    }

    private static let commonSystemApps = [
        "com.apple.AppStore", "com.apple.mobilesafari", "com.apple.Preferences", "com.apple.mobileslideshow",
        "com.apple.camera", "com.apple.Maps", "com.apple.MobileSMS", "com.apple.mobilephone",
        "com.apple.mobilemail", "com.apple.weather", "com.apple.mobilecal", "com.apple.mobilenotes",
        "com.apple.Music", "com.apple.podcasts", "com.apple.DocumentsApp", "com.apple.Health",
        "com.apple.reminders", "com.apple.shortcuts", "com.apple.mobiletimer", "com.apple.TestFlight",
    ]

    private var currentBundleIDMisses = 0

    /// Front-app pid → bundle id, learned by resolveForegroundBundleId.
    private var frontByPID: [pid_t: String] = [:]
    private var springboardPID: pid_t = 0
    /// Apps opened through this runner, most recent first — the first
    /// candidates when naming the front app by pid.
    private var recentApps: [String] = []
    private func noteOpened(_ bundleId: String) {
        recentApps.removeAll { $0 == bundleId }
        recentApps.insert(bundleId, at: 0)
        if recentApps.count > 8 { recentApps.removeLast() }
    }

    /// Browsers render their page into a web view that XCUITest does not walk:
    /// the accessibility tree stops at the browser chrome, so page_source returns
    /// a few dozen anonymous `Other` nodes and NO page content. Element lookups
    /// therefore always miss, and the generic "try scroll/contains" advice sends
    /// the caller in circles. Detect it so the error can say what actually works
    /// (screenshot + tap by coordinate) instead.
    private static let webViewHostBundleIds: Set<String> = [
        "com.apple.mobilesafari",
        "com.google.chrome.ios",
        "com.microsoft.msedge",
        "org.mozilla.ios.Firefox",
        "com.apple.SafariViewService",
    ]

    private func foregroundIsWebViewHost() -> Bool {
        guard let bid = resolveForegroundBundleId() else { return false }
        return Self.webViewHostBundleIds.contains(bid)
    }

    /// Appended to lookup failures in a browser — the one piece of advice that
    /// actually recovers the situation.
    /// Told at the moment a caller is hunting for an app icon — screenshotting
    /// or tapping the home screen — since that is when the advice lands; the
    /// same rule sitting in SKILL.md was skipped in a real session.
    static let homeScreenAdvice =
        "You are on the home screen. To open an app don't hunt for its icon (folders, pages and " +
        "layout differ per device): resolve_app{text:\"<app name>\"} → launch_app{bundle_id}."

    static func isHomeScreen() -> Bool {
        ForegroundApp.currentBundleID() == "com.apple.springboard"
    }

    private static let webViewAdvice =
        " ⚠️ The foreground app is a BROWSER: web page content is NOT exposed to the " +
        "accessibility tree, so find_element/page_source can never see links, buttons or text in the page " +
        "(page_source returns only browser chrome). Do NOT retry with scroll_to_element or match:'contains' — " +
        "they cannot help here. Next: call screenshot, read the target's position off the image, convert " +
        "pixel→point by dividing by the `scale` field in that same screenshot response, then tap{x,y}."


    // MARK: - Screen Geometry (for progressive disclosure)

    /// Cached point size. Reading `app.frame` triggers XCUITest quiescence waiting
    /// (waits for the UI to be idle), which on animation-heavy apps can take many
    /// seconds or time out. The screen size never changes during a session (rotation
    /// aside), so we fetch it once lazily and reuse it — keeping the hot path (tap/
    /// swipe validation + hint) free of quiescence.
    private var cachedPointSize: CGRect?

    /// Logical point size of the screen — the coordinate space ALL tap/swipe/drag use.
    /// Fetched once, then cached, to avoid repeated quiescence waits.
    private var pointSize: CGRect {
        if let cached = cachedPointSize { return cached }
        let frame = app.frame
        // Refuse to cache a compatibility-mode reading. The runner has no launch
        // storyboard, so a size sourced from UIScreen (or an app.frame read
        // before SpringBoard is attached) comes back 320x480 on every device.
        // Caching that once would silently mis-scale screenshots AND shift every
        // tap coordinate for the rest of the session — the failure this guard
        // exists to prevent. Better to re-read next call than to lock in a lie.
        guard !Self.isCompatibilityModeSize(frame) else {
            iCTRLUITests.logBuffer.append(
                "⚠️ screen size read as \(Int(frame.width))x\(Int(frame.height)) "
                + "(iOS compatibility-mode default) — not caching; retrying on next call")
            return frame
        }
        cachedPointSize = frame
        return frame
    }

    /// The 320x480 (and 320x568) sizes iOS hands an app that has no launch
    /// storyboard. Never a real modern device's point size.
    private static func isCompatibilityModeSize(_ r: CGRect) -> Bool {
        let known: [(CGFloat, CGFloat)] = [(320, 480), (320, 568)]
        return known.contains { $0 == r.width && $1 == r.height }
    }

    /// Device scale factor (points → pixels). UIScreen access does NOT trigger
    /// quiescence.
    ///
    /// NOTE: `UIScreen.main.bounds` must NEVER be used for the point size here.
    /// The XCUITest runner ships without a launch storyboard, so iOS runs it in
    /// compatibility mode and reports a 320x480 screen no matter the hardware —
    /// use `pointSize` (backed by `app.frame`, which reads true device geometry
    /// through the accessibility server). `.scale` is unaffected by compatibility
    /// mode and stays correct, which is the only reason this one is safe.
    private var scale: Double { Double(UIScreen.main.scale) }

    /// Validate a coordinate is inside the tappable point-space.
    /// Uses the cached size — no quiescence wait.
    private func validateCoordinate(x: Double, y: Double, context: String) -> JSONRPCError? {
        let size = pointSize
        let w = size.width, h = size.height
        guard x >= 0, y >= 0, x <= w, y <= h else {
            return JSONRPCError(
                code: -32602,
                message: "\(context): coordinate (\(x), \(y)) is out of bounds. " +
                    "Valid tap range is x∈[0,\(Int(w))], y∈[0,\(Int(h))] in POINTS (not pixels). " +
                    "If you computed this from a screenshot, divide pixel coordinates by scale=\(scale) first.",
                data: [
                    "point_width": .double(w),
                    "point_height": .double(h),
                    "scale": .double(scale),
                ]
            )
        }
        return nil
    }

    /// A compact hint object attached to spatial-action responses so the model
    /// keeps the coordinate space in context without re-querying device_info.
    /// Uses the cached size — no quiescence wait.
    private var coordinateHint: JSONValue {
        let size = pointSize
        return .object([
            "coordinate_space": .string("points"),
            // Live health. Sustained capture heats the device and iOS throttles
            // it, so thermal_state explains a stream that is slowing down.
            "system": .object(systemMetrics()),
            "point_width": .double(size.width),
            "point_height": .double(size.height),
            "scale": .double(scale),
        ])
    }

    /// Interactions refused while a system alert covers the app, unless aimed
    /// by raw coordinates (see systemAlertBlocks).
    private static let uiActionMethods: Set<String> = [
        "tap", "double_tap", "long_press", "swipe", "scroll", "drag",
        "page", "page_down", "page_up", "collect",
        "scroll_to_element", "scroll_to", "tap_element",
    ]

    /// XCUIApplication.State raw values (see ForegroundApp.appStateForBundleID).
    private enum AppState: Int {
        case unknown = 0, notRunning = 1, backgroundSuspended = 2
        case background = 3, foreground = 4
    }

    /// A system alert (permission prompt, etc.) sits above the app. A ref or
    /// element interaction on the app underneath would misfire, so it is
    /// refused with guidance; a raw coordinate touch may be aimed at the
    /// alert's own button, so those go through.
    static let systemAlertHint = "A system alert (permission, network, sign-in…) is on screen over the app. " +
        "Answer it first: find_element{element_id:\"<button text>\", bundle_id:\"com.apple.springboard\"} → " +
        "tap{ref} (or tap a button's center; a coordinate tap off its buttons is refused). Ref actions on the " +
        "app underneath are refused until it is gone."

    private func systemAlertBlocks() -> JSONRPCError? {
        guard systemAlertUp() else { return nil }
        // Name it and its buttons: alerts pop up on their own (a permission
        // asked a few seconds after launch) and the caller otherwise spends a
        // read just to learn what to tap.
        let buttons = alertButtons().map { $0.label }.filter { !$0.isEmpty }
        let what = (alertTitle().map { " (\"\($0)\")" } ?? "") +
            (buttons.isEmpty ? "" : ", buttons: " + buttons.map { "'\($0)'" }.joined(separator: ", "))
        return JSONRPCError(code: -32000, message:
            "A system alert/permission dialog\(what) is on screen, covering the app. Answer it first: " +
            "find_element{element_id:\"<button text>\", bundle_id:\"com.apple.springboard\"} → tap{ref}, or tap " +
            "one of its buttons' centers. Ref/element actions on the app underneath won't work until it is gone.", data: nil)
    }

    func dispatch(method: String, params: [String: JSONValue]?) -> ([String: JSONValue]?, JSONRPCError?) {
        let cmd = ActionCommand(method: method, params: params)
        readFrame = nil
        if let t = cmd.elementType, let raws = Self.typeFilterRaws(t), raws.isEmpty {
            return (nil, JSONRPCError(code: -32602, message:
                "Unknown element_type '\(t)'. Use a type name as page_source prints it — e.g. Button, StaticText, " +
                "TextField (also matches SearchField/SecureTextField), SearchField, Cell, Image, Switch, Link, " +
                "TextView — or leave element_type out.", data: nil))
        }
        fastHandler.lastTouchPoint = nil
        tapTargetFrame = nil
        pageKeyboardTop = nil

        if Self.uiActionMethods.contains(method), cmd.bundleId == nil {
            let coordinateBased = (cmd.x != nil && cmd.y != nil) || (cmd.fromX != nil && cmd.fromY != nil)
                || ContinuousDragPath.startPoint(cmd.dragPathParams) != nil
            // A ref into SpringBoard is the alert's own button (find_element
            // with bundle_id springboard hands those out): refusing it "because
            // an alert is up" made the alert impossible to answer by ref.
            let targetsSystem = cmd.ref.flatMap { refStore[$0]?.bundleId } == "com.apple.springboard"
            if !coordinateBased, !targetsSystem, let err = systemAlertBlocks() { return (nil, err) }
            if targetsSystem, let r = cmd.ref, let was = refAlertTitle[r], let now = alertTitle(), now != was {
                return (nil, JSONRPCError(code: -32602, message:
                    "The alert changed since \(r) was found: it was \"\(was)\", now it is \"\(now)\". Not tapped — the " +
                    "same button label on the new alert may mean something else. Read the new alert and find its button again.",
                    data: nil))
            }
        }

        // A drag on an anti-bot slider is an attempt to solve it: refused.
        if ["swipe", "drag", "scroll"].contains(method), let c = lastChallenge, nowMonotonic - c.at < 120,
           c.bid == resolveForegroundBundleId() {
            let start = ContinuousDragPath.startPoint(cmd.dragPathParams)
                ?? cmd.fromX.flatMap { x in cmd.fromY.map { CGPoint(x: x, y: $0) } }
                ?? cmd.x.flatMap { x in cmd.y.map { CGPoint(x: x, y: $0) } }
                ?? CGPoint(x: pointSize.width / 2, y: pointSize.height / 2)
            if c.area.contains(start) {
                iCTRLUITests.logBuffer.append("🛑 \(method) refused: it starts on an anti-bot check")
                return (nil, JSONRPCError(code: -32602, message:
                    "Not done: this \(method) starts on the anti-bot check read moments ago (slider / puzzle). iCTRL " +
                    "doesn't solve verification. Close it (its 关闭 / ×), back out, or stop and report the step as blocked " +
                    "by verification.", data: nil))
            }
        }

        // Settle check: a frame before the action, then watch until the
        // screen stops reacting, so the caller can read right away instead of
        // sleeping a guessed delay. On by default — callers that most need it
        // are the ones that never pass options.
        let dispatchStart = nowMonotonic
        let settleOn = Self.settleMethods.contains(method) && cmd.settle != false
        // Aimed by coordinates or at the focused field: it lands on whatever is
        // there now, which may not be what the caller last saw.
        let blind = Self.blindActionMethods.contains(method)
            && cmd.ref == nil && cmd.fromRef == nil && cmd.toRef == nil
            && (method == "type" || method == "clear_text" || (cmd.x != nil && cmd.y != nil) || cmd.fromX != nil || cmd.dragPathParams != nil)
        // A tap keeps the pre-action capture: if the coarse frames say nothing
        // changed, the area around where the finger landed (known only after
        // a ref resolves) gets one fine look.
        var imageBefore: UIImage?
        let baseline: ScreenSettle.Frame?
        if settleOn, Self.pointTapMethods.contains(method), let img = iCTRLUITests.captureFrame() {
            baseline = ScreenSettle.frame(from: img)
            imageBefore = img
        } else {
            baseline = (settleOn || (blind && lastSeen != nil)) ? ScreenSettle.sample() : nil
        }
        // A deep link is meant to switch apps and names where it landed; while
        // an app launches each of these process queries costs a noticeable delay.
        let pidBefore = settleOn && !Self.switchingMethods.contains(method) ? ForegroundApp.frontmostPID() : 0
        // An alert puts SpringBoard's pid in front; answering it hands the
        // front back to the app — that's not the action switching apps.
        let alertBefore = pidBefore > 0 && systemAlertUp()
        let pageCheck = blind ? samePageCheck(before: baseline, typing: method == "type" || method == "clear_text") : nil

        readLaps = []
        var result = dispatchInner(method: method, cmd: cmd)
        if !readLaps.isEmpty { iCTRLUITests.logBuffer.append("🐢 \(method) slow parts: " + readLaps.joined(separator: " ")) }

        if settleOn, result.1 == nil, var data = result.0 {
            // Stay well inside the 6s call limit: a long type or a slow drag
            // leaves less room, and too little room means no check at all.
            let room = Self.settleCallBudget - (nowMonotonic - dispatchStart)
            // A learned slow app gets the room its learned windows need.
            let learnedNeed = resolveForegroundBundleId().map {
                max(lateReactQuiet[$0] ?? 0, (lateLoaderWatch[$0] ?? 0) + 0.6) + 0.3
            } ?? 0
            let budget = min(max(cmd.settleTimeout ?? max(Self.settleDefaultTimeout, learnedNeed), 0),
                             Self.settleMaxTimeout, room)
            iCTRLUITests.logBuffer.append(String(format: "🧘 settle %@ start: budget %.0fms, call at %.0fms",
                                                 method, budget * 1000, (nowMonotonic - dispatchStart) * 1000))
            if budget >= 0.3 {
                // A tap aimed at a control should make something happen, and
                // some apps start late: give those the longer quiet window.
                let hitControl: Bool = {
                    if method == "tap_element" || method == "find_and_tap" { return true }
                    if ["tap", "double_tap", "long_press"].contains(method) {
                        if cmd.ref != nil { return true }
                        if case .object? = data["hit"] { return true }
                    }
                    return false
                }()
                let settleBid = resolveForegroundBundleId()
                let baseQuiet = hitControl ? ScreenSettle.quietWindowForControls : ScreenSettle.quietWindow
                // What moved between the caller's last look and the moment
                // before this action is the screen's own animation.
                let ambientOnly: [Bool]? = {
                    guard let seen = lastSeen, let base = baseline, nowMonotonic - seen.at < 15 else { return nil }
                    let m = ScreenSettle.changedCells(seen.frame, base)
                    let share = Double(m.filter { $0 }.count) / Double(m.count)
                    // Small only: carousels and rotating placeholders are. A
                    // dialog that animated in after the last read is bigger,
                    // and masking it would hide its own dismissal (a consent tap
                    // that moved the app on would read as "no change").
                    return share > 0 && share < 0.1 ? m : nil
                }()
                // A Picture-in-Picture video floats over every app and changes
                // every frame: unmasked, every no-op tap would read "changed".
                // Its window is SpringBoard's.
                let ambient: [Bool]? = {
                    guard let pip = pipWindowFrame() else { return ambientOnly }
                    let m = ScreenSettle.cells(covering: [pip.insetBy(dx: -4, dy: -4)], screen: pointSize.size)
                    guard let a = ambientOnly else { return m }
                    return zip(a, m).map { $0 || $1 }
                }()
                var s = ScreenSettle.wait(baseline: baseline, budget: budget,
                                          quiet: max(baseQuiet, settleBid.flatMap { lateReactQuiet[$0] } ?? 0),
                                          focus: fastHandler.lastTouchPoint, screen: pointSize.size,
                                          newScreenWatch: settleBid.flatMap { lateLoaderWatch[$0] } ?? ScreenSettle.newScreenWatch,
                                          ignore: ambient)
                // The coarse grid saw nothing: one fine look around the tap
                // (~0.1s, only on this path).
                if s.stable, s.changed == false, let p = fastHandler.lastTouchPoint, let shot = imageBefore,
                   case let area = fineLookArea(point: p, element: tapTargetFrame),
                   let before = ScreenSettle.patch(from: shot, in: area, screen: pointSize.size),
                   let img = iCTRLUITests.captureFrame(),
                   let after = ScreenSettle.patch(from: img, in: area, screen: pointSize.size),
                   ScreenSettle.patchChanged(before, after) {
                    s.changed = true
                    s.nearTap = true
                    s.last = ScreenSettle.frame(from: img) ?? s.last
                    iCTRLUITests.logBuffer.append("🔬 settle: small change near the tap (fine look)")
                }
                imageBefore = nil
                // Watched too briefly to settle and nothing moved yet: that is
                // "don't know", not "no change" — a slow ref tap can leave about a
                // second to watch, and the screen may still navigate after it.
                let unknown = !s.stable && s.changed == false
                if unknown { s.changed = nil }
                // A new page or a launching app is when permission alerts
                // come — often 1–4s later, after this call returned. Look
                // for one on every call for a few seconds.
                if s.newScreen { alertWatchUntil = nowMonotonic + Self.alertWatchSeconds }
                if let last = s.last {
                    noteSeen(last)
                    // The home screen isn't a page that loads; paging its icons
                    // read as "late content" and taught a wrong watch.
                    if s.stable, s.changed == true, let bid = settleBid, bid != "com.apple.springboard" {
                        lastSettle = (bid, last, nowMonotonic)
                    }
                    lastNoChange = nil
                    if s.stable, s.changed == false, let bid = settleBid, bid != "com.apple.springboard" {
                        lastNoChange = (bid, last, nowMonotonic, baseQuiet)
                    }
                }
                // "Nothing labelled there" is moot once the screen reacted: an
                // unlabelled back button or list row was hit, and the warning
                // would send callers to re-check a tap that worked.
                if s.changed == true { data["hit_warning"] = nil }
                // A scroll's `moved` comes from a capped tree fingerprint; a big
                // container (a calendar's 60+ day cells) can be cut off so the
                // fingerprint looks unchanged while the screen visibly scrolled
                // (reporting moved:false, at_end:true mid-list). The pixels win.
                // With a keyboard up before the action, the pixels can't
                // tell: closing it moves the screen (and the search field with
                // it) without scrolling anything. The tree comparison decides.
                let keyboardWasUp = pageKeyboardTop != nil
                // The content, not just anything, must have changed: at the
                // end of a feed a rotating search placeholder and a playing
                // video card would otherwise read as "moved" page after page.
                let contentScrolled = s.changed == true && {
                    guard let b = baseline, let l = s.last else { return true }
                    return ScreenSettle.contentDiff(b, l) >= ScreenSettle.scrolledShare
                }()
                if contentScrolled, !keyboardWasUp, case .bool(false)? = data["moved"] {
                    data["moved"] = .bool(true)
                    data["at_end"] = nil
                    data["moved_by"] = .string("screen")
                    data["hint"] = nil   // scrollOutcome's "did not change — at the end"
                }
                if s.changed == true, keyboardWasUp, case .bool(false)? = data["moved"] {
                    data["keyboard_closed"] = .bool(true)
                    data["at_end"] = nil
                    data["hint"] = .string("Only the keyboard closed; the content did not scroll. Page again to scroll it.")
                }
                // Nothing on screen moved, so nothing scrolled — whatever the
                // tree says (a label that changes on its own, a lazy list).
                if s.stable, s.changed == false, case .bool(true)? = data["moved"] {
                    data["moved"] = .bool(false)
                    data["at_end"] = .bool(true)
                    data["moved_by"] = .string("screen")
                    data["hint"] = .string("The content did not move — you are most likely at the end in this " +
                        "direction (or the page can't scroll). If it was still loading, read again before concluding that.")
                }
                // "At the end" is wrong when a login wall or dialog covers the
                // page: the list behind it can't scroll, so every page would
                // report the end.
                if method.hasPrefix("page"), case .bool(true)? = data["at_end"], let cover = coveringLayer() {
                    data["at_end"] = nil
                    data["covered"] = .bool(true)
                    data["hint"] = .string("Nothing scrolled because \(cover) covers the page — this is not the end of " +
                        "the content. Close it (or log in, if the task allows) and page again.")
                }
                data["settle"] = s.json
                iCTRLUITests.logBuffer.append("🧘 settle \(method) stable=\(s.stable) changed=\(s.changed.map(String.init) ?? "?") " +
                                              "\(s.waitedMs)ms/\(s.samples) frames last=\(String(format: "%.1f", s.lastDiff * 100))% " +
                                              "first=\(s.firstChangeMs.map { "\($0)ms" } ?? "-")")
                // Said in `hint`, which callers already read: whether they can
                // read now or should look again. Prepended, so it comes first.
                let settleHint: String
                if unknown {
                    settleHint = "The action left only \(s.waitedMs)ms to watch the screen and nothing had changed " +
                        "yet — it may still react. Read before deciding it missed, and don't repeat it blindly."
                } else if !s.stable, budget < 1.2 {
                    // The action itself (several drags) used most of the call:
                    // too short a look to say it is still moving (a multi-screen page
                    // can read "still changing" while the next read is already final).
                    settleHint = "The action left only \(s.waitedMs)ms to watch the screen, too short to confirm it " +
                        "settled. Read it now; it is usually final."
                } else if !s.stable {
                    settleHint = "Screen still changing after \(s.waitedMs)ms (long transition, loading or animation): " +
                        "read it now; if it shows the old or a loading screen, read again."
                } else if s.changed == false {
                    // Some apps start reacting only after ~1s (e.g. a sheet that opens
                    // late), past the quiet window — so "no change" can be "not
                    // yet". One more read tells them apart; a repeat may not.
                    settleHint = "No visible change within \(s.waitedMs)ms. Some apps react late: read once more " +
                        "before concluding the action missed — and before repeating it."
                } else if s.nearTap {
                    settleHint = "Screen has settled — only a small change near the tap point (a checkmark, a " +
                        "counter, a toggle): the tap registered. Read it now; don't repeat it."
                } else if s.motion {
                    settleHint = "Screen has settled around continuous motion (a video playing) — read it now; " +
                        "the moving area will keep changing."
                } else {
                    settleHint = "Screen has settled — read it now; no need to wait."
                }
                if case .string(let old)? = data["hint"] {
                    data["hint"] = .string(settleHint + " " + old)
                } else {
                    data["hint"] = .string(settleHint)
                }
                // A permission or system alert raised by this action sits in
                // SpringBoard, so a plain read of the app doesn't show it and
                // the next ref action is refused. Say so now. Only checked
                // when the screen changed: an alert can't appear unseen.
                if s.changed == true, systemAlertUp(precise: true) { flagAlert(&data) }
                result = (data, nil)
            }
        }
        // The action took the caller to another app (a banner, a deep link,
        // a "turn on notifications" button opening Settings): say so, or the
        // next calls act on an app they don't know is in front.
        if settleOn, pidBefore > 0, !alertBefore, var data = result.0 {
            let pidAfter = ForegroundApp.frontmostPID()
            if pidAfter > 0, pidAfter != pidBefore, pidAfter != springboardPID || !systemAlertUp() {
                let now = resolveForegroundBundleId() ?? "another app"
                data["app_switched_to"] = .string(now)
                let old: String
                if case .string(let h)? = data["hint"] { old = " " + h } else { old = "" }
                data["hint"] = .string("This action switched apps: \(now) is in front now (a link, banner or button " +
                    "opened it). Read before going on; activate_app returns to the previous app." + old)
                result = (data, result.1)
            }
        }

        // After the settle hint, so this one — the more important — reads first.
        if let check = pageCheck, var data = result.0 {
            data["page_check"] = check.json
            if !check.same {
                let hint = "Heads-up: this acted on a screen that differs from what you last saw (" + check.why +
                    "). Check the result before going on, and correct course if it hit the wrong thing."
                if case .string(let old)? = data["hint"] { data["hint"] = .string(hint + " " + old) }
                else { data["hint"] = .string(hint) }
            }
            result = (data, result.1)
        }

        // A read of the app doesn't show a system alert over it (the alert
        // lives in SpringBoard), and callers then act on a screen they can't
        // see. Say it's there.
        if Self.alertCheckedReads.contains(method), cmd.bundleId != "com.apple.springboard",
           result.1 == nil, var data = result.0, timedAlertCheck() {
            flagAlert(&data)
            result = (data, nil)
        }

        // "No visible change", yet the next read shows one: this app reacts
        // late (a sheet, an error page or an alert ~1s after the tap).
        // Lengthen its quiet window, and tell the reader the last action
        // did take effect.
        if Self.seenOnRead.contains(method), result.1 == nil, var data = result.0,
           let quiet = lastNoChange, nowMonotonic - quiet.at < 10,
           let frame = readFrame ?? ScreenSettle.sample(),
           quiet.bid == resolveForegroundBundleId(),
           ScreenSettle.diff(quiet.frame, frame) >= 0.1 {
            let learned = min(2.5, max(lateReactQuiet[quiet.bid] ?? quiet.base, quiet.base) + 0.5)
            lateReactQuiet[quiet.bid] = learned
            lastNoChange = nil
            iCTRLUITests.logBuffer.append("🐢 \(quiet.bid) reacts late — quiet window now \(learned)s")
            let old: String
            if case .string(let h)? = data["hint"] { old = " " + h } else { old = "" }
            data["hint"] = .string("The screen changed after your last action reported \"no visible change\" — it " +
                "did take effect, just late. Don't repeat it. iCTRL now waits longer for this app's reactions." + old)
            result = (data, nil)
        }

        // The screen moved on after settle called it stable: this app draws
        // a skeleton or spinner first and its content arrives late (taps
        // settle on grey placeholders). Watch its new screens longer from
        // now on, and tell this reader to look again.
        if Self.seenOnRead.contains(method), result.1 == nil, var data = result.0,
           let settled = lastSettle, nowMonotonic - settled.at < 10,
           let frame = readFrame ?? ScreenSettle.sample(),
           settled.bid == resolveForegroundBundleId(),
           ScreenSettle.diff(settled.frame, frame) >= 0.25 {
            let watch = min(2.0, (lateLoaderWatch[settled.bid] ?? ScreenSettle.newScreenWatch) + 0.5)
            lateLoaderWatch[settled.bid] = watch
            lastSettle = nil
            iCTRLUITests.logBuffer.append("📈 \(settled.bid) loads late — new-screen watch now \(watch)s")
            let old: String
            if case .string(let h)? = data["hint"] { old = " " + h } else { old = "" }
            data["hint"] = .string("This screen kept changing after the last action reported it settled (content " +
                "loading late); this read is newer than that verdict. iCTRL now waits longer on this app's new screens." + old)
            result = (data, nil)
        }

        // Reads show the caller the screen: remember what it looked like —
        // from the read's own capture when it took one.
        if Self.seenOnRead.contains(method), result.1 == nil, let frame = readFrame ?? ScreenSettle.sample() {
            noteSeen(frame)
        }
        return result
    }

    /// Set by a read that captured the screen anyway (screenshot, OCR), so
    /// recording what the caller saw costs no second capture.
    private var readFrame: ScreenSettle.Frame?
    /// The last settled navigation, to notice an app whose content lands
    /// after settle said stable.
    private var lastSettle: (bid: String, frame: ScreenSettle.Frame, at: TimeInterval)?
    /// Per app, how long to keep watching a new screen (learned, ≤2s).
    private var lateLoaderWatch: [String: Double] = [:]
    /// The last action settle saw no change for, and the quiet window it had.
    private var lastNoChange: (bid: String, frame: ScreenSettle.Frame, at: TimeInterval, base: Double)?
    /// Per app, a learned (longer) quiet window for late reactions, ≤2.5s.
    private var lateReactQuiet: [String: Double] = [:]

    // MARK: - "Is this still the page the caller saw?"

    /// The screen as the caller last saw it: at their last read, or as the
    /// last action left it. Compared before a blind action so the reply can
    /// say the screen had changed underneath — not to refuse anything.
    private var lastSeen: (frame: ScreenSettle.Frame, pid: pid_t, at: TimeInterval)?
    private static let seenOnRead: Set<String> = ["page_source", "screen_text", "screenshot", "collect"]
    private static let alertCheckedReads: Set<String> = ["page_source", "screen_text", "find_element", "collect"]

    /// Whether a system alert is up. A system alert puts SpringBoard's
    /// pid in front, so that cheap check gates the real one — a walk of
    /// SpringBoard that can take seconds on a busy phone, and would
    /// otherwise be paid on every read and changed-screen action.
    /// The buttons of the system alert on screen, from a capped SpringBoard walk.
    private func alertButtons() -> [(label: String, frame: CGRect)] {
        guard let root = ForegroundApp.boundedSnapshot(forBundleID: "com.apple.springboard",
                                                       maxDepth: Self.defaultMaxDepth, maxChildren: 50) else { return [] }
        var n = 0
        var t: ObjCBool = false
        guard let body = ForegroundApp.renderBoundedSnapshot(
                root, maxDepth: Self.defaultMaxDepth, maxElements: 600,
                visibleRect: CGRect(x: 0, y: 0, width: pointSize.width, height: pointSize.height),
                nodesWritten: &n, truncated: &t) else { return [] }
        var out: [(String, CGRect)] = []
        var alertIndent: Int?
        for line in body.split(separator: "\n") {
            let indent = line.prefix { $0 == " " }.count
            let text = line.dropFirst(indent)
            if let ai = alertIndent, indent <= ai { alertIndent = nil }
            if text.hasPrefix("Alert,") { alertIndent = indent; continue }
            guard alertIndent != nil, text.hasPrefix("Button,"),
                  let r = line.range(of: "{{"),
                  let end = line.range(of: "}}", range: r.lowerBound..<line.endIndex) else { continue }
            let v = line[r.lowerBound..<end.upperBound]
                .split(whereSeparator: { !"-0123456789.".contains($0) }).compactMap { Double($0) }
            guard v.count >= 4, v[2] > 0, v[3] > 0 else { continue }
            var label = ""
            if let lr = line.range(of: ", label: '") {
                let rest = line[lr.upperBound...]
                if let le = rest.range(of: "'") { label = String(rest[..<le.lowerBound]) }
            }
            out.append((label, CGRect(x: v[0], y: v[1], width: v[2], height: v[3])))
        }
        return out
    }

    /// The title of the system alert on screen (e.g. "Allow “App” to Use
    /// Wireless Data?"), so the caller knows whose alert it is — it may
    /// belong to another app, such as a background install.
    private func alertTitle() -> String? {
        guard let root = ForegroundApp.boundedSnapshot(forBundleID: "com.apple.springboard",
                                                       maxDepth: 6, maxChildren: 50) else { return nil }
        var n = 0
        var t: ObjCBool = false
        guard let body = ForegroundApp.renderBoundedSnapshot(root, maxDepth: 6, maxElements: 200,
                                                             nodesWritten: &n, truncated: &t) else { return nil }
        // Alerts stack (tracking, then notifications…): the LAST in the tree
        // is the one on top, the one a tap would answer. Taking the first
        // would name a covered alert.
        var title: String?
        for line in body.split(separator: "\n") where line.drop(while: { $0 == " " }).hasPrefix("Alert,") {
            if let r = line.range(of: ", label: '") {
                let rest = line[r.upperBound...]
                if let e = rest.range(of: "'") { title = String(rest[..<e.lowerBound]) }
            }
        }
        return title
    }

    private func flagAlert(_ data: inout [String: JSONValue]) {
        data["system_alert"] = .bool(true)
        let title = alertTitle()
        if let title = title { data["system_alert_title"] = .string(title) }
        let old: String
        if case .string(let h)? = data["hint"] { old = " " + h } else { old = "" }
        data["hint"] = .string((title.map { "System alert: \"\($0)\". " } ?? "") + Self.systemAlertHint + old)
    }

    /// `precise`: always walk SpringBoard. Some alerts (tracking, local
    /// network) leave the app's pid in front, so the pid gate misses
    /// them; reads and changed-screen actions pay the walk.
    private func systemAlertUp(precise: Bool = false) -> Bool {
        if !precise, nowMonotonic >= alertWatchUntil {
            if springboardPID == 0 { springboardPID = ForegroundApp.processID(forBundleID: "com.apple.springboard") }
            let front = ForegroundApp.frontmostPID()
            if springboardPID > 0, front > 0, front != springboardPID { return false }
        }
        return Self.springboardHasAlert()
    }

    /// One capped request instead of XCTest's live `alerts.count`, which
    /// walks all of SpringBoard — home-screen icons included, ~0.7s, twice
    /// per action on the home screen. An alert sits ~3 levels down.
    static func springboardHasAlert() -> Bool {
        let t0 = ProcessInfo.processInfo.systemUptime
        guard let root = ForegroundApp.boundedSnapshot(forBundleID: "com.apple.springboard",
                                                       maxDepth: 5, maxChildren: 30) else {
            let r = ForegroundApp.hasSystemAlert()
            iCTRLUITests.logBuffer.append(String(format: "🐌 alert check fell back to the full query (%.0fms)",
                                                 (ProcessInfo.processInfo.systemUptime - t0) * 1000))
            return r
        }
        var n = 0
        var t: ObjCBool = false
        guard let body = ForegroundApp.renderBoundedSnapshot(root, maxDepth: 5, maxElements: 300,
                                                             nodesWritten: &n, truncated: &t) else {
            return ForegroundApp.hasSystemAlert()
        }
        return body.split(separator: "\n").contains { $0.drop(while: { $0 == " " }).hasPrefix("Alert,") }
    }
    private func timedAlertCheck() -> Bool {
        let t = nowMonotonic
        let r = systemAlertUp(precise: true)
        iCTRLUITests.logBuffer.append(String(format: "🚨 alert check %.0fms → %@", (nowMonotonic - t) * 1000, r ? "yes" : "no"))
        return r
    }
    private static let switchingMethods: Set<String> = ["open_url", "open"]
    /// A coordinate tap with an alert up must land on one of its buttons.
    /// A guess aimed from a screenshot a few points off "Allow" can hit the
    /// alert's title with no warning — a little further and it grants tracking.
    private func offAlertButtons(x: Double, y: Double) -> JSONRPCError? {
        let buttons = alertButtons()
        guard !buttons.isEmpty, !buttons.contains(where: { $0.frame.contains(CGPoint(x: x, y: y)) }) else { return nil }
        let list = buttons.map { "'\($0.label)' at (\(Int($0.frame.midX)),\(Int($0.frame.midY)))" }
            .joined(separator: ", ")
        return JSONRPCError(code: -32602, message:
            "A system alert is up and (\(Int(x)),\(Int(y))) is on none of its buttons — not tapped, so a " +
            "near-miss can't press the wrong one. Its buttons: \(list). Tap one of those centers, or use " +
            "find_element{element_id:\"<button>\", bundle_id:\"com.apple.springboard\"} → tap{ref}.", data: nil)
    }

    /// Right before the touch, while late alerts are expected (after a
    /// launch or a new page): the check at the start of the call can be up to
    /// ~0.7s old by then (the hit probe, a ref resolving), and an alert that
    /// comes up in between would take the touch.
    /// Without a point (an element tap) any alert stops it; with one, only a
    /// point off the alert's buttons does.
    private func alertRaisedBeforeTouch(x: Double? = nil, y: Double? = nil) -> JSONRPCError? {
        guard nowMonotonic < alertWatchUntil, Self.springboardHasAlert() else { return nil }
        iCTRLUITests.logBuffer.append("🚨 alert came up just before the touch — not tapped")
        if let x = x, let y = y { return offAlertButtons(x: x, y: y) }
        let title = alertTitle().map { " (\"\($0)\")" } ?? ""
        return JSONRPCError(code: -32000, message:
            "A system alert\(title) came up just before this tap, so it was not tapped: it would have landed on the " +
            "alert, not on the app. Answer it first: find_element{element_id:\"<button text>\", " +
            "bundle_id:\"com.apple.springboard\"} → tap{ref}.", data: nil)
    }

    /// The element a ref/find tap aimed at, for the fine look.
    private var tapTargetFrame: CGRect?
    /// Where to look closely after a tap: ±120pt around a coordinate tap; for
    /// a tapped element its own frame plus a margin — a row's checkmark sits
    /// at its right edge, ~150pt from the centre a ref tap lands on.
    private func fineLookArea(point p: CGPoint, element: CGRect?) -> CGRect {
        let r = ScreenSettle.patchRadius
        let around = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        guard let f = element, f.width * f.height <= pointSize.width * pointSize.height * 0.5 else { return around }
        return f.insetBy(dx: -24, dy: -24)
    }
    private static let pointTapMethods: Set<String> = ["tap", "double_tap", "long_press", "tap_element", "find_and_tap"]
    /// Until then every alert check walks SpringBoard instead of trusting the
    /// front pid: set after a launch or a new page, when late permission
    /// alerts (tracking leaves the app's pid in front) show up.
    private var alertWatchUntil: TimeInterval = 0
    private static let alertWatchSeconds = 5.0
    /// Actions aimed by coordinates or at the focused field, not at an element.
    private static let blindActionMethods: Set<String> = [
        "tap", "double_tap", "long_press", "swipe", "drag", "type", "clear_text",
    ]
    /// Share of the screen that must differ to call it another page: a
    /// playing video or a new badge stays well under it, a navigation, sheet
    /// or app switch well over it.
    private static let otherPageShare = 0.25

    private func noteSeen(_ frame: ScreenSettle.Frame) {
        lastSeen = (frame, ForegroundApp.frontmostPID(), nowMonotonic)
    }

    private struct PageCheck {
        let same: Bool
        let why: String
        let changedPct: Double
        let appChanged: Bool
        let seenAgoMs: Int
        var json: JSONValue {
            .object([
                "same_page": .bool(same),
                "changed_pct": .double((changedPct * 1000).rounded() / 10),
                "app_changed": .bool(appChanged),
                "seen_ms_ago": .int(seenAgoMs),
                // Read as "after the action" it looked stale (same_page:true on
                // a type that then navigated). It is about where the action
                // landed, so say so.
                "compares": .string("the screen just before this action vs. what you last saw"),
            ])
        }
    }

    private func samePageCheck(before: ScreenSettle.Frame?, typing: Bool = false) -> PageCheck? {
        guard let seen = lastSeen, let now = before else { return nil }
        let pid = ForegroundApp.frontmostPID()
        let appChanged = pid > 0 && seen.pid > 0 && pid != seen.pid
        // Typing follows the tap that raised the keyboard, which covers the
        // bottom ~40%: compared whole, that reads as a different page.
        // Compare what the keyboard can't cover.
        let d = ScreenSettle.diff(seen.frame, now, topShare: typing ? 0.55 : 1)
        let same = !appChanged && d < Self.otherPageShare
        let why = appChanged ? "another app or the home screen is in front now"
            : "\(Int(d * 100))% of the screen is different"
        return PageCheck(same: same, why: why, changedPct: d, appChanged: appChanged,
                         seenAgoMs: Int((nowMonotonic - seen.at) * 1000))
    }

    /// Actions followed by a settle check (see ScreenSettle).
    private static let settleMethods: Set<String> = [
        "tap", "double_tap", "long_press", "swipe", "scroll", "drag",
        "page", "page_down", "page_up", "type", "clear_text",
        "tap_element", "find_and_tap",
        // A deep link lands on a page that is still loading (a maps route
        // can read "no info available" on the first look).
        "open_url", "open",
    ]
    private static let settleDefaultTimeout = 2.0
    private static let settleMaxTimeout = 3.0
    /// The whole call — action plus settle — ends by this, under the 6s limit.
    private static let settleCallBudget = 4.3

    private func dispatchInner(method: String, cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        switch method {
        case "device_info":
            return deviceInfo()
        case "screenshot":
            return screenshot(cmd)
        case "tap":
            return tap(cmd)
        case "double_tap":
            return doubleTap(cmd)
        case "long_press":
            return longPress(cmd)
        case "swipe":
            return swipe(cmd)
        case "page", "page_down", "page_up":
            return pageScroll(cmd, method: method)
        case "collect":
            return collect(cmd)
        case "scroll":
            return scroll(cmd)
        case "type":
            return typeText(cmd)
        case "clear_text":
            return clearText(cmd)
        case "home":
            return pressHome()
        case "lock":
            return lock()
        case "unlock":
            return unlock()
        case "is_locked":
            return isLocked()
        case "logs", "recent_logs":
            // An RPC, not just the GET /logs byte stream. The timeout messages
            // tell a caller to "check the logs to see whether the action
            // actually landed" — but /logs needs a stream_ticket minted over
            // this very channel, so following that advice cost an extra
            // round trip plus URL assembly at exactly the wrong moment.
            // Reported as a real obstacle during a wedged session.
            let n = max(1, min(cmd.maxElements ?? 80, 500))
            let all = iCTRLUITests.logBuffer.dump().split(separator: "\n").map(String.init)
            var tail = Array(all.suffix(n))
            if let needle = cmd.text, !needle.isEmpty {
                tail = all.filter { $0.localizedCaseInsensitiveContains(needle) }.suffix(n)
            }
            return ([
                "lines": .array(tail.map { .string($0) }),
                "count": .int(tail.count),
                "total": .int(all.count),
                "hint": .string(
                    "Most recent last. After a timeout, look for '⏱ ✓ <method>' — that means the action "
                    + "COMPLETED on the device and must not be retried; '⏱ ✗' means it failed. '⏱ TIMEOUT' only means "
                    + "the reply went out before it finished — it keeps running, so wait for its '⏱ ✓' line. "
                    + "Pass text:\"<method>\" to filter, max_elements to change how many lines come back."),
            ], nil)
        case "snapshot_api":
            var out: [String: JSONValue] = [:]
            for (k, v) in ForegroundApp.snapshotAPICapabilities() {
                out[String(describing: k)] = .string(String(describing: v))
            }
            return (out, nil)
        case "reset":
            return reset()
        case "snapshot_bench":
            return snapshotBench(cmd)
        case "list_apps", "installed_apps":
            return listApps(cmd)
        case "resolve_app", "search_app", "search_apps":
            return resolveApp(cmd)
        case "open_url", "open":
            return openURL(cmd)
        case "launch_app":
            return launchApp(cmd)
        case "activate_app":
            return activateApp(cmd)
        case "terminate_app":
            return terminateApp(cmd)
        case "page_source", "view_tree", "ui_tree":
            // Right after a launch XCTest may not know the process yet ("is not
            // running" a couple of seconds after launch_app): a short retry
            // instead of an error the caller has to work around.
            var out = pageSource(cmd)
            for _ in 0..<2 {
                guard let e = out.1, e.message.hasPrefix("Could not snapshot"),
                      let at = launchedAt.values.max(), nowMonotonic - at < 10 else { break }
                iCTRLUITests.logBuffer.append("🔁 page_source: no snapshot right after a launch — retrying")
                usleep(700_000)
                out = pageSource(cmd)
            }
            return out
        case "scroll_to_element", "scroll_to":
            return scrollToElement(cmd)
        case "find_element":
            return findElementInfo(cmd)
        case "screen_text", "ocr":
            return screenText(cmd)
        case "tap_element":
            return tapElement(cmd)
        case "find_and_tap":
            return findAndTap(cmd)
        case "drag":
            return drag(cmd)
        case "wait":
            return wait(cmd)
        default:
            return (nil, Self.unknownMethodError(method))
        }
    }

    /// Every dispatchable method name, including aliases — the source of truth for
    /// "did you mean" suggestions. Keep in sync with the switch above.
    private static let knownMethods: [String] = [
        "activate_app", "clear_text", "device_info", "double_tap", "drag", "snapshot_api",
        "find_and_tap", "find_element", "home", "installed_apps", "is_locked",
        "launch_app", "list_apps", "lock", "long_press", "open", "open_url",
        "page", "page_down", "page_source", "page_up", "reset", "resolve_app",
        "screenshot", "scroll", "scroll_to", "scroll_to_element", "search_app",
        "search_apps", "snapshot_bench", "swipe", "tap", "tap_element",
        "screen_text", "ocr", "terminate_app", "type", "ui_tree", "unlock", "view_tree", "wait",
    ]

    /// Unknown method → name the closest matches and point at /schema, so a caller
    /// that guessed (`type_text` for `type`) recovers on the next call instead of
    /// guessing again.
    private static func unknownMethodError(_ attempted: String) -> JSONRPCError {
        let want = attempted.lowercased()
        // Cheap similarity: shared prefix, or one name containing the other —
        // enough to catch the realistic near-misses without a full edit distance.
        let suggestions = knownMethods.filter { known in
            known.contains(want) || want.contains(known)
                || known.prefix(4) == want.prefix(4)
        }.prefix(4)

        var message = "Method '\(attempted)' does not exist."
        if !suggestions.isEmpty {
            message += " Did you mean: \(suggestions.joined(separator: ", "))?"
        }
        message += " Next: GET /schema (unauthenticated) for the full method list with parameters" +
            " — one call, and it prevents further guessing."
        return JSONRPCError(code: -32601, message: message, data: nil)
    }

    // MARK: - Device

    /// Live system health: thermal state, memory, CPU.
    ///
    /// What iOS actually allows differs per metric, so each one reports whether
    /// it worked instead of quietly returning zero:
    ///   - thermal state and total RAM come from public ProcessInfo API;
    ///   - this process's footprint and CPU come from task/thread info, which a
    ///     sandboxed app may always read about ITSELF;
    ///   - system-wide free memory and CPU need a host port, which the sandbox
    ///     usually denies. Those keys are simply absent when denied.
    ///
    /// Relevant to this project specifically: sustained capture heats the device
    /// and iOS then throttles it, which is what drags the stream's frame rate
    /// down over minutes. `thermal_state` is the signal for that.
    private func systemMetrics() -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        let pi = ProcessInfo.processInfo

        let thermal: String
        switch pi.thermalState {
        case .nominal:  thermal = "nominal"
        case .fair:     thermal = "fair"
        case .serious:  thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        out["thermal_state"] = .string(thermal)
        out["low_power_mode"] = .bool(pi.isLowPowerModeEnabled)
        out["total_memory_mb"] = .int(Int(pi.physicalMemory / 1024 / 1024))
        out["processor_count"] = .int(pi.activeProcessorCount)

        // This process's memory footprint — the number iOS uses for jetsam.
        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size / MemoryLayout<integer_t>.size)
        let vmKR = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        if vmKR == KERN_SUCCESS {
            out["process_memory_mb"] = .int(Int(vmInfo.phys_footprint / 1024 / 1024))
        }

        // This process's CPU, summed across its threads. Can exceed 100% on
        // multiple cores.
        var threads: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        if task_threads(mach_task_self_, &threads, &threadCount) == KERN_SUCCESS, let list = threads {
            var total = 0.0
            for i in 0..<Int(threadCount) {
                var ti = thread_basic_info()
                var tc = mach_msg_type_number_t(THREAD_INFO_MAX)
                let kr = withUnsafeMutablePointer(to: &ti) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(tc)) {
                        thread_info(list[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &tc)
                    }
                }
                if kr == KERN_SUCCESS, ti.flags & TH_FLAGS_IDLE == 0 {
                    total += Double(ti.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
                }
            }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.size))
            out["process_cpu_percent"] = .double((total * 10).rounded() / 10)
        }

        // System-wide free memory. Needs a host port; absent if the sandbox says no.
        var vmStats = vm_statistics64_data_t()
        var statCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let statKR = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(statCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &statCount)
            }
        }
        if statKR == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            out["system_free_memory_mb"] = .int(Int(UInt64(vmStats.free_count) * page / 1024 / 1024))
        }

        out.merge(diskMetrics()) { a, _ in a }
        out.merge(batteryMetrics()) { a, _ in a }

        // Screen/app state. Without these a caller that gets a black screenshot or
        // a tap that "worked" but changed nothing has no way to tell a locked
        // device from a broken one, and no way to know which app it is actually
        // driving — both cost a round of blind guessing to diagnose.
        out["screen_locked"] = .bool(LockStateMonitor.shared().isLocked)
        if let fg = resolveForegroundBundleId() {
            out["foreground_app"] = .string(fg)
            if Self.webViewHostBundleIds.contains(fg) {
                out["foreground_is_browser"] = .bool(true)
            }
        }
        return out
    }

    /// Storage capacity and free space.
    ///
    /// Two different "free" numbers are reported because iOS answers the question
    /// twice. `volumeAvailableCapacityForImportantUsage` is what Settings shows
    /// and what an app can actually expect to get — it counts space iOS would
    /// reclaim by evicting purgeable caches. The raw `volumeAvailableCapacity` is
    /// usually much smaller and looks alarming without meaning anything is wrong.
    /// Reporting only one of them invites the wrong conclusion, so both ship.
    private func diskMetrics() -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return out }

        let mb = { (bytes: Int64) in Int(bytes / 1024 / 1024) }
        if let total = values.volumeTotalCapacity {
            out["disk_total_mb"] = .int(mb(Int64(total)))
        }
        // The realistic figure, and the one to compare against Settings.
        if let important = values.volumeAvailableCapacityForImportantUsage {
            out["disk_free_mb"] = .int(mb(important))
        }
        // The conservative figure: excludes anything iOS would have to purge.
        if let available = values.volumeAvailableCapacity {
            out["disk_available_now_mb"] = .int(mb(Int64(available)))
        }
        if let total = values.volumeTotalCapacity, total > 0,
           let important = values.volumeAvailableCapacityForImportantUsage {
            let usedPct = (1.0 - Double(important) / Double(total)) * 100.0
            out["disk_used_percent"] = .double((usedPct * 10).rounded() / 10)
        }
        return out
    }

    /// Battery level and charging state.
    ///
    /// Monitoring has to be enabled before iOS populates these, and it is left on
    /// afterwards: the runner is long-lived, and toggling it per call would make
    /// every reading the first one (iOS returns -1 until the first update lands).
    private func batteryMetrics() -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }

        // -1 means "not known yet" — report nothing rather than a bogus level.
        let level = device.batteryLevel
        if level >= 0 { out["battery_percent"] = .int(Int((level * 100).rounded())) }

        let state: String
        switch device.batteryState {
        case .charging: state = "charging"
        case .full:     state = "full"
        case .unplugged: state = "unplugged"
        case .unknown:  state = "unknown"
        @unknown default: state = "unknown"
        }
        if device.batteryState != .unknown { out["battery_state"] = .string(state) }
        return out
    }

    /// Drop cached automation state so the next UI call starts clean.
    ///
    /// Intended for use after the accessibility connection to the foreground app
    /// drops (`kAXErrorServerNotFound`), which otherwise leaves every UI method
    /// timing out. What this can and can't do is worth being precise about:
    ///
    /// It clears OUR state — element refs (now pointing into a dead tree), the
    /// learned front-app pids, and the cached screen size. It cannot restart XCTest's
    /// accessibility session; that belongs to the framework and has no public
    /// reset. The reconnect, if it happens, comes from the next query against a
    /// foregrounded app. So this is a cheap thing to try before the guaranteed
    /// fix (relaunch the runner via config{stop_server:true}), not a promise.
    ///
    /// Deliberately free of XCUITest calls, so it stays answerable when the UI
    /// queue is wedged — a recovery method that queues behind the fault it
    /// recovers from would be useless.
    func reset() -> ([String: JSONValue]?, JSONRPCError?) {
        let refCount = refStore.count
        refStore.removeAll()
        cachedPointSize = nil
        frontByPID.removeAll()
        lastSeen = nil

        iCTRLUITests.logBuffer.append("♻️ reset — cleared \(refCount) refs")

        // Report the foreground app so the caller can decide what to re-launch;
        // this reads a private API, not XCUITest, so it can't block.
        let foreground = resolveForegroundBundleId()
        var out: [String: JSONValue] = [
            "reset": .bool(true),
            "cleared_refs": .double(Double(refCount)),
            "hint": .string(
                "Cleared cached refs and the screen-size cache. "
                + "Re-establishing the accessibility connection is up to XCTest: call launch_app "
                + "(or activate_app) on the target app, then retry. If UI calls still time out, "
                + "the runner itself must be restarted — config{stop_server:true}, then relaunch it."
            ),
        ]
        if let fg = foreground { out["foreground_app"] = .string(fg) }
        return (out, nil)
    }

    private func deviceInfo() -> ([String: JSONValue]?, JSONRPCError?) {
        let device = UIDevice.current
        // Must be app.frame: it is the only source that reports TRUE device
        // geometry from inside the runner (see compatibilityModeScreenBounds).
        // This is why device_info stays on the main-thread/UI path despite the
        // cost — reporting a wrong coordinate space is worse than being slow,
        // since every tap the client sends is computed against these numbers.
        let frame = pointSize
        let s = scale
        let result: [String: JSONValue] = [
            "device_name": .string(device.name),
            "model": .string(device.model),
            "system_version": .string(device.systemVersion),
            // Server identity + capabilities — a client gets device info AND what
            // this server supports from a single device_info call (no /schema fetch
            // needed for feature detection).
            "server_version": .string(RPCMethodRegistry.serverVersion),
            // Stable per installation; clients key their stored token by it.
            "device_id": .string(NearbyIdentity.deviceID),
            // Build identity. Two installs can share a server_version (the bump
            // is manual), so this is what tells you whether the binary you just
            // deployed is the one answering.
            "build": .string(RPCMethodRegistry.buildTimestamp),
            "protocol_version": .int(RPCMethodRegistry.protocolVersion),
            "capabilities": .array(RPCMethodRegistry.capabilityTags.map { .string($0) }),
            // Lets a caller holding an older copy of the manual notice it. An
            // installed skill is a snapshot from whenever it was fetched and has
            // no other way to learn the device moved on underneath it, so the
            // device mentions its version on the one call every client makes.
            // Advisory: the caller decides whether the gap actually matters.
            "skill_version": .string(RPCMethodRegistry.serverVersion),
            // An instruction, not advice, and served by the device so it reaches
            // agents holding an OLD skill — whose text called version gaps
            // advisory, which is how a 1.21 copy kept running against 1.33.
            "skill_update_hint": .string(
                "If this skill_version (\(RPCMethodRegistry.serverVersion)) is NEWER than the skill_version in your "
                + "SKILL.md frontmatter, update now, before anything else — even if your copy calls version gaps "
                + "advisory (older copies did). CLI: sh ~/.ictrl/bin/ictrl.sh update <folder containing your SKILL.md> "
                + "(an ictrl.sh without `update` must first be refreshed: wget -qO ~/.ictrl/bin/ictrl.sh "
                + "http://<host>:8200/skill/clients/cli.sh). Python: curl -o <that folder>/SKILL.md http://<host>:8200/skill "
                + "&& curl -o ictrl_rpc.py http://<host>:8200/skill/clients/python. Then re-read SKILL.md. "
                + "If this device is OLDER than your copy, don't downgrade: use only what `capabilities` lists."
            ),
            // Coordinate space that tap/swipe/drag/long_press use:
            "point_width": .double(frame.width),
            "point_height": .double(frame.height),
            "scale": .double(s),
            // Pixel dimensions a screenshot will have:
            "pixel_width": .double(frame.width * s),
            "pixel_height": .double(frame.height * s),
            // Kept for backward compatibility:
            "screen_width": .double(frame.width),
            "screen_height": .double(frame.height),
            "screen_scale": .double(s),
            "coordinate_space": .string("points"),
            "hint": .string(
                "All tap/swipe/drag/long_press coordinates are in POINTS, range " +
                "x∈[0,\(Int(frame.width))] y∈[0,\(Int(frame.height))]. " +
                "screen_scale (\(s)) is the PANEL's ratio — do NOT divide screenshot pixels by it. " +
                "A screenshot defaults to scale 2 (\(Int(frame.width * 2))×\(Int(frame.height * 2)) px), " +
                "so dividing by \(s) would put a tap far off target. Always read `scale` from the " +
                "screenshot response itself and use point = pixel / that scale. " +
                "Bottom tab bars sit above the home-indicator safe area (~y \(Int(frame.height) - 60)–\(Int(frame.height) - 20))."
            ),
            // Live device health. This is the call /remote polls for its status
            // overlay, and the documented home for these metrics — they were
            // previously attached only to coordinateHint, which rides along with
            // tap/swipe responses and so never reached a plain device_info.
            "system": .object(systemMetrics()),
        ]
        return (result, nil)
    }

    private func screenshot(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        // XCUIScreen.screenshot() grabs the current frame directly and does NOT
        // wait for quiescence. Use the CACHED point size (not app.frame) so the
        // screenshot path stays fast on animation-heavy apps.
        let frame = pointSize
        let deviceScale = scale  // native pixels-per-point (e.g. 3)

        // Requested output scale (pixels-per-point): default 2, clamp to (0, 3].
        let requested = cmd.scale ?? 2.0
        let targetScale = min(max(requested, 0.05), 3.0)

        // Target selection:
        //   - explicit bundle_id → screenshot ONLY that app's window (opt-in)
        //   - otherwise → the WHOLE SCREEN (XCUIScreen) — always fast (~0.4s).
        // IMPORTANT: we DO NOT screenshot a specific app here. App-scoped
        // XCUIApplication.screenshot() can block for 8s+ while the app is in a
        // transition (page switch / loading), which blocked the main thread long
        // enough for XCTest to terminate the test (observed crash, twice).
        // XCUIScreen.screenshot() is always fast and captures whatever's on screen,
        // which is what you want by default anyway.
        var fullImage: UIImage
        let scopedTo: String?
        if let bid = cmd.bundleId, !bid.isEmpty {
            // Explicit opt-in: app-scoped, but time-bounded (fall back to the fast
            // full-screen shot if it's slow/throws/black). This is the ONLY path
            // that can be slow, and only when the caller explicitly asked for it.
            var appImage: UIImage?
            var finished = false
            let done = runWithTimeout(seconds: 3, label: "app-screenshot") {
                _ = ObjCException.catching {
                    appImage = XCUIApplication(bundleIdentifier: bid).screenshot().image
                }
                finished = true
            }
            if done, finished, let img = appImage {
                fullImage = img
                scopedTo = bid
            } else {
                fullImage = XCUIScreen.main.screenshot().image
                scopedTo = nil
                iCTRLUITests.logBuffer.append("📸 app-scoped screenshot for \(bid) slow/failed — fell back to full screen")
            }
        } else {
            fullImage = XCUIScreen.main.screenshot().image
            scopedTo = nil
        }
        if scopedTo == nil { readFrame = ScreenSettle.frame(from: fullImage) }

        // Resize on the server to targetScale so the client gets a smaller PNG.
        let targetPixelW = frame.width * targetScale
        let targetPixelH = frame.height * targetScale
        // JPEG by default. The client has to run the whole response body through
        // the envelope's HMAC keystream, so response SIZE is what dominates a
        // screenshot's end-to-end cost — a PNG of a UI screen is typically 5-10x
        // larger than a visually equivalent JPEG, and that multiplier lands
        // directly on the client's decrypt loop. PNG stays available for callers
        // that need lossless output (pixel diffing, OCR on fine text).
        let wantPNG = (cmd.format ?? "jpeg").lowercased() == "png"
        let quality = min(max(cmd.quality ?? 0.6, 0.1), 1.0)
        let targetPixels = CGSize(width: targetPixelW, height: targetPixelH)
        let imageData = wantPNG
            ? Self.encodePNG(fullImage, targetPixels: targetPixels)
            : Self.encodeJPEG(fullImage, targetPixels: targetPixels, quality: quality)
        let base64 = imageData.base64EncodedString()

        var result: [String: JSONValue] = [
            "format": .string(wantPNG ? "png" : "jpeg"),
            "encoding": .string("base64"),
            "data": .string(base64),
            "bytes": .double(Double(imageData.count)),
            // Pixel dimensions of THIS (possibly downscaled) image:
            "pixel_width": .double(targetPixelW),
            "pixel_height": .double(targetPixelH),
            // The point-space to convert INTO before tapping:
            "point_width": .double(frame.width),
            "point_height": .double(frame.height),
            "scale": .double(targetScale),
            "requested_scale": .double(requested),
            "device_scale": .double(deviceScale),
            "device_name": .string(UIDevice.current.name),
            // Kept for backward compatibility:
            "width": .double(frame.width),
            "height": .double(frame.height),
            "hint": .string(
                "This image is \(Int(targetPixelW))×\(Int(targetPixelH)) PIXELS at scale \(targetScale). " +
                "tap/swipe coordinates are in POINTS (\(Int(frame.width))×\(Int(frame.height))). " +
                "Convert a pixel location (px,py) in THIS image to a tap point with: " +
                "x = px / \(targetScale), y = py / \(targetScale)."
            ),
            // Its own field, not a clause buried in the coordinate maths above.
            // Screenshots are the most over-used tool here: a model reads one,
            // eyeballs a control, converts pixels to points and taps — and every
            // one of those steps can be wrong in a way nothing reports. Measured
            // in this project: a tap meant for a destination field landed on the
            // nav bar, and a stray tap during scrolling added a product to a
            // cart. find_element returns a ref that re-resolves the live element,
            // so it cannot drift and needs no conversion at all.
            "prefer_instead": .string(
                "DON'T tap from this image if you can avoid it. To act on a control: " +
                "find_element{element_id:\"<label>\"} → tap{ref} — a ref re-resolves the live element, " +
                "survives scrolling/animation, and skips the pixel→point conversion entirely. " +
                "To understand the layout: page_source{visible_only:true} returns every on-screen " +
                "element with its type, label and exact frame, and is usually FASTER than a screenshot " +
                "(~100ms vs ~150ms) as well as far smaller. " +
                "Screenshots earn their place when the tree can't answer you: an element with no label " +
                "(icon-only buttons, images), a layout question you can only judge visually, " +
                "verifying that an action actually landed, or when page_source comes back sparse " +
                "(check its ax_coverage / sparse_hint / viewport_warning fields) — most often a web view, " +
                "where page content never reaches the accessibility tree at all."
            ),
        ]
        if !wantPNG { result["quality"] = .double(quality) }
        if Self.isHomeScreen() { result["hint"] = .string(Self.homeScreenAdvice) }
        var out = result
        if let bid = scopedTo {
            out["scoped_to"] = .string(bid)
            out["scope"] = .string("app")
        } else {
            out["scope"] = .string("screen")
        }
        return (out, nil)
    }

    /// Render a UIImage to JPEG at the requested pixel size and quality.
    ///
    /// Shares the resize path with `encodePNG`; only the final serialization
    /// differs. `opaque = true` matters here — a screen capture has no alpha, and
    /// telling the renderer so avoids a needless alpha channel.
    private static func encodeJPEG(_ image: UIImage, targetPixels: CGSize, quality: Double) -> Data {
        let resized = resize(image, targetPixels: targetPixels)
        return resized.jpegData(compressionQuality: CGFloat(quality))
            ?? image.jpegData(compressionQuality: CGFloat(quality))
            ?? Data()
    }

    /// Downscale to an exact pixel size. Shared by the PNG and JPEG encoders.
    private static func resize(_ image: UIImage, targetPixels: CGSize) -> UIImage {
        let w = max(1, Int(targetPixels.width.rounded()))
        let h = max(1, Int(targetPixels.height.rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1               // we specify size in raw pixels
        format.opaque = true
        let size = CGSize(width: w, height: h)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// Render a UIImage to PNG at the requested pixel size (server-side downscale).
    private static func encodePNG(_ image: UIImage, targetPixels: CGSize) -> Data {
        let resized = resize(image, targetPixels: targetPixels)
        return resized.pngData() ?? image.pngData() ?? Data()
    }


    /// Why an element that exists can't be tapped, said so the caller does
    /// the right next thing. "Scroll it into view" alone is wrong for
    /// elements already on screen under a popup — it sends callers
    /// scrolling under a privacy dialog or permission alert.
    ///
    /// nil = nothing explains it: on screen, no system alert, nothing in the
    /// tree drawn over it. XCTest's isHittable then is often just wrong (it
    /// can refuse a plain back button with nothing on top; WebDriverAgent
    /// ignores it for the same reason), so callers tap the center instead of refusing.
    private func notHittableAdvice(label: String, frame f: CGRect) -> String? {
        let s = pointSize
        let onScreen = f.width > 0 && f.height > 0 && f.midX >= 0 && f.midX <= s.width
            && f.midY >= 0 && f.midY <= s.height
        let at = "(\(Int(f.midX)),\(Int(f.midY)))"
        guard onScreen else {
            return "it is off-screen at \(at). Scroll it into view (scroll_to_element), then retry."
        }
        if systemAlertUp() {
            return "it is on screen at \(at) but a system alert covers the app. " + Self.systemAlertHint
        }
        // Tree order is not z-order: a later node "over" the element may be a
        // hidden pull-to-refresh label, and refusing on it would block a plain
        // back-button tap. Tap; settle and page_check show whether it took.
        return nil
    }

    // MARK: - Tap

    /// Resolve a ref for a spatial action, returning the live element or a
    /// descriptive error. Shared by tap/double_tap/long_press.
    /// The ref's element, in view, from a capped walk of its app — or nil,
    /// and the caller takes the live route (which also explains failures).
    /// The ordinal must agree: a ref names the n-th element with its label.
    /// A capped walk can cut off earlier look-alikes and shift ordinals, so
    /// it is trusted only when it holds a single match.
    private func boundedRefHit(_ ref: ElementRef) -> LocateHit? {
        guard let bid = ref.bundleId else { return nil }
        let want: String
        let byLabel: Bool
        switch ref.match {
        case .exactLabel(let l): want = l; byLabel = true
        case .identifier(let i): want = i; byLabel = false
        case .containsLabel: return nil
        }
        func pick(_ scan: LocateScan?) -> LocateHit? {
            scan?.candidates.first {
                $0.ordinal == ref.index && $0.byLabel == byLabel && (byLabel ? $0.label : $0.identifier) == want
            }
        }
        let quick = scanCandidates(query: want, type: ref.elementType, matchMode: "exact", bundleId: bid,
                                   maxChildren: Self.childrenLadder[0])
        let same = quick?.candidates.filter { $0.byLabel == byLabel && ($0.byLabel ? $0.label : $0.identifier) == want }
        func miss(_ why: String, _ scan: LocateScan?) -> LocateHit? {
            let seen = (scan?.candidates ?? []).map { "\($0.ordinal)/\($0.byLabel ? "L" : "I")/\($0.visibility)" }
            iCTRLUITests.logBuffer.append("🎯 ref \(ref.index) '\(want)' bounded miss: \(why) [\(seen.joined(separator: " "))]")
            return nil
        }
        if same?.count == 1, let h = pick(quick) { return h.inView ? h : miss("not in view", quick) }
        // None in the capped walk: the live route (a wider walk here could
        // cost seconds on a long list, and then the live route anyway).
        guard (same?.count ?? 0) > 1 else { return miss("\(same?.count ?? -1) in capped walk", quick) }
        // Several share the label: the ref's ordinal came from find_element's
        // own capped walk, so match it in this one first. The uncapped walk can
        // take seconds on a heavy app and come back empty, turning a tab tap into a hang.
        if let h = pick(quick) { return h.inView ? h : miss("not in view", quick) }
        let full = scanCandidates(query: want, type: ref.elementType, matchMode: "exact", bundleId: bid)
        guard let h = pick(full) else { return miss("no ordinal match", full) }
        return h.inView ? h : miss("not in view", full)
    }

    private func resolveRefForAction(_ refId: String) -> (XCUIElement?, JSONRPCError?) {
        let (resolved, err) = resolveRef(refId)
        guard let el = resolved else { return (nil, err) }
        if !el.safeIsHittable, let why = notHittableAdvice(label: el.label, frame: el.frame) {
            return (nil, JSONRPCError(code: -32602, message: "Element for ref '\(refId)' can't be tapped: " + why, data: nil))
        }
        return (el, nil)
    }

    /// A small random offset (±maxJitter pt, default 3) to add to an element-tap
    /// point so successive taps don't all land on the exact same pixel — a little
    /// more human. Clamped so the point stays comfortably inside the element frame
    /// (never within 2pt of an edge), and skipped for tiny elements.
    private func humanizedPoint(in frame: CGRect, maxJitter: Double = 3.0) -> (Double, Double) {
        let cx = Double(frame.midX), cy = Double(frame.midY)
        // Keep at least a 2pt margin from each edge; if the element is too small to
        // jitter safely, just use the center.
        let jx = min(maxJitter, max(0, Double(frame.width) / 2 - 2))
        let jy = min(maxJitter, max(0, Double(frame.height) / 2 - 2))
        func rand(_ mag: Double) -> Double {
            guard mag > 0 else { return 0 }
            // Uniform in [-mag, +mag], 0.1pt resolution.
            let steps = UInt32(mag * 20) + 1              // e.g. mag=3 → 61 steps
            let v = Double(arc4random_uniform(steps)) / 10.0
            return v - mag
        }
        return (cx + rand(jx), cy + rand(jy))
    }

    private func tap(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        // A ref to a system alert's button: tap where that button is on the
        // alert up NOW. The live query can match a stale button left in
        // SpringBoard by an earlier alert at another position, and the tap
        // would miss the current alert.
        if let refId = cmd.ref, let ref = refStore[refId], ref.bundleId == "com.apple.springboard" {
            let want: String
            switch ref.match {
            case .exactLabel(let l), .containsLabel(let l), .identifier(let l): want = l
            }
            let buttons = alertButtons()
            if let b = buttons.first(where: { $0.label == want }) ?? buttons.first(where: { $0.label.contains(want) }) {
                let r = fastHandler.fastTap(x: b.frame.midX, y: b.frame.midY)
                if r.1 != nil { return r }
                return (["message": .string("Tapped ref \(refId) ('\(b.label)') at (\(Int(b.frame.midX)),\(Int(b.frame.midY)))")], nil)
            }
        }
        // A ref re-found in ONE capped walk, tapped at its frame. The live
        // route below costs ~5 whole-app walks (exists, hittable, frame,
        // label, type) — ~0.1s each on a light app, seconds each on a heavy
        // one, where a walk can also time out and be retried.
        if cmd.fast != false, let refId = cmd.ref, let ref = refStore[refId], nowMonotonic - ref.createdAt <= Self.refTTL,
           let bid = ref.bundleId, bid != "com.apple.springboard", resolveForegroundBundleId() == bid,
           let hit = boundedRefHit(ref) {
            let f = hit.frame
            let (cx, cy) = humanizedPoint(in: f)
            if let err = alertRaisedBeforeTouch() { return (nil, err) }
            if [.textField, .searchField, .secureTextField, .textView].contains(hit.elementType) {
                lastKeyboardSeen = (bid, nowMonotonic)
            }
            tapTargetFrame = f
            let r = fastHandler.fastTap(x: cx, y: cy)
            if r.1 == nil {
                return (["message": .string("Tapped ref \(refId) ('\(hit.label.isEmpty ? hit.identifier : hit.label)') at (\(Int(cx)),\(Int(cy)))")], nil)
            }
        }
        // Prefer a stable element ref if provided (re-resolves the live element).
        if let refId = cmd.ref {
            let (el, err) = resolveRefForAction(refId)
            if let err = err { return (nil, err) }
            // Resolve the element to its frame and tap by SYNTHESIZED event
            // (fastTap) instead of XCUIElement.tap(). XCUIElement.tap() does its own
            // waiting and post-event settling; when the tap navigates to a new page
            // that settling ran ~4s and coincided with the test being torn down.
            // A coordinate synthesized tap is fast (<1s) and doesn't wait.
            // Land a few pt off-center (within the element) so taps look less robotic.
            let f = el!.frame
            let label = el!.label
            let (cx, cy) = humanizedPoint(in: f)
            if refStore[refId]?.bundleId != "com.apple.springboard", let err = alertRaisedBeforeTouch() { return (nil, err) }
            if [.textField, .searchField, .secureTextField, .textView].contains(el!.elementType),
               let bid = refStore[refId]?.bundleId ?? resolveForegroundBundleId() {
                lastKeyboardSeen = (bid, nowMonotonic)   // its keyboard comes up: page must stay above it
            }
            tapTargetFrame = f
            let r = fastHandler.fastTap(x: cx, y: cy)
            if r.1 != nil {
                // Fallback to element tap only if the synthesized tap failed.
                el!.tap()
            }
            return (["message": .string("Tapped ref \(refId) ('\(label)') at (\(Int(cx)),\(Int(cy)))")], nil)
        }

        guard let x = cmd.x, let y = cmd.y else {
            return (nil, JSONRPCError(code: -32602, message: "tap requires x and y (in points), or a 'ref' from find_element/scroll_to_element", data: nil))
        }
        if let err = validateCoordinate(x: x, y: y, context: "tap") { return (nil, err) }

        // Fast (event synthesis) is the DEFAULT — it doesn't wait for UI quiescence,
        // which on animation-heavy apps could block for up to 60s. Pass fast:false
        // only if you specifically need XCUITest's element-aware tap.
        // Off every button of a system alert: refuse and say where they are.
        if systemAlertUp(), let err = offAlertButtons(x: x, y: y) { return (nil, err) }

        if cmd.fast != false {
            // Sample what sits under the point BEFORE tapping: afterwards the UI
            // may have moved (a keyboard appearing shifts everything up), so a
            // post-tap probe would describe the new layout, not what was hit.
            let hit = elementUnder(x: x, y: y)
            if let err = alertRaisedBeforeTouch(x: x, y: y) { return (nil, err) }
            var r = fastHandler.fastTap(x: x, y: y)
            if var data = r.0 {
                if var h = hit {
                    if case .string(let note)? = h.removeValue(forKey: "note") { data["hint"] = .string(note) }
                    if case .string(let t)? = h["element_type"], ["TextField", "SearchField", "SecureTextField", "TextView"].contains(t),
                       let bid = resolveForegroundBundleId() {
                        lastKeyboardSeen = (bid, nowMonotonic)
                    }
                    data["hit"] = .object(h)
                } else if hitSkipped {
                    data["hit_skipped"] = .string("This app's accessibility tree is very slow right now, so what " +
                        "sits under the point wasn't checked. Confirm the result with a screenshot.")
                } else {
                    // Nothing interactive there. The synthesized event still
                    // "succeeds" — iOS delivers it to empty space — so without
                    // this the caller sees success and only finds out from a
                    // screenshot that the keyboard never appeared.
                    data["hit_warning"] = .string(
                        "No labelled element at (\(Int(x)),\(Int(y))) — an unlabelled control, content not in the "
                        + "accessibility tree (web, custom-drawn — expected if you aimed from OCR), or empty space. "
                        + "The screen didn't visibly react, so confirm with a fresh read. Coordinates also go "
                        + "stale when the layout shifts (a keyboard appearing moves everything up).")
                }
                if Self.isHomeScreen() { data["hint"] = .string(Self.homeScreenAdvice) }
                r.0 = data
            }
            return r
        }

        let normalized = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let coordinate = normalized.withOffset(CGVector(dx: x, dy: y))
        coordinate.tap()

        return ([
            "message": .string("Tapped at (\(x), \(y))"),
            "screen": coordinateHint,
        ], nil)
    }

    private func doubleTap(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        // ref-first, like tap.
        if let refId = cmd.ref {
            let (el, err) = resolveRefForAction(refId)
            if let err = err { return (nil, err) }
            // Synthesized rather than XCUIElement.doubleTap(), for the same
            // reason tap(ref:) synthesizes: the native gesture waits for
            // quiescence on both sides — measured 6230ms here, and it timed out
            // hard enough to trip the UI circuit breaker.
            let f = el!.frame
            let label = el!.label
            let (cx, cy) = humanizedPoint(in: f)
            let r = fastHandler.fastDoubleTap(x: cx, y: cy)
            if r.1 == nil {
                return (["message": .string("Double tapped ref \(refId) ('\(label)')")], nil)
            }
            el!.doubleTap()
            return (["message": .string("Double tapped ref \(refId) ('\(label)') (native)")], nil)
        }
        guard let x = cmd.x, let y = cmd.y else {
            return (nil, JSONRPCError(code: -32602, message: "double_tap requires x and y (in points), or a 'ref'", data: nil))
        }
        if let err = validateCoordinate(x: x, y: y, context: "double_tap") { return (nil, err) }

        if cmd.fast != false {
            // mode:"separate" sends two independent synthesize calls; the default
            // packs both presses into one event path so the gap is exact.
            let separate = (cmd.matchMode ?? "").lowercased() == "separate"
            let r = separate
                ? fastHandler.fastDoubleTapSeparate(x: x, y: y)
                : fastHandler.fastDoubleTap(x: x, y: y)
            if r.1 == nil {
                return (["message": .string("Double tapped at (\(x), \(y))" +
                                            (separate ? " (two records)" : " (one record)")),
                         "screen": coordinateHint], nil)
            }
        }

        let normalized = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let coordinate = normalized.withOffset(CGVector(dx: x, dy: y))
        coordinate.doubleTap()

        return (["message": .string("Double tapped at (\(x), \(y)) (native)"), "screen": coordinateHint], nil)
    }

    private func longPress(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        let duration = cmd.duration ?? 2.0
        // ref-first, like tap.
        if let refId = cmd.ref {
            let (el, err) = resolveRefForAction(refId)
            if let err = err { return (nil, err) }
            let label = el!.label
            // Native: a synthesized hold is not recognised as a long press (see
            // the coordinate path below).
            el!.press(forDuration: duration)
            return (["message": .string("Long pressed ref \(refId) ('\(label)') for \(duration)s")], nil)
        }
        guard let x = cmd.x, let y = cmd.y else {
            return (nil, JSONRPCError(code: -32602, message: "long_press requires x and y (in points), or a 'ref'", data: nil))
        }
        if let err = validateCoordinate(x: x, y: y, context: "long_press") { return (nil, err) }

        // Native by default — unlike tap/swipe, a synthesized hold does NOT work.
        // XCPointerEventPath reports the press and the lift (and any samples in
        // between), but UIKit's long-press recognizer never fires: WeChat opened
        // the chat as an ordinary tap, and on a message bubble no action menu
        // appeared, while the native press at the same point produced the full
        // copy/forward/delete menu. Opt in with fast:true if an app disagrees.
        if cmd.fast == true {
            let r = fastHandler.fastLongPress(x: x, y: y, duration: duration)
            if r.1 == nil {
                return (["message": .string("Long pressed at (\(x), \(y)) for \(duration)s (synthesized — " +
                                            "may register as a tap; omit fast:true if no menu appears)"),
                         "screen": coordinateHint], nil)
            }
        }

        let normalized = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let coordinate = normalized.withOffset(CGVector(dx: x, dy: y))
        coordinate.press(forDuration: duration)

        return (["message": .string("Long pressed at (\(x), \(y)) for \(duration)s (native)"), "screen": coordinateHint], nil)
    }

    // MARK: - Swipe & Scroll

    /// Page-scroll: move by (about) one screenful, like Page Down / Page Up on a
    /// keyboard. Precise (no momentum) so you can read content page by page without
    /// the overshoot that swipe+velocity:fast causes. Params:
    ///   direction: "down" (default, reveal content below) / "up"; page_down/page_up
    ///     methods force the direction.
    ///   pages: how many screenfuls (default 1; e.g. 0.5 for half a page).
    private func pageScroll(_ cmd: ActionCommand, method: String) -> ([String: JSONValue]?, JSONRPCError?) {
        let size = pointSize
        let cx = size.width / 2

        // Direction: explicit method wins, else the `direction` param, else down.
        var goingDown = true
        if method == "page_up" { goingDown = false }
        else if method == "page_down" { goingDown = true }
        else if let d = cmd.direction?.lowercased() { goingDown = (d != "up") }

        // Number of screenfuls (default 1). One "page" moves 66% of the height,
        // leaving ~a third overlapping between consecutive reads — about 300pt,
        // close to a typical feed card's height, so an item on the
        // boundary is fully readable in one of the two reads.
        //
        // Overlap only means something now that the drag actually lands where it
        // is aimed (see the velocity note below). It was 85% with a fixed-duration
        // drag that overshot by up to 61%, so the intended "sliver of overlap"
        // was consumed by overshoot and consecutive reads shared nearly nothing.
        let pages = max(0.1, min(cmd.distance ?? 1.0, 5.0))   // reuse `distance` as page count

        let fpStart = nowMonotonic
        // On a heavy list the two tree walks can take most of a page call
        // (seconds each, enough to time out); the pixels decide movement there.
        let heavy = resolveForegroundBundleId().map { bid in
            (heavyList[bid].map { nowMonotonic - $0 < 300 } ?? false) || (grownTree[bid].map { nowMonotonic - $0 < 300 } ?? false)
                || (treeCost[bid] ?? 0) > 1.2 } ?? false
        // There the visible cells give the fingerprint (~0.3s); the tree walk
        // only when the app has no cell list.
        let cellsBid = heavy ? resolveForegroundBundleId() : nil
        // One read each side, no stale-retries: a lagging list just reads
        // as unmoved and the pixels decide (retries stretch a page far past its budget).
        func fingerprint() -> String? {
            if let bid = cellsBid, let fast = visibleListBody(bid, verifyFresh: false) {
                return Self.fingerprint(ofBody: fast.body, height: pointSize.height)
            }
            return cellsBid == nil ? scrollFingerprint() : nil
        }
        let before = fingerprint()
        if !heavy, let bid = resolveForegroundBundleId() { noteCappedCost(bid, seconds: nowMonotonic - fpStart) }
        // A keyboard is often not in the capped tree: ask as page_source does,
        // so that closing it isn't taken for a scroll.
        // Only when a keyboard was seen in this app lately: the probe walks
        // the app, which on a heavy feed costs seconds per page.
        if pageKeyboardTop == nil, let seen = lastKeyboardSeen, seen.bid == resolveForegroundBundleId(),
           nowMonotonic - seen.at < 120,
           case .object(let k) = keyboardState(), case .double(let top)? = k["covers_from_y"] {
            pageKeyboardTop = top
        }
        iCTRLUITests.logBuffer.append(String(format: "⌨️ page: fingerprint+keyboard %.0fms, keyboard %@",
                                             (nowMonotonic - fpStart) * 1000, pageKeyboardTop.map { "at \(Int($0))" } ?? "none"))
        let band = pageBand(pages: pages)
        let bandBottom = band.bottom, pageTravel = band.travel

        // Scroll within the middle band, away from the very top/bottom (nav bars,
        // home indicator, pull-to-refresh zones).
        let fromY: Double, toY: Double
        // A page is the band one drag can cover, 66% of the height: wider
        // bands failed — a drag starting in the bottom 20% (tab bars, iOS 27's
        // floating search bar) or ending in the top 6% (status bar) moved
        // nothing. So consecutive reads overlap by about a third.
        if goingDown {
            fromY = bandBottom
            toY = max(size.height * 0.12, fromY - pageTravel)
        } else {
            fromY = size.height * 0.22
            toY = min(pageKeyboardTop == nil ? size.height * 0.88 : bandBottom, fromY + pageTravel)
        }

        // A fast drag, then the finger rests on the end point before lifting.
        // iOS adds momentum from the velocity at lift-off, which at speed can
        // overshoot a whole screen. Holding the drag slow avoids that but costs
        // seconds per page. Resting samples at the end (see fastSwipe) bring
        // lift-off velocity to zero instead: a short drag plus a brief rest moves
        // the content by about the finger travel, the same in both directions.
        //
        // More than one screenful is several such drags: the band a drag can
        // use is ~66% of the height, and a longer `toY` would be silently clamped
        // (several screenfuls asked, less than one moved).
        let perDrag = abs(fromY - toY)
        var remaining = pageTravel
        var drags = 0
        // On a busy screen (a video playing) the walk is slow; doing it twice
        // would leave no time for settle.
        let fingerprintAfter = heavy || nowMonotonic - fpStart < 0.8
        while remaining > 1, drags < 4 {
            let t = min(remaining, perDrag)
            let endY = goingDown ? fromY - t : fromY + t
            let r = fastHandler.fastSwipe(fromX: cx, fromY: fromY, toX: cx, toY: endY,
                                          duration: cmd.duration ?? 0.35, hold: 0.25)
            if r.1 != nil { return r }
            remaining -= t
            drags += 1
        }
        usleep(100_000)
        let moved = (pageTravel - remaining) / (size.height * 0.66)
        var out: [String: JSONValue] = [
            "message": .string("Paged \(goingDown ? "down" : "up") \(String(format: "%.2g", moved)) screenful(s) — two thirds of the screen each, so consecutive reads overlap by about a third and nothing falls between them. Precise scroll (no momentum). Re-read with page_source/screenshot."),
            "screen": coordinateHint,
        ]
        if fingerprintAfter {
            for (k, v) in scrollOutcome(before: before, after: fingerprint()) { out[k] = v }
        }
        return (out, nil)
    }

    private func swipe(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        // x/y are OPTIONAL. Default start point is the screen center, so a bare
        // {"method":"swipe","params":{"direction":"up"}} scrolls from the middle.
        let size = pointSize
        let x = cmd.x ?? size.width / 2
        let y = cmd.y ?? size.height / 2
        if let err = validateCoordinate(x: x, y: y, context: "swipe start") { return (nil, err) }

        let direction = cmd.direction ?? "up"
        // Default finger travel is 100 pt from the start point (per spec).
        let distance = cmd.distance ?? 100.0

        let endX: Double
        let endY: Double
        switch direction {
        case "up":    endX = x; endY = y - distance
        case "down":  endX = x; endY = y + distance
        case "left":  endX = x - distance; endY = y
        case "right": endX = x + distance; endY = y
        default:
            return (nil, JSONRPCError(
                code: -32602,
                message: "Invalid swipe direction '\(direction)'. Use one of: up, down, left, right.",
                data: nil
            ))
        }

        // Clamp endpoint into bounds rather than failing — swipes near edges are common.
        let clampedEndX = min(max(endX, 0), size.width)
        let clampedEndY = min(max(endY, 0), size.height)

        // Velocity controls how the gesture is interpreted:
        //   "fast"/"flick"   → quick swipe, triggers iOS momentum → scrolls FAR beyond finger travel
        //   "normal"         → moderate (default)
        //   "slow"/"precise" → precise drag, moves ~exactly the finger travel, no momentum
        // Shorter move duration = higher velocity = more momentum.
        let velocity = cmd.velocity ?? "normal"
        let moveDuration: Double
        switch velocity.lowercased() {
        case "fast", "flick":   moveDuration = 0.05
        case "slow", "precise": moveDuration = 0.5
        default:                moveDuration = 0.15
        }

        if cmd.fast != false {
            // Default to the synthesized fast path (no quiescence wait); velocity via duration.
            let r = fastHandler.fastSwipe(fromX: x, fromY: y, toX: clampedEndX, toY: clampedEndY, duration: moveDuration)
            if var data = r.0 {
                data["from"] = .object(["x": .double(x), "y": .double(y)])
                if clampedEndX != endX || clampedEndY != endY {
                    let travel = hypot(clampedEndX - x, clampedEndY - y)
                    data["clamped"] = .string("The end point was off-screen, so the finger travelled \(Int(travel))pt, " +
                        "not \(Int(distance))pt. For long moves use page (several screens per call) or repeat the swipe.")
                }
                data["velocity"] = .string(velocity)
                data["note"] = .string("Started at (\(Int(x)),\(Int(y))) — default is screen center. velocity=\(velocity): 'fast' adds momentum (scrolls farther), 'slow' is a precise drag.")
                return (data, r.1)
            }
            return r
        }

        // Legacy XCUITest path (waits for quiescence).
        let normalized = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let start = normalized.withOffset(CGVector(dx: x, dy: y))
        let end = normalized.withOffset(CGVector(dx: clampedEndX, dy: clampedEndY))
        start.press(forDuration: 0.1, thenDragTo: end)

        return ([
            "message": .string("Swiped \(direction) from (\(x), \(y)) to (\(clampedEndX), \(clampedEndY))"),
            "screen": coordinateHint,
        ], nil)
    }

    private func scroll(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        let direction = cmd.direction ?? "down"
        guard ["up", "down", "left", "right"].contains(direction) else {
            return (nil, JSONRPCError(
                code: -32602,
                message: "Invalid scroll direction '\(direction)'. Use one of: up, down, left, right. " +
                    "Note: direction is the finger movement — 'up' reveals content below.",
                data: nil
            ))
        }

        // Synthesized by default, like tap/swipe. app.swipeUp() and friends run
        // XCTest's element-aware gesture, which waits for quiescence before AND
        // after the event — the same settling that cost find_and_tap ~7.6s per
        // call. A synthesized drag over the same distance doesn't wait at all.
        // fast:false keeps the native gesture for apps where synthesis doesn't
        // land (SwiftUI Lists being the known case).
        if cmd.fast != false {
            let s = pointSize
            let midX = s.width / 2
            // Vertical travel stays inside the middle band (30%..80% of height).
            // Starting a downward drag near the top is read as a pull-down by
            // several apps — WeChat opened its mini-program panel instead of
            // scrolling — and the bottom eighth is the home-indicator area.
            let topY = s.height * 0.30, botY = s.height * 0.80
            let dx = s.width * 0.275
            let midY = s.height / 2
            let (fx, fy, tx, ty): (Double, Double, Double, Double)
            switch direction {
            case "up":    (fx, fy, tx, ty) = (midX, botY, midX, topY)
            case "down":  (fx, fy, tx, ty) = (midX, topY, midX, botY)
            case "left":  (fx, fy, tx, ty) = (midX + dx, midY, midX - dx, midY)
            default:      (fx, fy, tx, ty) = (midX - dx, midY, midX + dx, midY)
            }
            let before = scrollFingerprint()
            let r = fastHandler.fastSwipe(fromX: fx, fromY: fy, toX: tx, toY: ty, duration: 0.3)
            if r.1 == nil {
                usleep(350_000)
                var out: [String: JSONValue] = [
                    "message": .string("Scrolled \(direction) (synthesized)"),
                    "screen": coordinateHint,
                ]
                for (k, v) in scrollOutcome(before: before, after: scrollFingerprint()) { out[k] = v }
                return (out, nil)
            }
            // fall through to the native gesture when synthesis failed
        }

        switch direction {
        case "up":    app.swipeUp()
        case "down":  app.swipeDown()
        case "left":  app.swipeLeft()
        default:      app.swipeRight()
        }
        return (["message": .string("Scrolled \(direction) (native)")], nil)
    }

    // MARK: - Type

    /// Best-effort detection of an on-screen keyboard. NOTE: this is unreliable —
    /// third-party keyboards (Google/Sogou/…) and many apps render the keyboard in
    /// a process whose elements don't appear in the app's OR SpringBoard's
    /// accessibility tree, so a visible keyboard can still report count == 0.
    /// Because of that we use this only for a SOFT warning, never to block typing.
    private func hasKeyboardFocus() -> Bool {
        let bid = resolveForegroundBundleId()
        let target: XCUIApplication = bid.map { XCUIApplication(bundleIdentifier: $0) } ?? app
        if target.keyboards.count > 0 { return true }
        if app.keyboards.count > 0 { return true }
        // SpringBoard hosts the system keyboard on some setups.
        if XCUIApplication(bundleIdentifier: "com.apple.springboard").keyboards.count > 0 { return true }
        return false
    }

    /// Advisory keyboard-focus warning, computed AFTER the text has been
    /// synthesized. Best-effort and cheap: a single keyboards.count probe on the
    /// foreground app (the cross-app SpringBoard probe is skipped — it's the
    /// slowest and this is only for a soft hint, never to block or fail typing).
    private func keyboardWarningAfterType() -> String? {
        let bid = resolveForegroundBundleId()
        // A whole-app walk; on a slow tree it cost seconds per type call.
        if let bid = bid, isSlowTree(bid) { return nil }
        let target: XCUIApplication = bid.map { XCUIApplication(bundleIdentifier: $0) } ?? app
        if target.keyboards.count > 0 { return nil }
        return "Could not confirm a focused text field / visible keyboard (detection can't see all keyboards). " +
            "VERIFY BEFORE RETRYING — screenshot and check whether the text landed; typing again would enter it twice. " +
            "If it did NOT land, tap a real textfield first (find_element{element_id:\"<placeholder text>\", element_type:\"textfield\", match:\"contains\"} → tap{ref}), read again until the field is focused, then type again. " +
            "A home-screen 'search bar' is often a button that opens a separate search page."
    }

    private func typeText(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        if let bid = resolveForegroundBundleId() { lastKeyboardSeen = (bid, nowMonotonic) }
        let clearFirst = cmd.clear == true
        // text is optional when clear:true (type{clear:true} just empties the field).
        guard let text = cmd.text ?? (clearFirst ? "" : nil) else {
            return (nil, JSONRPCError(code: -32602, message: "type requires a 'text' parameter (or clear:true to just empty the field)", data: nil))
        }

        var focusedByTap = false
        if let x = cmd.x, let y = cmd.y {
            if let err = validateCoordinate(x: x, y: y, context: "type focus tap") { return (nil, err) }
            let normalized = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            let coordinate = normalized.withOffset(CGVector(dx: x, dy: y))
            coordinate.tap()
            usleep(500_000)
            focusedByTap = true
        }

        // Typing into a field that already has content APPENDS, and nothing about
        // the result says so: the response reports the text you asked for, the
        // field now holds old+new, and a search silently runs on the wrong query.
        // Hit for real here — searching "椰子汁" in a box still holding "黄桃"
        // searched for "黄桃椰子汁". So read the field first and say what happened.
        //
        // Read-only and cheap: the same snapshot lookup clearFocusedField() does,
        // skipped entirely when clear:true (the field is about to be emptied).
        var preexisting = ""
        if !clearFirst, !text.isEmpty {
            preexisting = focusedFieldValue() ?? ""
        }

        // clear:true empties the field before typing (tap to focus first, above).
        if clearFirst { clearFocusedField() }

        // submit:true appends a Return/Search keystroke so the field's action
        // (search/go/send) fires — synthesized text alone often doesn't trigger it.
        let submit = cmd.submit == true

        // NOTE: keyboard detection (hasKeyboardFocus) is a SOFT warning only, and
        // its keyboards.count queries wait for quiescence — on a live/animating
        // page (e.g. char-by-char typing) they can block until the 6s RPC watchdog
        // fires, making a SUCCESSFUL type look like a timeout. So we do NOT probe
        // the keyboard before typing. Synthesize first (the actual input), return
        // immediately, and only then do a best-effort keyboard check for the
        // advisory warning — computed AFTER the text is already in.
        // Surfaced on BOTH return paths: the append is silent otherwise, and the
        // response would happily report the text the caller asked for while the
        // field holds something else entirely.
        func appendWarning() -> String? {
            guard !preexisting.isEmpty else { return nil }
            return "The field already contained \"\(preexisting)\", so it now reads "
                + "\"\(preexisting + text)\" — typing APPENDS, it does not replace. "
                + "If you meant to replace, call type{clear:true, text:\"...\"} instead. "
                + (submit ? "NOTE a Return was already sent, so any search ran on the combined text." : "")
        }

        if cmd.fast == true {
            let r = fastHandler.fastTypeText(text)
            // Before Return: submitting a search hides the keyboard, which
            // read as "no focused field" and warned on text that had landed.
            let keyboardWarning = r.1 == nil ? keyboardWarningAfterType() : nil
            if submit, r.1 == nil { sendReturnKey() }
            if var data = r.0 {
                let prefix = clearFirst ? "Cleared then typed: " : "Typed: "
                data["message"] = .string(text.isEmpty && clearFirst ? "Cleared focused field" : (prefix + text + (submit ? " + Return" : "")))
                if let a = appendWarning() { data["append_warning"] = .string(a) }
                if let w = keyboardWarning { data["warning"] = .string(w) }
                return (data, r.1)
            }
            return r
        }

        let eventRecord = XCSynthesizedEventRecord(name: "Type")
        let eventPath = XCPointerEventPath(forTextInput: ())
        eventPath.typeText(text, atOffset: 0.0, typingSpeed: 60, shouldRedact: false)
        eventRecord.add(eventPath)

        do {
            try eventRecord.synthesize()
            // Before Return: submitting a search hides the keyboard, which
            // read as "no focused field" and warned on text that had landed.
            let keyboardWarning = keyboardWarningAfterType()
            if submit { sendReturnKey() }
            let prefix = clearFirst ? "Cleared then typed: " : "Typed: "
            let msg = text.isEmpty && clearFirst ? "Cleared focused field" : (prefix + text + (submit ? " + Return" : ""))
            var out: [String: JSONValue] = ["message": .string(msg)]
            if let a = appendWarning() { out["append_warning"] = .string(a) }
            if let w = keyboardWarning { out["warning"] = .string(w) }
            return (out, nil)
        } catch {
            let guidance = focusedByTap
                ? "Typing failed even after tapping to focus. The tapped point may not be a text field, or the keyboard did not appear. Take a screenshot to confirm a text field is focused (keyboard visible), then retry."
                : "Typing failed: no input field currently has keyboard focus. First tap the text field (pass x,y to this command, or call tap), wait for the keyboard, then type."
            return (nil, JSONRPCError(code: -32603, message: guidance, data: nil))
        }
    }

    /// Synthesize a Return/Enter keystroke (triggers Search/Go/Send on the field).
    private func sendReturnKey() {
        let record = XCSynthesizedEventRecord(name: "Return")
        let path = XCPointerEventPath(forTextInput: ())
        path.typeText("\n", atOffset: 0.0, typingSpeed: 60, shouldRedact: false)
        record.add(path)
        try? record.synthesize()
    }

    /// Current text of the focused field, or nil if it can't be read.
    ///
    /// Best-effort by nature: plenty of apps put their search box in a WebView or
    /// a custom control that never reports hasKeyboardFocus, and nil there means
    /// "unknown", NOT "empty" — callers must not treat the two the same.
    private func focusedFieldValue() -> String? {
        guard let bid = resolveForegroundBundleId() else { return nil }
        let target = XCUIApplication(bundleIdentifier: bid)
        // One query over the three field types and one snapshot of the match:
        // a single walk of the app. Probing each type with exists + value +
        // placeholderValue is up to nine walks, ~1–2s of every type call.
        let types = [XCUIElement.ElementType.textField, .secureTextField, .searchField].map { $0.rawValue }
        let el = target.descendants(matching: .any).matching(NSPredicate(
            format: "hasKeyboardFocus == true AND elementType IN %@", types)).firstMatch
        // exists first: snapshotting a query with no match makes XCTest retry
        // it three times at about a second each — most of a type call when the
        // field doesn't report keyboard focus.
        guard el.safeExists,
              let snap = ForegroundApp.safeSnapshot(ofElement: el) as? XCUIElementSnapshot else { return nil }
        // An empty field reports its placeholder as its value: that would read
        // as existing text and raise a false append warning.
        guard let v = snap.value as? String else { return nil }
        return v == snap.placeholderValue ? "" : v
    }

    /// Clear the currently-focused text field. Requires the field to already have
    /// keyboard focus (tap it first). Strategy: ⌘A + one delete, verified by
    /// re-reading the field; if the selection didn't take, a run of backspaces
    /// and forward-deletes sized from the text length (extra deletes past an
    /// empty field are harmless no-ops).
    /// Returns the number of delete keystrokes sent — exactly 1 means select-all worked.
    @discardableResult
    private func clearFocusedField() -> Int {
        // Best-effort read of the focused field's current text. nil means
        // unknown, so clear anyway; a field read as empty needs nothing
        // (select-all + delete there costs about a second for no effect).
        let current = focusedFieldValue()
        if current == "" { return 0 }
        let count = current?.count ?? 0
        // Select-all, then one delete. Backspacing character-by-character was
        // wrong in two ways that compounded:
        //
        //   * it sent EXACTLY `count` backspaces, leaving no margin, so any
        //     dropped keystroke left text behind;
        //   * the comment claimed it moved the caret to the end first, but no
        //     such key was ever sent — so it only deleted to the LEFT of
        //     wherever the caret happened to be.
        //
        // Observed: clearing "someone@example.com" (19 chars, 19 backspaces)
        // left ".com" — the caret sat before ".com", 15 characters went, and the
        // remaining 4 backspaces hit an empty run.
        //
        // ⌘A doesn't care where the caret is and is a fixed two keystrokes
        // regardless of length, so it is both correct and faster.
        let selectedAll = selectAllInFocusedField()

        // Backspace after select-all replaces the selection. If ⌘A didn't take
        // (some custom/web inputs ignore it), fall back to backspaces — with
        // slack this time, and a forward-delete run to catch anything sitting
        // to the RIGHT of the caret.
        func send(_ keys: String) {
            let record = XCSynthesizedEventRecord(name: "ClearText")
            let path = XCPointerEventPath(forTextInput: ())
            path.typeText(keys, atOffset: 0.0, typingSpeed: 90, shouldRedact: false)
            record.add(path)
            try? record.synthesize()
        }
        func backspaceRun() -> Int {
            let n = min(max(count + 8, 40), 200)
            send(String(repeating: "\u{8}", count: n) + String(repeating: "\u{7F}", count: n))
            return n
        }

        guard selectedAll else { return backspaceRun() }
        send("\u{8}")
        // ⌘A being DELIVERED is not ⌘A being honoured: Flutter, React Native
        // and web inputs often ignore the shortcut, and then the single delete
        // above removed one character while this reported the field cleared.
        // If the text shrank by one or less, the selection never happened.
        // (An emptied field may read back as its placeholder; that is a
        // different length, and a spare backspace run on it is a no-op.)
        if count > 1, let after = focusedFieldValue(), !after.isEmpty, after.count >= count - 1 {
            iCTRLUITests.logBuffer.append("⌨️ ⌘A had no effect on the focused field — falling back to backspaces")
            return 1 + backspaceRun()
        }
        return 1
    }

    /// Select the whole contents of the focused field with ⌘A.
    ///
    /// Returns false when no focused element could be resolved, or when the
    /// keystroke threw — callers then need a fallback, since a false negative
    /// here means the field is still full.
    private func selectAllInFocusedField() -> Bool {
        guard let bid = resolveForegroundBundleId() else { return false }
        let target = XCUIApplication(bundleIdentifier: bid)
        // One query over every text-input type (one walk, not one per type).
        let types = [XCUIElement.ElementType.textField, .secureTextField, .searchField, .textView].map { $0.rawValue }
        let el = target.descendants(matching: .any).matching(NSPredicate(
            format: "hasKeyboardFocus == true AND elementType IN %@", types)).firstMatch
        guard el.safeExists else { return false }
        // Obj-C @try: typeKey raises on an element that cannot accept keys,
        // and an NSException here would take the runner down with it.
        var ok = false
        _ = ObjCException.catching {
            el.typeKey("a", modifierFlags: .command)
            ok = true
        }
        return ok
    }

    /// clear_text method: clear the focused field without typing anything new.
    private func clearText(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        let keyboardConfirmed = hasKeyboardFocus()
        let sent = clearFocusedField()
        // `sent == 1` means select-all worked; anything larger means it fell
        // back to blind backspacing, which is worth knowing when a field turns
        // out not to be empty afterwards.
        var out: [String: JSONValue] = [
            "message": .string(sent == 0 ? "The focused field was already empty"
                : sent == 1 ? "Cleared focused field (select-all + delete)"
                : "Cleared focused field by deleting characters (\(sent) keystrokes) — this field doesn't support select-all"),
            "method": .string(sent == 0 ? "none" : sent == 1 ? "select_all" : "backspaces"),
        ]
        if !keyboardConfirmed {
            out["warning"] = .string(
                "Could not confirm a focused text field / visible keyboard. If the field wasn't cleared, " +
                "tap a real textfield first (find_element{element_id:\"<placeholder text>\", element_type:\"textfield\", match:\"contains\"} → tap{ref}), then clear_text again.")
        }
        return (out, nil)
    }

    // MARK: - Device Buttons

    private func pressHome() -> ([String: JSONValue]?, JSONRPCError?) {
        // Which app we are leaving.
        let before = resolveForegroundBundleId()
        let springboard = "com.apple.springboard"

        // `press(.home)` normally blocks until SpringBoard is frontmost — but that
        // wait lives in XCTest's quiescence machinery, which this runner no-ops
        // globally (see QuiescenceDisabler) to stop taps stalling for seconds. So
        // the press is delivered and we return before the transition happens,
        // which reads as "Home did nothing". Verify the result ourselves instead
        // of reporting success blind.
        _ = ObjCException.catching { XCUIDevice.shared.press(.home) }

        // Verify via the app we are trying to LEAVE, not via "is SpringBoard
        // frontmost". The private activeApplications detector returns nil on
        // iOS 26 whatever is in front, so a check built on it passes instantly
        // and reports success for a press that did nothing. XCUIApplication.state
        // is public, works, and answers the question that actually matters: did
        // the app we were in stop being foreground?
        if springboardPID == 0 { springboardPID = ForegroundApp.processID(forBundleID: springboard) }
        func leftForeground() -> Bool {
            guard let bid = before, bid != springboard else {
                // Nothing was in front (already home), or SpringBoard itself —
                // there is nothing to leave, so the press has nothing to prove.
                return true
            }
            // SpringBoard's pid in front is direct proof. The app's own state
            // below can lag: on iOS 27 it can keep saying "foreground" for seconds
            // after the home screen is up, failing a press that worked.
            if springboardPID > 0, ForegroundApp.frontmostPID() == springboardPID { return true }
            let state = AppState(rawValue: ForegroundApp.appState(forBundleID: bid)) ?? .unknown
            return state != .foreground
        }

        // Poll rather than sleep a fixed interval: the animation is ~300-500ms but
        // varies with what's on screen, and a fixed wait either lies or wastes time.
        var landed = false
        for _ in 0..<20 {
            if leftForeground() { landed = true; break }
            usleep(100_000)
        }

        // Fallback: activate SpringBoard directly. `press(.home)` is a no-op on
        // iOS 26 here — the button event goes nowhere on a device that has no
        // physical Home button — whereas activating SpringBoard as an app is a
        // normal foreground switch and does not depend on button synthesis.
        if !landed {
            // This is what WebDriverAgent actually ships for its home-screen
            // route (fb_switchToSystemApplicationWithError): activate SpringBoard
            // as an app, launching it if it isn't running. WDA dropped
            // pressButton: for this years ago precisely because the press was
            // async and unreliable — which matches what this device does.
            iCTRLUITests.logBuffer.append("🏠 press(.home) had no effect — activating SpringBoard instead")
            _ = ObjCException.catching { _ = ForegroundApp.activateOrLaunchBundleID(springboard) }
            for _ in 0..<20 {
                if leftForeground() { landed = true; break }
                usleep(100_000)
            }
        }

        guard landed else {
            return (nil, .serverError(
                "Could not leave '\(before ?? "the foreground app")': both the Home button and "
                + "activating SpringBoard failed to background it. A modal alert or system sheet can hold "
                + "focus — check page_source for a dialog and dismiss it — or the device may be locked "
                + "(call is_locked)."
            ))
        }
        // At the home screen the front pid is SpringBoard's: learn it, for
        // when XCTest can't report it directly.
        if springboardPID == 0 { springboardPID = ForegroundApp.frontmostPID() }
        return ([
            "message": .string("Returned to the home screen"),
            "foreground_app": .string(springboard),
            "previous_app": before.map { JSONValue.string($0) } ?? .null,
        ], nil)
    }

    private func lock() -> ([String: JSONValue]?, JSONRPCError?) {
        let monitor = LockStateMonitor.shared()
        do {
            try monitor.lockScreen(withTimeout: 5.0)
            return (["message": .string("Screen locked")], nil)
        } catch {
            return (nil, .serverError("Lock failed: \(error.localizedDescription)"))
        }
    }

    private func unlock() -> ([String: JSONValue]?, JSONRPCError?) {
        let monitor = LockStateMonitor.shared()
        do {
            try monitor.unlockScreen(withTimeout: 5.0)
            return (["message": .string("Screen unlocked")], nil)
        } catch {
            return (nil, .serverError(
                "Unlock failed: \(error.localizedDescription). " +
                "This only wakes the screen; if the device has a passcode, it cannot be entered automatically — " +
                "the user must unlock manually. Call is_locked to check the current state."
            ))
        }
    }

    private func isLocked() -> ([String: JSONValue]?, JSONRPCError?) {
        let locked = LockStateMonitor.shared().isLocked
        return (["locked": .bool(locked)], nil)
    }

    // MARK: - App Control

    /// Run a potentially-blocking app action off the main thread with a watchdog.
    /// XCUIApplication.launch()/activate() can hang indefinitely (bad bundle id,
    /// animation-heavy launch), and since RPCs run serially on the main thread,
    /// one hang freezes the WHOLE server. This bounds the wait and returns instead.
    ///
    /// A timeout only stops the WAITING: the work can't be cancelled and keeps
    /// running. With `label`, at most one abandoned call per label may be alive —
    /// while one is, new calls with that label are refused (return false at
    /// once) instead of stacking up. Unbounded stacking is how abandoned XCTest
    /// queries can hold several cores at 100% until iOS kills the runner.
    private func runWithTimeout(seconds: TimeInterval, label: String? = nil,
                                _ work: @escaping () -> Void) -> Bool {
        if let label = label, let since = Self.abandonedSince(label) {
            iCTRLUITests.logBuffer.append(
                "🧵 \(label) skipped — the previous one was abandoned \(Int(nowMonotonic - since))s ago and is still running")
            return false
        }
        final class Job { let lock = NSLock(); var state = 0 }   // 0 running, 1 finished, 2 abandoned
        let job = Job()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            sem.signal()
            job.lock.lock()
            let wasAbandoned = job.state == 2
            job.state = 1
            job.lock.unlock()
            if wasAbandoned, let label = label, let since = Self.clearAbandoned(label) {
                iCTRLUITests.logBuffer.append(
                    "🧵 abandoned \(label) finally ended after \(Int(ProcessInfo.processInfo.systemUptime - since))s")
            }
        }
        if sem.wait(timeout: .now() + seconds) == .success { return true }
        job.lock.lock()
        defer { job.lock.unlock() }
        guard job.state == 0 else { return true }   // finished in the gap
        job.state = 2
        if let label = label {
            Self.markAbandoned(label)
            iCTRLUITests.logBuffer.append(
                "🧵 \(label) abandoned after \(Int(seconds))s — still running in the background")
        }
        return false
    }

    private static let abandonedLock = NSLock()
    private static var abandoned: [String: TimeInterval] = [:]

    private static func abandonedSince(_ label: String) -> TimeInterval? {
        abandonedLock.lock(); defer { abandonedLock.unlock() }
        return abandoned[label]
    }
    private static func markAbandoned(_ label: String) {
        abandonedLock.lock(); abandoned[label] = ProcessInfo.processInfo.systemUptime; abandonedLock.unlock()
    }
    private static func clearAbandoned(_ label: String) -> TimeInterval? {
        abandonedLock.lock(); defer { abandonedLock.unlock() }
        return abandoned.removeValue(forKey: label)
    }

    /// List installed apps (bundle_id + name). Optional `text` filters by a
    /// case-insensitive substring of the name or bundle id. `element_type`=="all"
    /// includes system apps (default: user apps only).
    private func listApps(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        let userOnly = (cmd.elementType?.lowercased() != "all")
        let enumerated = ForegroundApp.installedAppsUserOnly(userOnly) ?? []

        // iOS 26 answers the enumeration with nothing. What we can still say is
        // which apps were opened successfully HERE — incomplete, but every entry
        // is real, which is more than an empty list offers.
        let fromHistory = enumerated.isEmpty
        let apps: [[AnyHashable: Any]] = fromHistory ? AppMemory.shared.openedApps() : enumerated

        let filter = cmd.text?.lowercased()
        var items: [JSONValue] = []
        for entry in apps {
            let bid = entry["bundle_id"] as? String ?? ""
            var name = entry["name"] as? String ?? ""
            if name.isEmpty {
                name = Self.builtInApp(bid)?["name"] ?? entry["store_name"] as? String ?? ""
            }
            if let f = filter, !f.isEmpty,
               !name.lowercased().contains(f), !bid.lowercased().contains(f) {
                continue
            }
            var obj: [String: JSONValue] = ["bundle_id": .string(bid), "name": .string(name)]
            if fromHistory, let t = entry["last_opened"] as? Double {
                obj["last_opened"] = .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: t)))
            }
            items.append(.object(obj))
        }

        // An empty list is NOT proof the app is missing. This enumeration goes
        // through LSApplicationWorkspace, which iOS has been progressively
        // locking down — on iOS 26 it has been observed returning nothing at all
        // on a device with dozens of apps installed. Saying so here matters:
        // otherwise a caller reads count:0 as "not installed" and abandons a
        // task that was perfectly doable.
        var hint = "Use a bundle_id with launch_app. Pass {\"text\":\"<name>\"} to filter, " +
                   "or {\"element_type\":\"all\"} to include system apps."
        if fromHistory {
            hint = "iOS refused app enumeration, so this lists only apps previously OPENED successfully " +
                   "through iCTRL on this device (most recent first). Every entry is installed; an app " +
                   "missing from here may still be installed — resolve_app{text:\"<name>\"} then " +
                   "launch_app to check."
        }
        if items.isEmpty {
            hint = "⚠️ Empty result — this does NOT mean the app is absent. App enumeration is a " +
                   "private API that newer iOS versions may refuse, returning nothing even when the " +
                   "app IS installed. Do not conclude 'not installed' from this alone. " +
                   Self.appLookupFallbackHint
        }
        return ([
            "count": .int(items.count),
            "source": .string(fromHistory ? "opened_history" : "system"),
            "apps": .array(items),
            "hint": .string(hint),
        ], nil)
    }

    /// What to do when a bundle id can't be confirmed by lookup. Spotlight is
    /// the authority the OS itself uses, so it finds apps the private
    /// enumeration/catalog paths miss — and it works by NAME, which is what a
    /// user asks for anyway.
    static let appLookupFallbackHint =
        "To verify for real: (1) call launch_app with a candidate bundle_id — an error means genuinely " +
        "not installed, success means it was there all along; or (2) ask iOS itself: call `home`, then " +
        "swipe{direction:\"down\"} from mid-screen to open Spotlight, type the app's NAME, and read the " +
        "result — Spotlight indexes every installed app regardless of API limits. " +
        "Only report 'not installed' after one of these, never from an empty list."

    /// Built-in app catalog (name → bundle_id), loaded once from AppBundles.plist
    /// bundled into the runner. Lets resolve_app answer common apps instantly and
    /// offline; misses fall back to the iTunes Search API.
    private static let builtInApps: [[String: String]] = {
        // The plist ships inside the .xctest bundle.
        let bundle = Bundle(for: ActionHandler.self)
        guard let url = bundle.url(forResource: "AppBundles", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let apps = obj["apps"] as? [[String: String]] else {
            return []
        }
        return apps
    }()

    /// The built-in catalog entry for one bundle id, if it has one.
    private static func builtInApp(_ bundleId: String) -> [String: String]? {
        builtInApps.first { $0["bundle_id"] == bundleId }
    }

    /// Case-insensitive lookup in the built-in catalog: substring on name and
    /// query, but EXACT on bundle_id. A substring match on ids turned "Trip.com"
    /// into Ctrip ("c·trip.com"), and since an offline hit skips the App Store,
    /// every rephrasing returned the same wrong app.
    private func lookupBuiltInApps(_ term: String) -> [[String: String]] {
        let t = term.lowercased()
        return Self.builtInApps.filter { app in
            (app["name"]?.lowercased().contains(t) ?? false) ||
            (app["query"]?.lowercased().contains(t) ?? false) ||
            app["bundle_id"]?.lowercased() == t
        }
    }

    /// Resolve an app name/keyword to its bundle_id (+ basic info). Checks the
    /// built-in catalog first (offline/instant), then the iTunes Search API.
    /// Use this to get the bundle_id for launch_app when you only know the app's
    /// name. Params: text (query, required), country (default us), limit (default 5).
    private func resolveApp(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        guard let term = cmd.text, !term.isEmpty else {
            return (nil, JSONRPCError(
                code: -32602,
                message: "resolve_app requires 'text' (the app name / keyword to look up). " +
                    "NOTE: this SEARCHES THE APP STORE — it does not list what is installed on this device, " +
                    "so it must NOT be used to verify an install (it happily returns a different version than the one installed). " +
                    "Next: to check an installed app use list_apps; to search the store retry as resolve_app{text:\"<name>\"}. " +
                    "Full parameter list: GET /schema.",
                data: nil))
        }
        // The US store by default: it carries far more of the apps people ask
        // for by an international name (Trip.com is not in the China store,
        // so a "cn" search for it returns Ctrip). Pass country:"cn" for apps
        // that only ship in China.
        let country = cmd.country ?? "us"
        // An explicit country is a request to ask THAT store — answering from
        // the offline catalog instead would make the parameter do nothing.
        let storeOnly = cmd.country != nil
        let limit = min(max(Int(cmd.distance ?? 5), 1), 25)

        // Several candidate names in one call ("Trip.com|Ctrip|Trip"). An app's
        // name is often not what the user said — a brand vs its store title,
        // English vs Chinese — and trying them one per round cost a real session
        // three model turns. Searched in parallel, merged by bundle_id.
        var terms: [String] = []
        for part in term.split(separator: "|") {
            let t = part.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !terms.contains(t) { terms.append(t) }
        }
        if terms.count > 1 {
            return resolveMany(Array(terms.prefix(6)), country: country, limit: limit, storeOnly: storeOnly)
        }
        return resolveOne(term: terms.first ?? term, country: country, limit: limit, storeOnly: storeOnly)
    }

    /// Which store a result came from, and how to ask another one. Said in every
    /// store-backed answer: an app missing from the default (US) store looks
    /// exactly like an app that doesn't exist, unless the caller knows which
    /// store was asked.
    private static func storeRegionNote(_ country: String) -> String {
        "Searched the \(country.uppercased()) App Store (country:\"\(country)\"). Apps are listed per region — " +
        "if the app you want isn't here, or the user's context points elsewhere (Chinese names or a China-only " +
        "app → \"cn\", Japan → \"jp\", Hong Kong → \"hk\", …), call resolve_app again with that country."
    }

    /// resolve_app for several terms at once: each looked up as resolveOne
    /// would, concurrently, then merged — opened-on-this-device first, one entry
    /// per bundle_id, each tagged with the term that found it.
    private func resolveMany(_ terms: [String], country: String, limit: Int,
                             storeOnly: Bool) -> ([String: JSONValue]?, JSONRPCError?) {
        var results = [([String: JSONValue]?, JSONRPCError?)](repeating: (nil, nil), count: terms.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: terms.count) { i in
            let r = resolveOne(term: terms[i], country: country, limit: limit, storeOnly: storeOnly)
            lock.lock(); results[i] = r; lock.unlock()
        }
        var verified: [JSONValue] = [], others: [JSONValue] = []
        var seen = Set<String>()
        var perTerm: [String: JSONValue] = [:]
        for (i, (res, err)) in results.enumerated() {
            if let err = err { perTerm[terms[i]] = .string("error: \(err.message)"); continue }
            perTerm[terms[i]] = res?["source"] ?? .null
            guard case .array(let apps)? = res?["apps"] else { continue }
            for case .object(var o) in apps {
                guard case .string(let bid)? = o["bundle_id"], !bid.isEmpty, seen.insert(bid).inserted else { continue }
                o["matched_term"] = .string(terms[i])
                if case .string("opened_here")? = o["source"] { verified.append(.object(o)) } else { others.append(.object(o)) }
            }
        }
        let apps = Array((verified + others).prefix(limit * 2))
        return ([
            "count": .int(apps.count),
            "terms": .array(terms.map { .string($0) }),
            "country": .string(country),
            "per_term_source": .object(perTerm),
            "apps": .array(apps),
            "hint": .string(verified.isEmpty
                ? "Merged results for every term; matched_term says which one found each app. None of them has " +
                  "been opened on this device yet — pick the one whose name is the app you want and launch_app it " +
                  "(an error means not installed). " + Self.storeRegionNote(country)
                : "Entries with source 'opened_here' were launched successfully on THIS device before — " +
                  "launch_app that bundle_id directly. Others: " + Self.storeRegionNote(country)),
        ], nil)
    }

    /// resolve_app for one term: offline (learned + built-in), else the App Store.
    private func resolveOne(term: String, country: String, limit: Int,
                            storeOnly: Bool) -> ([String: JSONValue]?, JSONRPCError?) {
        // 1) Offline first: what this device has learned (opened apps, earlier
        //    store lookups) merged with the built-in catalog. Both use the same
        //    {name, bundle_id, query, country} shape and are joined PER BUNDLE
        //    ID — a term may hit only one side (the catalog's query "boss直聘"
        //    vs the home-screen name read at launch), and either hit must still
        //    carry the other side's facts, above all "opened here".
        var order: [String] = []
        var seen = Set<String>()
        for e in AppMemory.shared.lookup(term) {
            if let bid = e["bundle_id"] as? String, seen.insert(bid).inserted { order.append(bid) }
        }
        for a in lookupBuiltInApps(term) {
            if let bid = a["bundle_id"], seen.insert(bid).inserted { order.append(bid) }
        }
        var offline: [(verified: Bool, obj: JSONValue)] = []
        for bid in order {
            let learned = AppMemory.shared.entry(for: bid)
            let builtIn = Self.builtInApp(bid)
            let verified = (learned?["installed"] as? Bool) == true
            let name = (learned?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? builtIn?["name"] ?? learned?["store_name"] as? String ?? ""
            var obj: [String: JSONValue] = [
                "name": .string(name),
                "bundle_id": .string(bid),
                "source": .string(verified ? "opened_here" : (builtIn != nil ? "built-in" : "learned")),
            ]
            if let installed = learned?["installed"] as? Bool { obj["installed_here"] = .bool(installed) }
            if let t = learned?["last_opened"] as? Double {
                obj["last_opened"] = .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: t)))
            }
            offline.append((verified, .object(obj)))
        }
        // Proven-installed first, otherwise the order found (a partition, not
        // sort — Swift's sort does not promise stability).
        offline = offline.filter { $0.verified } + offline.filter { !$0.verified }
        let anyVerified = offline.contains { $0.verified }
        if !offline.isEmpty, !storeOnly {
            let apps = offline.prefix(limit).map(\.obj)
            return ([
                "count": .int(apps.count),
                "term": .string(term),
                "source": .string("offline"),
                "country": .string("offline — no App Store region was searched"),
                "apps": .array(apps),
                // A catalog hit says what a bundle id IS, never whether it is on
                // this device. It reads like confirmation and is not one:
                // resolving 美团 to com.meituan.imeituan succeeded on a device
                // that did not have it, and only launch_app revealed that. Only
                // 'opened_here' entries are evidence about this device.
                "hint": .string(anyVerified
                    ? "Entries with source 'opened_here' were launched successfully on THIS device before — " +
                      "call launch_app with that bundle_id directly. Other entries only map a name to a bundle_id."
                    : "Matched offline (built-in catalog / earlier store lookups) — this maps a NAME to a " +
                      "bundle_id and does NOT mean the app is installed here. Confirm by calling " +
                      "launch_app: success proves it, an error means genuinely absent. If this isn't the app, " +
                      "pass country (\"us\", \"cn\", …) to search that App Store instead. " +
                      Self.appLookupFallbackHint),
            ], nil)
        }
        // 2) Fall back to the iTunes Search API.
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        guard let url = comps.url else {
            return (nil, JSONRPCError(code: -32602, message: "Invalid search term", data: nil))
        }

        // Synchronous fetch with a bounded wait (this runs on the main thread).
        var payload: Data?
        var netError: Error?
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: url) { data, _, err in
            payload = data; netError = err; sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + 10) != .success {
            task.cancel()
            return (nil, .serverError("App Store search timed out (network). Check the device's internet connection."))
        }
        if let netError = netError {
            return (nil, .serverError("App Store search failed: \(netError.localizedDescription)"))
        }
        guard let data = payload,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else {
            return (nil, .serverError("App Store search returned no parseable results."))
        }

        let apps: [JSONValue] = results.map { r in
            .object([
                "name": .string(r["trackName"] as? String ?? ""),
                "bundle_id": .string(r["bundleId"] as? String ?? ""),
                "developer": .string(r["artistName"] as? String ?? ""),
                "category": .string(r["primaryGenreName"] as? String ?? ""),
                "rating": .double((r["averageUserRating"] as? Double) ?? 0),
                "rating_count": .int((r["userRatingCount"] as? Int) ?? 0),
                "price": .string(r["formattedPrice"] as? String ?? ""),
                "version": .string(r["version"] as? String ?? ""),
                "track_id": .int((r["trackId"] as? Int) ?? 0),
            ])
        }

        // Keep the mapping so the next lookup for this name is offline.
        for r in results {
            guard let bid = r["bundleId"] as? String, let name = r["trackName"] as? String else { continue }
            AppMemory.shared.recordResolved(bundleId: bid, name: name, query: term, country: country)
        }

        return ([
            "count": .int(apps.count),
            "term": .string(term),
            "country": .string(country),
            "source": .string("app_store"),
            "apps": .array(apps),
            "hint": .string(Self.storeRegionNote(country) + " Use a result's bundle_id with launch_app; it " +
                            "confirms App Store identity, NOT that the app is installed here — launch_app tells you."),
        ], nil)
    }

    /// Open any URL from the runner (custom scheme or https://) to jump to an app
    /// or a deep-linked feature — e.g. "weixin://", "alipays://platformapi/…",
    /// "https://…", "tel:…", or a callback like "minis://done?x=1". Uses the same
    /// XCTest-daemon path that reliably opens URLs from inside the runner.
    private static func bundleForScheme(_ scheme: String?) -> String? {
        switch scheme {
        case "itms-apps", "itms-appss", "itms", "itmss": return "com.apple.AppStore"
        case "http", "https": return "com.apple.mobilesafari"
        case "app-prefs", "prefs": return "com.apple.Preferences"
        case "maps": return "com.apple.Maps"
        case "tel", "telprompt": return "com.apple.mobilephone"
        case "sms": return "com.apple.MobileSMS"
        case "mailto": return "com.apple.mobilemail"
        default: return nil
        }
    }

    private func openURL(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        guard let raw = cmd.url ?? cmd.text, !raw.isEmpty else {
            return (nil, JSONRPCError(code: -32602, message: "open_url requires a 'url' (e.g. 'weixin://', 'https://example.com', 'alipays://platformapi/startapp?...')", data: nil))
        }
        guard let url = URL(string: raw) else {
            return (nil, JSONRPCError(code: -32602, message: "'\(raw)' is not a valid URL. URL-encode query values if needed.", data: nil))
        }
        let opened = ForegroundApp.open(url)
        guard opened else {
            return (nil, .serverError(
                "Could not open '\(raw)'. The scheme may not be installed/registered, or the URL is malformed. " +
                "For opening an app by identity, use launch_app with a bundle_id instead."
            ))
        }
        // The front app is known by pid only, and only apps opened through
        // this runner are candidates for naming it. A page opened by URL right
        // after a restart (e.g. in the App Store) would read as "nil" in front,
        // and every read and find_element would miss it. The scheme says where it went.
        if let bid = Self.bundleForScheme(url.scheme?.lowercased()) { noteOpened(bid) }
        alertWatchUntil = nowMonotonic + Self.settleCallBudget + Self.alertWatchSeconds
        usleep(150_000)   // the switch itself; settle then waits for the page
        var out: [String: JSONValue] = [
            "message": .string("Opened URL \(url.scheme ?? "")://… . Give it a moment, then page_source/screenshot to see where it landed."),
        ]
        if let front = resolveForegroundBundleId() { out["foreground_app"] = .string(front) }
        return (out, nil)
    }

    private func launchApp(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        guard let bundleId = cmd.bundleId else {
            return (nil, JSONRPCError(code: -32602, message: "launch_app requires a 'bundle_id' (e.g. 'com.apple.Preferences', 'ctrip.com')", data: nil))
        }
        // Open via LSApplicationWorkspace (same as WebDriverAgent): this is
        // NON-BLOCKING and returns immediately — no quiescence wait, so a wrong
        // bundle_id or an ad/launch screen can't hang the whole server (which is
        // what XCUIApplication.launch()/activate() did).
        // The whole call stays inside the 6s reply limit: on a busy phone
        // (apps installing) a single frame can take a second, and an unbounded
        // launch runs long enough to wedge the next call. Waits below get what
        // is left of 4.5s.
        let launchStart = nowMonotonic
        let before = ForegroundApp.frontmostPID()
        // Only "is it already in front?" — naming an unknown front pid asks
        // every known app for its state, which right after a runner restart
        // can take seconds and push the launch past 6s.
        let wasFront: Bool = {
            if springboardPID == 0 { springboardPID = ForegroundApp.processID(forBundleID: "com.apple.springboard") }
            if before <= 0 || before == springboardPID { return false }
            if let known = frontByPID[before] { return known == bundleId }
            // Asking XCTest for the app's state can take over half a second and
            // can name the wrong app in front. Unknown: treat as not in front.
            return false
        }()
        let preAt = nowMonotonic
        let startFrame = ScreenSettle.sample()
        let captureCost = nowMonotonic - preAt
        let opened = ForegroundApp.openBundleID(bundleId)
        guard opened else {
            AppMemory.shared.recordNotInstalled(bundleId: bundleId)
            return (nil, .serverError(
                "Could not open '\(bundleId)'. The bundle_id is likely wrong or not installed. " +
                "Call resolve_app{text:\"<app name>\"} to look up the correct one."
            ))
        }
        let openedAt = nowMonotonic
        let preMs = (preAt - launchStart) * 1000
        noteOpened(bundleId)
        rememberOpened(bundleId)
        // This call runs up to 4.5s; watch for late alerts past its end.
        alertWatchUntil = launchStart + 4.5 + Self.alertWatchSeconds
        launchedAt[bundleId] = launchStart
        // The open is asynchronous. Returning after a fixed delay let the
        // caller's first read land on the previous app (the App Store, the
        // app switcher) as if it were this one. Wait for the front process
        // to actually change instead, bounded.
        // A system alert raised at launch (network, permission) keeps
        // SpringBoard's pid in front, so the pid never changes: look for one
        // every half second and stop waiting when it's there.
        var alertSeen = false
        if !wasFront {
            let deadline = min(nowMonotonic + 2.5, launchStart + 2.6)
            var polls = 0
            while nowMonotonic < deadline {
                usleep(100_000)
                polls += 1
                let pid = ForegroundApp.frontmostPID()
                if pid > 0 && pid != before {
                    // The process that just came up is the one launched: naming
                    // it by asking XCTest for each app's state right after a
                    // launch can block for seconds ("Unable to update application
                    // state promptly") on the first read.
                    // Mid-switch the front list can lead with the app going away,
                    // which would pin the previous app's pid to the new app's name
                    // for good. So only a pid that stays in front, and isn't
                    // already known as another app. (Asking XCTest for this
                    // app's pid instead can take seconds right after the launch.)
                    usleep(150_000)
                    if ForegroundApp.frontmostPID() == pid, frontByPID[pid] == nil || frontByPID[pid] == bundleId {
                        frontByPID[pid] = bundleId
                    }
                    break
                }
                if polls % 5 == 0, systemAlertUp() { alertSeen = true; break }
            }
        }
        let frontAt = nowMonotonic
        // Then let the launch animation and first draw finish: a read right
        // away caught splash screens, and the permission or network alert an
        // app raises at start appears only after it is drawn — too late for
        // the alert check below without this.
        // Against one deadline for the whole call: on a hot phone each phase
        // would overrun its own cap (frames at ~1s each) and launches hit 6s.
        // Not when a capture is slow: then the screen itself is (a hot phone,
        // a heavy app starting, where one capture can take seconds), and watching
        // it only makes launch_app overrun. The caller reads next anyway.
        let drawn: ScreenSettle.Outcome? = captureCost > 0.35 ? nil :
            ScreenSettle.wait(baseline: startFrame, budget: max(0.3, min(1.5, launchStart + 3.8 - nowMonotonic)))
        if let last = drawn?.last { noteSeen(last) }
        let settledAt = nowMonotonic
        // A new process in front once the launch has drawn is the app just
        // opened (the mid-switch mix-up the loop above guards against is
        // over by now). Naming it the general way asks every known app for
        // its state, which after a runner restart can take many seconds.
        let pidNow = ForegroundApp.frontmostPID()
        var front: String?
        if let known = frontByPID[pidNow] {
            front = known
        } else if pidNow > 0, pidNow != before, pidNow != springboardPID {
            frontByPID[pidNow] = bundleId
            front = bundleId
        } else {
            front = resolveForegroundBundleId()
        }
        if let f = front { Self.lastFront = (f, nowMonotonic) }
        // Precise: a tracking alert left by ANOTHER app keeps its pid in front
        // and covers whatever opens next, which would otherwise be reported
        // as a plain "Opened".
        let resolvedAt = nowMonotonic
        // Only with time left: on a loaded phone the SpringBoard walk itself
        // can take many seconds. The next read checks again anyway.
        let alert = alertSeen || systemAlertUp(precise: nowMonotonic - launchStart < 3.5)
        let alertMs = (nowMonotonic - resolvedAt) * 1000
        // A system alert puts SpringBoard's pid in front even though the app
        // is there underneath it; name the app, and flag the alert below.
        // Not confirmed by asking XCTest for the app's state: under an alert
        // that can block for seconds, pushing launch_app past its 6s limit
        // and queueing the next read behind it.
        if alert, front == "com.apple.springboard" {
            front = bundleId
        }
        let total = nowMonotonic - launchStart
        if wasFront || total > 3.5 {
            iCTRLUITests.logBuffer.append("🔢 launch \(bundleId): before=\(before) wasFront=\(wasFront) now=\(pidNow) known=\(frontByPID[before] ?? "-")")
        }
        if total > 3.5 {
            iCTRLUITests.logBuffer.append(String(format: "🐢 launch_app %.0fms: pre=%.0f capture=%.0f open=%.0f front=%.0f settle=%.0f name=%.0f alert=%.0f",
                total * 1000, preMs, captureCost * 1000, (openedAt - preAt - captureCost) * 1000, (frontAt - openedAt) * 1000,
                (settledAt - frontAt) * 1000, (resolvedAt - settledAt) * 1000, alertMs))
        }
        var data: [String: JSONValue] = ["message": .string("Opened \(bundleId)."), "settle": drawn?.json ??
            .object(["skipped": .string("screen captures are slow right now (\(Int(captureCost * 1000))ms), so the launch wasn't watched")])]
        if let front = front { data["foreground_app"] = .string(front) }
        if front == bundleId {
            // No fixed delay: on current devices apps are usually drawn almost
            // immediately, and a suggested fixed wait tends to become a blind
            // sleep in every session. Read, and read again only if needed.
            data["hint"] = .string("Read the screen right away (page_source). If it still shows a splash or placeholder, " +
                                   "read again every ~0.5s until it changes (cap ~10s) — don't sleep a fixed time.")
        } else {
            data["hint"] = .string("Opened, but \(front ?? "another app") is in front, not \(bundleId): it may still " +
                                   "be launching, or a system alert (permission, network) covers it. Read with " +
                                   "page_source{bundle_id:\"com.apple.springboard\"} to see an alert; otherwise read again.")
        }
        if alert { data["hint"] = nil; flagAlert(&data) }
        return (data, nil)
    }

    private func activateApp(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        guard let bundleId = cmd.bundleId else {
            return (nil, JSONRPCError(code: -32602, message: "activate_app requires a 'bundle_id'", data: nil))
        }
        // Opening a running app through LSApplicationWorkspace brings it to the
        // front, like tapping its icon, and returns at once. It is tried first:
        // XCUIApplication.activate() throws immediately on iOS 27 and can
        // block for seconds where it does work. The XCTest path stays as the
        // fallback.
        // Whether the app is still alive in the background: iOS ends idle ones,
        // and then activating starts it fresh — its screen, scroll position
        // and every ref are gone, which the caller must know.
        var pidBefore: pid_t = -1
        _ = runWithTimeout(seconds: 1.5, label: "activate-pid") { pidBefore = ForegroundApp.processID(forBundleID: bundleId) }
        let activateStart = nowMonotonic
        let startFrame = ScreenSettle.sample()
        let captureCost = nowMonotonic - activateStart
        var activated = ForegroundApp.openBundleID(bundleId)
        if !activated {
            let ok = runWithTimeout(seconds: 5, label: "activate") {
                activated = ForegroundApp.safeActivateBundleID(bundleId)
            }
            guard ok else {
                return (nil, .serverError("activate_app timed out after 5s for '\(bundleId)'. Check the bundle_id."))
            }
        }
        guard activated else {
            return (nil, .serverError("Could not activate '\(bundleId)' (not installed, or activation failed). Use resolve_app/list_apps to verify the bundle_id."))
        }
        noteOpened(bundleId)
        rememberOpened(bundleId)
        // An accepted request is not a switch: activate_app can report
        // "Activated" while the current app (e.g. Settings opened from a
        // banner) stays in front. Wait for the front to change, and say where it ended up.
        let deadline = nowMonotonic + 2.0
        var front = resolveForegroundBundleId()
        while front != bundleId, nowMonotonic < deadline {
            usleep(150_000)
            front = resolveForegroundBundleId()
        }
        var out: [String: JSONValue] = ["message": .string("Activated \(bundleId).")]
        if let front = front { out["foreground_app"] = .string(front) }
        // In front is not yet resumed: the switch animation is still running
        // and the app re-lays out — a tree read right away can show a stale
        // screen (a feed instead of the page it was left on) for about a second.
        if front == bundleId, captureCost <= 0.35 {
            let drawn = ScreenSettle.wait(baseline: startFrame, budget: max(0.3, min(1.2, activateStart + 3.0 - nowMonotonic)))
            if let last = drawn.last { noteSeen(last) }
            out["settle"] = drawn.json
        }
        if pidBefore >= 0 {
            out["was_running"] = .bool(pidBefore > 0)
            if pidBefore == 0 {
                forgetAppState(bundleId)
                launchedAt[bundleId] = nowMonotonic
                out["relaunched"] = .bool(true)
                out["message"] = .string("\(bundleId) was no longer running (iOS ends apps left in the background), so " +
                    "it started fresh: earlier screens, scroll position and refs are gone. Read the screen before acting.")
            }
        }
        // An alert (often another app's) covers the screen: the switch may
        // well have happened underneath it, and launch_app wouldn't help.
        if systemAlertUp(precise: true) {
            if front == "com.apple.springboard" { out["foreground_app"] = .string(bundleId) }
            flagAlert(&out)
            return (out, nil)
        }
        if front != bundleId {
            out["message"] = .string("Asked to activate \(bundleId), but \(front ?? "another app") is still in front.")
            out["hint"] = .string("The switch didn't happen. Try launch_app{bundle_id:\"\(bundleId)\"}, or home and then launch_app.")
        }
        return (out, nil)
    }

    /// A fresh process: whatever its tree had grown to, and what collect
    /// learned about it, is gone.
    private func forgetAppState(_ bundleId: String) {
        grownTree[bundleId] = nil
        heavyList[bundleId] = nil
        slowCappedRead[bundleId] = nil
        treeCost[bundleId] = nil
        liveWalkSlow.remove(bundleId)
        collectChildren[bundleId] = nil
        collectHistory[bundleId] = nil
        collectOCRMode[bundleId] = nil
        lastVisibleCells[bundleId] = nil
    }

    /// An app opened by launch_app/activate_app, not yet confirmed running.
    private var pendingRemember: String?

    /// Whether some node in a rendered (unclipped) tree has `cap` children —
    /// all a capped fetch allowed it.
    static func childCapHit(_ body: String, cap: Int) -> Bool {
        var counts: [Int: Int] = [:]   // indent of parent → children seen so far
        for line in body.split(separator: "\n") {
            let ind = line.prefix { $0 == " " }.count
            counts = counts.filter { $0.key < ind }
            counts[ind - 2, default: 0] += 1
            if counts[ind - 2]! >= cap { return true }
        }
        return false
    }

    /// Apps whose capped read was slow (a heavy list): page_source and page
    /// prefer the visible-cells read and pixel movement there.
    private var heavyList: [String: TimeInterval] = [:]
    private var slowCappedRead: [String: TimeInterval] = [:]

    /// A capped walk's cost toward calling the app's list heavy: one over 3s,
    /// or two over 1.5s within two minutes. A single slow read can be a hot
    /// phone rather than a heavy list; a heavy list keeps reading slowly.
    private func noteCappedCost(_ bid: String, seconds: Double) {
        if seconds > 3 {
            heavyList[bid] = nowMonotonic
        } else if seconds > 1.5 {
            if let prev = slowCappedRead[bid], nowMonotonic - prev < 120 { heavyList[bid] = nowMonotonic }
            slowCappedRead[bid] = nowMonotonic
        }
    }
    /// Apps whose list tree grew too large to read quickly, and when.
    private var grownTree: [String: TimeInterval] = [:]
    /// When each app was last launched: its first read is slow anyway.
    private var launchedAt: [String: TimeInterval] = [:]

    /// The visible part of a long list in page_source's text form, without
    /// walking the rows scrolled past: a shallow snapshot finds the list, the
    /// list names its visible cells (XC_kAXXCAttributeVisibleCells), only
    /// those are read, and they replace the list's subtree. Deep into a long
    /// list this stays near a second where the capped read takes many seconds.
    private func visibleListBody(_ bid: String, verifyFresh: Bool = true) -> (body: String, cells: Int, rows: Int, ms: Int)? {
        let t = nowMonotonic
        let screen = CGRect(x: 0, y: 0, width: pointSize.width, height: pointSize.height)
        var parts: [AnyHashable: Any]?
        var cellKey = ""
        // What the screen shows must be what this returns — more is fine,
        // less is not. The list can lag a scroll (returning the previous
        // screen's cells): the same cells as last time while the pixels
        // moved means stale, so wait and ask again; give up after three tries.
        let frameNow = ScreenSettle.sample()
        let tries = verifyFresh ? 3 : 1
        for attempt in 0..<tries {
            guard let d = ForegroundApp.visibleListParts(bid, screen: screen, maxElements: 2000),
                  let cells = d["cell_bodies"] as? [String], !cells.isEmpty else { return nil }
            cellKey = cells.map { String($0.prefix(120)) }.joined(separator: "|")
            if let last = lastVisibleCells[bid], last.key == cellKey, let a = last.frame, let b = frameNow,
               ScreenSettle.contentDiff(a, b) >= ScreenSettle.scrolledShare {
                if attempt == tries - 1 {
                    iCTRLUITests.logBuffer.append("⚡️ visible cells \(bid): still the previous screen's — tree read instead")
                    return nil
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                continue
            }
            parts = d
            break
        }
        guard let d = parts, let root = d["root_body"] as? String, let type = d["container_type"] as? String,
              let frameV = d["container_frame"] as? NSValue, let cells = d["cell_bodies"] as? [String] else { return nil }
        // Cells only: a section header or "show more" row between them isn't
        // one. A gap between consecutive on-screen cells means something
        // there wasn't read — read the tree instead.
        let tops = cells.compactMap { Self.frameOf(Substring($0.prefix { $0 != "\n" })) }
            .filter { $0[1] + $0[3] > 0 && $0[1] < Double(screen.height) }.sorted { $0[1] < $1[1] }
        for (a, b) in zip(tops, tops.dropFirst()) where b[1] - (a[1] + a[3]) > 80 {
            iCTRLUITests.logBuffer.append("⚡️ visible cells \(bid): \(Int(b[1] - (a[1] + a[3])))pt gap between cells — tree read instead")
            return nil
        }
        lastVisibleCells[bid] = (cellKey, frameNow, nowMonotonic)
        let cf = frameV.cgRectValue
        var lines = root.components(separatedBy: "\n")
        let rows = (d["children_count"] as? NSNumber)?.intValue ?? -1
        let cellLines: (Int) -> [String] = { indent in
            let pad = String(repeating: " ", count: indent)
            return cells.flatMap { $0.components(separatedBy: "\n").filter { !$0.isEmpty }.map { pad + $0 } }
        }
        if let i = lines.firstIndex(where: { l in
            l.drop { $0 == " " }.hasPrefix(type + ",") && Self.frameOf(Substring(l)).map {
                abs($0[0] - cf.minX) < 1 && abs($0[1] - cf.minY) < 1 && abs($0[2] - cf.width) < 1 } == true }) {
            let indent = lines[i].prefix { $0 == " " }.count
            var j = i + 1
            while j < lines.count, lines[j].prefix(while: { $0 == " " }).count > indent { j += 1 }
            lines.replaceSubrange((i + 1)..<j, with: cellLines(indent + 2))
        } else {
            lines += cellLines(2)
        }
        let ms = Int((nowMonotonic - t) * 1000)
        iCTRLUITests.logBuffer.append("⚡️ visible cells \(bid): \(cells.count) of \(rows) rows, \(ms)ms " +
            "(shallow \(Int((d["shallow_ms"] as? NSNumber)?.doubleValue ?? 0))ms)")
        return (lines.joined(separator: "\n"), cells.count, rows, ms)
    }

    /// The visible cells last read per app and the screen they came with,
    /// to tell a lagging list from a scrolled one.
    private var lastVisibleCells: [String: (key: String, frame: ScreenSettle.Frame?, at: TimeInterval)] = [:]

    /// What scroll_position's own walk (1000 children a node) last cost per
    /// app: on a list that keeps its scrolled-past rows it can grow past a
    /// second of every read, so it is skipped there for a while.
    private var scrollPositionCost: [String: (s: Double, at: TimeInterval)] = [:]

    /// Post-fetch costs of the current page_source, logged when slow.
    private var readLaps: [String] = []
    private func timedLap<T>(_ name: String, _ work: () -> T) -> T {
        let t = nowMonotonic
        let v = work()
        let ms = Int((nowMonotonic - t) * 1000)
        if ms >= 150 { readLaps.append("\(name)=\(ms)ms") }
        return v
    }

    /// Note that `bundleId` was just opened; it is recorded in AppMemory the
    /// first time a read of it succeeds (see confirmOpened).
    ///
    /// Not confirmed here: asking XCTest for an app's state right after opening
    /// it blocks ~2s ("Unable to update application state promptly") — which
    /// made every launch_app take 2.9s instead of 0.9s, then came back
    /// "unknown", so nothing was remembered either. And YES from
    /// openApplicationWithBundleID: means the request was accepted, not that
    /// anything launched, so it can't stand in as proof.
    private func rememberOpened(_ bundleId: String) {
        pendingRemember = bundleId
    }

    /// A read of `bundleId` succeeded — proof it is installed and running.
    /// `name` comes from the tree's Application node when the caller has it.
    private func confirmOpened(_ bundleId: String?, name: String?) {
        guard let bundleId = bundleId, bundleId == pendingRemember else { return }
        pendingRemember = nil
        AppMemory.shared.recordOpened(bundleId: bundleId, name: name)
        iCTRLUITests.logBuffer.append("📒 remembered \(bundleId)\(name.map { " as '\($0)'" } ?? "")")
    }

    private func terminateApp(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        guard let bundleId = cmd.bundleId else {
            return (nil, JSONRPCError(code: -32602, message: "terminate_app requires a 'bundle_id'", data: nil))
        }
        let pidBefore = ForegroundApp.processID(forBundleID: bundleId)
        // On this thread (the main one), not via runWithTimeout: XCTest
        // asserts "-[XCUIApplication terminate] must be called on the main
        // thread"; elsewhere the exception is swallowed and terminate_app
        // would report "Terminated" while the app kept running with all its
        // accumulated state.
        _ = ForegroundApp.safeTerminateBundleID(bundleId)
        var pidAfter = ForegroundApp.processID(forBundleID: bundleId)
        for _ in 0..<10 where pidBefore > 0 && pidAfter == pidBefore {
            usleep(150_000)
            pidAfter = ForegroundApp.processID(forBundleID: bundleId)
        }
        iCTRLUITests.logBuffer.append("🪓 terminate \(bundleId): pid \(pidBefore) → \(pidAfter)")
        frontByPID[pidBefore] = nil
        if pidAfter != pidBefore { forgetAppState(bundleId) }
        if pidBefore > 0, pidAfter == pidBefore {
            return (nil, .serverError("terminate_app couldn't end \(bundleId): it is still running (pid \(pidBefore)). " +
                "A relaunch won't start it fresh; swipe it away in the app switcher if a clean start matters."))
        }
        return (["message": .string(pidBefore > 0 ? "Terminated \(bundleId) (pid \(pidBefore))" : "\(bundleId) wasn't running")], nil)
    }

    // MARK: - View Hierarchy

    /// Returns the accessibility/view hierarchy as text — the PREFERRED way for a
    /// model to understand layout (element types, labels, identifiers, frames)
    /// without decoding a screenshot image. Pass bundle_id to inspect a specific
    /// foreground app; otherwise the whole screen (SpringBoard) tree is returned.
    /// Set when locateElement refused to run because the target app can't be
    /// snapshotted. `locateElement` returns an optional so its callers can treat
    /// "not found" uniformly; this carries the actionable reason alongside, so a
    /// backgrounded app reports as such instead of as a plain miss.
    private var lastLocateError: JSONRPCError?

    /// Snapshot geometry of the node the last locate finally chose
    /// (post-elevation). nil when the live-query fallback matched — that path
    /// has no snapshot, and consumers must read the live element instead.
    /// Same clear-per-call pattern as lastLocateError.
    private var lastLocateSnapFrame: CGRect?
    private var lastLocateSnapLabel: String?
    /// Every candidate the last bounded locate saw, best first — lets
    /// find_element say "3 matches, picked the on-screen one" instead of
    /// silently choosing. nil when a fallback path matched.
    private var lastLocateScan: LocateScan?

    /// One match from `ForegroundApp.locateInBoundedSnapshot`.
    struct LocateHit {
        let label: String
        let identifier: String
        let value: String
        let elementType: XCUIElement.ElementType
        let byLabel: Bool          // re-resolve by label (else by identifier)
        let byValue: Bool          // only a value: no live re-resolve, act on the frame
        let ordinal: Int           // index among same-label (or same-id) live matches
        let how: String            // exact | id | contains
        let frame: CGRect
        let visibility: String     // in_view | partial | offscreen
        let container: CGRect?     // nearest scrollable ancestor

        var inView: Bool { visibility == "in_view" }
        var match: ElementRef.Match { byLabel ? .exactLabel(label) : .identifier(identifier) }

        init?(_ d: [String: Any]) {
            func num(_ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
            label = d["label"] as? String ?? ""
            identifier = d["identifier"] as? String ?? ""
            value = d["value"] as? String ?? ""
            elementType = XCUIElement.ElementType(rawValue: (d["type"] as? NSNumber)?.uintValue ?? 0) ?? .any
            let key = d["key"] as? String
            byValue = key == "value"
            byLabel = key == "label"
            ordinal = (d["ordinal"] as? NSNumber)?.intValue ?? 0
            how = d["how"] as? String ?? "exact"
            frame = CGRect(x: num("x"), y: num("y"), width: num("w"), height: num("h"))
            visibility = d["visibility"] as? String ?? "offscreen"
            container = (d["container"] as? [String: Any]).map(LocateScan.rect)
            if byValue ? value.isEmpty : (byLabel ? label.isEmpty : identifier.isEmpty) { return nil }
        }

        var summary: JSONValue {
            .object([
                "label": .string(label.isEmpty ? identifier : label),
                "visibility": .string(visibility),
                "center_x": .double(frame.midX),
                "center_y": .double(frame.midY),
            ])
        }
    }

    /// The result of one bounded walk: ranked candidates plus the screen facts
    /// scroll_to_element steers by.
    struct LocateScan {
        let candidates: [LocateHit]
        let contentTop: Double
        let contentBottom: Double
        let fingerprint: String
        let scrollContainer: CGRect?
        let visited: Int

        static func rect(_ d: [String: Any]) -> CGRect {
            func num(_ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
            return CGRect(x: num("x"), y: num("y"), width: num("w"), height: num("h"))
        }
    }

    /// XCUIElementType raw values matching `elementQuery(in:type:)` exactly —
    /// the ordinal a candidate carries is only meaningful against a live query
    /// filtered the same way. nil = any type.
    /// Element types by every name a caller might use: the renderer's own
    /// names (what page_source prints: "SearchField", "StaticText"…), plus
    /// a few aliases. Unknown names used to be silently ignored, so
    /// element_type:"SearchField" filtered nothing and returned a StaticText.
    private static let typeNames: [String: [XCUIElement.ElementType]] = {
        var m: [String: [XCUIElement.ElementType]] = [:]
        for raw in UInt(0)...UInt(90) {
            guard let t = XCUIElement.ElementType(rawValue: raw) else { continue }
            let name = elementTypeName(t).lowercased()
            if !name.isEmpty, !name.hasPrefix("type"), m[name] == nil { m[name] = [t] }
        }
        // A search box or password box is a text field to whoever asks for one.
        m["textfield"] = [.textField, .searchField, .secureTextField]
        m["text_field"] = m["textfield"]
        m["input"] = [.textField, .searchField, .secureTextField, .textView]
        m["text_view"] = [.textView]
        m["search_field"] = [.searchField]
        m["label"] = [.staticText]
        m["static_text"] = [.staticText]
        m["text"] = [.staticText]
        return m
    }()

    /// nil = no filter. Throws-by-result: `unknownType` is set for a name
    /// nothing maps to, so the caller can say so instead of ignoring it.
    private static func typeFilterRaws(_ type: String?) -> [NSNumber]? {
        guard let key = type?.lowercased().replacingOccurrences(of: " ", with: ""), !key.isEmpty else { return nil }
        guard let types = typeNames[key] else { return [] }   // matches nothing → "no element of type X"
        return types.map { NSNumber(value: $0.rawValue) }
    }

    /// One bounded snapshot, every match ranked. nil when the bounded path is
    /// unavailable — callers fall back rather than treating that as "absent".
    private func scanCandidates(query: String, type: String?, matchMode: String,
                                bundleId: String,
                                maxChildren: Int = ActionHandler.maxChildrenPerNode) -> LocateScan? {
        guard let root = ForegroundApp.boundedSnapshot(
                forBundleID: bundleId,
                maxDepth: Self.defaultMaxDepth,
                maxChildren: maxChildren),
              let r = ForegroundApp.locate(
                inBoundedSnapshot: root, query: query,
                contains: matchMode == "contains",
                types: Self.typeFilterRaws(type),
                viewport: CGRect(x: 0, y: 0, width: pointSize.width, height: pointSize.height),
                maxDepth: Self.defaultMaxDepth) as? [String: Any] else { return nil }
        let raw = r["candidates"] as? [[String: Any]] ?? []
        var hits = raw.compactMap(LocateHit.init)
        if matchMode == "contains" { hits = Self.rankContains(hits, query: query) }
        return LocateScan(
            candidates: hits,
            contentTop: (r["content_top"] as? NSNumber)?.doubleValue ?? 0,
            contentBottom: (r["content_bottom"] as? NSNumber)?.doubleValue ?? pointSize.height,
            fingerprint: r["fingerprint"] as? String ?? "",
            scrollContainer: (r["scroll_container"] as? [String: Any]).map(LocateScan.rect),
            visited: (r["visited"] as? NSNumber)?.intValue ?? 0)
    }

    /// Contains-matching "Allow" also matches "Don't Allow" — the opposite
    /// answer, which may come first. Negations of the query are dropped
    /// (the not-found error still lists them among the on-screen labels),
    /// the exact label goes first, and otherwise the locator's order stands.
    static func rankContains(_ hits: [LocateHit], query: String) -> [LocateHit] {
        let q = query.lowercased()
        func rank(_ h: LocateHit) -> Int {
            let l = h.label.lowercased()
            let negated = ["不", "别", "拒绝", "don't ", "do not ", "not ", "never "].contains { neg in
                l.contains(neg + q) || l.hasPrefix(neg) && !q.hasPrefix(neg) && l.contains(q)
            }
            if negated { return 2 }
            return l == q || h.identifier.lowercased() == q ? 0 : 1
        }
        return hits.enumerated()
            .filter { rank($0.element) < 2 }
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// Re-resolve a snapshot hit to the LIVE element that IS that node.
    ///
    /// `label == X` + firstMatch returned whichever same-labelled element came
    /// first — with two "日历" buttons, or a month view holding "25" in three
    /// months, that is routinely a different one. The ordinal picks the same
    /// position; the frame check confirms it, and a short scan recovers when
    /// the tree shifted between the snapshot and now.
    private func liveElement(for hit: LocateHit, in q: XCUIElementQuery) -> (XCUIElement, Int)? {
        let sub = hit.byLabel
            ? q.matching(NSPredicate(format: "label == %@", hit.label))
            : q.matching(identifier: hit.identifier)
        func sameSpot(_ el: XCUIElement) -> Bool {
            let f = el.frame
            return abs(f.midX - hit.frame.midX) <= 2 && abs(f.midY - hit.frame.midY) <= 2
        }
        let atOrdinal = sub.element(boundBy: hit.ordinal)
        let probeStart = nowMonotonic
        let exists = atOrdinal.safeExists
        if exists, sameSpot(atOrdinal) { return (atOrdinal, hit.ordinal) }
        // Each probe here is a whole-app walk. When the first pair was already
        // slow, more of them only add walks (on an app busy starting up, one
        // more can run past 6s): keep the snapshot's ordinal.
        if nowMonotonic - probeStart > 0.8 {
            return exists ? (atOrdinal, hit.ordinal) : nil
        }
        for i in 0..<6 where i != hit.ordinal {
            let el = sub.element(boundBy: i)
            guard el.safeExists else { break }
            if sameSpot(el) { return (el, i) }
        }
        // Frames can legitimately move (an animation settling); the ordinal is
        // still the best guess at the same node.
        return atOrdinal.safeExists ? (atOrdinal, hit.ordinal) : nil
    }

    /// Refuses a snapshot that is going to fail slowly, before it is attempted.
    ///
    /// `snapshot()` on an app that isn't frontmost has no main window to read, so
    /// the accessibility server answers `kAXErrorServerNotFound` — but only after
    /// XCTest's internal ~16s timeout. That call cannot be cancelled, and the RPC
    /// queue is serial, so those 16s block every later request too: one
    /// backgrounded app stalls tap, screenshot, even device_info. Checking the
    /// app's state up front turns that into an instant, actionable error.
    ///
    /// SpringBoard is always readable, so it's exempt.
    ///
    /// `strict` is for callers that go on to query THIS app (find, scroll):
    /// they must not proceed just because something else is in front, since the
    /// query would still be aimed at the backgrounded app.
    static func snapshotPrecheck(bundleId: String?, action: String,
                                 retryWith method: String, strict: Bool = false) -> JSONRPCError? {
        guard let bid = bundleId, bid != "com.apple.springboard" else { return nil }
        // Just named as the front app (by pid): no need to ask XCTest's
        // state, which lags on iOS 27 and can report an app that is on screen
        // as "in the background".
        if let front = lastFront, front.bid == bid, ProcessInfo.processInfo.systemUptime - front.at < 2 { return nil }
        var state = AppState(rawValue: ForegroundApp.appState(forBundleID: bid)) ?? .unknown

        // The id checked may be one the caller named, or one a ref was made in,
        // rather than what is on screen now. If that app has gone to the
        // background but something else is frontmost, the screen is still
        // readable — refusing would be wrong for a plain read (a screenshot can
        // succeed while the named app reports no snapshottable window).
        if !strict, state == .background || state == .backgroundSuspended || state == .notRunning,
           let live = ForegroundApp.currentBundleID(), !live.isEmpty, live != bid {
            let liveState = AppState(rawValue: ForegroundApp.appState(forBundleID: live)) ?? .unknown
            if liveState == .foreground || liveState == .unknown {
                iCTRLUITests.logBuffer.append(
                    "🔀 precheck: \(bid) is \(state), but \(live) is frontmost — proceeding")
                state = .foreground
            }
        }

        switch state {
        case .notRunning:
            return JSONRPCError(code: -32004, message:
                "Can't \(action): app '\(bid)' is not running (it may have crashed or been closed). " +
                "Call launch_app to (re)open it, then retry.", data: nil)
        case .background, .backgroundSuspended:
            return JSONRPCError(code: -32004, message:
                "Can't \(action): app '\(bid)' is in the background, so it has no snapshottable window. " +
                "What is on screen is something else now — read it (page_source/screenshot) and decide; to go " +
                "back to this app, call activate_app/launch_app, then retry \(method).", data: nil)
        default:
            return nil  // foreground or unknown → proceed (unknown may still work)
        }
    }

    /// Diagnostic: measures whether XCTest's snapshot request honours a
    /// server-side depth limit, which is the only way to make page_source cheaper
    /// on a large tree — our own max_depth trims after the whole tree has already
    /// been walked and shipped across IPC.
    private func snapshotBench(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        guard let bundleId = cmd.bundleId ?? resolveForegroundBundleId() else {
            return (nil, .serverError("snapshot_bench needs a bundle_id (or a resolvable foreground app)."))
        }
        if let err = Self.snapshotPrecheck(bundleId: bundleId, action: "benchmark the view tree",
                                           retryWith: "snapshot_bench") {
            return (nil, err)
        }
        // element_id names the single property to sample off a node; reading
        // several undocumented getters in one pass hard-crashed the runner.
        ForegroundApp.setProbeSelectorName(cmd.elementId)
        // Negative depth = "use |depth| but SKIP the unbounded baseline". That
        // baseline is an unlimited snapshot which can hang the accessibility
        // connection badly enough that only restarting the runner recovers it,
        // so it must be asked for explicitly (positive max_depth), never default.
        let depth = cmd.maxDepth ?? -8
        guard let raw = ForegroundApp.benchmarkSnapshot(forBundleID: bundleId, maxDepth: depth) else {
            return (nil, .serverError("snapshot_bench unavailable: private XCTest API missing on this build."))
        }
        var out: [String: JSONValue] = ["bundle_id": .string(bundleId)]
        for (k, v) in raw {
            guard let key = k as? String else { continue }
            if let n = v as? NSNumber { out[key] = .int(n.intValue) }
            else if let s = v as? String { out[key] = .string(s) }
        }
        return (out, nil)
    }

    private func pageSource(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        // enhanced: the whole tree, then OCR for what it lacks (see ocrOnly).
        var cmd = cmd
        if cmd.enhanced == true, cmd.maxChildren == nil { cmd.maxChildren = 5000 }
        // Resolve which app to inspect:
        //   explicit bundle_id → that app
        //   otherwise → the app actually in front
        let inspectedBundleId = cmd.bundleId ?? resolveForegroundBundleId()

        let target: XCUIApplication
        if let bundleId = inspectedBundleId {
            target = XCUIApplication(bundleIdentifier: bundleId)
        } else {
            // Last resort: SpringBoard (only system UI — warn the caller).
            target = app
        }

        if let err = Self.snapshotPrecheck(bundleId: inspectedBundleId, action: "read the view tree",
                                           retryWith: "page_source") {
            return (nil, err)
        }

        // Custom snapshot traversal so we can bound depth / count and filter —
        // debugDescription enumerates & serializes the WHOLE tree (68KB+ on rich
        // pages), which is what makes the first call block for tens of seconds.
        // 40 covers the deepest rows real apps put content at (X's feed cells sit
        // near depth 22) without walking the pathological tail of a long-scrolled
        // list. Unbounded was the old default and is what made a deep feed read
        // take seconds.
        let maxDepth = cmd.maxDepth ?? Self.defaultMaxDepth
        // Hard cap to prevent timeouts even when the caller passes nothing.
        // Raised with max_children: a timeline page already returned ~370 nodes
        // under the old 100-child cap, so leaving this at 500 would just move the
        // truncation from one limit to the other.
        let maxElements = min(cmd.maxElements ?? 2000, 4000)
        let filter = SnapshotFilter(type: cmd.filterType, label: cmd.filterLabel, text: cmd.filterText)

        // Snapshot roots to render. We take the single application.snapshot()
        // (fast, ~0.5-1s, already contains the main window hierarchy) AND any
        // additional VISIBLE overlay windows — so fixed floating bars (e.g. a
        // buy/submit bar in a separate window) are always included. No opt-in flag
        // is needed because we don't blindly walk every window: the earlier 17s
        // hang came from snapshotting all ~8 windows including offscreen/zero-size
        // ones. Here we frame-check first and only snapshot the 1-2 windows the
        // user can actually see, under a hard 3s budget.
        var roots: [XCUIElementSnapshot] = []
        // Prefer the device-bounded fetch: it applies max_depth/max_children
        // while the app walks its own tree, instead of shipping everything over
        // and trimming here. On a scrolled X timeline that is ~1.6s vs 6.5-8.5s.
        // It rides on private XCTest API that has already moved several times, so
        // any failure falls through to the supported call rather than surfacing.
        // Rendered in Obj-C: the bounded fetch returns an XCElementSnapshot, and
        // bridging it to the XCUIElementSnapshot protocol silently degrades it —
        // frames read as zero and children stop after one level. Filters still
        // run through the protocol path, so fall back when one is active.
        var usedBoundedSnapshot = false
        var boundedBody: String?
        var rawBoundedBody: String?
        var boundedCount = 0
        var boundedTruncated = false
        // Re-enabled after the empty-tree cause was found. It was never the
        // renderer: the bounded fetch passed standardAttributeNames raw, whose
        // snapshot-domain names ("label") the AX server silently ignores — only
        // the XC_kAXXCAttribute* wire keys fetch content, and snapshot_bench had
        // them while this path didn't. With the same attrs both read full text.
        // Verify snapshot_path:"bounded" appears in responses; a silent fall
        // back to "full" is how a future private-API shift will present.
        // Phase timings: the two costs here are very different in nature — the
        // AX round trip into the target app (fetch) vs. walking the returned
        // tree and building strings (render). A single total can't tell you
        // which one a slow page is paying for, and they have opposite fixes.
        var fetchMs = 0.0
        var renderMs = 0.0
        var childrenUsed = 0
        var ladderSteps: [String] = []
        var capRaisedForGrowth = false
        var ocrFallback: (items: [JSONValue], shotMs: Double, ocrMs: Double)?
        let boundedEnabled = true
        let fetchStart = nowMonotonic

        // maxChildren is one of only TWO knobs the AX server honours at fetch
        // time (the other is maxDepth). Measured: max_elements does NOT bound the
        // fetch — 20 vs 2000 both cost ~90ms, because it truncates after the tree
        // is already materialised. On a wide recycling list, capping children is
        // the only way to stop the server walking thousands of cells at all.
        //
        // An explicit max_children pins the value (one fetch, no ladder) so the
        // parameter stays predictable for callers doing their own tuning.
        let pinnedChildren = cmd.maxChildren.map { max(1, min($0, 5000)) }

        /// One bounded fetch + render at a given child cap.
        func attempt(_ children: Int) -> (body: String, nodes: Int, truncated: Bool, capHit: () -> Bool)? {
            guard let bid = inspectedBundleId,
                  let bounded = ForegroundApp.boundedSnapshot(
                    forBundleID: bid,
                    maxDepth: maxDepth == Int.max ? Self.defaultMaxDepth : maxDepth,
                    maxChildren: children)
            else { return nil }
            var n = 0
            var t: ObjCBool = false
            let viewport = cmd.visibleOnly == true
                ? CGRect(x: 0, y: 0, width: pointSize.width, height: pointSize.height)
                : CGRect.null
            guard let text = ForegroundApp.renderBoundedSnapshot(
                    bounded,
                    maxDepth: maxDepth == Int.max ? Self.defaultMaxDepth : maxDepth,
                    maxElements: maxElements,
                    visibleRect: viewport,
                    nodesWritten: &n,
                    truncated: &t) else { return nil }
            // Whether some node gave all `children` it was allowed: rows
            // scrolled past pile up in a list's container, fill the cap, and
            // push the on-screen rows out (after a long scroll, coverage can
            // drop to a few percent at 50). Rendered again from the same fetch,
            // unclipped. Asked only when a read comes back thin: on a large tree
            // the extra render costs up to a second a read when run every time.
            let depth = maxDepth == Int.max ? Self.defaultMaxDepth : maxDepth
            let capHit = { () -> Bool in
                var m = 0
                var t2: ObjCBool = false
                return ForegroundApp.renderBoundedSnapshot(bounded, maxDepth: depth, maxElements: 4000, visibleRect: .null,
                                                           nodesWritten: &m, truncated: &t2).map { Self.childCapHit($0, cap: children) } ?? false
            }
            return (text, n, t.boolValue, capHit)
        }

        // Known not to answer (see below), recently: skip straight to OCR
        // rather than waiting out another tree timeout first.
        var grownSkip = false
        var visibleCellsRead: (cells: Int, rows: Int)?
        if let bid = inspectedBundleId, (treeCost[bid] ?? 0) >= 99, nowMonotonic - treeCostAt < 20 {
            fetchMs = 99_000
        } else if cmd.visibleOnly == true, !filter.active, cmd.maxChildren.map({ $0 <= 100 }) ?? true,
                  let bid = inspectedBundleId, (grownTree[bid].map { nowMonotonic - $0 < 300 } ?? false) || (heavyList[bid].map { nowMonotonic - $0 < 300 } ?? false),
                  collectNoCells[bid].map({ nowMonotonic - $0 > 300 }) ?? true, let fast = visibleListBody(bid) {
            // A list known to have grown: its visible cells only, whatever its size.
            rawBoundedBody = fast.body
            boundedBody = fast.body
            boundedCount = fast.body.components(separatedBy: "\n").count
            usedBoundedSnapshot = true
            childrenUsed = 0
            fetchMs = Double(fast.ms)
            visibleCellsRead = (fast.cells, fast.rows)
        } else if let bid = inspectedBundleId, let at = grownTree[bid], nowMonotonic - at < 60, cmd.maxChildren.map({ $0 <= 200 }) ?? true {
            // Grown too big to read quickly (see below): OCR for a while.
            fetchMs = 99_000
            grownSkip = true
        } else if boundedEnabled, inspectedBundleId != nil {
            var chosen: (body: String, nodes: Int, truncated: Bool, capHit: () -> Bool)?
            var usedChildren = 0

            if let pinned = pinnedChildren {
                chosen = attempt(pinned)
                usedChildren = pinned
                // A caller pinning max_children:50 (as documented usage does) skips
                // the climb below, and on a grown list got a few percent coverage
                // and "ocr". Widen once there too.
                if pinned <= 100, let c = chosen, cmd.visibleOnly == true,
                   visibleLabelledCoverage(c.body) < Self.treeCoverageThreshold,
                   Self.contentTextCount(c.body, height: pointSize.height) < Self.minTreeTextItems, c.capHit(),
                   let bid = inspectedBundleId, let fast = visibleListBody(bid) {
                    chosen = (fast.body, fast.body.components(separatedBy: "\n").count, false, { false })
                    capRaisedForGrowth = true
                    visibleCellsRead = (fast.cells, fast.rows)
                    grownTree[bid] = nowMonotonic
                    ladderSteps.append("pinned\(pinned)→visible-cells")
                } else if pinned <= 100, let c = chosen,
                   visibleLabelledCoverage(c.body) < Self.treeCoverageThreshold,
                   Self.contentTextCount(c.body, height: pointSize.height) < Self.minTreeTextItems, c.capHit(),
                   let wider = attempt(200),
                   visibleLabelledCoverage(wider.body) >= Self.treeCoverageThreshold
                    || Self.contentTextCount(wider.body, height: pointSize.height) >= Self.minTreeTextItems {
                    chosen = wider
                    usedChildren = 200
                    capRaisedForGrowth = true
                    ladderSteps.append("pinned\(pinned)→200")
                }
            } else {
                // Climb only while the probe says list content stops ABOVE the
                // viewport AND the container still has more to give.
                // Start cheap: measured p50 416ms / p90 593ms across 8 apps, and
                // on every app whose list behaves normally this is also COMPLETE
                // (verified at 6-8 pages of scroll in RED/GitHub/JD: identical
                // visible labels to an unbounded read, half the time).
                if let first = attempt(Self.childrenLadder[0]) {
                    chosen = first
                    usedChildren = Self.childrenLadder[0]
                    let coverage = visibleLabelledCoverage(first.body)
                    ladderSteps.append(String(format: "50:%.0f%%", coverage * 100))
                    if let bid = inspectedBundleId, let frame = ScreenSettle.sample() {
                        coverageCache = (bid, frame, coverage)
                        readFrame = frame   // also serves page_check's "last seen"
                    }

                    // Escalate when the tree barely describes the content area. A
                    // ratio rather than a node count: count thresholds encode
                    // assumptions about screen size and row density that break on
                    // the next device or app, while a fraction of the content band
                    // means the same thing everywhere.
                    //
                    // The bar is deliberately LOW. Measured coverages:
                    //   WeChat scrolled  0%  — tree had only nav/tab furniture
                    //   Telegram        11%  — genuinely missing rows
                    //   RED (小红书)     26%  — tree was COMPLETE; every title,
                    //                          author and like count was present.
                    //                          It reads low only because its cards
                    //                          are mostly images, so text covers
                    //                          little area.
                    //   GitHub 92%, App Store 100%, Spotify 89%, X 100%
                    // A 50% bar fired on RED and cost ~400ms of OCR for nothing.
                    // 15% separates the real failures (0-11%) from sparse-but-fine
                    // layouts (26%+) on everything measured.
                    // Text that covers little area is still text: a list of short
                    // titles can sit under 10% coverage and need no OCR.
                    // Low because the cap cut the visible rows off, not because
                    // the app hides them: widen once before giving up on the tree.
                    var widened = false
                    if cmd.visibleOnly == true, coverage < Self.treeCoverageThreshold,
                       Self.contentTextCount(first.body, height: pointSize.height) < Self.minTreeTextItems, first.capHit(),
                       let bid = inspectedBundleId, let fast = visibleListBody(bid) {
                        chosen = (fast.body, fast.body.components(separatedBy: "\n").count, false, { false })
                        ladderSteps.append("visible-cells:\(fast.cells)/\(fast.rows)")
                        widened = true
                        capRaisedForGrowth = true
                        visibleCellsRead = (fast.cells, fast.rows)
                        grownTree[bid] = nowMonotonic
                    }
                    if !widened, coverage < Self.treeCoverageThreshold, nowMonotonic - fetchStart < 2.0,
                       Self.contentTextCount(first.body, height: pointSize.height) < Self.minTreeTextItems, first.capHit(),
                       let wider = attempt(200) {
                        let c2 = visibleLabelledCoverage(wider.body)
                        ladderSteps.append(String(format: "200:%.0f%%", c2 * 100))
                        if c2 >= Self.treeCoverageThreshold
                            || Self.contentTextCount(wider.body, height: pointSize.height) >= Self.minTreeTextItems {
                            chosen = wider
                            usedChildren = 200
                            widened = true
                            capRaisedForGrowth = true
                        }
                    }
                    if !widened, coverage < Self.treeCoverageThreshold,
                       Self.contentTextCount(first.body, height: pointSize.height) < Self.minTreeTextItems {
                        // Run the wider fetch and the OCR CONCURRENTLY: serially
                        // they are ~1.2s + ~0.7s, which blows the 1s budget on
                        // exactly the screens that need help most.
                        //
                        // Only the screen CAPTURE is main-thread bound (XCUIScreen,
                        // like every other UI call here); Vision itself is pure
                        // image work. So grab the frame first — cheap, ~106ms —
                        // then let recognition run on a background queue while the
                        // accessibility server walks the bigger tree.
                        // Run OCR INLINE, not on another queue waited on from here.
                        //
                        // The earlier "parallel" version deadlocked the runner: a
                        // page_source is delivered via DispatchQueue.main.sync, so
                        // blocking that main thread on a semaphore while Vision
                        // worked on a background queue left nothing to service work
                        // Vision itself hops to the main queue for. One page_source
                        // on a scrolled WeChat list was enough to kill the HTTP
                        // layer outright — socket still accepting, no responses,
                        // recoverable only by restarting the runner.
                        //
                        // Inline costs ~260ms and cannot deadlock. The theoretical
                        // saving from overlapping it with the wider fetch was ~260ms;
                        // not worth a whole-server hang.
                        //
                        // The wider fetch is also skipped here: measured on exactly
                        // this case it ALSO returns zero on-screen rows, so its
                        // ~1.2s bought nothing. OCR is what actually reads the
                        // screen (tree 6 texts vs OCR 35).
                        ladderSteps.append("500:skipped(ocr)")
                        ocrFallback = runOCR(query: nil, fast: false, minConfidence: 0.3)
                    }
                }
            }

            childrenUsed = usedChildren
            fetchMs = (nowMonotonic - fetchStart) * 1000
            // A capped read this slow (seconds from the first screen at full
            // coverage, timeouts after a long scroll) is a heavy list: read its
            // visible cells from now on (falls back to this read if it has none).
            // Two slow reads in a row: one alone may be a hot phone, which would
            // flag a light app and cost its pages their movement check.
            if cmd.visibleOnly == true, let bid = inspectedBundleId, !capRaisedForGrowth {
                noteCappedCost(bid, seconds: fetchMs / 1000)
            }
            // Widening kept the visible rows but costs more every screen as
            // the list grows (from about a second to many seconds over a few
            // dozen screens). Past 3s, read this app by OCR for a minute.
            if capRaisedForGrowth, fetchMs > 3000, let bid = inspectedBundleId {
                grownTree[bid] = nowMonotonic
                iCTRLUITests.logBuffer.append("🌳 \(bid) tree has grown too large (\(Int(fetchMs))ms) — OCR for the next reads")
            }
            if let bid = inspectedBundleId { treeCost[bid] = fetchMs / 1000 }
            if let got = chosen {
                let renderStart = nowMonotonic
                // Acceptance: a sizeable tree with NO labels at all is the known
                // bad-fetch signature (wrong attribute domain → shape without
                // content), not a plausible real screen. Falling back to the full
                // snapshot there costs seconds; shipping a content-free tree
                // costs the caller a wrong "this page is empty" conclusion.
                //
                // Judged on the RAW fetch: a filter legitimately reduces the tree
                // to a handful of nodes, and judging the filtered text would read
                // that as the bad-fetch signature and fall back for no reason.
                if got.nodes > 1, got.nodes < 40 || got.body.contains("label:") {
                    rawBoundedBody = got.body
                    if filter.active {
                        let (filtered, matches) = Self.filterRenderedTree(got.body, filter: filter)
                        boundedBody = filtered
                        boundedCount = matches
                    } else {
                        boundedBody = got.body
                        boundedCount = got.nodes
                    }
                    boundedTruncated = got.truncated
                    usedBoundedSnapshot = true
                }
                renderMs = (nowMonotonic - renderStart) * 1000
            }
        }

        // The capped fetch failed after a long wait: the app's accessibility
        // isn't answering (kAXErrorIPCTimeout). The full-snapshot fallback
        // below would make XCTest retry it ~9 times at the AX timeout each —
        // well over a minute, wedging every call behind it. Read the screen
        // by OCR instead, and mark the tree slow so other calls skip it too.
        if !usedBoundedSnapshot, let bid = inspectedBundleId, fetchMs > 3000 {
            if fetchMs < 99_000 { treeCost[bid] = 99 }
            if !grownSkip {
                iCTRLUITests.logBuffer.append("🧊 \(bid) accessibility not answering (\(Int(fetchMs))ms) — OCR instead of the full snapshot")
            }
            guard let ocr = runOCR(query: nil, fast: false, minConfidence: 0.3) else {
                return (nil, .serverError("\(bid)'s accessibility isn't answering right now and the screen couldn't be " +
                                          "captured either. Take a screenshot, wait a moment, and read again."))
            }
            var out: [String: JSONValue] = [
                "source": .string(""),
                "bundle_id": .string(bid),
                "ax_unresponsive": .bool(true),
                "ocr_items": .array(ocr.items),
                "ocr_count": .int(ocr.items.count),
                // 99_000 marks "skipped, known unresponsive" — not a time.
                "timing": .object(["fetch_ms": .int(fetchMs >= 99_000 ? 0 : Int(fetchMs)), "ocr_ms": .int(Int(ocr.ocrMs)),
                                   "tree_skipped": .bool(fetchMs >= 99_000)]),
                "hint": .string("This app's accessibility isn't answering (" +
                                (fetchMs >= 99_000 ? "it timed out moments ago" : "its tree request timed out after \(Int(fetchMs / 1000))s") +
                                " — often a busy feed or playing video), so the screen was read " +
                                "by OCR: use ocr_items and tap{x:center_x,y:center_y}. find_element and refs won't work " +
                                "until it recovers; screenshots and coordinate actions do."),
            ]
            if grownSkip {
                out["ax_unresponsive"] = nil
                out["tree_growth"] = .bool(true)
                out["hint"] = .string("This list keeps the rows already scrolled past, and its tree has grown too large " +
                    "to read quickly, so the screen was read by OCR (~1s): use ocr_items and tap{x:center_x,y:center_y}. " +
                    "Relaunching the app (terminate_app + launch_app; loses your position) makes the tree small again; " +
                    "pass max_children explicitly to force a tree read.")
            }
            flagBlockers(ocr.items.compactMap(Self.ocrScreenText), bid: bid, overlayShown: false, into: &out)
            // An app busy drawing its first page is often the one not answering.
            if ocr.items.count <= 2, let frame = readFrame, ScreenSettle.blankShare(frame) >= 0.85 {
                out["loading"] = .bool(true)
                out["loading_reason"] = .string("blank")
                if case .string(let h)? = out["hint"] { out["hint"] = .string(Self.blankLoadingHint + " " + h) }
            }
            return (out, nil)
        }

        let appSnap = usedBoundedSnapshot
            ? nil
            : (ForegroundApp.safeSnapshot(ofElement: target) as? XCUIElementSnapshot)
        if let appSnap = appSnap { roots.append(appSnap) }

        let screen = pointSize
        // With the 2s XCTest state-timeout cap, target.snapshot() above is bounded;
        // keep the overlay budget tight too so total page_source stays well under
        // the 6s RPC watchdog even on a busy/animating page.
        let budgetDeadline = nowMonotonic + 2.0
        // Skip entirely when the bounded root is in play: win.snapshot() is the
        // unbounded call, so walking overlays here would pay back the very cost
        // the bounded fetch just avoided. The bounded root is taken at the
        // application element, so it already spans that app's windows.
        let windowCount = usedBoundedSnapshot ? 0 : min(target.windows.count, 6)
        for i in 0..<windowCount {
            if nowMonotonic >= budgetDeadline { break }
            let win = target.windows.element(boundBy: i)
            // Cheap frame check first — skip offscreen / zero-size / inactive
            // windows so we only pay snapshot cost for windows the user can see.
            let f = win.frame
            let onScreen = f.width > 1 && f.height > 1
                && f.minX < screen.width && f.minY < screen.height
                && f.maxX > 0 && f.maxY > 0
            guard onScreen else { continue }
            // Skip a window that's the same size as the app root (already covered).
            if let appSnap = appSnap,
               Int(f.width) == Int(appSnap.frame.width),
               Int(f.height) == Int(appSnap.frame.height),
               Int(f.minY) == Int(appSnap.frame.minY) {
                continue
            }
            if let ws = ForegroundApp.safeSnapshot(ofElement: win) as? XCUIElementSnapshot {
                roots.append(ws)
            }
        }
        guard usedBoundedSnapshot || !roots.isEmpty else {
            return (nil, .serverError(
                "Could not snapshot the accessibility tree. The app may still be launching — wait briefly and retry, or take a screenshot."
            ))
        }

        var lines: [String] = []
        var count = 0
        var localCount = 0
        var truncated = false
        // Track element frames already emitted so overlapping window/app snapshots
        // don't duplicate the same nodes.
        var seenFrames = Set<String>()
        let cullViewport = cmd.visibleOnly == true
            ? CGRect(x: 0, y: 0, width: screen.width, height: screen.height)
            : CGRect.null
        for root in roots {
            renderSnapshotInto(root, depth: 0, maxDepth: maxDepth, maxElements: maxElements,
                               filter: filter,
                               cullToViewport: cmd.visibleOnly == true, viewportRect: cullViewport,
                               lines: &lines, localCount: &localCount,
                               globalCount: &count, truncated: &truncated, seenFrames: &seenFrames)
            if count >= maxElements { break }
        }

        let body = boundedBody ?? lines.joined(separator: "\n")
        if usedBoundedSnapshot {
            count = boundedCount
            truncated = boundedTruncated
        }

        var hint = "Accessibility tree (types, labels, identifiers, frames in POINTS), including visible overlay " +
            "windows (fixed bottom/floating bars). Frames are {{x,y},{w,h}} — tap an element at its frame center " +
            "(or use find_element to get a ref). If an element is still missing, the app may not expose it — fall " +
            "back to screenshot + coordinate tap."
        if truncated {
            hint = "⚠️ Tree truncated at \(count) nodes (page has more). Narrow the query: " +
                (cmd.visibleOnly == true ? "" :
                    "pass visible_only:true to return ONLY what is on screen (on a long/recycling list most nodes are " +
                    "offscreen rows that eat the budget before the visible ones are reached — scroll and re-read to see more), or ") +
                "pass filter:{label:\"…\"} or filter:{type:\"button\"} to return only matching nodes (with their ancestor path), " +
                "or max_depth:3-4 for just the top structure. " + hint
        } else if filter.active {
            hint = "Filtered view: only nodes matching your filter (plus their ancestors) are shown. " +
                "Remove the filter for the full tree. " + hint
        }

        // State the active limits every time, not only when they bite. A caller
        // that doesn't know a cap applied will read a partial tree as the whole
        // page and conclude an element is absent when it was merely cut off.
        let usedDefaults = cmd.maxDepth == nil && cmd.maxElements == nil
        let depthLabel = maxDepth == Int.max ? "unlimited" : String(maxDepth)
        let effectiveMaxChildren = cmd.maxChildren.map { max(1, min($0, 5000)) } ?? Self.maxChildrenPerNode
        let limits = "Limits on THIS response: max_depth=\(depthLabel), max_children=\(effectiveMaxChildren), " +
            "max_elements=\(maxElements)\(usedDefaults ? " (defaults)" : " (as requested)"). " +
            "Deeper or wider reads are available — pass max_depth / max_elements — but cost scales with the " +
            "number of nodes actually walked: on a feed that has been scrolled for a while, offscreen rows " +
            "accumulate and a full read can take seconds and may exceed the 6s call limit. Cheaper first " +
            "moves: filter:{label:\"…\"}/{type:\"button\"} to fetch only what you need, or relaunch the app " +
            "to drop accumulated rows."
        hint = limits + " " + hint

        var result: [String: JSONValue] = [
            "format": .string("text"),
            "source": .string(body),
            "truncated": .bool(truncated),
            "total_returned": .int(count),
            "coordinate_space": .string("points"),
            "hint": .string(hint),
            // Which fetch ran. The bounded path can drop out silently if the
            // private API shifts again, and the only symptom would be the old
            // multi-second timings — so make it observable.
            "snapshot_path": .string(usedBoundedSnapshot ? "bounded" : "full"),
            // Where the time actually went. fetch_ms is the AX round trip into
            // the target app; render_ms is walking that tree and building the
            // text. They have different fixes — a slow fetch means the app's
            // hierarchy is huge (cap depth/children, or relaunch to drop
            // accumulated rows), a slow render means too many nodes are being
            // written out (filter, or visible_only).
            "timing": .object([
                "fetch_ms": .int(Int(fetchMs.rounded())),
                "render_ms": .int(Int(renderMs.rounded())),
            ]),
            "max_children_used": .int(childrenUsed),
            // Always reported, not just when the fallback fires: without it there
            // is no way to tell "the trigger decided the tree was fine" from "the
            // trigger never ran", which is exactly the ambiguity that hid a bug here.
            "ax_coverage": .double((visibleLabelledCoverage(body) * 100).rounded() / 100),
            // A well-covered screen is readable whatever else it holds (a
            // hidden tab's long list may have no visible children).
            "channel": visibleLabelledCoverage(body) < 0.5 && Self.hasOpaqueContent(body, screen: pointSize.size)
                ? .object([
                    "ax_coverage": .double((visibleLabelledCoverage(body) * 100).rounded() / 100),
                    "recommended": .string("ocr"),
                    "why": .string("A page-sized content area here (a web view or custom-drawn document) exposes no " +
                                   "text to the accessibility tree; only the controls around it are listed. Read it " +
                                   "with screen_text and tap by coordinate. Check again on the next screen."),
                ])
                : Self.screenChannel(visibleLabelledCoverage(body),
                                     textItems: Self.contentTextCount(body, height: pointSize.height)),
            // Where this read sits in the list, so a caller can tell "more below"
            // from "already at the bottom" without scrolling to find out.
            // Another walk of the app; skipped while its tree is slow.
            // And within 10s of a launch: the app is still starting, and each
            // extra walk can cost several times the read itself.
            "scroll_position": (inspectedBundleId.map { isSlowTree($0) || justLaunched($0)
                || (scrollPositionCost[$0].map { nowMonotonic - $0.at < 120 && $0.s > 0.8 } ?? false) } == true
                ? nil : timedLap("scroll_position") { () -> [String: JSONValue]? in
                    let t = nowMonotonic
                    let v = scrollPosition()
                    if let bid = inspectedBundleId { scrollPositionCost[bid] = (nowMonotonic - t, nowMonotonic) }
                    return v
                })
                .map { JSONValue.object($0) } ?? .null,
            // A keyboard appearing shifts the whole layout up, which silently
            // invalidates any coordinate read before it — the reported failure
            // was a send button that moved ~50pt between the read and the tap.
            // Reporting the occluded band lets a caller notice that itself.
            "keyboard": timedLap("keyboard") { keyboardState(body: rawBoundedBody) },
            // Which channel produced the tree. NOT named "source": that key is
            // already the tree TEXT in this same dictionary, and a duplicate key
            // in a Swift dictionary literal is a runtime trap — it crashed the
            // runner outright (EXC_BREAKPOINT in Dictionary.init(dictionaryLiteral:))
            // on the first page_source after the tag was added.
            "source_channel": .string("ax"),
        ]
        let rootName = body.split(separator: "\n", maxSplits: 1).first.flatMap { line -> String? in
            guard line.hasPrefix("Application"), let r = line.range(of: "label: '") else { return nil }
            let rest = line[r.upperBound...]
            return rest.firstIndex(of: "'").map { String(rest[..<$0]) }
        }
        confirmOpened(inspectedBundleId, name: rootName?.isEmpty == false ? rootName : nil)
        if usedBoundedSnapshot {
            iCTRLUITests.logBuffer.append(
                "🌲 page_source fetch=\(Int(fetchMs.rounded()))ms render=\(Int(renderMs.rounded()))ms "
                + "nodes=\(count)\(boundedTruncated ? " TRUNCATED" : "")"
                + " mc=\(childrenUsed)\(ladderSteps.count > 1 ? "[\(ladderSteps.joined(separator: " "))]" : "")"
                + (cmd.visibleOnly == true ? " visible_only" : "")
                + (filter.active ? " filtered" : ""))
        }

        // The one failure mode this whole path can still hit, and the only one
        // that is silent: a long list whose rows are ALL above the viewport in
        // the returned tree. Measured on a scrolled WeChat chat list — the 2000
        // element cap is consumed by offscreen rows before the visible ones are
        // reached, so the caller gets a healthy-looking tree with zero on-screen
        // rows, `truncated` false, and no error. Say so explicitly, because the
        // natural (wrong) conclusion is "the screen is empty".
        if usedBoundedSnapshot, cmd.visibleOnly != true,
           let probe = Self.underFetchProbe(body, requested: childrenUsed),
           probe.lastBottom < 0 {
            let rowsShort = probe.rowHeight > 0 ? abs(probe.lastBottom) / probe.rowHeight : 0
            result["viewport_warning"] = .string(
                "The list rows in this tree all sit ABOVE the screen (lowest row ends "
                + "\(abs(probe.lastBottom))pt above the top"
                + (rowsShort > 0 ? ", roughly \(rowsShort) rows short" : "") + "). "
                + "The rows you can actually see were not reached"
                + (probe.saturated
                    ? " — the container returned everything it has, so raising max_children will NOT help; "
                      + "the element cap is what ran out. Raise max_elements, or pass visible_only:true "
                      + "(it keeps on-screen rows within the same budget)."
                    : " — raise max_children.")
                + " Do NOT conclude the screen is empty from this tree."
                + " Fastest recovery: screen_text — it OCRs the screenshot, which does not go"
                + " through the accessibility channel at all. Measured on this exact case it read"
                + " ~5x more on-screen text than the tree, in ~700ms.")
        }

        // Same advice, one step earlier: a tree that is technically fine but
        // nearly empty on a page the user can see content on. Measured: a
        // scrolled WeChat list yields 6 visible labels via the tree vs 35 via
        // OCR. Without this a caller reasonably concludes the screen is bare.
        if usedBoundedSnapshot, result["viewport_warning"] == nil, count > 0 {
            let visibleLabeled = body.split(separator: "\n").filter {
                $0.contains(", label: '") || $0.contains(", value: '")
            }.count
            if visibleLabeled < 10, count > 50 {
                result["sparse_hint"] = .string(
                    "Only \(visibleLabeled) labelled nodes here despite \(count) nodes total — typical of a "
                    + "recycling list that keeps its rows out of the accessibility tree. If the screen looks "
                    + "fuller than this, call screen_text (OCR of the screenshot, ~700ms, bypasses accessibility).")
            }
        }
        // OCR fallback: only present when the accessibility tree came back with
        // nothing on screen. Same item shape as find_element/screen_text, each
        // tagged source:"ocr", so it can be used directly — tap{x:center_x,
        // y:center_y} — without a second code path.
        if let ocr = ocrFallback {
            result["ocr_items"] = .array(ocr.items)
            result["ocr_count"] = .int(ocr.items.count)
            result["ocr_timing"] = .object([
                "screenshot_ms": .int(Int(ocr.shotMs.rounded())),
                "ocr_ms": .int(Int(ocr.ocrMs.rounded())),
            ])
            let axCoverage = visibleLabelledCoverage(body)
            result["ocr_reason"] = .string(
                axCoverage < 0.05
                ? "The accessibility tree returned NO on-screen content, so the screen was read by OCR instead. "
                  + "Use ocr_items (coordinates are in points; tap{x:center_x,y:center_y}). "
                  + "They carry no `ref` and go stale on scroll, so act on them immediately."
                : "The tree covers only \(Int(axCoverage * 100))% of the content area — below the 15% bar, so the "
                  + "screen was ALSO read by OCR. Compare the two: the tree has real types and refs, OCR has "
                  + "labelled on-screen nodes, which is what the tree above describes. OCR is included as a "
                  + "cross-check — prefer the tree items, they have real types and support refs.")
        }
        if filter.active { result["filtered"] = .bool(true) }
        // An in-app overlay drawn outside accessibility (privacy dialogs,
        // coach marks, login sheets) leaves the tree as it was while the
        // screen changes under the caller's eyes, and taps land beneath it.
        // Same labels as the last read, but a clearly different screen, is
        // that signature.
        let screenFrame = inspectedBundleId != "com.apple.springboard" && !filter.active
            ? readFrame ?? ScreenSettle.sample() : nil
        if readFrame == nil { readFrame = screenFrame }
        if let bid = inspectedBundleId, bid != "com.apple.springboard", let frame = screenFrame {
            let labels = Self.labelFingerprint(body)
            if let prev = lastTreeRead, prev.bid == bid, prev.labels == labels, body.contains(", label: '"),
               ScreenSettle.diff(prev.frame, frame) >= 0.35 {
                result["overlay_suspected"] = .bool(true)
                let old: String
                if case .string(let h)? = result["hint"] { old = " " + h } else { old = "" }
                result["hint"] = .string("Heads-up: the screen changed since your last read but this tree didn't — " +
                    "something not in the accessibility tree (a dialog, coach mark or login sheet) is probably drawn " +
                    "on top, and taps from this tree would land under it. Take a screenshot and deal with it first." + old)
            }
            lastTreeRead = (bid, labels, frame)
        }
        // Share of the screen in one colour, when nothing on it is labelled.
        let blankShare: Double? = {
            guard let frame = screenFrame, inspectedBundleId != "com.apple.springboard",
                  visibleLabelledCoverage(body) < 0.05, (ocrFallback?.items.count ?? 0) <= 2 else { return nil }
            let share = ScreenSettle.blankShare(frame)
            iCTRLUITests.logBuffer.append(String(format: "⬜️ blank share %.2f", share))
            return share
        }()
        if Self.looksLikeLoading(body) {
            result["loading"] = .bool(true)
            let old: String
            if case .string(let h)? = result["hint"] { old = " " + h } else { old = "" }
            result["hint"] = .string("The page shows a loading indicator: prices, lists and counts may still be " +
                "provisional. Read again before relying on them." + old)
        } else if let share = blankShare, share >= 0.85 {
            // A skeleton or a page not drawn yet has no spinner and no wording
            // ("settled" pages can still be grey boxes). Nearly one
            // colour and nothing labelled is that — or a page that is really
            // empty, which the second read tells apart.
            result["loading"] = .bool(true)
            result["loading_reason"] = .string("blank")
            let old: String
            if case .string(let h)? = result["hint"] { old = " " + h } else { old = "" }
            result["hint"] = .string(Self.blankLoadingHint + old)
        }
        if Self.looksLikeLoginWall(body) {
            result["login_wall"] = .bool(true)
            let old: String
            if case .string(let h)? = result["hint"] { old = " " + h } else { old = "" }
            result["hint"] = .string("This screen asks you to log in (one-tap / phone / code sign-in). If the task " +
                "doesn't allow logging in, close it (关闭 / × / 跳过 / 返回 / 暂不登录) and continue as a guest, or report " +
                "the step as blocked by login. Never tap one-tap / \"继续\" / \"Continue as …\" buttons here: they sign in." + old)
        }
        if let v = visibleCellsRead {
            result["visible_cells"] = .object(["cells": .int(v.cells), "list_rows": .int(v.rows)])
        }
        if capRaisedForGrowth || visibleCellsRead != nil {
            result["tree_growth"] = .bool(true)
            let old: String
            if case .string(let h)? = result["hint"] { old = " " + h } else { old = "" }
            result["hint"] = .string((visibleCellsRead != nil
                ? "This list keeps the rows already scrolled past (\(visibleCellsRead!.rows) rows in it), so only its " +
                  "\(visibleCellsRead!.cells) visible cells were read — fast at any depth. "
                : "This list keeps the rows already scrolled past (its container filled the 50-child cap and pushed the " +
                  "visible rows out), so this read widened to 200 children; reads slow down as you scroll. ") +
                "For long reading use collect; relaunching the app (losing the position) resets the list." + old)
        }
        if cmd.enhanced == true, ocrFallback == nil, let extra = timedLap("ocr_only", { ocrOnly(body) }), !extra.isEmpty {
            result["ocr_only"] = .array(extra)
            result["ocr_only_note"] = .string("\(extra.count) pieces of on-screen text are not in the tree (drawn into " +
                "images or custom views), read from the screenshot: points, tap{x:center_x,y:center_y}, no ref; " +
                "they go stale on scroll.")
        }
        let layered = Self.stackedLayers(body, screen: pointSize.size)
        flagBlockers(Self.screenTexts(body) + (ocrFallback?.items ?? []).compactMap(Self.ocrScreenText),
                     bid: inspectedBundleId, overlayShown: layered != nil || result["overlay_suspected"] != nil
                        || result["login_wall"] != nil, into: &result)
        if let top = layered {
            result["stacked_layers"] = .int(top.count)
            let old: String
            if case .string(let h)? = result["hint"] { old = " " + h } else { old = "" }
            result["hint"] = .string("This tree holds \(top.count) full-screen layers; the last is drawn on top — likely a " +
                "dialog, login wall or sheet over the page (its text: \(top.labels.map { "'\($0)'" }.joined(separator: ", "))). " +
                "Deal with it first; controls of the layers under it can't be tapped." + old)
        }
        if let bid = inspectedBundleId {
            result["bundle_id"] = .string(bid)
            // Say it up front, while the caller is still deciding how to locate
            // things — otherwise they burn a find_element round trip discovering
            // the page simply isn't in this tree.
            if Self.webViewHostBundleIds.contains(bid) {
                result["warning"] = .string(
                    "This is a BROWSER. The tree below is browser chrome ONLY — web page content " +
                    "(links, buttons, text inside the page) is not exposed to the accessibility tree and is absent here. " +
                    "Do not expect find_element to match anything in the page. " +
                    "To act on the page: screenshot → locate the target visually → divide pixel coords by that " +
                    "response's `scale` → tap{x,y}."
                )
            }
        } else {
            result["bundle_id"] = .string("com.apple.springboard")
            result["warning"] = .string(
                "Could not determine the foreground app, so this is the SpringBoard (system) tree, " +
                "which does NOT contain the current app's internal elements. " +
                "Pass bundle_id explicitly to inspect a specific app."
            )
        }
        return (result, nil)
    }

    // MARK: - Snapshot rendering (depth/count-bounded, filterable)

    /// Default traversal bounds for page_source, reported back in every response
    /// so a caller can tell a capped read from a complete one.
    static let defaultMaxDepth = 40
    /// 100 cut every page of a scrolled X timeline (8 of 9 reads came back
    /// truncated), because a feed keeps hundreds of rendered rows under one
    /// container. 500 clears that; the cost is bounded by max_elements anyway.
    static let maxChildrenPerNode = 1000

    private struct SnapshotFilter {
        let type: String?       // element type name substring (e.g. "button")
        let label: String?      // label/value substring
        let text: String?       // label+value+identifier substring
        var active: Bool { type != nil || label != nil || text != nil }

        /// Does this node itself match all provided filter conditions?
        func matches(_ s: XCUIElementSnapshot) -> Bool {
            if let t = type, !ActionHandler.elementTypeName(s.elementType).lowercased().contains(t.lowercased()) {
                return false
            }
            let label = s.label
            let value = (s.value as? String) ?? ""
            let ident = s.identifier
            if let l = self.label {
                let hay = (label + " " + value).lowercased()
                if !hay.contains(l.lowercased()) { return false }
            }
            if let tx = self.text {
                let hay = (label + " " + value + " " + ident).lowercased()
                if !hay.contains(tx.lowercased()) { return false }
            }
            return true
        }

        /// Same predicate, against one ALREADY-RENDERED line from the bounded
        /// fetch. The bounded path is ~2x faster than the protocol walk but hands
        /// back text, not snapshots — so a filter used to disable it entirely and
        /// pay full price to return FEWER nodes. Matching the rendered line keeps
        /// the fast path.
        ///
        /// Line shape (see ICTRLRenderNode): `<indent>Type, label: '…', value: '…', id: '…', {{x, y}, {w, h}}`
        /// Only the type name is positional; the rest are optional named parts.
        func matchesRenderedLine(_ line: String) -> Bool {
            let trimmed = line.drop { $0 == " " }
            let typeName = trimmed.prefix { $0 != "," }.lowercased()
            if let t = type, !typeName.contains(t.lowercased()) { return false }

            // Field extraction must not fall back to the whole line: a `type`
            // filter would then match the frame digits, and a `label` filter
            // would match an id it was never meant to see.
            func field(_ name: String) -> String {
                guard let r = line.range(of: ", \(name): '") else { return "" }
                let rest = line[r.upperBound...]
                guard let end = rest.range(of: "'") else { return "" }
                return String(rest[..<end.lowerBound])
            }
            let label = field("label")
            let value = field("value")
            let ident = field("id")

            if let l = self.label {
                if !(label + " " + value).lowercased().contains(l.lowercased()) { return false }
            }
            if let tx = self.text {
                if !(label + " " + value + " " + ident).lowercased().contains(tx.lowercased()) { return false }
            }
            return true
        }
    }

    /// Escalation ladder for the adaptive `max_children` fetch.
    ///
    /// Starts small because the measured distribution is strongly BIMODAL: across
    /// 20 apps x 2 screens, 38 of 40 samples had at most 36 direct children in
    /// their largest scrollable container (median 10) — WeChat's chat list was the
    /// lone outlier at 392. So a small first fetch satisfies almost everything,
    /// and only the outliers pay for a second round.
    ///
    /// The jumps are large because there is NO caching on the accessibility side:
    /// measured, fetching mc=400 costs the same (~600ms) whether or not mc=800
    /// was just fetched, and ascending/descending sweeps are symmetric. A refetch
    /// is therefore paid in full, which rules out cautious doubling — few, big
    /// steps beat many small ones.
    private static let childrenLadder = [50, 500, 1000, 2000]

    /// How many LABELLED nodes in this rendered tree actually intersect the
    /// screen — i.e. how much of it a caller could act on.
    ///
    /// This is the escalation trigger. Node count alone is useless here: a
    /// scrolled chat list happily returns 2000 nodes with zero on-screen rows,
    /// which reads as success everywhere except this measure.
    private func visibleLabelledCount(_ body: String) -> Int {
        let w = pointSize.width, h = pointSize.height
        // Chrome bands: the nav/status area and the tab bar. Their labels are
        // ALWAYS present (app title, search, tab names) whether or not any real
        // content came back, so counting them hides the exact failure this
        // measure exists to catch. Measured on a scrolled WeChat list: 8 visible
        // labels, every one chrome (微信/搜索/快捷操作/标签页栏/通讯录/发现),
        // zero conversations — while OCR read 34 texts including 10 real rows.
        //
        // The bounds are READ FROM THE TREE, not hardcoded: they differ per
        // device (screen height, presence of a home indicator) and per app
        // (measured: WeChat nav 62..106 + tab 780..873; RED tab 796..874 and no
        // nav bar at all). A fixed inset would be wrong on the next device or
        // the next app, and wrong silently.
        var topChrome = 0.0
        var bottomChrome = h
        for line in body.split(separator: "\n") {
            let t = line.drop { $0 == " " }
            let isNav = t.hasPrefix("NavigationBar,") || t.hasPrefix("StatusBar,")
            let isTab = t.hasPrefix("TabBar,")
            guard isNav || isTab else { continue }
            guard let r = line.range(of: "{{"),
                  let end = line.range(of: "}}", range: r.lowerBound..<line.endIndex) else { continue }
            let f = line[r.lowerBound..<end.upperBound]
                .split(whereSeparator: { !"-0123456789".contains($0) }).compactMap { Double($0) }
            guard f.count >= 4, f[3] > 0 else { continue }
            let (top, bottom) = (f[1], f[1] + f[3])
            // A bar spanning most of the screen is a container mislabelled as
            // chrome (Settings reports a Toolbar covering 0..874); honouring it
            // would exclude the whole screen and make this count always zero.
            guard f[3] < h * 0.4 else { continue }
            if isNav, bottom > topChrome, top < h * 0.3 { topChrome = bottom }
            if isTab, top < bottomChrome, bottom > h * 0.7 { bottomChrome = top }
        }
        var n = 0
        for line in body.split(separator: "\n") {
            guard line.contains(", label: '") || line.contains(", value: '") else { continue }
            guard let r = line.range(of: "{{"),
                  let end = line.range(of: "}}", range: r.lowerBound..<line.endIndex) else { continue }
            let nums = line[r.lowerBound..<end.upperBound]
                .split(whereSeparator: { !"-0123456789".contains($0) }).compactMap { Double($0) }
            guard nums.count >= 4 else { continue }
            let (x, y, ww, hh) = (nums[0], nums[1], nums[2], nums[3])
            guard ww > 0, hh > 0, x < w, y < h, x + ww > 0, y + hh > 0 else { continue }
            // Count only what sits in the CONTENT band.
            let mid = y + hh / 2
            if mid > topChrome, mid < bottomChrome { n += 1 }
        }
        return n
    }

    /// A cheap fingerprint of what is on screen, for telling whether a scroll
    /// actually moved anything.
    ///
    /// Reads the bounded snapshot rather than live `staticTexts` queries: this
    /// runs before AND after every page/swipe, and a live query costs a full
    /// hierarchy walk per call. Labels plus their y positions, because a feed
    /// can repeat the same strings at different offsets.
    /// The last time a keyboard was seen up, and in which app.
    private var lastKeyboardSeen: (bid: String, at: TimeInterval)?
    /// Where the keyboard started on the last scroll fingerprint (points),
    /// nil when none was up.
    private var pageKeyboardTop: Double?

    /// Whether a node sits in the middle 70% of the screen: what scrolls.
    /// The first labels in tree order are often tabs and a search bar,
    /// which never move, so a scrolled feed would read as unmoved.
    static func inContentBand(_ f: [Double], height: Double) -> Bool {
        let mid = f[1] + f[3] / 2
        return mid > height * 0.15 && mid < height * 0.85
    }

    /// A scroll fingerprint from a rendered body: content-band labels and
    /// where they are (see scrollFingerprint).
    static func fingerprint(ofBody body: String, height: Double) -> String? {
        var parts: [String] = []
        for line in body.split(separator: "\n") {
            guard let r = line.range(of: ", label: '") else { continue }
            let rest = line[r.upperBound...]
            guard let e = rest.range(of: "'") else { continue }
            let label = rest[..<e.lowerBound]
            if label.contains("滚动条") || label.lowercased().contains("scroll bar") { continue }
            guard let f = frameOf(line), inContentBand(f, height: height) else { continue }
            parts.append("\(label)@\(Int(f[0])),\(Int(f[1]))")
            if parts.count >= 40 { break }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "|")
    }

    static func frameOf(_ line: Substring) -> [Double]? {
        guard let r = line.range(of: "{{"), let e = line.range(of: "}}", range: r.lowerBound..<line.endIndex) else { return nil }
        let v = line[r.lowerBound..<e.upperBound].split(whereSeparator: { !"-0123456789.".contains($0) }).compactMap { Double($0) }
        return v.count >= 4 ? v : nil
    }

    /// Whether the content moved between two fingerprints: most labels seen
    /// in both shifted. One control changing place (a search field following
    /// the keyboard down) is not a scroll; a whole new set of labels is.
    static func contentShifted(_ before: String, _ after: String) -> Bool {
        func parse(_ s: String) -> [String: (Double, Double)] {
            var out: [String: (Double, Double)] = [:]
            for p in s.split(separator: "|") {
                guard let at = p.lastIndex(of: "@") else { continue }
                let xy = p[p.index(after: at)...].split(separator: ",").compactMap { Double($0) }
                let key = String(p[..<at])
                if xy.count == 2, out[key] == nil { out[key] = (xy[0], xy[1]) }
            }
            return out
        }
        let b = parse(before), a = parse(after)
        let shared = b.keys.filter { a[$0] != nil }
        // Mostly different labels: the content was replaced by a scroll.
        if shared.count < 2 || Double(shared.count) < Double(min(a.count, b.count)) * 0.3 {
            iCTRLUITests.logBuffer.append("🧭 content shift: \(shared.count) of \(min(a.count, b.count)) labels shared → \(before != after ? "replaced" : "same")")
            return before != after
        }
        let moving = shared.filter {
            abs(a[$0]!.0 - b[$0]!.0) > 4 || abs(a[$0]!.1 - b[$0]!.1) > 4
        }
        let verdict = Double(moving.count) >= max(1, Double(shared.count) / 3)
        iCTRLUITests.logBuffer.append("🧭 content shift: \(moving.count)/\(shared.count) shared labels moved " +
            "(\(moving.prefix(3).map { "\($0.prefix(12))" }.joined(separator: ", "))) → \(verdict ? "moved" : "still")")
        return verdict
    }

    private func scrollFingerprint() -> String? {
        guard let bid = resolveForegroundBundleId() else { return nil }
        // Two walks per page; on a tree that isn't answering they can take
        // the whole page call. Without them `moved` is just unknown.
        if isSlowTree(bid) { return nil }
        let walkStart = nowMonotonic
        defer { if nowMonotonic - walkStart > Self.slowTreeSeconds { treeCost[bid] = nowMonotonic - walkStart } }
        guard let root = ForegroundApp.boundedSnapshot(
                forBundleID: bid,
                maxDepth: Self.defaultMaxDepth,
                maxChildren: Self.childrenLadder[0]) else { return nil }
        var n = 0
        var t: ObjCBool = false
        guard let body = ForegroundApp.renderBoundedSnapshot(
                root, maxDepth: Self.defaultMaxDepth, maxElements: 400,
                visibleRect: CGRect(x: 0, y: 0, width: pointSize.width, height: pointSize.height),
                nodesWritten: &n, truncated: &t) else { return nil }
        var parts: [String] = []
        var kbIndent: Int?
        for line in body.split(separator: "\n") {
            // The keyboard is no content: its keys filled the cap, and closing
            // it read as a scroll (a page on a search screen). Note where it
            // starts, for telling a closing keyboard from a scroll.
            let indent = line.prefix { $0 == " " }.count
            if let k = kbIndent, indent > k { continue }
            kbIndent = nil
            if line.dropFirst(indent).hasPrefix("Keyboard,") {
                kbIndent = indent
                if let f = Self.frameOf(line) { pageKeyboardTop = min(pageKeyboardTop ?? f[1], f[1]) }
                continue
            }
            // Past the cap, only looking for the keyboard (late in the tree).
            if parts.count >= 40 { continue }
            guard let r = line.range(of: ", label: '") else { continue }
            let rest = line[r.upperBound...]
            guard let end = rest.range(of: "'") else { continue }
            let label = rest[..<end.lowerBound]
            // Scroll bars show up while a finger drags, even on a page that
            // can't scroll: they made every page there "moved".
            if label.contains("滚动条") || label.lowercased().contains("scroll bar") { continue }
            guard let f = Self.frameOf(line), Self.inContentBand(f, height: pointSize.height) else { continue }
            parts.append("\(label)@\(Int(f[0])),\(Int(f[1]))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "|")
    }

    /// Whether a keyboard is up and which part of the screen it covers.
    ///
    /// Read from the tree page_source already fetched when there is one. The
    /// live `keyboards.firstMatch.exists` probe walks the whole app again —
    /// on a large results list that alone can be most of a page_source.
    private func keyboardState(body: String? = nil) -> JSONValue {
        guard let bid = resolveForegroundBundleId() else { return .object(["visible": .bool(false)]) }
        var visible = false
        var top: Double = 0
        if let body = body {
            for line in body.split(separator: "\n") where line.drop(while: { $0 == " " }).hasPrefix("Keyboard,") {
                guard let r = line.range(of: "{{") else { continue }
                let v = line[r.lowerBound...].split(whereSeparator: { !"-0123456789.".contains($0) }).compactMap { Double($0) }
                if v.count >= 4, v[3] > 0 { visible = true; top = v[1]; break }
            }
        }
        // Not in a capped tree is not proof: the 50-children cap can cut the
        // Keyboard node off, and some apps' keyboards aren't in their tree
        // (reported visible:false with the keyboard up). Ask live then,
        // unless this app's tree is too slow for it.
        // Asked as one capped, shallow request rather than a live query: the
        // live `keyboards.firstMatch.exists` is retried by XCTest on an AX
        // timeout (several AX timeouts in a row on a busy feed), while this is
        // a single request bounded by the AX timeout. The keyboard sits near
        // the top of the tree, so a few levels and a wide child cap find it.
        if !visible, !isSlowTree(bid), !justLaunched(bid),
           let root = ForegroundApp.boundedSnapshot(forBundleID: bid, maxDepth: 4, maxChildren: 200) {
            var n = 0
            var t: ObjCBool = false
            if let shallow = ForegroundApp.renderBoundedSnapshot(root, maxDepth: 4, maxElements: 800,
                                                                 nodesWritten: &n, truncated: &t) {
                for line in shallow.split(separator: "\n") where line.drop(while: { $0 == " " }).hasPrefix("Keyboard,") {
                    guard let r = line.range(of: "{{") else { continue }
                    let v = line[r.lowerBound...].split(whereSeparator: { !"-0123456789.".contains($0) }).compactMap { Double($0) }
                    if v.count >= 4, v[3] > 0 { visible = true; top = v[1]; break }
                }
            }
        }
        guard visible else { return .object(["visible": .bool(false)]) }
        lastKeyboardSeen = (bid, nowMonotonic)
        // A Chinese keyboard's candidate bar sits above the Keyboard node, in
        // the full-width host that runs to the bottom of the screen: keys can
        // start some 45pt above the Keyboard node's reported top, so taps
        // "above the keyboard" in that gap land on the candidate bar.
        if let body = body {
            let w = pointSize.width, h = pointSize.height
            for line in body.split(separator: "\n") {
                guard let f = Self.frameOf(line), f[0] <= 1, f[2] >= w * 0.95, f[1] + f[3] >= h - 2,
                      f[1] < top, f[1] >= top - 80 else { continue }
                top = f[1]
            }
        }
        return .object([
            "visible": .bool(true),
            "covers_from_y": .double(top.rounded()),
            "usable_height": .double(top.rounded()),
            "hint": .string(
                "A keyboard is up and covers y >= \(Int(top)). Coordinates read BEFORE it appeared are "
                + "stale — content above it has shifted up. Re-read before tapping by coordinate."),
        ])
    }

    /// A few labels actually present on screen, for failure diagnostics.
    private func nearbyLabels(limit: Int) -> [String]? {
        guard let bid = resolveForegroundBundleId(),
              let root = ForegroundApp.boundedSnapshot(
                forBundleID: bid, maxDepth: Self.defaultMaxDepth,
                maxChildren: Self.maxChildrenPerNode) else { return nil }
        var n = 0
        var t: ObjCBool = false
        guard let body = ForegroundApp.renderBoundedSnapshot(
                root, maxDepth: Self.defaultMaxDepth, maxElements: 600,
                visibleRect: CGRect(x: 0, y: 0, width: pointSize.width, height: pointSize.height),
                nodesWritten: &n, truncated: &t) else { return nil }
        var out: [String] = []
        for line in body.split(separator: "\n") {
            guard let r = line.range(of: ", label: '") else { continue }
            let rest = line[r.upperBound...]
            guard let e = rest.range(of: "'") else { continue }
            let v = String(rest[..<e.lowerBound])
            if v.count >= 2, !out.contains(v) { out.append(v) }
            if out.count >= limit { break }
        }
        return out
    }

    /// The smallest labelled element containing a point, from the bounded
    /// snapshot. Used to tell a caller what a coordinate tap actually hit.
    ///
    /// Smallest-containing, because frames nest: the window, a container and a
    /// button can all contain the point, and only the innermost is informative.
    private func elementUnder(x: Double, y: Double) -> [String: JSONValue]? {
        hitSkipped = false
        guard let bid = resolveForegroundBundleId() else { return nil }
        // A tap is ~0.1s; this probe is a whole-tree walk. On a slow tree it
        // can turn every tap into many seconds, so skip it there and say so.
        if isSlowTree(bid) { hitSkipped = true; return nil }
        let probeStart = nowMonotonic
        defer { treeCost[bid] = nowMonotonic - probeStart }
        guard let root = ForegroundApp.boundedSnapshot(
                forBundleID: bid,
                maxDepth: Self.defaultMaxDepth,
                maxChildren: Self.childrenLadder[0]) else { return nil }
        var n = 0
        var t: ObjCBool = false
        guard let body = ForegroundApp.renderBoundedSnapshot(
                root, maxDepth: Self.defaultMaxDepth, maxElements: 2000,
                nodesWritten: &n, truncated: &t) else { return nil }

        return Self.hit(in: body, x: x, y: y, screen: pointSize.size)
    }

    /// What a tap at (x, y) lands on, from a rendered tree: the smallest
    /// labelled node containing the point — on the top layer when full-screen
    /// layers are stacked.
    static func hit(in body: String, x: Double, y: Double, screen: CGSize) -> [String: JSONValue]? {
        let lines = body.split(separator: "\n")
        // A dialog or login wall drawn as a later full-screen layer covers
        // the page under it, yet the page's controls are still in the tree
        // and "contain" the point: hit would name a control under a captcha.
        let stack = layerStack(lines, screen: screen)
        func smallest(in range: Range<Int>) -> (area: Double, type: String, label: String, f: [Double])? {
        var best: (area: Double, type: String, label: String, f: [Double])?
        for line in lines[range] {
            guard line.contains(", label: '") || line.contains(", value: '") else { continue }
            guard let r = line.range(of: "{{"),
                  let end = line.range(of: "}}", range: r.lowerBound..<line.endIndex) else { continue }
            let f = line[r.lowerBound..<end.upperBound]
                .split(whereSeparator: { !"-0123456789".contains($0) }).compactMap { Double($0) }
            guard f.count >= 4, f[2] > 0, f[3] > 0 else { continue }
            guard x >= f[0], x <= f[0] + f[2], y >= f[1], y <= f[1] + f[3] else { continue }
            let area = f[2] * f[3]
            // A node covering (nearly) the whole screen is the app or a page
            // container, not what was tapped — reporting it as the hit says
            // nothing while looking like an answer.
            if area >= Double(screen.width * screen.height) * 0.9 { continue }
            if best == nil || area < best!.area {
                let t = String(line.drop { $0 == " " }.prefix { $0 != "," })
                var label = ""
                if let lr = line.range(of: ", label: '") {
                    let rest = line[lr.upperBound...]
                    if let le = rest.range(of: "'") { label = String(rest[..<le.lowerBound]) }
                }
                best = (area, t, label, f)
            }
        }
        return best
        }
        func json(_ b: (area: Double, type: String, label: String, f: [Double])) -> [String: JSONValue] {
            [
                "element_type": .string(b.type),
                "label": .string(b.label),
                "x": .double(b.f[0]), "y": .double(b.f[1]),
                "width": .double(b.f[2]), "height": .double(b.f[3]),
            ]
        }
        let under = smallest(in: lines.indices)
        // An anti-bot box drawn over part of a page (a slider over a list):
        // the page's rows under it still "contain" the point.
        let check = blockers(screenTexts(body))
        if check.kind == "captcha", let area = check.area, area.contains(CGPoint(x: x, y: y)), let u = under,
           !check.close.contains(where: { $0.text == u.label }),
           !captchaPhrases.contains(where: { u.label.lowercased().contains($0) }), u.label != "滑块" {
            return [
                "element_type": .string("captcha"), "label": .string("anti-bot check"),
                "x": .double(area.minX), "y": .double(area.minY), "width": .double(area.width), "height": .double(area.height),
                "covering_layer": .bool(true), "covered": .object(json(u)),
                "note": .string("An anti-bot check covers this point, so the tap landed on it, not on '\(u.label)'. " +
                                "iCTRL doesn't solve verification: close it or back out."),
            ]
        }
        guard let top = stack?.top else { return under.map(json) }
        // The innermost node on the top layer, else the layer itself.
        let onTop = smallest(in: top)
        if let u = under, let t = onTop, u.f == t.f, u.label == t.label { return json(u) }
        var out: [String: JSONValue]
        if let t = onTop {
            out = json(t)
        } else {
            let layer = lines[top.lowerBound]
            let f = layer.range(of: "{{").map {
                layer[$0.lowerBound...].split(whereSeparator: { !"-0123456789".contains($0) }).compactMap { Double($0) }
            } ?? []
            out = [
                "element_type": .string(String(layer.drop { $0 == " " }.prefix { $0 != "," })),
                "label": .string(stack!.labels.joined(separator: " / ")),
            ]
            if f.count >= 4 {
                out["x"] = .double(f[0]); out["y"] = .double(f[1])
                out["width"] = .double(f[2]); out["height"] = .double(f[3])
            }
        }
        out["covering_layer"] = .bool(true)
        if let u = under {
            out["covered"] = .object(json(u))
            out["note"] = .string("A full-screen layer (a dialog, login wall or sheet; its text: " +
                "\(stack!.labels.map { "'\($0)'" }.joined(separator: ", "))) is drawn over '\(u.label)', so the tap " +
                "landed on the layer, not on it. Deal with the layer first.")
        }
        return out
    }

    // MARK: - Which channel can read this screen

    /// Below this share of the content area covered by labelled nodes, the
    /// accessibility tree can't be trusted for this screen and OCR reads it
    /// instead. One threshold for both the automatic fallback and the advice.
    static let treeCoverageThreshold = 0.15

    /// The reading channel for THIS screen, decided from what was just measured.
    ///
    /// Said in every read so a caller decides per screen, not per app: the same
    /// app routinely mixes native screens (tree readable) with web or
    /// custom-drawn ones (tree empty), and a lesson carried from one to the
    /// other turns into OCR everywhere — refs lost, misreads, coordinate taps.
    static func screenChannel(_ coverage: Double, textItems: Int = 0) -> JSONValue {
        let c = (coverage * 100).rounded() / 100
        // Small text nodes cover little area: a list of short titles can be
        // fully in the tree at under 10% coverage, and "ocr" would send callers
        // to OCR and coordinate taps for a list the tree can read (episode
        // lists, flight dates and reviews behave the same).
        if coverage < treeCoverageThreshold, textItems >= minTreeTextItems {
            return .object([
                "ax_coverage": .double(c),
                "text_items": .int(textItems),
                "recommended": .string("tree"),
                "why": .string("The tree holds \(textItems) pieces of text on this screen, though they cover only " +
                               "\(Int(c * 100))% of it: use page_source / find_element → tap{ref}."),
            ])
        }
        let tree = coverage >= treeCoverageThreshold
        return .object([
            "ax_coverage": .double(c),
            "recommended": .string(tree ? "tree" : "ocr"),
            "why": .string(tree
                ? "The accessibility tree covers \(Int(c * 100))% of this screen: use page_source / find_element → tap{ref}."
                : "The accessibility tree covers only \(Int(c * 100))% of this screen (web or custom-drawn content): "
                  + "read it with screen_text and tap by coordinate. Check again on the next screen."),
        ])
    }

    static let minTreeTextItems = 6

    /// OCR items whose text the tree doesn't hold where OCR saw it — for
    /// page_source enhanced. Matched by place (a short tab label isn't "found"
    /// in a longer row label further down) and loosely — OCR splits and joins
    /// lines and misreads a glyph, the tree joins fields with "。" — so a line
    /// counts as present when most of its 3-character pieces are in the text
    /// of tree nodes over the same spot.
    private func ocrOnly(_ body: String) -> [JSONValue]? {
        // screen_text's bar: mixed small text over a picture (a channel row
        // of short tab names) reads at 0.3 and is still right.
        guard let o = runOCR(query: nil, fast: false, minConfidence: 0.3) else { return nil }
        let norm = { (t: String) -> [Character] in Array(t.lowercased().filter { $0.isLetter || $0.isNumber }) }
        let nodes = Self.screenTexts(body).map { ($0.frame, String(norm($0.text))) }.filter { !$0.1.isEmpty }
        func present(_ n: [Character], in tree: String) -> Bool {
            if n.count <= 3 { return tree.contains(String(n)) }
            var hit = 0
            for i in 0...(n.count - 3) where tree.contains(String(n[i..<i + 3])) { hit += 1 }
            return Double(hit) >= 0.6 * Double(n.count - 2)
        }
        var out: [JSONValue] = []
        for v in o.items {
            guard case .object(let d) = v, case .string(let label)? = d["label"], let e = Self.ocrScreenText(v) else { continue }
            let n = norm(label)
            guard n.count >= 2 else { continue }
            let spot = e.frame.insetBy(dx: -12, dy: -12)
            if present(n, in: nodes.filter { $0.0.intersects(spot) }.map { $0.1 }.joined(separator: "|")) { continue }
            out.append(.object(d.filter { ["label", "x", "y", "width", "height", "center_x", "center_y"].contains($0.key) }))
        }
        return out
    }

    /// Distinct text labels (8+ characters) in the content band — sentences,
    /// titles, prices with words. Icon names ("ic rate small",
    /// "float_widget_activity_") don't count.
    static func contentTextCount(_ body: String, height: Double) -> Int {
        var seen = Set<String>()
        for e in screenTexts(body) where e.text.count >= 8 && !e.text.contains("滚动条") {
            let mid = e.frame.midY
            guard mid > height * 0.15, mid < height * 0.85, e.frame.width > 0 else { continue }
            let ascii = e.text.allSatisfy { $0.isASCII }
            if ascii, e.text.contains("_") || e.text == e.text.lowercased() { continue }
            seen.insert(e.text)
        }
        return seen.count
    }

    /// Labelled-node coverage of the foreground app's visible screen — one
    /// bounded read, for responses that don't otherwise walk the tree.
    /// The last coverage measured, with the screen it was measured on. A
    /// walk can cost seconds on a busy page, more than the OCR it rides
    /// along with, and an unchanged screen has an unchanged tree.
    private var coverageCache: (bid: String, frame: ScreenSettle.Frame, value: Double)?
    /// A visible loading indicator: a spinner element or standard wording.
    /// Pixel settle can't tell a stable "Loading…" page from a loaded one,
    /// and values such as prices can change across consecutive reads.
    // MARK: - Anti-bot checks, rate limits, popups

    struct ScreenText { let text: String; let type: String; let frame: CGRect }

    /// An OCR item (screen_text / page_source's OCR fallback) as an entry.
    static func ocrScreenText(_ v: JSONValue) -> ScreenText? {
        guard case .object(let o) = v, case .string(let t)? = o["label"] else { return nil }
        func num(_ k: String) -> Double { if case .double(let d)? = o[k] { return d }; if case .int(let i)? = o[k] { return Double(i) }; return 0 }
        return ScreenText(text: t, type: "ocr", frame: CGRect(x: num("x"), y: num("y"), width: num("width"), height: num("height")))
    }

    /// A slider / puzzle / "are you a robot" check. Specific phrases only:
    /// broader words also match an SMS-code login or a puzzle toy on a shopping feed.
    private static let captchaPhrases = [
        "滑块验证", "向右滑动", "拖动滑块", "滑动解锁", "拖动下方滑块", "完成拼图", "依次点击", "身份核实", "安全验证",
        "人机验证", "验证码拦截", "是不是机器人", "不是机器人", "drag the slider", "slide to verify", "verify you are human",
        "not a robot", "complete the puzzle",
    ]
    /// The app throttling or refusing automation: wait, don't push.
    private static let rateLimitPhrases = [
        "休息一会", "活动太火爆", "太火爆了", "访问过于频繁", "操作过于频繁", "操作太频繁", "请求过于频繁", "访问受限",
        "系统繁忙", "稍后再试", "稍后重试", "几分钟后", "出了点问题", "too many requests", "try again later",
        "unusual traffic",
    ]
    private static let promoPhrases = ["消费券", "立即领", "领取", "红包", "优惠券", "抢券"]
    private static let closeLabels = ["关闭", "close", "×", "✕", "取消", "跳过", "暂不", "以后再说", "不感兴趣", "我知道了", "知道了"]

    /// What blocks the screen, if anything, and the ways out it labels.
    static func blockers(_ entries: [ScreenText]) -> (kind: String?, area: CGRect?, close: [ScreenText], promo: Bool) {
        var kind: String?
        var area: CGRect?
        func hit(_ e: ScreenText, _ phrases: [String]) -> Bool {
            let t = e.text.lowercased()
            return phrases.contains { t.contains($0) }
        }
        // A blocking page is sparse and says it in a short line; a feed can
        // carry the same words in a title (a story quoting "try again later"
        // must not stop collect as "rate_limit").
        let longTexts = Set(entries.filter { $0.text.count >= 8 }.map { $0.text }).count
        let sparse = longTexts <= 12
        for e in entries {
            if (sparse && e.text.count <= 40 && hit(e, captchaPhrases)) || (e.text == "滑块" && e.type == "Button") {
                kind = "captcha"
                area = area.map { $0.union(e.frame) } ?? e.frame
            }
        }
        if kind == nil, sparse, entries.contains(where: { $0.text.count <= 40 && hit($0, rateLimitPhrases) }) {
            kind = "rate_limit"
        }
        let promo = entries.contains { e in promoPhrases.contains { e.text.contains($0) } && e.text.count <= 30 }
        let close = entries.filter { e in
            let t = e.text.lowercased()
            // Icons are named in English ("ic close s", "login close normal");
            // a longer Chinese label containing "close" is text (an ad's "VIP can turn this off").
            return closeLabels.contains(t) || t.contains("close") && e.text.count <= 30
                || t.contains("关闭") && e.text.count <= 6
        }
        // A button and its own text both carry the label: one each.
        var names = Set<String>()
        let ways = close.filter { names.insert($0.text).inserted }
        return (kind, area, Array(ways.prefix(3)), promo)
    }

    /// The last anti-bot check seen, per app — to refuse drags on it and to
    /// count how often this app is pushing back.
    private var lastChallenge: (bid: String, area: CGRect, at: TimeInterval)?
    private var blockedSeen: [String: [TimeInterval]] = [:]

    /// Adds blocked_by / close_candidates / promo_popup and their advice to
    /// a read. `overlayShown`: the read already flagged a layer over the page.
    private func flagBlockers(_ entries: [ScreenText], bid: String?, overlayShown: Bool, into result: inout [String: JSONValue]) {
        let b = Self.blockers(entries)
        var advice: [String] = []
        if let kind = b.kind, let bid = bid {
            result["blocked_by"] = .string(kind)
            let recent = (blockedSeen[bid] ?? []).filter { nowMonotonic - $0 < 600 } + [nowMonotonic]
            blockedSeen[bid] = recent
            if kind == "captcha" {
                if let a = b.area { lastChallenge = (bid, a.insetBy(dx: -60, dy: -120), nowMonotonic) }
                advice.append("An anti-bot check (slider / puzzle / \"are you a robot\") is on screen. iCTRL will not " +
                    "solve it and refuses drags on it: don't try. Close it if it offers a way out (below), otherwise back " +
                    "out (返回, or relaunch the app), then slow down — or stop and report the step as blocked by verification.")
            } else {
                advice.append("This app is throttling: a \"too busy / rest a while / too many requests\" page. Don't retry " +
                    "or tap around — wait at least a minute, then try once (刷新 / 重试 / back). If it comes back, stop using " +
                    "this app for now and report it.")
            }
            if recent.count >= 3 {
                advice.append("This app has pushed back \(recent.count) times in 10 minutes: stop using it for now — more " +
                    "attempts only escalate its checks.")
            }
        } else if b.promo, overlayShown {
            result["promo_popup"] = .bool(true)
            advice.append("A promotional popup (coupons / red packets) is over the page. Close it; never tap its 领取 / " +
                "立即领 / claim buttons — they open activity pages that may dead-end.")
        }
        if !b.close.isEmpty, b.kind != nil || overlayShown {
            result["close_candidates"] = .array(b.close.map {
                .object(["label": .string($0.text), "x": .double($0.frame.midX.rounded()), "y": .double($0.frame.midY.rounded())])
            })
            advice.append("Ways out on screen: " + b.close.map { "'\($0.text)' at (\(Int($0.frame.midX)),\(Int($0.frame.midY)))" }
                .joined(separator: ", ") + ".")
        }
        guard !advice.isEmpty else { return }
        let old: String
        if case .string(let h)? = result["hint"] { old = " " + h } else { old = "" }
        result["hint"] = .string(advice.joined(separator: " ") + old)
    }

    /// Entries for the detector from a rendered tree.
    static func screenTexts(_ body: String) -> [ScreenText] {
        var out: [ScreenText] = []
        for line in body.split(separator: "\n") {
            guard let r = line.range(of: ", label: '") else { continue }
            let rest = line[r.upperBound...]
            guard let e = rest.range(of: "'"), let f = frameOf(line) else { continue }
            let t = line.drop { $0 == " " }
            out.append(ScreenText(text: String(rest[..<e.lowerBound]), type: String(t.prefix { $0 != "," }),
                                  frame: CGRect(x: f[0], y: f[1], width: f[2], height: f[3])))
        }
        return out
    }

    static let blankLoadingHint = "The screen is nearly one colour with nothing labelled: probably a page still " +
        "loading (a blank or skeleton screen). Read once more; if it looks the same, the page is really empty and " +
        "this loading flag was wrong."
    private static func looksLikeLoading(_ body: String) -> Bool {
        for line in body.split(separator: "\n") {
            let t = line.drop(while: { $0 == " " })
            if t.hasPrefix("ActivityIndicator,") { return true }
            let l = t.lowercased()
            if l.contains("正在加载") || l.contains("加载中") || l.contains("正在搜索") || l.contains("搜索中")
                || l.contains("生成中") || l.contains("处理中") || l.contains("请稍候") || l.contains("请稍等")
                || l.contains("loading…") || l.contains("loading...")
                || l.contains("please wait") { return true }
        }
        return false
    }

    /// A sign-in screen or sheet, by its standard wording: common app
    /// vocabulary, not one app's layout, so callers don't spend calls
    /// discovering one from the raw tree.
    private static func looksLikeLoginWall(_ body: String) -> Bool {
        let text = body.lowercased()
        if text.contains("一键登录") || text.contains("本机号码登录") { return true }
        // Sign-up / social sign-in screens ("sign up or log in", "continue with
        // Google", a saved account plus "create new account").
        if ["注册或登录", "登录或注册", "帐号登录", "账号登录", "创建新账户", "创建账户", "创建新帐户",
            "continue with google", "continue with apple", "sign in with apple", "create new account",
            "create account", "sign up or log in", "log in or sign up"].contains(where: text.contains) { return true }
        let zhLogin = text.contains("登录") && (text.contains("手机号") || text.contains("验证码") || text.contains("其他方式登录")
            || text.contains("其他登录方式"))
        // Some apps write it as one word: "Continue with Phone", "Login with username".
        let enLogin = (text.contains("sign in") || text.contains("log in") || text.contains("login with")) &&
            (text.contains("continue with") || text.contains("phone number") || text.contains("password"))
        return zhLogin || enLogin
    }

    /// A content node much taller than the screen (a scrolled document) with
    /// at most one labelled node under it: the document's text isn't exposed
    /// (a web article: a node many screens tall, no text, chrome around it at
    /// 20% coverage, so the tree would be recommended and nothing read).
    static func hasOpaqueContent(_ body: String, screen: CGSize) -> Bool {
        let lines = body.split(separator: "\n")
        for (i, l) in lines.enumerated() {
            guard let r = l.range(of: "{{") else { continue }
            let v = l[r.lowerBound...].split(whereSeparator: { !"-0123456789.".contains($0) }).compactMap { Double($0) }
            guard v.count >= 4, v[3] > screen.height * 3, v[2] >= screen.width * 0.8,
                  v[1] < screen.height, v[1] + v[3] > 0 else { continue }
            let indent = l.prefix { $0 == " " }.count
            var labelled = 0
            var j = i + 1
            while j < lines.count, lines[j].prefix(while: { $0 == " " }).count > indent {
                if lines[j].contains(", label: '"), !lines[j].contains("滚动条"), !lines[j].contains("scroll bar") { labelled += 1 }
                j += 1
            }
            if labelled <= 1 { return true }
        }
        return false
    }

    /// Sibling full-screen subtrees that each carry labelled content: pages
    /// stacked in one tree (a search page plus a login sheet, a home feed plus a
    /// login wall). In document order the last sibling is drawn on top. Returns
    /// the count and the top layer's first labels, or nil when there is one layer.
    private static func stackedLayers(_ body: String, screen: CGSize) -> (count: Int, labels: [String])? {
        layerStack(body.split(separator: "\n"), screen: screen).map { ($0.count, $0.labels) }
    }

    /// The same, with the top layer's lines (indices into `lines`).
    private static func layerStack(_ lines: [Substring], screen: CGSize)
        -> (count: Int, labels: [String], top: Range<Int>)? {
        func frame(_ l: Substring) -> [Double]? {
            guard let r = l.range(of: "{{") else { return nil }
            let v = l[r.lowerBound...].split(whereSeparator: { !"-0123456789.".contains($0) }).compactMap { Double($0) }
            return v.count >= 4 ? v : nil
        }
        func label(_ l: Substring) -> String? {
            guard let r = l.range(of: ", label: '") else { return nil }
            let rest = l[r.upperBound...]
            guard let e = rest.range(of: "'") else { return nil }
            let s = String(rest[..<e.lowerBound])
            return s.isEmpty || s.contains("滚动条") ? nil : s
        }
        // The keyboard's subtrees: its candidate bar (，。？！) sits in the
        // middle band, and it holds full-screen containers of its own, so it
        // would read as a dialog layer.
        var inKeyboard = [Bool](repeating: false, count: lines.count)
        var kbIndent: Int? = nil
        for (i, l) in lines.enumerated() {
            let ind = l.prefix { $0 == " " }.count
            if let k = kbIndent, ind > k { inKeyboard[i] = true; continue }
            kbIndent = nil
            let t = l.dropFirst(ind)
            if t.hasPrefix("Keyboard,") || t.contains("nputAssistantView'") || t.contains("id: 'inputView'") {
                inKeyboard[i] = true; kbIndent = ind
            }
        }
        // Full-screen nodes, grouped by indent: (index, indent).
        var byIndent: [Int: [Int]] = [:]
        for (i, l) in lines.enumerated() {
            guard let f = frame(l), f[0] <= 1, f[1] <= 1, f[2] >= screen.width - 1, f[3] >= screen.height - 1 else { continue }
            byIndent[l.prefix { $0 == " " }.count, default: []].append(i)
        }
        for indent in byIndent.keys.sorted() {
            // Siblings: same indent and no shallower line between them.
            var layers: [(labels: [String], lines: Range<Int>)] = []
            for i in byIndent[indent]! {
                if inKeyboard[i] { continue }
                var labels: [String] = []
                var j = i + 1
                while j < lines.count, lines[j].prefix(while: { $0 == " " }).count > indent {
                    if inKeyboard[j] { j += 1; continue }
                    // Content only: chrome containers are full-screen too (iOS
                    // 27's glass toolbar, table header/footer holders) but
                    // keep their text at the edges.
                    if let s = label(lines[j]), let f = frame(lines[j]),
                       f[1] + f[3] / 2 > screen.height * 0.25, f[1] + f[3] / 2 < screen.height * 0.75 {
                        labels.append(s)
                    }
                    j += 1
                }
                if labels.count >= 2 { layers.append((labels, i..<j)) }
            }
            if let top = layers.last, layers.count >= 2 {
                // A button and its text carry the same label: say it once.
                let names = top.labels.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                return (layers.count, Array(names.prefix(3)), top.lines)
            }
        }
        return nil
    }

    /// The last page_source of an app: its labels and the screen they came with.
    private var lastTreeRead: (bid: String, labels: Int, frame: ScreenSettle.Frame)?
    private static func labelFingerprint(_ body: String) -> Int {
        var h = Hasher()
        for line in body.split(separator: "\n") where line.contains(", label: '") {
            if let r = line.range(of: ", label: '") { h.combine(line[r.upperBound...].prefix(60)) }
        }
        return h.finalize()
    }

    /// What covers the front app's content, if anything: a login wall or a
    /// full-screen layer over the page. One capped read; skipped on a slow tree.
    private func coveringLayer() -> String? {
        guard let bid = resolveForegroundBundleId(), bid != "com.apple.springboard", !isSlowTree(bid),
              heavyList[bid].map({ nowMonotonic - $0 < 300 }) != true,
              let root = ForegroundApp.boundedSnapshot(forBundleID: bid, maxDepth: Self.defaultMaxDepth, maxChildren: 50)
        else { return nil }
        var n = 0
        var t: ObjCBool = false
        guard let body = ForegroundApp.renderBoundedSnapshot(
                root, maxDepth: Self.defaultMaxDepth, maxElements: 600,
                visibleRect: CGRect(x: 0, y: 0, width: pointSize.width, height: pointSize.height),
                nodesWritten: &n, truncated: &t) else { return nil }
        if Self.looksLikeLoginWall(body) { return "a login screen" }
        if let top = Self.stackedLayers(body, screen: pointSize.size) {
            return "a layer on top (" + top.labels.prefix(3).map { "'\($0)'" }.joined(separator: ", ") + ")"
        }
        return nil
    }

    private func currentTreeCoverage() -> Double? {
        guard let bid = resolveForegroundBundleId(), bid != "com.apple.springboard" else { return nil }
        if let c = coverageCache, c.bid == bid, let now = readFrame, ScreenSettle.diff(c.frame, now) < 0.02 {
            return c.value
        }
        if isSlowTree(bid) { return nil }
        guard let root = ForegroundApp.boundedSnapshot(forBundleID: bid, maxDepth: Self.defaultMaxDepth,
                                                       maxChildren: 50) else { return nil }
        var n = 0
        var t: ObjCBool = false
        guard let body = ForegroundApp.renderBoundedSnapshot(
                root, maxDepth: Self.defaultMaxDepth, maxElements: 600,
                visibleRect: CGRect(x: 0, y: 0, width: pointSize.width, height: pointSize.height),
                nodesWritten: &n, truncated: &t) else { return nil }
        let value = visibleLabelledCoverage(body)
        if let frame = readFrame { coverageCache = (bid, frame, value) }
        coverageBody = body
        return value
    }
    /// The tree text behind the last coverage measured: lets screen_text check
    /// whether the words OCR sees are in the tree at all.
    private var coverageBody: String?

    /// Share of OCR'd text lines (4+ characters) that also appear in the tree.
    /// Labelled chrome can cover the screen while a web article's text isn't
    /// in the tree at all (high coverage, no article text).
    static func treeTextShare(_ ocr: [String], body: String) -> Double? {
        func norm(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }
        let tree = norm(body)
        let lines = ocr.map(norm).filter { $0.count >= 4 }
        guard lines.count >= 5 else { return nil }
        let found = lines.filter { tree.contains($0.prefix(12)) }.count
        return Double(found) / Double(lines.count)
    }

    /// Screen regions drawn OVER the foreground app by the system: the status
    /// bar, and anything SpringBoard shows outside the app's own card (banners,
    /// the Dynamic Island and its live activities, alerts). Text found there is
    /// not the app's — reading it as the app's content is how one run decided
    /// the phone was "mirroring" another app.
    ///
    /// Generic on purpose: no knowledge of which app or activity drew what,
    /// just "inside the app's card" versus "on top of it".
    /// SpringBoard's overlay regions barely change between reads (status bar,
    /// a rare banner) but cost a walk of SpringBoard each screen_text — a
    /// large share of the call. Reuse them briefly.
    private var overlayCache: (bid: String, rects: [CGRect], at: TimeInterval)?

    private func overlayRects() -> [CGRect] {
        guard let fg = resolveForegroundBundleId(), fg != "com.apple.springboard" else { return [] }
        if let c = overlayCache, c.bid == fg, nowMonotonic - c.at < 5 { return c.rects }
        let rects = computeOverlayRects()
        overlayCache = (fg, rects, nowMonotonic)
        return rects
    }

    private func computeOverlayRects() -> [CGRect] {
        guard let root = ForegroundApp.boundedSnapshot(forBundleID: "com.apple.springboard",
                                                       maxDepth: Self.defaultMaxDepth, maxChildren: 50) else { return [] }
        let screen = CGRect(x: 0, y: 0, width: pointSize.width, height: pointSize.height)
        var n = 0
        var t: ObjCBool = false
        guard let body = ForegroundApp.renderBoundedSnapshot(
                root, maxDepth: Self.defaultMaxDepth, maxElements: 600, visibleRect: screen,
                nodesWritten: &n, truncated: &t) else { return [] }
        var rects: [CGRect] = []
        var cardIndent: Int?
        for line in body.split(separator: "\n") {
            let indent = line.prefix { $0 == " " }.count
            let text = line.dropFirst(indent)
            if let ci = cardIndent, indent <= ci { cardIndent = nil }
            if text.contains("id: 'card:") { cardIndent = indent; continue }
            let isStatusBar = text.hasPrefix("StatusBar,") || text.hasPrefix("Type25,")
            if cardIndent != nil && !isStatusBar { continue }
            guard let r = line.range(of: "{{"),
                  let end = line.range(of: "}}", range: r.lowerBound..<line.endIndex) else { continue }
            let f = line[r.lowerBound..<end.upperBound]
                .split(whereSeparator: { !"-0123456789.".contains($0) }).compactMap { Double($0) }
            guard f.count >= 4, f[2] > 0, f[3] > 0 else { continue }
            let rect = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
            // Full-screen nodes are containers (windows, the app switcher), not overlays.
            guard rect.width * rect.height < screen.width * screen.height * 0.6 else { continue }
            rects.append(rect.insetBy(dx: -2, dy: -2))
        }
        return rects
    }

    /// Where the list is scrolled to, derived from the row frames.
    ///
    /// There is no contentOffset to read: a scrollable container reports the
    /// SCREEN rect as its own frame (WeChat's chat Table is exactly
    /// {{0,0},{402,874}} however far it is scrolled). What does carry the
    /// information is its rows — their frames are absolute, so rows above the
    /// viewport have negative y and rows below run past the screen height.
    /// Measured on a WeChat chat list: 388 rows spanning y -9091..20500, which
    /// puts the viewport 9091pt into a 28717pt scrollable range — 31.7%.
    ///
    /// Only meaningful when the app materialises rows it is not showing. Lists
    /// built lazily (SwiftUI, and Settings/App Store/RED as measured) expose
    /// only what is on screen, so the arithmetic degenerates to 0% or 100%;
    /// `confidence` says which case you are in rather than leaving the caller
    /// to guess.
    private func scrollPosition() -> [String: JSONValue]? {
        guard let bid = resolveForegroundBundleId(),
              let root = ForegroundApp.boundedSnapshot(
                forBundleID: bid,
                maxDepth: Self.defaultMaxDepth,
                maxChildren: Self.maxChildrenPerNode) else { return nil }
        var n = 0
        var t: ObjCBool = false
        guard let body = ForegroundApp.renderBoundedSnapshot(
                root, maxDepth: Self.defaultMaxDepth, maxElements: 4000,
                nodesWritten: &n, truncated: &t) else { return nil }

        // Rows only — Cell for tables/collections, and the direct children of a
        // ScrollView for everything else. Chrome must not count: a nav bar at
        // y=62 would anchor `top` to the viewport and flatten the range.
        var tops: [Double] = []
        var bottoms: [Double] = []
        var rowHeights: [Double] = []
        for line in body.split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            guard trimmed.hasPrefix("Cell,") else { continue }
            guard let r = line.range(of: "{{"),
                  let end = line.range(of: "}}", range: r.lowerBound..<line.endIndex) else { continue }
            let f = line[r.lowerBound..<end.upperBound]
                .split(whereSeparator: { !"-0123456789".contains($0) }).compactMap { Double($0) }
            guard f.count >= 4, f[3] > 0 else { continue }
            tops.append(f[1])
            bottoms.append(f[1] + f[3])
            rowHeights.append(f[3])
        }
        guard tops.count >= 3, let top = tops.min(), let bottom = bottoms.max() else { return nil }

        let viewportH = pointSize.height
        let contentH = bottom - top
        let scrollable = contentH - viewportH
        // The rows in the tree fit on screen. That proves "nothing to scroll"
        // only if they also end well short of the bottom edge: a lazily built
        // list exposes just its on-screen rows, which always "fit" — an endless
        // feed would be reported as having nothing to scroll.
        guard scrollable > 1 else {
            if bottom < viewportH * 0.85 {
                return [
                    "fits_on_screen": .bool(true),
                    "confidence": .string("exact"),
                    "note": .string("All \(tops.count) rows fit in the viewport and end above its bottom — there is nothing to scroll."),
                ]
            }
            return [
                "confidence": .string("unknown"),
                "note": .string("Only on-screen rows are in the tree (a lazily built list), so how much more there " +
                                "is can't be told. page{direction:\"down\"} and check `moved` to find out."),
            ]
        }

        let scrolledPast = max(-top, 0)
        let fraction = min(max(scrolledPast / scrollable, 0), 1)
        let rowH = rowHeights.sorted()[rowHeights.count / 2]
        let rowIndex = rowH > 0 ? Int(scrolledPast / rowH) + 1 : 0

        // `truncated` means max_children cut the row list short, so `bottom` is
        // not the real end of the content and the percentage reads high.
        let cut = t.boolValue
        var out: [String: JSONValue] = [
            "percent": .double((fraction * 1000).rounded() / 10),
            "fraction": .double((fraction * 1000).rounded() / 1000),
            "scrolled_pt": .double(scrolledPast.rounded()),
            "scrollable_pt": .double(scrollable.rounded()),
            "content_pt": .double(contentH.rounded()),
            "viewport_pt": .double(viewportH),
            "content_top_y": .double(top.rounded()),
            "content_bottom_y": .double(bottom.rounded()),
            "rows_seen": .int(tops.count),
            "confidence": .string(cut ? "low" : "estimated"),
        ]
        if rowIndex > 0 { out["row_estimate"] = .string("~\(rowIndex)/\(tops.count)") }
        out["note"] = .string(cut
            ? "max_children truncated the row list, so content_pt is an underestimate and percent reads HIGH. Raise max_children for a better figure."
            : "Derived from row frames, not a real contentOffset. Apps that build rows lazily (SwiftUI lists) expose only the visible ones, which pins this near 0% or 100% — treat a suspiciously round figure with rows_seen in single digits as unreliable.")
        return out
    }

    /// Compare two fingerprints into the fields a caller needs.
    ///
    /// `moved:false` is the signal that matters: it means the gesture changed
    /// nothing, so the content you are looking for is NOT further in this
    /// direction and repeating the scroll is wasted. Without it a caller keeps
    /// swiping at a wall, which is exactly what happened in testing.
    ///
    /// One caveat worth passing on: a page still LOADING also looks unchanged,
    /// so `at_end` is reported as a likelihood, not a fact.
    /// Where a page drag starts and how far it goes. With a keyboard up the
    /// drag must stay above it: one starting low (78% of the height) lands on
    /// the keys, scrolls nothing and could type. The search field iOS 27 floats
    /// on top of the keyboard, and a band above it, take the touch too: from
    /// 120pt above the keyboard nothing moves, from 165pt it scrolls.
    private func pageBand(pages: Double) -> (bottom: Double, travel: Double) {
        let h = pointSize.height
        let bottom = pageKeyboardTop.map { max(h * 0.3, min($0 - 120, $0 * 0.72)) } ?? h * 0.78
        return (bottom, (pageKeyboardTop == nil ? h * 0.66 : bottom - h * 0.12) * pages)
    }

    // MARK: - collect: page + read, several screens per call

    /// What earlier collect calls returned, per app — so the next call
    /// continues the list instead of repeating it.
    private var collectSeen: (bid: String, texts: Set<String>, at: TimeInterval)?
    /// Apps where collect found no table / collection view list to read by
    /// visible cells, and when.
    private var collectNoCells: [String: TimeInterval] = [:]
    /// The mode collect left an app's list in for cost, so the next call
    /// starts there.
    private var collectOCRMode: [String: (reason: String, at: TimeInterval)] = [:]
    /// The child cap collect reads an app's list with, once widened.
    private var collectChildren: [String: (n: Int, at: TimeInterval)] = [:]
    /// Recent tree reads (seconds, nodes) per app, for collect's mode choice.
    private var collectHistory: [String: (samples: [(ms: Double, nodes: Int)], at: TimeInterval)] = [:]

    /// Whether the tree has become too costly to keep reading screen by
    /// screen, and why. One read over 4s; the median of the last three over
    /// 2s; or a rising trend (≥150ms a screen over 4+ reads) about to cross
    /// 2s on the next — left before it times out, not after.
    static func treeTooCostly(_ h: [(ms: Double, nodes: Int)]) -> String? {
        guard let last = h.last else { return nil }
        if last.ms > 4 { return "slow" }
        if h.count >= 3 {
            let m = h.suffix(3).map { $0.ms }.sorted()[1]
            if m > 2 { return "slow" }
        }
        if h.count >= 4 {
            let ys: [Double] = h.suffix(6).map { $0.ms }
            let n = Double(ys.count)
            let mx: Double = (n - 1) / 2
            var my: Double = 0
            for y in ys { my += y }
            my /= n
            var num: Double = 0, den: Double = 0
            for (i, y) in ys.enumerated() {
                let dx = Double(i) - mx
                num += dx * (y - my)
                den += dx * dx
            }
            let slope = den > 0 ? num / den : 0
            if slope > 0.15, last.ms + slope > 2 {
                let grew = h.first.map { last.nodes - $0.nodes } ?? 0
                return "growing (+\(Int(slope * 1000))ms/screen, nodes \(grew >= 0 ? "+" : "")\(grew))"
            }
        }
        return nil
    }

    /// Apps whose list text was found to be mostly outside the tree.
    private var collectPrefersOCR: [String: TimeInterval] = [:]

    /// Paging a feed meant two calls a screen (page, then page_source) and
    /// several seconds each. One call reads, pages, reads… and hands back only
    /// text not seen before.
    private func collect(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        guard let bid = resolveForegroundBundleId() else {
            return (nil, .serverError("Can't tell which app is in front, so there is no tree to collect from. Read it with page_source first."))
        }
        // OCR when asked, or when the app's accessibility has stopped
        // answering — a long feed can stop after a few screens; tree reads
        // then fail and collect would return nothing.
        let source = cmd.source?.lowercased() ?? "auto"
        // fresh: a new list — judge the tree again rather than keep an old
        // "thin" verdict.
        if cmd.fresh == true { collectPrefersOCR[bid] = nil }
        // A tree read just measured at 3s+ can't fit several screens in the
        // budget: collect would wait out a failing read before going to OCR,
        // past its call limit.
        var useOCR = source == "ocr" || (source == "auto" && (treeCost[bid] ?? 0) >= 3 && nowMonotonic - treeCostAt < 20)
            || (source == "auto" && collectPrefersOCR[bid].map { nowMonotonic - $0 < 300 } == true)
        var switchedToOCR = false
        let start = nowMonotonic
        let budget = 11.0
        let pages = max(0, min(cmd.pages ?? 3, 8))
        let minLen = max(1, cmd.minLength ?? 2)
        let goingDown = cmd.direction?.lowercased() != "up"
        var seen: Set<String> = []
        if cmd.fresh != true, let c = collectSeen, c.bid == bid, nowMonotonic - c.at < 600 { seen = c.texts }
        let screen = CGRect(x: 0, y: 0, width: pointSize.width, height: pointSize.height)

        // A list found to keep its scrolled-past rows stays widened for the
        // rest of the session: reset to 50 on the next call, it hit the cap
        // again and the thin read sent the app to OCR for good.
        var cellsReads = 0
        var children = (cmd.fresh != true ? collectChildren[bid] : nil).flatMap { nowMonotonic - $0.at < 600 ? $0.n : nil }
            ?? Self.childrenLadder[0]
        var capHit: () -> Bool = { false }
        // Visible cells first: their cost doesn't grow with the list. Apps
        // without a table / collection view list fall back, and aren't asked
        // again for a while.
        var tryCells = collectNoCells[bid].map { nowMonotonic - $0 > 300 } ?? true
        func read() -> (items: [(String, String, [Double])], fingerprint: String)? {
            var n = 0
            let body: String
            if tryCells, let fast = visibleListBody(bid) {
                body = fast.body
                n = fast.cells
                capHit = { false }
                cellsReads += 1
            } else {
                let triedCells = tryCells
                tryCells = false
                guard let root = ForegroundApp.boundedSnapshot(forBundleID: bid, maxDepth: Self.defaultMaxDepth,
                                                               maxChildren: children) else { return nil }
                var t: ObjCBool = false
                let cap = children
                capHit = {
                    var m = 0
                    var t2: ObjCBool = false
                    return ForegroundApp.renderBoundedSnapshot(root, maxDepth: Self.defaultMaxDepth, maxElements: 4000, visibleRect: .null,
                                                               nodesWritten: &m, truncated: &t2).map { Self.childCapHit($0, cap: cap) } ?? false
                }
                guard let b = ForegroundApp.renderBoundedSnapshot(root, maxDepth: Self.defaultMaxDepth, maxElements: 1200,
                                                                  visibleRect: screen, nodesWritten: &n, truncated: &t) else { return nil }
                body = b
                // Only a loaded screen says "no cell list here" (a cold start
                // may not have drawn its list yet).
                if triedCells, Self.contentTextCount(b, height: pointSize.height) >= Self.minTreeTextItems {
                    collectNoCells[bid] = nowMonotonic
                }
            }
            var items: [(String, String, [Double])] = []
            var parts: [String] = []
            var kbIndent: Int?
            lastBody = body
            lastNodes = n
            for line in body.split(separator: "\n") {
                let indent = line.prefix { $0 == " " }.count
                if let k = kbIndent, indent > k { continue }
                kbIndent = nil
                let text = line.dropFirst(indent)
                if text.hasPrefix("Keyboard,") {
                    kbIndent = indent
                    if let f = Self.frameOf(line), pageKeyboardTop == nil { pageKeyboardTop = f[1] }
                    continue
                }
                if text.hasPrefix("Application,") || text.hasPrefix("Window,") { continue }
                guard let r = line.range(of: ", label: '") else { continue }
                let rest = line[r.upperBound...]
                guard let e = rest.range(of: "'") else { continue }
                let label = String(rest[..<e.lowerBound]).trimmingCharacters(in: .whitespaces)
                if label.contains("滚动条") || label.lowercased().contains("scroll bar") { continue }
                guard let f = Self.frameOf(line), f[2] > 0, f[3] > 0,
                      CGRect(x: f[0], y: f[1], width: f[2], height: f[3]).intersects(screen) else { continue }
                if parts.count < 40, Self.inContentBand(f, height: pointSize.height) {
                    parts.append("\(label)@\(Int(f[0])),\(Int(f[1]))")
                }
                guard label.count >= minLen else { continue }
                items.append((label, String(text.prefix { $0 != "," }), f))
            }
            return (items, parts.joined(separator: "|"))
        }

        @discardableResult
        func dragPage() -> JSONRPCError? {
            let band = pageBand(pages: 1)
            let fromY = goingDown ? band.bottom : pointSize.height * 0.22
            let toY = goingDown ? max(pointSize.height * 0.12, fromY - band.travel)
                                : min(pageKeyboardTop == nil ? pointSize.height * 0.88 : band.bottom, fromY + band.travel)
            if let err = fastHandler.fastSwipe(fromX: pointSize.width / 2, fromY: fromY, toX: pointSize.width / 2, toY: toY,
                                               duration: 0.35, hold: 0.25).1 { return err }
            // Rows fill in right after the drag stops (lazy cells, prices).
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            return nil
        }
        var retriedFirst = false
        var lastBody: String?
        var lastNodes = 0
        // Tree read costs over this app's recent screens — across calls, so a
        // list read in several collect calls is judged as one session.
        var history = (cmd.fresh != true ? collectHistory[bid] : nil).flatMap { nowMonotonic - $0.at < 600 ? $0.samples : nil } ?? []
        var ocrReason: String? = useOCR ? (source == "ocr" ? "asked" : (treeCost[bid] ?? 0) >= 99 ? "unresponsive" : (treeCost[bid] ?? 0) >= 3 ? "slow" : "thin") : nil
        var ocrScreens = 0
        // Left on OCR for cost last time: start there (re-checked below every
        // 4 screens) instead of paying one more slow tree read to find out.
        if !useOCR, source == "auto", cmd.fresh != true, let m = collectOCRMode[bid], nowMonotonic - m.at < 300 {
            useOCR = true
            ocrReason = m.reason
            ocrScreens = 1
        }
        var modeChanges: [JSONValue] = []
        func switchMode(toOCR: Bool, screen: Int, reason: String) {
            useOCR = toOCR
            ocrReason = toOCR ? reason : nil
            if toOCR, reason == "slow" || reason.hasPrefix("growing") { collectOCRMode[bid] = (reason, nowMonotonic) }
            if !toOCR { collectOCRMode[bid] = nil }
            if toOCR { switchedToOCR = true }
            ocrScreens = 0
            modeChanges.append(.object(["screen": .int(screen), "to": .string(toOCR ? "ocr" : "tree"), "reason": .string(reason)]))
            iCTRLUITests.logBuffer.append("🧺 collect: screen \(screen) → \(toOCR ? "OCR" : "tree") (\(reason))")
        }
        var lastEntries: [ScreenText] = []
        func readOCR() -> (items: [(String, String, [Double])], fingerprint: String)? {
            guard let o = runOCR(query: nil, fast: false, minConfidence: 0.4) else { return nil }
            var items: [(String, String, [Double])] = []
            var parts: [String] = []
            for v in o.items {
                guard let e = Self.ocrScreenText(v) else { continue }
                let f = [Double(e.frame.minX), Double(e.frame.minY), Double(e.frame.width), Double(e.frame.height)]
                if parts.count < 40, Self.inContentBand(f, height: pointSize.height) {
                    parts.append("\(e.text)@\(Int(f[0])),\(Int(f[1]))")
                }
                if e.text.count >= minLen { items.append((e.text, "ocr", f)) }
            }
            return (items, parts.joined(separator: "|"))
        }
        var out: [JSONValue] = []
        var screensRead = 0
        var atEnd = false
        var stoppedForTime = false
        var staleRereads = 0
        var lastFingerprint: String?
        var lastFrame = ScreenSettle.sample()
        var perScreen = 1.0
        for i in 0...pages {
            let t0 = nowMonotonic
            // A screen costs a read plus a drag; don't start one that can't finish.
            if i > 0, nowMonotonic - start + perScreen * 1.2 > budget { stoppedForTime = true; break }
            let readStart = nowMonotonic
            var maybe = useOCR ? readOCR() : read()
            // A read that came back empty quickly is a hiccup (a screen still
            // changing), not an app that stopped answering: try once more.
            if maybe == nil, !useOCR, nowMonotonic - readStart < 2 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                maybe = read()
            }
            if maybe == nil, !useOCR, source == "auto" {
                // The tree read failed: the app stopped answering. Mark it, and
                // read this screen and the rest by OCR.
                if nowMonotonic - readStart > 2 { treeCost[bid] = 99 }
                switchMode(toOCR: true, screen: i, reason: "unresponsive")
                maybe = readOCR()
            }
            guard var got = maybe else { break }
            // Thin because the list kept its scrolled-past rows and they filled
            // the child cap — not because the text isn't in the tree: widen.
            // Only when the capped read was cheap and the call has room: on a
            // cold, already-large tree the extra render plus a 200-child
            // fetch can push one screen past the call limit.
            if !useOCR, children < 200, nowMonotonic - readStart < 1.5, budget - (nowMonotonic - start) > 4,
               Set(got.items.filter { $0.0.count >= 8 && Self.inContentBand($0.2, height: pointSize.height) }.map { $0.0 }).count
                < Self.minTreeTextItems, capHit() {
                children = 200
                collectChildren[bid] = (200, nowMonotonic)
                if let wider = read() {
                    got = wider
                    modeChanges.append(.object(["screen": .int(i), "to": .string("tree, 200 children"),
                                                "reason": .string("tree growth: scrolled-past rows filled the 50-child cap")]))
                    iCTRLUITests.logBuffer.append("🧺 collect: screen \(i) child cap hit — widened to 200")
                }
            }
            // A thin tree: the screen's content isn't in it (e.g. section
            // headers only, where OCR reads several times more). Check the
            // first screen against OCR once and keep whichever reads more.
            if i == 0, !useOCR, source == "auto" {
                // Right after a launch the feed is still filling in (the first tree
                // can hold almost no text) — give it a second first, or the whole
                // session would go to OCR and lose the tree's texts.
                if launchedAt[bid].map({ readStart - $0 < 10 }) == true,
                   got.items.filter({ $0.0.count >= 8 && Self.inContentBand($0.2, height: pointSize.height) }).count < Self.minTreeTextItems {
                    RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                    if let again = read() { got = again }
                }
                // Few texts from the visible cells may be the wrong list (a banner
                // strip on the first screen while the tree holds the feed):
                // the plain tree decides before OCR does.
                let thinNow = { (g: (items: [(String, String, [Double])], fingerprint: String)) in
                    g.items.filter { $0.0.count >= 8 && Self.inContentBand($0.2, height: self.pointSize.height) }.count
                }
                if tryCells, cellsReads > 0, thinNow(got) < Self.minTreeTextItems {
                    tryCells = false
                    if let plain = read(), thinNow(plain) > thinNow(got) { got = plain } else { tryCells = true }
                }
                // Still thin from a capped tree (after a long scroll the cap can
                // hide most of what the screen shows): one wider read before OCR,
                // which drops the tree's types and refs.
                if !tryCells, children < 200, thinNow(got) < Self.minTreeTextItems, budget - (nowMonotonic - start) > 4 {
                    let saved = children
                    children = 200
                    if let wider = read(), thinNow(wider) > thinNow(got) {
                        got = wider
                        collectChildren[bid] = (200, nowMonotonic)
                        iCTRLUITests.logBuffer.append("🧺 collect: screen \(i) thin at \(saved) children — widened to 200")
                    } else { children = saved }
                }
                // Compared by the amount of text, not the number of pieces: some
                // apps put a whole post (author, text, counts) in one label, a few
                // a screen, while OCR splits the same text into many lines — by
                // count a complete tree would read as "thin".
                let treeSet = Set(got.items.filter { $0.0.count >= 8 && Self.inContentBand($0.2, height: pointSize.height) }.map { $0.0 })
                let treeTexts = treeSet.count
                let treeChars = treeSet.reduce(0) { $0 + $1.count }
                if treeTexts < Self.minTreeTextItems, let o = readOCR() {
                    let ocrSet = Set(o.items.filter { $0.0.count >= 8 }.map { $0.0 })
                    let ocrTexts = ocrSet.count
                    let ocrChars = ocrSet.reduce(0) { $0 + $1.count }
                    if ocrTexts >= Self.minTreeTextItems, ocrChars >= treeChars * 2 {
                        collectPrefersOCR[bid] = nowMonotonic
                        switchMode(toOCR: true, screen: i, reason: "thin (tree \(treeTexts) texts, OCR \(ocrTexts))")
                        got = o
                    }
                }
            }
            // Whether to leave the tree is judged on its recent cost, not one
            // read: a single slow read on a hot phone would send an app to OCR
            // for good, while a tree that grows as rows pile up gets slower screen
            // by screen and should be left before it costs a timeout.
            // The first read after a launch pays the app's start-up: not a
            // measure of its tree.
            let coldRead = launchedAt[bid].map { readStart - $0 < 10 } == true && i == 0
            if !useOCR, !coldRead {
                history.append((nowMonotonic - readStart, lastNodes))
                if history.count > 12 { history.removeFirst(history.count - 12) }
                if source == "auto", let why = Self.treeTooCostly(history) { switchMode(toOCR: true, screen: i, reason: why) }
            } else if useOCR {
                ocrScreens += 1
                // Not for good: look at the tree again now and then, and go back
                // when it is quick (slow / growing) or carries the text (thin).
                // A thin verdict is rechecked on each call's first screen as
                // well: the tree may have filled in since (an app still starting).
                if source == "auto", let reason = ocrReason, ocrScreens % 4 == 0 || (ocrScreens == 1 && reason.hasPrefix("thin")),
                   reason == "slow" || reason.hasPrefix("growing") || reason.hasPrefix("thin") {
                    let t = nowMonotonic
                    if let tree = read() {
                        let ms = nowMonotonic - t
                        let textSet = Set(tree.items.filter { $0.0.count >= 8 && Self.inContentBand($0.2, height: pointSize.height) }.map { $0.0 })
                        let texts = textSet.count
                        let chars = textSet.reduce(0) { $0 + $1.count }
                        let back = reason.hasPrefix("thin") ? texts >= Self.minTreeTextItems || chars >= 300 : ms < 1.2
                        if back {
                            history = [(ms, lastNodes)]
                            if reason.hasPrefix("thin") { collectPrefersOCR[bid] = nil }
                            switchMode(toOCR: false, screen: i, reason: reason.hasPrefix("thin")
                                       ? "tree carries the text again (\(texts))" : "tree quick again (\(Int(ms * 1000))ms)")
                        }
                    }
                }
            }
            if i > 0 {
                // Whether the drag scrolled is the pixels' call: this tree
                // lags them (the read right after a drag can return the
                // previous screen's tree, every frame unchanged).
                let frame = ScreenSettle.sample()
                let scrolled = lastFrame.flatMap { a in frame.map { ScreenSettle.contentDiff(a, $0) } }
                if let d = scrolled, d < ScreenSettle.scrolledShare, let prev = lastFingerprint,
                   !Self.contentShifted(prev, got.fingerprint) {
                    // An app can ignore the first drag after a relaunch and take the
                    // second: one unmoved first page is not the end yet.
                    if i == 1, !retriedFirst {
                        retriedFirst = true
                        dragPage()
                        if let again = useOCR ? readOCR() : read() { got = again }
                        let f2 = ScreenSettle.sample()
                        let d2 = lastFrame.flatMap { a in f2.map { ScreenSettle.contentDiff(a, $0) } } ?? 0
                        if d2 < ScreenSettle.scrolledShare, !Self.contentShifted(prev, got.fingerprint) { atEnd = true; break }
                        lastFrame = f2
                    } else { atEnd = true; break }
                }
                lastFrame = frame
                var tries = 0
                while (scrolled ?? 0) >= ScreenSettle.scrolledShare,
                      let prev = lastFingerprint, !Self.contentShifted(prev, got.fingerprint), tries < 4,
                      nowMonotonic - start < budget - 1 {
                    // Let the run loop turn: XCTest refreshes what it knows of
                    // the app's tree on this thread, and a blocked thread kept
                    // handing back the old screen.
                    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                    tries += 1
                    staleRereads += 1
                    guard let again = useOCR ? readOCR() : read() else { break }
                    got = again
                }
            }
            screensRead += 1
            lastFingerprint = got.fingerprint
            lastEntries = got.items.map { ScreenText(text: $0.0, type: $0.1, frame: CGRect(x: $0.2[0], y: $0.2[1], width: $0.2[2], height: $0.2[3])) }
            for (label, type, f) in got.items where !seen.contains(label) {
                seen.insert(label)
                out.append(.object([
                    "text": .string(label), "type": .string(type),
                    "x": .double(f[0]), "y": .double(f[1]), "width": .double(f[2]), "height": .double(f[3]),
                    "screen": .int(i),
                ]))
            }
            if i == pages { break }
            if nowMonotonic - start + perScreen > budget { stoppedForTime = true; break }
            if let err = dragPage() { return (nil, err) }
            perScreen = nowMonotonic - t0
        }
        // A login sheet over the list stops it as surely as its end (a guest
        // feed that shows one screen, then a "log in to see more" prompt).
        let loginWall = lastBody.map(Self.looksLikeLoginWall) == true
        if loginWall { atEnd = false }
        // An app that isn't answering accessibility is often busy enough to
        // ignore a drag too (collect would call the end on screen one while
        // the next page scrolls). That early, it's "didn't move", not "end".
        var busy = false
        if atEnd, useOCR, source == "auto", screensRead <= 2 { atEnd = false; busy = true }
        collectSeen = (bid, seen, nowMonotonic)
        collectHistory[bid] = (history, nowMonotonic)
        let ms = Int((nowMonotonic - start) * 1000)
        iCTRLUITests.logBuffer.append("🧺 collect \(bid): \(screensRead) screens, \(out.count) new items, \(ms)ms, " +
                                      "\(staleRereads) stale-tree rereads\(atEnd ? ", end" : "")")
        var result: [String: JSONValue] = [
            "items": .array(out), "new_count": .int(out.count), "screens_read": .int(screensRead),
            "at_end": .bool(atEnd), "elapsed_ms": .int(ms), "bundle_id": .string(bid),
            "source": .string(useOCR ? "ocr" : cellsReads > 0 ? "visible_cells" : "tree"),
        ]
        if !modeChanges.isEmpty { result["mode_changes"] = .array(modeChanges) }
        if let h = history.last {
            result["tree_read"] = .object([
                "last_ms": .int(Int(h.ms * 1000)), "last_nodes": .int(h.nodes),
                "first_nodes": .int(history.first?.nodes ?? h.nodes), "samples": .int(history.count),
            ])
        }
        var hint: String
        if atEnd {
            hint = "Reached the end of the list in this direction — nothing more to collect that way."
        } else if stoppedForTime {
            hint = "Stopped after \(screensRead) screens to stay inside the call time; call collect again to continue."
        } else {
            hint = "Call collect again to continue the list; items already returned won't repeat (fresh:true starts over)."
        }
        if loginWall {
            result["login_wall"] = .bool(true)
            hint = "A login wall is over the list — that, not the end, stopped it. If logging in isn't allowed, close " +
                "it (×, 暂不登录, 返回) and call collect again, or report the rest as needing login."
        }
        if busy {
            hint = "The list didn't move under the drag — this app is busy (it isn't answering accessibility either). " +
                "Call collect again in a few seconds; only at_end:true means the end."
        }
        if switchedToOCR {
            hint = "Read by OCR: this app's list text is mostly outside the accessibility tree, or the tree was too " +
                "slow / stopped answering (items have no refs; tap by their x/y). " + hint
        }
        if out.isEmpty, !atEnd, screensRead == 0 {
            hint = "Couldn't read the screen (neither the tree nor OCR answered). Wait a few seconds and call again. " + hint
        } else if out.isEmpty, !atEnd {
            hint = "No new text on these screens — the list may be drawn outside the accessibility tree (check " +
                "channel.recommended with page_source; on ocr use page + screen_text). " + hint
        }
        result["hint"] = .string(hint)
        flagBlockers(lastEntries, bid: bid, overlayShown: false, into: &result)
        readFrame = lastFrame
        return (result, nil)
    }

    private func scrollOutcome(before: String?, after: String?) -> [String: JSONValue] {
        guard let b = before, let a = after else {
            return ["moved": .bool(true), "motion_check": .string("unavailable")]
        }
        let moved = Self.contentShifted(b, a)
        var out: [String: JSONValue] = ["moved": .bool(moved)]
        // Another walk of the app, gated as page_source gates it: ungated here
        // it can take most of a page call, leaving the settle a negative budget.
        let bid = resolveForegroundBundleId()
        let skip = bid.map { isSlowTree($0) || justLaunched($0)
            || (scrollPositionCost[$0].map { nowMonotonic - $0.at < 120 && $0.s > 0.8 } ?? false) } ?? false
        if !skip {
            let t = nowMonotonic
            if let pos = scrollPosition() { out["position"] = .object(pos) }
            if let bid = bid { scrollPositionCost[bid] = (nowMonotonic - t, nowMonotonic) }
        }
        if !moved {
            out["at_end"] = .bool(true)
            out["hint"] = .string(
                "The screen did not change — you are most likely at the end of the scrollable "
                + "content in this direction, so scrolling further will do nothing. "
                + "If the page was still loading when this ran, read again before concluding that.")
        }
        return out
    }

    /// Fraction of the CONTENT area (screen minus nav/tab chrome) covered by
    /// labelled nodes the caller could act on, 0...1.
    ///
    /// This is the fallback trigger, in preference to a node count: a count needs
    /// a threshold that is really a guess about screen size and list density,
    /// whereas a ratio is dimensionless and so travels across devices and apps
    /// unchanged. It also catches the case a count misses — a handful of labels
    /// that happen to exist while the body of the screen is empty.
    ///
    /// Overlapping rects are unioned on a coarse grid rather than summed: chat
    /// rows stack a cell, its title and its subtitle at the same place, and
    /// adding those areas up reports >100% coverage on a screen showing nothing.
    private func visibleLabelledCoverage(_ body: String) -> Double {
        let w = pointSize.width, h = pointSize.height
        var topChrome = 0.0
        var bottomChrome = h
        for line in body.split(separator: "\n") {
            let t = line.drop { $0 == " " }
            let isNav = t.hasPrefix("NavigationBar,") || t.hasPrefix("StatusBar,")
            let isTab = t.hasPrefix("TabBar,")
            guard isNav || isTab else { continue }
            guard let r = line.range(of: "{{"),
                  let end = line.range(of: "}}", range: r.lowerBound..<line.endIndex) else { continue }
            let f = line[r.lowerBound..<end.upperBound]
                .split(whereSeparator: { !"-0123456789".contains($0) }).compactMap { Double($0) }
            guard f.count >= 4, f[3] > 0, f[3] < h * 0.4 else { continue }
            if isNav, f[1] + f[3] > topChrome, f[1] < h * 0.3 { topChrome = f[1] + f[3] }
            if isTab, f[1] < bottomChrome, f[1] + f[3] > h * 0.7 { bottomChrome = f[1] }
        }
        let contentTop = topChrome, contentBottom = bottomChrome
        let contentH = max(contentBottom - contentTop, 1)

        // 16x32 occupancy grid over the content band — enough resolution to tell
        // "a few scattered labels" from "the screen is full", without the cost of
        // real polygon union.
        let cols = 16, rows = 32
        var grid = [Bool](repeating: false, count: cols * rows)
        for line in body.split(separator: "\n") {
            guard line.contains(", label: '") || line.contains(", value: '") else { continue }
            guard let r = line.range(of: "{{"),
                  let end = line.range(of: "}}", range: r.lowerBound..<line.endIndex) else { continue }
            let f = line[r.lowerBound..<end.upperBound]
                .split(whereSeparator: { !"-0123456789".contains($0) }).compactMap { Double($0) }
            guard f.count >= 4, f[2] > 0, f[3] > 0 else { continue }
            // Skip labelled nodes that span (nearly) the whole screen. They are
            // containers — an Application/Window element carrying the app's name,
            // or a full-bleed backdrop — not things a caller can act on. Measured:
            // a scrolled WeChat list returns `微信` with h=874, and that single
            // node filled the entire occupancy grid, pinning coverage at 100% and
            // stopping the OCR fallback from EVER firing, on every app.
            guard f[2] < w * 0.98 || f[3] < h * 0.8 else { continue }
            let x0 = max(f[0], 0), y0 = max(f[1], contentTop)
            let x1 = min(f[0] + f[2], w), y1 = min(f[1] + f[3], contentBottom)
            guard x1 > x0, y1 > y0 else { continue }
            let c0 = Int((x0 / w) * Double(cols)), c1 = Int(((x1 / w) * Double(cols)).rounded(.up))
            let r0 = Int(((y0 - contentTop) / contentH) * Double(rows))
            let r1 = Int((((y1 - contentTop) / contentH) * Double(rows)).rounded(.up))
            for rr in max(r0, 0)..<min(max(r1, r0 + 1), rows) {
                for cc in max(c0, 0)..<min(max(c1, c0 + 1), cols) { grid[rr * cols + cc] = true }
            }
        }
        var coverage = Double(grid.filter { $0 }.count) / Double(cols * rows)
        // Area undercounts image-led layouts: a screen can sit under 10%
        // coverage with hundreds of usable labelled nodes. Many distinct
        // labelled nodes on screen is a readable tree, whatever area.
        let labelledOnScreen = body.split(separator: "\n").filter { line in
            guard line.contains(", label: '"), !line.contains("滚动条"),
                  let r = line.range(of: "{{") else { return false }
            let v = line[r.lowerBound...].split(whereSeparator: { !"-0123456789.".contains($0) }).compactMap { Double($0) }
            return v.count >= 4 && v[2] > 0 && v[3] > 0 && v[1] + v[3] > contentTop && v[1] < contentBottom
                && v[0] + v[2] > 0 && v[0] < w
        }.count
        if labelledOnScreen >= 30 { coverage = max(coverage, Self.treeCoverageThreshold) }
        // Search bars, tabs and filter chips alone can reach 18–27% — over
        // the bar — while the list that IS the content is an empty container
        // (answers, search results, map POIs: rows drawn but not exposed).
        // A big list with no labelled row inside means the tree is
        // missing the content whatever the furniture adds up to.
        if coverage >= Self.treeCoverageThreshold, hasEmptyListArea(body, contentHeight: contentH) {
            return min(coverage, Self.treeCoverageThreshold / 2)
        }
        return coverage
    }

    /// A CollectionView/Table/ScrollView covering over a third of the content
    /// band with no labelled node inside it.
    private func hasEmptyListArea(_ body: String, contentHeight: Double) -> Bool {
        let lines = body.split(separator: "\n")
        let w = pointSize.width
        for (i, line) in lines.enumerated() {
            let indent = line.prefix { $0 == " " }.count
            let t = line.dropFirst(indent)
            guard t.hasPrefix("CollectionView,") || t.hasPrefix("Table,") || t.hasPrefix("ScrollView,"),
                  let r = line.range(of: "{{"),
                  let end = line.range(of: "}}", range: r.lowerBound..<line.endIndex) else { continue }
            let f = line[r.lowerBound..<end.upperBound]
                .split(whereSeparator: { !"-0123456789.".contains($0) }).compactMap { Double($0) }
            guard f.count >= 4, f[2] >= w * 0.6, f[3] >= contentHeight / 3 else { continue }
            var labelled = 0
            for inner in lines[(i + 1)...] {
                if inner.prefix(while: { $0 == " " }).count <= indent { break }
                // Scroll indicators are labelled ("Vertical scroll bar, 1 page") but are not content.
                if inner.contains("滚动条") || inner.lowercased().contains("scroll bar") { continue }
                if inner.contains(", label: '") || inner.contains(", value: '") { labelled += 1 }
                if labelled > 0 { break }
            }
            if labelled == 0 { return true }
        }
        return false
    }

    /// Worst (smallest) bottom edge among the direct children of any scrollable
    /// container, plus whether that container returned fewer children than asked.
    ///
    /// This is the under-fetch signal. It must be computed PER CONTAINER: a global
    /// "does anything reach the viewport" test always passes, because the nav bar,
    /// tab bar and window span the screen no matter how little list content came
    /// back — verified, it reported success even when zero rows were on screen.
    private static func underFetchProbe(_ body: String, requested: Int)
        -> (underFetched: Bool, saturated: Bool, lastBottom: Int, rowHeight: Int)? {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func indent(_ s: String) -> Int { s.prefix { $0 == " " }.count / 2 }
        func frame(_ s: String) -> (x: Int, y: Int, w: Int, h: Int)? {
            guard let r = s.range(of: "{{"), let end = s.range(of: "}}", range: r.lowerBound..<s.endIndex)
            else { return nil }
            let nums = s[r.lowerBound..<end.upperBound]
                .split(whereSeparator: { !"-0123456789".contains($0) })
                .compactMap { Int($0) }
            guard nums.count >= 4 else { return nil }
            return (nums[0], nums[1], nums[2], nums[3])
        }

        var result: (Bool, Bool, Int, Int)?
        for (i, line) in lines.enumerated() {
            let t = line.drop { $0 == " " }
            guard t.hasPrefix("Table,") || t.hasPrefix("CollectionView,") || t.hasPrefix("ScrollView,")
            else { continue }
            let depth = indent(line)
            var kids: [(x: Int, y: Int, w: Int, h: Int)] = []
            var j = i + 1
            while j < lines.count, indent(lines[j]) > depth {
                if indent(lines[j]) == depth + 1, let f = frame(lines[j]) { kids.append(f) }
                j += 1
            }
            // Containers with a couple of children are chrome, not a feed.
            guard kids.count >= 3 else { continue }
            let lastBottom = kids.map { $0.y + $0.h }.max() ?? 0
            let heights = kids.map { $0.h }.filter { $0 > 0 }.sorted()
            let rowH = heights.isEmpty ? 0 : heights[heights.count / 2]
            // Fewer children than requested means the container is exhausted —
            // asking for more cannot return more, so the ladder must stop.
            let saturated = kids.count < requested
            let under = lastBottom < 0
            if result == nil || lastBottom < result!.2 {
                result = (under, saturated, lastBottom, rowH)
            }
        }
        return result
    }

    /// Apply a filter to bounded-fetch output, preserving the ancestor path of
    /// every match so the result reads as a tree rather than a flat list — the
    /// same contract `renderSnapshotInto` provides on the protocol path.
    private static func filterRenderedTree(_ body: String, filter: SnapshotFilter) -> (text: String, count: Int) {
        guard filter.active else { return (body, body.isEmpty ? 0 : body.split(separator: "\n").count) }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var keep = [Bool](repeating: false, count: lines.count)

        func indent(_ s: String) -> Int { s.prefix { $0 == " " }.count }

        for (i, line) in lines.enumerated() where filter.matchesRenderedLine(line) {
            keep[i] = true
            // Walk back up marking each strictly-shallower ancestor, so the
            // match keeps its context instead of appearing at the root.
            var need = indent(line)
            guard need > 0 else { continue }
            var j = i - 1
            while j >= 0, need > 0 {
                let ind = indent(lines[j])
                if ind < need { keep[j] = true; need = ind }
                j -= 1
            }
        }

        var out: [String] = []
        var matched = 0
        for (i, line) in lines.enumerated() where keep[i] {
            out.append(line)
            if filter.matchesRenderedLine(line) { matched += 1 }
        }
        // Count reports MATCHES, not emitted lines — ancestors are context, and
        // counting them would inflate "how many buttons are on screen".
        return (out.joined(separator: "\n"), matched)
    }

    /// Recursively render a snapshot subtree into `lines`. When a filter is
    /// active, a node is emitted only if it matches OR one of its descendants
    /// matches — so the ancestor path to every match is preserved and the tree
    /// stays readable. `globalCount` is shared across the whole traversal so the
    /// max_elements hard cap is honored regardless of subtree.
    @discardableResult
    private func renderSnapshotInto(_ s: XCUIElementSnapshot, depth: Int, maxDepth: Int,
                                    maxElements: Int, filter: SnapshotFilter,
                                    cullToViewport: Bool = false,
                                    viewportRect: CGRect = .null,
                                    lines: inout [String], localCount: inout Int,
                                    globalCount: inout Int, truncated: inout Bool,
                                    seenFrames: inout Set<String>) -> Bool {
        if globalCount >= maxElements { truncated = true; return false }

        // Dedup across app + per-window snapshots: skip a node we've already
        // emitted (same type + frame). Container 'Other'/'Application' roots are
        // allowed to repeat (their frames overlap by nature) but leaf identity is
        // keyed on type+frame+label.
        let f = s.frame
        let key = "\(s.elementType.rawValue)|\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))|\(s.label)"
        let isDup = seenFrames.contains(key)

        // Mirror the bounded path's viewport culling so visible_only behaves the
        // same when the fast fetch falls back — otherwise the flag would silently
        // do nothing exactly on the pages that most need it.
        let selfVisible = !cullToViewport || {
            let fr = s.frame
            return fr.width > 0 && fr.height > 0 && fr.intersects(viewportRect)
        }()
        let selfMatches = (!filter.active || filter.matches(s)) && selfVisible
        var childLines: [String] = []
        var descendantMatched = false

        if depth < maxDepth {
            // Cap siblings per node as well as total depth: a single list can
            // hold hundreds of rendered rows, and walking all of them is what
            // makes a scrolled feed expensive. Reported in the response hint.
            //
            var childrenWalked = 0
            for child in s.children {
                if globalCount >= maxElements { truncated = true; break }
                if childrenWalked >= Self.maxChildrenPerNode { truncated = true; break }
                childrenWalked += 1
                var sub: [String] = []
                var subCount = 0
                let kept = renderSnapshotInto(child, depth: depth + 1, maxDepth: maxDepth,
                                              maxElements: maxElements, filter: filter,
                                              cullToViewport: cullToViewport, viewportRect: viewportRect,
                                              lines: &sub, localCount: &subCount,
                                              globalCount: &globalCount, truncated: &truncated,
                                              seenFrames: &seenFrames)
                if kept { childLines.append(contentsOf: sub); descendantMatched = true }
            }
        }

        // Skip emitting a duplicate leaf, but still surface children that are new.
        // With culling on, an invisible node survives only as the ancestor path
        // of a visible descendant — never on its own.
        let gate = cullToViewport ? (selfMatches || descendantMatched)
                                  : (!filter.active || selfMatches || descendantMatched)
        let keep = gate && (!isDup || descendantMatched)
        guard keep else { return false }

        if !isDup {
            seenFrames.insert(key)
            let indent = String(repeating: "  ", count: depth)
            lines.append(indent + describeSnapshot(s))
            localCount += 1
            globalCount += 1
        }
        // Append the rendered child subtree AFTER this node — without this the
        // whole descendant tree was silently dropped (only the root was emitted).
        lines.append(contentsOf: childLines)
        return true
    }

    /// One-line description of a snapshot node: Type, label/value/id, frame.
    private func describeSnapshot(_ s: XCUIElementSnapshot) -> String {
        var parts = [Self.elementTypeName(s.elementType)]
        if !s.label.isEmpty { parts.append("label: '\(s.label)'") }
        if let v = s.value as? String, !v.isEmpty { parts.append("value: '\(v)'") }
        if !s.identifier.isEmpty { parts.append("id: '\(s.identifier)'") }
        let f = s.frame
        parts.append("{{\(Int(f.minX)), \(Int(f.minY))}, {\(Int(f.width)), \(Int(f.height))}}")
        return parts.joined(separator: ", ")
    }

    /// Human-readable name for an XCUIElement.ElementType raw value.
    private static func elementTypeName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .any: return "Any"
        case .application: return "Application"
        case .window: return "Window"
        case .button: return "Button"
        case .staticText: return "StaticText"
        case .textField: return "TextField"
        case .secureTextField: return "SecureTextField"
        case .textView: return "TextView"
        case .searchField: return "SearchField"
        case .image: return "Image"
        case .icon: return "Icon"
        case .cell: return "Cell"
        case .table: return "Table"
        case .collectionView: return "CollectionView"
        case .scrollView: return "ScrollView"
        case .switch: return "Switch"
        case .slider: return "Slider"
        case .link: return "Link"
        case .navigationBar: return "NavigationBar"
        case .tabBar: return "TabBar"
        case .toolbar: return "Toolbar"
        case .alert: return "Alert"
        case .sheet: return "Sheet"
        case .keyboard: return "Keyboard"
        case .key: return "Key"
        case .picker: return "Picker"
        case .pickerWheel: return "PickerWheel"
        case .segmentedControl: return "SegmentedControl"
        case .map: return "Map"
        case .webView: return "WebView"
        case .other: return "Other"
        case .group: return "Group"
        default: return "Type\(type.rawValue)"
        }
    }

    /// Scroll until an element whose label/value/identifier contains `element_id`
    /// (or matches accessibility id) becomes visible, then return its tap point.
    /// Uses native XCUIElement scrolling against the foreground app.
    /// Bring an element into view.
    ///
    /// Aims instead of searching when it can: the bounded snapshot usually
    /// already holds the target's frame (a calendar day view keeps all 24 hours
    /// in the tree), so one precise drag of exactly the right distance replaces
    /// a series of blind 40% swipes in a guessed direction. It also refuses to
    /// call an element "found" merely because it exists — the old check did,
    /// and so answered "on screen" for things hundreds of points away.
    ///
    /// Only when the target is absent from the tree (recycling lists) does it
    /// scroll blind — inside the real scroll container, at a speed below iOS's
    /// momentum threshold, reversing once if the direction wasn't given, and
    /// saying plainly when both ends were reached without a sighting.
    private func scrollToElement(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        guard let query = cmd.elementId, !query.isEmpty else {
            return legacyScrollToElement(cmd)
        }
        guard let bundleId = cmd.bundleId ?? resolveForegroundBundleId() else {
            return legacyScrollToElement(cmd)
        }
        // Same few-ms guard as locateElement: every scan and drag below targets
        // this app, and a backgrounded one makes each scan a slow, CPU-bound miss.
        if let err = Self.snapshotPrecheck(bundleId: bundleId, action: "scroll to '\(query)'",
                                           retryWith: "scroll_to_element", strict: true) {
            return (nil, err)
        }
        let matchMode = (cmd.matchMode ?? "exact").lowercased()
        let typeFilter = cmd.elementType
        let explicitDirection = cmd.direction?.lowercased()
        var direction = explicitDirection ?? "up"
        let maxSteps = max(1, Int(cmd.distance ?? 12))
        let size = pointSize
        let target = XCUIApplication(bundleIdentifier: bundleId)
        let q = elementQuery(in: target, type: typeFilter)

        var steps = 0
        var reversed = false
        var endedDirections: [String] = []
        var lastFingerprint: String?
        var aimedStalls = 0
        var lastHit: LocateHit?
        var trace: [String] = []
        // The reply is due at 6s whether or not the search is done, and a
        // call still running then wedges the UI queue for every call behind it.
        // Each scan+drag costs ~0.7–1.5s (more on a hot phone), so stop when
        // the next one would not fit, and say how to continue.
        let started = nowMonotonic
        let timeBudget = 4.5
        var stepCost = 0.8
        var outOfTime = false
        func fitsAnotherStep() -> Bool {
            if nowMonotonic - started + stepCost <= timeBudget { return true }
            outOfTime = true
            return false
        }

        func opposite(_ d: String) -> String {
            switch d { case "up": return "down"; case "down": return "up"
                       case "left": return "right"; default: return "left" }
        }

        // A synthesized drag that rests on its end point before lifting, so
        // the content moves by the finger travel with no momentum.
        func drag(in area: CGRect, finger: String, travel: Double) {
            let horizontal = (finger == "left" || finger == "right")
            let span = horizontal ? area.width : area.height
            let t = min(travel, span * 0.8)
            let margin = (span - t) / 2
            let (fx, fy, tx, ty): (Double, Double, Double, Double)
            switch finger {
            case "down":  (fx, fy, tx, ty) = (area.midX, area.minY + margin, area.midX, area.minY + margin + t)
            case "left":  (fx, fy, tx, ty) = (area.maxX - margin, area.midY, area.maxX - margin - t, area.midY)
            case "right": (fx, fy, tx, ty) = (area.minX + margin, area.midY, area.minX + margin + t, area.midY)
            default:      (fx, fy, tx, ty) = (area.midX, area.maxY - margin, area.midX, area.maxY - margin - t)
            }
            // Fast drag + resting end point: no momentum (see pageScroll).
            _ = fastHandler.fastSwipe(fromX: fx, fromY: fy, toX: tx, toY: ty, duration: 0.3, hold: 0.25)
            usleep(100_000)
        }

        func dragArea(_ scan: LocateScan, _ hit: LocateHit?) -> CGRect {
            let band = CGRect(x: 0, y: scan.contentTop, width: size.width,
                              height: max(scan.contentBottom - scan.contentTop, 1))
            let area = (hit?.container ?? scan.scrollContainer ?? band).intersection(band)
            return area.isNull || area.height < 80 ? band : area
        }

        // The fingerprint is capped (50 children a node): a calendar's 60+ day
        // cells look the same after a drag that visibly moved them, which would
        // read as "the end" and reverse the search. A drag that changed the
        // screen moved, whatever the fingerprint says.
        var lastFrame: ScreenSettle.Frame?
        while true {
            let scanStart = nowMonotonic
            let frameNow = ScreenSettle.sample()
            let screenMoved: Bool = {
                guard let a = lastFrame, let b = frameNow else { return false }
                return ScreenSettle.diff(a, b) >= 0.02
            }()
            lastFrame = frameNow
            let scanned = scanCandidates(query: query, type: typeFilter, matchMode: matchMode, bundleId: bundleId)
            let scanCost = nowMonotonic - scanStart
            guard let scan = scanned else {
                // No bounded snapshot on this build/app — the old search still works.
                return steps == 0 ? legacyScrollToElement(cmd) : (nil, .serverError(
                    "scroll_to_element lost the accessibility snapshot after \(steps) scrolls. Call page_source to see where it stopped."))
            }
            let hit = scan.candidates.first
            lastHit = hit

            if let hit = hit, hit.inView {
                iCTRLUITests.logBuffer.append("🧭 scroll_to '\(query)' found after \(steps) [\(trace.joined(separator: " "))]")
                var out: [String: JSONValue] = [
                    "found": .bool(true),
                    "swipes": .int(steps),
                    "x": .double(hit.frame.midX), "y": .double(hit.frame.midY),
                    "center_x": .double(hit.frame.midX), "center_y": .double(hit.frame.midY),
                    "label": .string(hit.label),
                    "visibility": .string(hit.visibility),
                ]
                if let (_, idx) = liveElement(for: hit, in: q) {
                    let ref = makeRef(ElementRef(bundleId: bundleId, match: hit.match, elementType: typeFilter,
                                                 index: idx, createdAt: nowMonotonic))
                    out["ref"] = .string(ref)
                    out["hint"] = .string("Element is in view. Prefer tapping by ref: {\"method\":\"tap\",\"params\":{\"ref\":\"\(ref)\"}} — a ref re-resolves the live element and won't drift like a coordinate.")
                } else {
                    out["hint"] = .string("Element is in view but could not be re-resolved as a live element; tap its center by coordinate.")
                }
                return (out, nil)
            }

            if steps >= maxSteps { break }

            if let hit = hit {
                // Its position is known: drag by exactly the distance that
                // centres it in the content band.
                let area = dragArea(scan, hit)
                let offX = hit.frame.midX < 0 || hit.frame.midX > size.width
                let finger: String
                let travel: Double
                if offX {
                    // A sideways drag on a plain row is a swipe action (Delete,
                    // Archive), not a scroll — only aim sideways inside a real
                    // horizontal scroller.
                    guard hit.container != nil else {
                        return (nil, JSONRPCError(
                            code: -32602,
                            message: "'\(hit.label)' exists off to the side at (\(Int(hit.frame.midX)),\(Int(hit.frame.midY))) " +
                                "but not inside a scroll view, so dragging sideways could trigger a row's swipe action " +
                                "instead. It is on another page/tab — navigate there directly (page_source shows the controls).",
                            data: ["x": .double(hit.frame.midX), "y": .double(hit.frame.midY)]))
                    }
                    let dx = hit.frame.midX - size.width / 2
                    finger = dx > 0 ? "left" : "right"
                    travel = abs(dx)
                } else {
                    let dy = hit.frame.midY - (scan.contentTop + scan.contentBottom) / 2
                    finger = dy > 0 ? "up" : "down"
                    // Under ~20pt a drag reads as a tap to the scroll view.
                    travel = max(abs(dy), 40)
                }
                if let last = lastFingerprint, last == scan.fingerprint, !screenMoved {
                    aimedStalls += 1
                } else {
                    aimedStalls = 0
                }
                if aimedStalls >= 2 {
                    return (nil, JSONRPCError(
                        code: -32602,
                        message: "'\(hit.label)' exists at (\(Int(hit.frame.midX)),\(Int(hit.frame.midY))) but dragging " +
                            "toward it does not move the view — it belongs to a part of the UI that scrolling here " +
                            "can't reach (another page, tab, month or collapsed section). Navigate there directly " +
                            "instead; page_source shows the controls for it.",
                        data: ["x": .double(hit.frame.midX), "y": .double(hit.frame.midY)]))
                }
                lastFingerprint = scan.fingerprint
                guard fitsAnotherStep() else { break }
                trace.append("aim:\(finger)\(Int(travel))")
                let t0 = nowMonotonic
                drag(in: area, finger: finger, travel: travel)
                stepCost = (nowMonotonic - t0) + scanCost
                steps += 1
                continue
            }

            // Not in the tree at all — scroll blind and watch for the end.
            if let last = lastFingerprint, last == scan.fingerprint, !screenMoved {
                endedDirections.append(direction)
                if explicitDirection == nil, !reversed {
                    reversed = true
                    direction = opposite(direction)
                    trace.append("end→reverse")
                } else {
                    break
                }
            }
            lastFingerprint = scan.fingerprint
            guard fitsAnotherStep() else { break }
            let area = dragArea(scan, nil)
            let horizontal = (direction == "left" || direction == "right")
            trace.append("blind:\(direction)")
            let t0 = nowMonotonic
            drag(in: area, finger: direction, travel: (horizontal ? area.width : area.height) * 0.6)
            stepCost = (nowMonotonic - t0) + scanCost
            steps += 1
        }

        iCTRLUITests.logBuffer.append("🧭 scroll_to '\(query)' not found after \(steps) [\(trace.joined(separator: " "))]")
        let what = "'\(query)'" + (typeFilter.map { " of type '\($0)'" } ?? "")
        let message: String
        if outOfTime {
            let seenEnd = endedDirections.first.map { " (reached the end scrolling \($0) and turned back)" } ?? ""
            message = "Stopped after \(steps) scrolls (\(String(format: "%.1f", nowMonotonic - started))s) to stay inside " +
                "the call time limit; \(what) not seen yet\(seenEnd). Call scroll_to_element again — it continues " +
                "from where the view is now" +
                (lastHit.map { ". It is in the tree at (\(Int($0.frame.midX)),\(Int($0.frame.midY))), so it is reachable" } ?? "") + "."
        } else if let hit = lastHit {
            message = "'\(hit.label)' is in the view but still \(hit.visibility) at " +
                "(\(Int(hit.frame.midX)),\(Int(hit.frame.midY))) after \(steps) scrolls toward it. " +
                "Raise distance, or call page_source to see what is in the way."
        } else if endedDirections.count >= 2 {
            // Both ends seen: this is a statement about the view, not a search
            // that gave up. Said plainly, it sends the caller to question the
            // premise (wrong date, wrong tab, data never saved) instead of
            // scrolling and screenshotting the same view for ten more minutes.
            message = "\(what) is NOT anywhere in this scrollable view — scrolled to both ends (\(steps) scrolls) " +
                "without it appearing in the accessibility tree. It is not on this screen at all: check you are on " +
                "the right page/date/tab, or that the item actually exists."
        } else if endedDirections.count == 1 {
            message = "No match for \(what): reached the end scrolling \(endedDirections[0]) after \(steps) scrolls. " +
                "Try direction:\"\(opposite(endedDirections[0]))\"."
        } else {
            message = "No match for \(what) after \(steps) scrolls \(direction) (budget exhausted, end not reached). " +
                "Raise distance (the scroll budget) or check the label in page_source" +
                (matchMode == "contains" ? "." : ", or use match:\"contains\".")
        }
        if foregroundIsWebViewHost() {
            return (nil, JSONRPCError(code: -32602, message: message + Self.webViewAdvice, data: nil))
        }
        return (nil, JSONRPCError(code: -32602, message: message, data: nil))
    }

    /// The original swipe-and-look search, kept for when no bounded snapshot
    /// is available.
    private func legacyScrollToElement(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        guard let query = cmd.elementId, !query.isEmpty else {
            return (nil, JSONRPCError(
                code: -32602,
                message: "scroll_to_element requires 'element_id' (the label, value, or accessibility id to scroll to). " +
                    "Next: call page_source to read the available labels, then retry as " +
                    "scroll_to_element{element_id:\"<label>\", match:\"contains\"}. " +
                    "Full parameter list: GET /schema.",
                data: nil))
        }

        let bundleId = cmd.bundleId ?? resolveForegroundBundleId()

        let direction = (cmd.direction ?? "up").lowercased()
        // Smaller step (40% of the screen) so we don't scroll PAST a short target
        // between checks. More attempts to compensate for the shorter travel.
        let maxSwipes = Int(cmd.distance ?? 12)
        // Match mode: "exact" (default, precise) or "contains" (loose).
        let matchMode = (cmd.matchMode ?? "exact").lowercased()
        let typeFilter = cmd.elementType
        let size = pointSize
        let cx = size.width / 2, cy = size.height / 2
        let step = (direction == "left" || direction == "right" ? size.width : size.height) * 0.4

        // Reuse the shared matcher (exact label → id → contains, first hittable).
        func buildMatch() -> (XCUIElement, ElementRef.Match, Int)? {
            return locateElement(query: query, type: typeFilter, bundleId: bundleId, matchMode: matchMode)
        }

        // Lightweight signature of what's on screen, to detect "reached the end"
        // (content stopped moving) and stop early instead of swiping in place.
        func screenSignature() -> String {
            let bid = bundleId ?? resolveForegroundBundleId()
            let target: XCUIApplication = bid.map { XCUIApplication(bundleIdentifier: $0) } ?? app
            // First+last visible static-text labels + count is enough to tell motion.
            let texts = target.staticTexts
            let n = min(texts.count, 40)
            guard n > 0 else { return "empty" }
            var parts: [String] = ["n=\(texts.count)"]
            parts.append(texts.element(boundBy: 0).label)
            parts.append(texts.element(boundBy: n - 1).label)
            return parts.joined(separator: "|")
        }

        func result(_ el: XCUIElement, match: ElementRef.Match, index: Int, swipes: Int) -> ([String: JSONValue]?, JSONRPCError?) {
            let f = el.frame
            let ref = makeRef(ElementRef(bundleId: bundleId, match: match, elementType: typeFilter, index: index, createdAt: nowMonotonic))
            return ([
                "found": .bool(true),
                "swipes": .int(swipes),
                "ref": .string(ref),
                "x": .double(f.midX),
                "y": .double(f.midY),
                "center_x": .double(f.midX),
                "center_y": .double(f.midY),
                "label": .string(el.label),
                "hint": .string("Element is on screen. Prefer tapping by ref: {\"method\":\"tap\",\"params\":{\"ref\":\"\(ref)\"}} — a ref re-resolves the live element and won't drift like a coordinate."),
            ], nil)
        }

        if let (el, m, idx) = buildMatch() { return result(el, match: m, index: idx, swipes: 0) }

        var lastSig = screenSignature()
        var actualSwipes = 0
        var reachedEnd = false

        for i in 1...max(1, maxSwipes) {
            let (ex, ey): (Double, Double)
            switch direction {
            case "down":  (ex, ey) = (cx, cy + step)
            case "left":  (ex, ey) = (cx - step, cy)
            case "right": (ex, ey) = (cx + step, cy)
            default:      (ex, ey) = (cx, cy - step)
            }
            _ = fastHandler.fastSwipe(fromX: cx, fromY: cy,
                                      toX: min(max(ex, 0), size.width),
                                      toY: min(max(ey, 0), size.height), duration: 0.15)
            usleep(300_000)
            actualSwipes = i

            if let (el, m, idx) = buildMatch() { return result(el, match: m, index: idx, swipes: i) }

            // Stop early if the screen didn't change — we've hit the end/edge.
            let sig = screenSignature()
            if sig == lastSig {
                reachedEnd = true
                break
            }
            lastSig = sig
        }

        let scrollBase = "No \(matchMode == "contains" ? "" : "exact ")match for '\(query)'" +
            (typeFilter.map { " of type '\($0)'" } ?? "") +
            " after \(actualSwipes) swipes \(direction)" +
            (reachedEnd ? " (reached the end of scrollable content)" : "")
        if foregroundIsWebViewHost() {
            return (nil, JSONRPCError(code: -32602, message: scrollBase + "." + Self.webViewAdvice, data: nil))
        }
        return (nil, JSONRPCError(
            code: -32602,
            message: scrollBase +
                ". Tips: the label may contain hidden/formatting characters — copy it exactly from page_source, or use match:'contains'. Also try the opposite direction, or add element_type.",
            data: nil
        ))
    }

    // MARK: - Elements

    /// Locate an element (without scrolling) in the foreground app by exact label,
    /// then accessibility id, then (if match=contains) substring. Returns the first
    /// hittable match + its index, so both find_element and tap-by-ref agree.

    /// Seconds the last bounded walk of each app took — how slow its
    /// accessibility server is answering right now.
    private var treeCost: [String: Double] = [:] { didSet { treeCostAt = nowMonotonic } }
    private var treeCostAt: TimeInterval = 0
    /// Apps where a whole-app walk (each live exists/frame probe) was seen to
    /// be slow. treeCost is the last bounded read and can't tell: a bounded
    /// read can be fast while each live probe walks for seconds, so a lookup
    /// that trusted treeCost would confirm its hit with several slow walks.
    private var liveWalkSlow: Set<String> = []
    /// The Picture-in-Picture window's frame, if one is on screen. Read from a
    /// two-level SpringBoard snapshot (the PiP window hangs off its
    /// Application node), cached briefly: actions come in bursts.
    private var pipCache: (frame: CGRect?, at: TimeInterval)?
    private func pipWindowFrame() -> CGRect? {
        if let c = pipCache, nowMonotonic - c.at < 2 { return c.frame }
        var found: CGRect?
        let t = nowMonotonic
        if let root = ForegroundApp.boundedSnapshot(forBundleID: "com.apple.springboard", maxDepth: 2, maxChildren: 50) {
            var n = 0
            var tr: ObjCBool = false
            let body = ForegroundApp.renderBoundedSnapshot(root, maxDepth: 2, maxElements: 200,
                                                           nodesWritten: &n, truncated: &tr) ?? ""
            for line in body.split(separator: "\n") where line.contains("id: 'PIP-") {
                if let f = Self.frameOf(line), f[2] > 0, f[3] > 0 {
                    found = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
                    break
                }
            }
        }
        if found != nil || nowMonotonic - t > 0.3 {
            iCTRLUITests.logBuffer.append(String(format: "🖼 PiP %@ (%.0fms)", found.map { "\($0)" } ?? "none", (nowMonotonic - t) * 1000))
        }
        pipCache = (found, nowMonotonic)
        return found
    }

    /// Launched in the last 10s: the app is still starting, and every extra
    /// walk of it competes with that.
    private func justLaunched(_ bid: String) -> Bool {
        launchedAt[bid].map { nowMonotonic - $0 < 10 } == true
    }
    /// Above this, follow-up walks (live re-resolve, hit probes) cost more
    /// than they are worth; callers get coordinates instead of refs.
    private static let slowTreeSeconds = 1.5
    /// Only a recent measurement counts: a tree is slow while a heavy page
    /// is up, and taps should probe again once the app has moved on.
    private func isSlowTree(_ bid: String) -> Bool {
        (treeCost[bid] ?? 0) > Self.slowTreeSeconds && nowMonotonic - treeCostAt < 20
    }
    /// Set when locateElement found a match on a slow tree but skipped
    /// making it live: callers act on its frame.
    private var slowTreeHit: LocateHit?
    /// Why the last locate returned coordinates only, when not a slow tree.
    private var coordsOnlyNote: String?
    private var hitSkipped = false
    private func slowTreeNote(_ bid: String?) -> String {
        let ms = bid.flatMap { treeCost[$0] }.map { Int($0 * 1000) } ?? 0
        return "This app's accessibility tree is very slow right now (\(ms)ms per read), so no ref was made — " +
            "re-resolving it would take as long again. Tap the center by coordinate."
    }

    private func locateElement(query: String, type: String?, bundleId: String?, matchMode: String)
        -> (XCUIElement, ElementRef.Match, Int)? {
        // Cleared per call: a stale error from an earlier lookup must never be
        // reported against this one — and stale geometry from an earlier screen
        // must never aim this call's tap.
        lastLocateError = nil
        lastLocateSnapFrame = nil
        lastLocateSnapLabel = nil
        lastLocateScan = nil
        let bid = bundleId ?? resolveForegroundBundleId()
        let target: XCUIApplication = bid.map { XCUIApplication(bundleIdentifier: $0) } ?? app
        let q = elementQuery(in: target, type: type)

        // Phased timing: log how long each match stage takes so slow lookups can be
        // attributed (which stage, and snapshot node count for the fallback).
        let t0 = nowMonotonic
        var phases: [String] = []
        func lap(_ name: String, from: TimeInterval) {
            phases.append("\(name)=\(Int((nowMonotonic - from) * 1000))ms")
        }
        func done(_ hit: String) {
            iCTRLUITests.logBuffer.append("🔎 locate '\(query)' \(hit) [\(phases.joined(separator: " "))] total=\(Int((nowMonotonic - t0) * 1000))ms")
            // Past the bounded walks, a slow lookup is whole-app walks: remember
            // it, so the next lookup here stays bounded.
            if let bid = bid, nowMonotonic - t0 > 2.0 { liveWalkSlow.insert(bid) }
        }

        // Before ANY tree query: a few-ms state check. Every query below is
        // aimed at `target`, and against a backgrounded app none of them fails
        // fast — the live query timed out, was abandoned still running, and
        // spun XCTest at 100% CPU for 48s until iOS killed the runner
        // (cpu_resource_fatal, iOS 16). This check used to run only at the end.
        // Known not to answer moments ago: every route below waits out the
        // AX timeout again (10s+, past the call limit).
        if let bid = bid, (treeCost[bid] ?? 0) >= 99, nowMonotonic - treeCostAt < 20 {
            lastLocateError = JSONRPCError(code: -32000, message:
                "\(bid)'s accessibility isn't answering right now, so '\(query)' can't be looked up. Read the screen " +
                "with screen_text and tap by coordinate; try find_element again in ~20s.", data: nil)
            done("✗ax-unresponsive(known)")
            return nil
        }
        if let err = Self.snapshotPrecheck(bundleId: bid, action: "find '\(query)'",
                                           retryWith: "find_element", strict: true) {
            phases.append("precheck=refused")
            done("✗\(err.message.contains("background") ? "backgrounded" : "not-running")")
            lastLocateError = err
            return nil
        }

        // Every .safeExists / .safeIsHittable below is a round-trip that XCTest
        // answers by walking the app's hierarchy, so each scales with tree size. On a
        // long-scrolled feed a single probe ran into seconds, and the old loop of
        // up to 10 of them turned one find_element into 69.8s — during which the
        // serial UI queue is blocked and every later request piles up behind it.
        // Bound the whole scan instead of trusting any single call to be quick.
        let liveQueryDeadline = nowMonotonic + Self.liveQueryBudget
        func firstHittable(_ query: XCUIElementQuery) -> (XCUIElement, Int)? {
            let first = query.element(boundBy: 0)
            guard first.safeExists else { return nil }
            if first.safeIsHittable { return (first, 0) }
            // Probe siblings only while budget remains; 3 is plenty in practice
            // (the wanted element is almost always the first or second match).
            for i in 1..<3 {
                if nowMonotonic >= liveQueryDeadline {
                    phases.append("live-budget-hit")
                    break
                }
                let el = query.element(boundBy: i)
                if !el.safeExists { break }
                if el.safeIsHittable { return (el, i) }
            }
            return (first, 0)   // exists but not hittable — caller decides
        }

        // The live-query "fast path" is only fast on a small tree. XCUIElementQuery
        // evaluates its predicate node-by-node across the IPC boundary while the
        // app walks its whole hierarchy, so it scales with tree size just like a
        // snapshot does — measured at 5245ms to find WeChat's search field, and
        // 69865ms on a long-scrolled X timeline. One snapshot of the same WeChat
        // screen costs ~4100ms and answers exact/id/contains together, so it is
        // tried first and the live query is kept only as the fallback.
        // Fast path: the SAME bounded fetch page_source uses. find_element was
        // calling safeSnapshot — the unbounded one — which is exactly the cost
        // page_source was changed to avoid, and is why looking up one element
        // could be slower than dumping the entire tree.
        //
        // The walk runs in Obj-C: bridging a bounded snapshot to the
        // XCUIElementSnapshot protocol reads every frame as {{0,0},{0,0}} and
        // stops after one level of children, so a Swift walk would silently
        // search a tree of 16 empty nodes and report "not found".
        //
        // Two passes, like page_source: first with the small child cap that
        // keeps page_source under a second, then the full one. A wide list
        // makes the full walk slow (a long timeline: about a thousand nodes,
        // seconds against under a second capped), and what a caller looks for
        // is almost always on screen, which the capped walk already covers. Only
        // an in-view hit from the capped pass is trusted: anything else may be
        // one of the children it cut off, so the full walk decides.
        var s = nowMonotonic
        let boundedStart = s
        slowTreeHit = nil
        coordsOnlyNote = nil
        var fullScan: LocateScan?
        if let bid = bid {
            if let quick = scanCandidates(query: query, type: type, matchMode: matchMode, bundleId: bid,
                                          maxChildren: Self.childrenLadder[0]) {
                phases.append("bounded50=\(Int((nowMonotonic - s) * 1000))ms/\(quick.visited)nodes/\(quick.candidates.count)hits")
                if quick.candidates.first?.inView == true { fullScan = quick }
            }
            if fullScan == nil {
                s = nowMonotonic
                fullScan = scanCandidates(query: query, type: type, matchMode: matchMode, bundleId: bid)
                if let scan = fullScan {
                    phases.append("bounded=\(Int((nowMonotonic - s) * 1000))ms/\(scan.visited)nodes/\(scan.candidates.count)hits")
                }
            }
        }
        if let bid = bid {
            treeCost[bid] = nowMonotonic - boundedStart
        }
        if let bid = bid, let scan = fullScan {
            if let best = scan.candidates.first {
                // On a tree this slow, re-resolving the hit as a live element
                // is several more full walks (XCTest snapshots the whole app
                // for each exists/hittable probe): on a large results list each
                // walk can take many seconds and one find_element could run for
                // minutes, wedging every call behind it. Hand back the snapshot's frame instead.
                if isSlowTree(bid) || best.byValue {
                    lastLocateScan = scan
                    lastLocateSnapFrame = best.frame
                    lastLocateSnapLabel = best.label.isEmpty ? best.value : best.label
                    slowTreeHit = best
                    coordsOnlyNote = best.byValue && !isSlowTree(bid)
                        ? "Matched by its value ('\(best.value)'): it has no label or identifier, so no ref can be made. Tap the center by coordinate."
                        : nil
                    done("→slow-tree-coords/\(Int((treeCost[bid] ?? 0) * 1000))ms")
                    return nil
                }
                // On a costly tree, don't confirm the hit with live probes
                // (each a whole-app walk, together most of the lookup). The
                // walk's ordinal mirrors the live query; tap re-finds it the
                // same capped way.
                if (treeCost[bid] ?? 0) >= 0.5 { liveWalkSlow.insert(bid) }
                // Nor on an app that is still starting: there a single walk
                // can hang well past the call limit — before any check
                // between probes could stop it.
                let costly = liveWalkSlow.contains(bid) || nowMonotonic - (launchedAt[bid] ?? -100) < 15
                let probeAt = nowMonotonic
                let resolved = costly ? (q.matching(best.byLabel
                        ? NSPredicate(format: "label == %@", best.label)
                        : NSPredicate(format: "identifier == %@", best.identifier)).element(boundBy: best.ordinal), best.ordinal)
                    : liveElement(for: best, in: q)
                if !costly, nowMonotonic - probeAt > 1.0 { liveWalkSlow.insert(bid) }
                if let (live, idx) = resolved {
                    lastLocateScan = scan
                    lastLocateSnapFrame = best.frame
                    lastLocateSnapLabel = best.label
                    confirmOpened(bid, name: nil)
                    done("→bounded-\(best.how)/\(best.visibility)")
                    return (live, best.match, idx)
                }
                phases.append("bounded-reresolve=miss")
            }
        }

        // The bounded fetch itself failed after a long wait: the app's
        // accessibility isn't answering. The unbounded snapshot and the live
        // query below would each wait out long timeouts (a long-scrolled feed
        // can take tens of seconds), wedging every call behind it.
        if let bid = bid, fullScan == nil, nowMonotonic - boundedStart > 2.0 {
            treeCost[bid] = 99
            lastLocateError = JSONRPCError(code: -32000, message:
                "\(bid)'s accessibility isn't answering right now (the tree read failed after " +
                "\(Int(nowMonotonic - boundedStart))s), so '\(query)' couldn't be looked up. Read the screen with " +
                "screen_text and tap by coordinate; find_element works again once the app answers.", data: nil)
            done("✗ax-unresponsive")
            return nil
        }
        // Nothing found by the bounded walks on a slow tree: the unbounded
        // walk and the live query below would cost far more and, on a tree
        // the bounded walk already covered, find nothing new.
        // Nor where whole-app walks were slow before: a fast bounded miss
        // there would fall through to a very long snapshot and live query.
        // Nor when the bounded walk saw the whole tree: with fewer nodes than
        // one child cap, nothing was cut. An app still starting has few
        // nodes; the unbounded snapshot then hangs on an app too busy to
        // answer, and could find nothing new.
        if let bid = bid, let scan = fullScan,
           isSlowTree(bid) || liveWalkSlow.contains(bid) || nowMonotonic - boundedStart > 1.0
            || scan.visited < Self.childrenLadder[0] {
            done("✗no-match/slow-tree")
            return nil
        }
        s = nowMonotonic
        var snapshotAlreadyTried = false
        if !Self.preferLiveQueryFirst,
           Self.snapshotPrecheck(bundleId: bid, action: "find '\(query)'",
                                 retryWith: "find_element") == nil {
            snapshotAlreadyTried = true
            if let hit = locateViaSnapshot(query: query, matchMode: matchMode, target: target,
                                           q: q, appendPhase: { phases.append($0) }, lap: lap) {
                done("\(hit.2)")
                return (hit.0, hit.1, hit.3)
            }
            // A completed snapshot walk is authoritative: it saw every node and
            // the label was not among them, so the live query can only reach the
            // same verdict — at the cost of a full second traversal. Measured on
            // a scrolled X timeline: the snapshot answered in 4.6s, then the
            // redundant live query ran another 7.1s before hitting its budget.
            // Only skip it when the walk actually happened; if the snapshot
            // itself failed we learned nothing and still owe the live query.
            if !phases.contains("snapshot=failed") {
                done("✗no-match")
                return nil
            }
        }

        // Run the live query under a hard wall-clock cap. A single .safeExists on a
        // huge tree has been seen to take tens of seconds and cannot be
        // cancelled, so the work continues in the background — but we stop
        // waiting on it and fall through, which keeps the RPC inside its own
        // 6s watchdog instead of blocking the queue for a minute.
        // Boxed so the abandoned worker can keep writing safely after we stop
        // waiting: reading `liveHit` only once runWithTimeout reports success
        // means the two never touch it at the same time.
        final class HitBox { var value: (XCUIElement, Int)? }
        let box = HitBox()
        let liveDone = runWithTimeout(seconds: Self.liveQueryBudget, label: "live-query") {
            box.value = firstHittable(q.matching(NSPredicate(format: "label == %@", query)))
        }
        lap("exact", from: s)
        if !liveDone { phases.append("exact=timeout") }
        if liveDone, let (el, idx) = box.value {
            let (best, bestIdx) = elevateToButton(match: el, matchIdx: idx, in: target, phases: &phases)
            done("→exact\(bestIdx == idx ? "" : "→button")")
            return (best, .exactLabel(query), bestIdx)
        }

        // Re-checked here: the app can leave the screen during the lookups
        // above, and the snapshot path below costs ~16s against a backgrounded
        // app. (The live query does NOT fail fast either — see the check at the
        // top of this function.)
        if let err = Self.snapshotPrecheck(bundleId: bid, action: "find '\(query)'",
                                           retryWith: "find_element") {
            phases.append("precheck=refused")
            done("✗\(err.message.contains("background") ? "backgrounded" : "not-running")")
            lastLocateError = err
            return nil
        }

        // Only when the snapshot-first attempt above didn't already run. A miss
        // used to capture the tree twice (logged as snapshot=…ms … snapshot=…ms),
        // paying the most expensive step of the lookup a second time for nothing.
        if !snapshotAlreadyTried,
           let hit = locateViaSnapshot(query: query, matchMode: matchMode, target: target,
                                       q: q, appendPhase: { phases.append($0) }, lap: lap) {
            done("\(hit.2)")
            return (hit.0, hit.1, hit.3)
        }
        done("✗no-match")
        return nil
    }

    /// Whether to try the live XCUIElementQuery before the snapshot walk.
    ///
    /// Snapshot-first is the faster order on every screen measured (a live query
    /// took 5245ms to find WeChat's search field, 69865ms on a scrolled X
    /// timeline; one snapshot of the same WeChat screen is ~4100ms and answers
    /// exact/id/contains together). Promoting it once aborted the runner —
    /// snapshot() raises an NSException that `try?` cannot catch — so every call
    /// now goes through ForegroundApp.safeSnapshot, which catches it in Obj-C.
    /// Wall-clock cap on the live XCUIElementQuery stage of a lookup.
    ///
    /// 2.5s leaves room for the snapshot fallback to still finish inside the 6s
    /// RPC watchdog. Without a cap this stage measured 69.8s on a scrolled X
    /// timeline, blocking the serial UI queue for every request behind it.
    static let liveQueryBudget: TimeInterval = 2.5

    /// Flip to true to fall back to the old ordering without a code change.
    ///
    /// The two aborts this caused were never about XCTest: the crash report put
    /// swift_beginAccess -> fatalError directly under `lap`, i.e. `phases` was
    /// captured by that closure AND passed inout to the same call, so Swift
    /// trapped on overlapping exclusive access. Fixed by passing an appendPhase
    /// closure instead of the array.
    static let preferLiveQueryFirst = false

    /// Finds `query` by walking ONE snapshot, answering exact-label, identifier
    /// and substring matching in a single capture.
    ///
    /// A snapshot carries label, identifier, value, frame and elementType, which
    /// is everything these strategies need, so one capture answers all of them
    /// and the walk itself is ~20ms — versus a live query per strategy, each
    /// paying its own accessibility round-trip.
    /// `phases` is NOT taken inout: the caller's `lap` closure already captures
    /// and mutates that same array, so passing it inout as well opens two
    /// overlapping exclusive accesses and Swift traps at runtime
    /// (swift_beginAccess -> fatalError), killing the runner. Everything that
    /// needs to record a phase goes through `lap` / `appendPhase`.
    private func locateViaSnapshot(query: String, matchMode: String, target: XCUIApplication,
                                   q: XCUIElementQuery,
                                   appendPhase: (String) -> Void,
                                   lap: (String, TimeInterval) -> Void)
        -> (XCUIElement, ElementRef.Match, String, Int)? {
        let wantExact = Self.normalizeLabel(query)
        var s = nowMonotonic
        // Via the Obj-C wrapper: snapshot() throws an NSException that `try?`
        // cannot catch, which aborted the runner when this became the primary
        // path (SIGABRT on the first call, no phases logged).
        guard let root = ForegroundApp.safeSnapshot(ofElement: target) as? XCUIElementSnapshot else {
            lap("snapshot", s)
            appendPhase("snapshot=failed")   // distinguishes "couldn't look" from "looked, absent"
            return nil
        }
        lap("snapshot", s)

        // Depth-first walk, collecting the best candidate per strategy in one
        // pass. Ordering is preserved from the old sequential version: an exact
        // label beats an identifier, which beats a substring.
        s = nowMonotonic
        var exactSnap: XCUIElementSnapshot?
        var idSnap: XCUIElementSnapshot?
        var containsSnap: XCUIElementSnapshot?
        var stack: [XCUIElementSnapshot] = [root]
        var visited = 0
        var allNodes: [XCUIElementSnapshot] = []
        while let node = stack.popLast(), visited < 4000 {
            visited += 1
            allNodes.append(node)
            if exactSnap == nil, Self.normalizeLabel(node.label) == wantExact {
                exactSnap = node
                break   // exact wins immediately
            }
            if idSnap == nil, node.identifier == query {
                idSnap = node
            }
            if matchMode == "contains", containsSnap == nil {
                let hay = Self.normalizeLabel(node.label + " " + ((node.value as? String) ?? ""))
                if hay.localizedCaseInsensitiveContains(wantExact) { containsSnap = node }
            }
            stack.append(contentsOf: node.children)
        }
        appendPhase("walk=\(Int((nowMonotonic - s) * 1000))ms/\(visited)nodes")

        // Re-resolve the winning snapshot to a live XCUIElement. Elevation now
        // reuses `allNodes` instead of re-enumerating every button and cell.
        let ranked: [(XCUIElementSnapshot, ElementRef.Match, String)] = [
            exactSnap.map    { ($0, ElementRef.Match.exactLabel($0.label), "→snapshot-exact") },
            idSnap.map       { ($0, ElementRef.Match.identifier(query),    "→snapshot-id") },
            containsSnap.map { ($0, ElementRef.Match.exactLabel($0.label), "→snapshot-contains") },
        ].compactMap { $0 }

        s = nowMonotonic
        for (snap, match, hit) in ranked {
            guard let (live, idx) = resolveSnapshot(snap, match: match, in: q) else { continue }
            lap("resolve", s)
            // Local array, then hand the results to appendPhase: elevateToButton
            // needs an inout, and the caller's copy is already owned by `lap`.
            var elevatePhases: [String] = []
            let (best, bestIdx, finalSnap) = elevateToButton(match: live, matchIdx: idx, snapshot: snap,
                                                             allNodes: allNodes, phases: &elevatePhases)
            elevatePhases.forEach(appendPhase)
            // Geometry of the FINAL node (post-elevation), free to read — the
            // snapshot is already materialised. findAndTap uses this to skip
            // re-buying frame/label from the live element.
            lastLocateSnapFrame = finalSnap.frame
            lastLocateSnapLabel = finalSnap.label
            return (best, match, "\(hit)\(bestIdx == idx ? "" : "→button")", bestIdx)
        }
        lap("resolve", s)
        return nil
    }

    /// Turn a matched snapshot node back into a live, tappable XCUIElement.
    private func resolveSnapshot(_ snap: XCUIElementSnapshot, match: ElementRef.Match,
                                 in q: XCUIElementQuery) -> (XCUIElement, Int)? {
        // Prefer the identifier when that's what matched — it's more selective
        // than a label, which several nodes may share.
        let re: XCUIElement
        if case .identifier(let ident) = match {
            re = q.matching(identifier: ident).element(boundBy: 0)
        } else {
            re = q.matching(NSPredicate(format: "label == %@", snap.label)).element(boundBy: 0)
        }
        return re.safeExists ? (re, 0) : nil
    }

    /// When a label/identifier match landed on a non-interactive element
    /// (staticText, image, other), SwiftUI content often wraps it in a
    /// Button ancestor whose frame contains the leaf's frame. XCUIElement.tap
    /// on the leaf hits its pixel position but doesn't fire the Button's
    /// handler — same failure mode we've been chasing. Search the app's
    /// Button elements for the TIGHTEST-fitting ancestor (smallest frame
    /// area that still contains the match's centre point). If we find one
    /// AND it's not the match itself, prefer it.
    ///
    /// This is best-effort: if there are no covering buttons, or the match
    /// IS a button, return the input unchanged.
    private func elevateToButton(match: XCUIElement, matchIdx: Int,
                                 in target: XCUIApplication,
                                 phases: inout [String]) -> (XCUIElement, Int) {
        let t0 = nowMonotonic
        guard !Self.isIntrinsicallyTappable(match.elementType) else {
            phases.append("elevate=skip(\(match.elementType.rawValue))")
            return (match, matchIdx)
        }
        let matchFrame = match.frame
        // Empty-frame elements can't be usefully compared for containment.
        if matchFrame.width < 1 || matchFrame.height < 1 { return (match, matchIdx) }
        let centre = CGPoint(x: matchFrame.midX, y: matchFrame.midY)

        // Consider both buttons AND cells as elevation targets. SwiftUI
        // `List(selection:)` rows are exposed as .cell, not .button; a
        // staticText leaf inside such a row needs to be elevated to the
        // enclosing cell for XCUIElement.tap to hit the selection region.
        var candidates: [XCUIElement] = []
        candidates.append(contentsOf: target.buttons.allElementsBoundByAccessibilityElement)
        candidates.append(contentsOf: target.cells.allElementsBoundByAccessibilityElement)
        var best: (XCUIElement, CGRect)?
        for c in candidates {
            let f = c.frame
            if f.width < 1 || f.height < 1 { continue }
            if !f.contains(centre) { continue }
            // Prefer the tightest fit: smallest area that still contains the match.
            let area = f.width * f.height
            if let (_, current) = best, area >= current.width * current.height { continue }
            best = (c, f)
        }
        phases.append("elevate=\(Int((nowMonotonic - t0) * 1000))ms/\(candidates.count)cands")
        if let (bestEl, _) = best, bestEl.safeIsHittable {
            return (bestEl, matchIdx)
        }
        return (match, matchIdx)
    }

    /// Snapshot-based elevation: same tightest-containing-ancestor rule as the
    /// live variant, but the candidates come from the tree we already walked.
    ///
    /// The live version calls `allElementsBoundByAccessibilityElement` on both
    /// `buttons` and `cells` and then reads `.frame` on every result — two full
    /// enumerations plus a round-trip per candidate, paid on the SUCCESS path. The
    /// snapshot already carries frame and elementType for every node, so the same
    /// decision costs a pass over an in-memory array.
    /// Also returns the snapshot of the node the caller should treat as FINAL —
    /// the elevated ancestor's when elevation succeeded, the original match's
    /// otherwise. Callers that reuse snapshot geometry must take it from here:
    /// after elevation the tap target is the Button/Cell, and using the inner
    /// match's frame would aim at the row instead of its control.
    private func elevateToButton(match: XCUIElement, matchIdx: Int,
                                 snapshot snap: XCUIElementSnapshot,
                                 allNodes: [XCUIElementSnapshot],
                                 phases: inout [String]) -> (XCUIElement, Int, XCUIElementSnapshot) {
        let t0 = nowMonotonic
        guard !Self.isIntrinsicallyTappable(snap.elementType) else {
            phases.append("elevate=skip(\(snap.elementType.rawValue))")
            return (match, matchIdx, snap)
        }
        let matchFrame = snap.frame
        if matchFrame.width < 1 || matchFrame.height < 1 { return (match, matchIdx, snap) }
        let centre = CGPoint(x: matchFrame.midX, y: matchFrame.midY)

        var best: XCUIElementSnapshot?
        var bestArea = CGFloat.greatestFiniteMagnitude
        var considered = 0
        for node in allNodes {
            switch node.elementType {
            case .button, .cell: break
            default: continue
            }
            considered += 1
            let f = node.frame
            if f.width < 1 || f.height < 1 { continue }
            if !f.contains(centre) { continue }
            let area = f.width * f.height
            if area >= bestArea { continue }
            best = node
            bestArea = area
        }
        phases.append("elevate=\(Int((nowMonotonic - t0) * 1000))ms/\(considered)cands")

        // Re-resolve the chosen ancestor to a live element. Falling back to the
        // original match keeps this best-effort: a failed elevation must never
        // turn a found element into a miss.
        guard let bestSnap = best else { return (match, matchIdx, snap) }
        let query = bestSnap.elementType == .cell ? app.cells : app.buttons
        let live = bestSnap.identifier.isEmpty
            ? query.matching(NSPredicate(format: "label == %@", bestSnap.label)).element(boundBy: 0)
            : query.matching(identifier: bestSnap.identifier).element(boundBy: 0)
        if live.safeExists, live.safeIsHittable { return (live, matchIdx, bestSnap) }
        return (match, matchIdx, snap)
    }

    /// Element kinds that already dispatch their own handler on tap, so a
    /// label match landing on one needs no elevation.
    private static func isIntrinsicallyTappable(_ type: XCUIElement.ElementType) -> Bool {
        switch type {
        case .button, .cell, .switch, .toggle, .radioButton, .checkBox,
             .menuButton, .menuItem, .key, .link, .searchField, .textField, .textView:
            return true
        default:
            return false
        }
    }

    /// Strip invisible formatting/bidi control characters so labels compare cleanly.
    private static func normalizeLabel(_ s: String) -> String {
        let stripped = s.unicodeScalars.filter { scalar in
            // Drop format chars (Cf) like U+2066–2069 (bidi isolates), U+200E/F, etc.
            if scalar.properties.generalCategory == .format { return false }
            return true
        }
        return String(String.UnicodeScalarView(stripped)).trimmingCharacters(in: .whitespaces)
    }

    /// OCR the screen and return text boxes in the SAME shape find_element uses.
    ///
    /// Exists for one failure mode the accessibility path cannot recover from: a
    /// long recycling list whose on-screen rows never make it into the tree. On a
    /// scrolled WeChat chat list every route — default, max_children up to 1000,
    /// even a saturated container — returned ZERO on-screen cells, because the
    /// element budget is spent on offscreen rows before the visible ones are
    /// reached. Screenshots do not go through the accessibility channel at all,
    /// so they still work when that channel gives nothing useful.
    ///
    /// Deliberately mirrors find_element's keys (x/y/width/height/center_x/
    /// center_y/label/element_type) so a caller can feed a hit straight into
    /// tap{x,y} without a second code path.
    ///
    /// What it CANNOT give you: `ref` (so no scroll/animation-stable handle),
    /// `identifier`, or the real element type — everything here is typed
    /// "OCRText". It also only sees rendered text: icon-only buttons and image
    /// content are invisible to it, which is exactly where accessibility labels
    /// are most valuable. Treat it as a fallback, not a replacement.
    /// Convert Vision results into the shared item shape.
    ///
    /// Vision's box is normalised with the ORIGIN AT BOTTOM-LEFT while iOS points
    /// are top-left, so y is flipped here. Getting that wrong is quietly awful:
    /// every coordinate still looks plausible, but taps land mirrored about the
    /// middle of the screen.
    private func ocrItems(from request: VNRecognizeTextRequest, minConfidence: Float) -> [JSONValue] {
        let frame = pointSize
        var items: [JSONValue] = []
        for obs in (request.results ?? []) {
            guard let top = obs.topCandidates(1).first, top.confidence >= minConfidence else { continue }
            let b = obs.boundingBox
            let x = b.minX * frame.width
            let w = b.width * frame.width
            let h = b.height * frame.height
            let y = (1 - b.maxY) * frame.height
            items.append(.object([
                "label": .string(top.string),
                "confidence": .double(Double(top.confidence)),
                "x": .double(x.rounded()), "y": .double(y.rounded()),
                "width": .double(w.rounded()), "height": .double(h.rounded()),
                "center_x": .double((x + w / 2).rounded()),
                "center_y": .double((y + h / 2).rounded()),
                "element_type": .string("OCRText"),
                "source": .string("ocr"),
                "is_text_input": .bool(false), "exists": .bool(true),
            ]))
        }
        return items
    }

    /// Run OCR and return the items plus timings. Shared by `screen_text` and by
    /// page_source's automatic fallback, so both produce identical item shapes.
    private func runOCR(query: String?, fast: Bool, minConfidence: Float)
        -> (items: [JSONValue], shotMs: Double, ocrMs: Double)? {
        let frame = pointSize
        var image: UIImage?
        let shotStart = nowMonotonic
        _ = ObjCException.catching { image = XCUIScreen.main.screenshot().image }
        let shotMs = (nowMonotonic - shotStart) * 1000
        readFrame = image.flatMap(ScreenSettle.frame(from:))
        guard let cg = image?.cgImage else { return nil }

        let ocrStart = nowMonotonic
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        if let q = query, !q.isEmpty { request.customWords = [q] }
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        let ocrMs = (nowMonotonic - ocrStart) * 1000

        // Same rule as screen_text: text the system draws over the app is not
        // the app's, so it never becomes a fallback item.
        let overlays = overlayRects()
        var items: [JSONValue] = []
        for obs in (request.results ?? []) {
            guard let top = obs.topCandidates(1).first, top.confidence >= minConfidence else { continue }
            // Vision's box is normalised with the ORIGIN AT BOTTOM-LEFT; iOS points
            // are top-left. Flipping y is what makes these coordinates tappable —
            // get it wrong and every tap lands mirrored about the middle.
            let b = obs.boundingBox
            let x = b.minX * frame.width
            let w = b.width * frame.width
            let h = b.height * frame.height
            let y = (1 - b.maxY) * frame.height
            if let q = query, !q.isEmpty, !top.string.localizedCaseInsensitiveContains(q) { continue }
            if overlays.contains(where: { $0.contains(CGPoint(x: x + w / 2, y: y + h / 2)) }) { continue }
            items.append(.object([
                "label": .string(top.string),
                "confidence": .double(Double(top.confidence)),
                "x": .double(x.rounded()), "y": .double(y.rounded()),
                "width": .double(w.rounded()), "height": .double(h.rounded()),
                "center_x": .double((x + w / 2).rounded()),
                "center_y": .double((y + h / 2).rounded()),
                "element_type": .string("OCRText"),
                // Which channel produced this item. Both sources use identical
                // keys so a caller can merge them into one list and still tap
                // either, but they are NOT interchangeable: "ax" items carry a
                // usable element_type and can be re-located by ref, "ocr" items
                // are screen text at a moment in time and go stale on scroll.
                "source": .string("ocr"),
                "is_text_input": .bool(false), "exists": .bool(true),
            ]))
        }
        return (items, shotMs, ocrMs)
    }

    private func screenText(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        let frame = pointSize
        var image: UIImage?
        let shotStart = nowMonotonic
        // Same capture as `screenshot`: XCUIScreen never blocks on quiescence,
        // and crucially does NOT go through the accessibility channel — which is
        // the whole reason this method can succeed when page_source cannot.
        _ = ObjCException.catching { image = XCUIScreen.main.screenshot().image }
        let shotMs = (nowMonotonic - shotStart) * 1000
        readFrame = image.flatMap(ScreenSettle.frame(from:))
        guard let cg = image?.cgImage else {
            return (nil, .serverError("Could not capture the screen for OCR."))
        }

        let ocrStart = nowMonotonic
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = (cmd.matchMode == "fast") ? .fast : .accurate
        request.usesLanguageCorrection = false
        // Chinese first: the lists this exists for are Chinese apps, and Vision
        // weights by order. Latin stays in so mixed UI still reads.
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        if let q = cmd.elementId, !q.isEmpty { request.customWords = [q] }

        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return (nil, .serverError("OCR failed: \(error.localizedDescription)"))
        }
        let ocrMs = (nowMonotonic - ocrStart) * 1000

        let minConf = Float(cmd.scale ?? 0.3)
        let tOverlay = nowMonotonic
        let overlays = overlayRects()
        let overlayMs = (nowMonotonic - tOverlay) * 1000
        var items: [JSONValue] = []
        var overlayText: [JSONValue] = []
        for obs in (request.results ?? []) {
            guard let top = obs.topCandidates(1).first, top.confidence >= minConf else { continue }
            // Vision's box is normalised with the ORIGIN AT BOTTOM-LEFT; iOS points
            // are top-left. Flipping y is what makes these coordinates tappable —
            // get it wrong and every tap lands mirrored about the middle.
            let b = obs.boundingBox
            let x = b.minX * frame.width
            let w = b.width * frame.width
            let h = b.height * frame.height
            let y = (1 - b.maxY) * frame.height
            if let q = cmd.elementId, !q.isEmpty,
               !top.string.localizedCaseInsensitiveContains(q) { continue }
            let center = CGPoint(x: x + w / 2, y: y + h / 2)
            if overlays.contains(where: { $0.contains(center) }) {
                if overlayText.count < 12 { overlayText.append(.string(top.string)) }
                continue
            }
            items.append(.object([
                "label": .string(top.string),
                "confidence": .double(Double(top.confidence)),
                "x": .double(x.rounded()),
                "y": .double(y.rounded()),
                "width": .double(w.rounded()),
                "height": .double(h.rounded()),
                "center_x": .double((x + w / 2).rounded()),
                "center_y": .double((y + h / 2).rounded()),
                "element_type": .string("OCRText"),
                "source": .string("ocr"),
                "is_text_input": .bool(false),
                "exists": .bool(true),
            ]))
        }

        // OCR is the fallback channel. Whether it was the right call for THIS
        // screen is measurable, so measure it and say so — an agent that
        // learned "this app needs OCR" on one web page otherwise keeps using it
        // on native screens where the tree gives refs and exact labels.
        let tCov = nowMonotonic
        let coverage = currentTreeCoverage()
        let covMs = (nowMonotonic - tCov) * 1000
        let tConf = nowMonotonic
        confirmOpened(resolveForegroundBundleId(), name: nil)
        iCTRLUITests.logBuffer.append(String(format: "📝 screen_text shot=%.0fms ocr=%.0fms overlays=%.0fms coverage=%.0fms confirm=%.0fms",
                                             shotMs, ocrMs, overlayMs, covMs, (nowMonotonic - tConf) * 1000))
        var hint = "OCR of what is rendered on screen. Tap a result with tap{x:center_x, y:center_y} (points); "
            + "coordinates go stale on scroll, there are no refs, and icons/images are invisible here."
        let ocrLines = items.compactMap { item -> String? in
            if case .object(let o) = item, case .string(let l)? = o["label"] { return l }
            return nil
        }
        let textShare = coverage == nil ? nil : coverageBody.flatMap { Self.treeTextShare(ocrLines, body: $0) }
        if let share = textShare, share < 0.4 {
            hint = "Only \(Int((share * 100).rounded()))% of the text on screen is in the accessibility tree (web or " +
                "custom-drawn content), so OCR is the right tool here: read with screen_text and tap by coordinate. " + hint
        } else if let c = coverage, c >= Self.treeCoverageThreshold {
            hint = "This screen's accessibility tree is readable (\(Int((c * 100).rounded()))% coverage) — "
                + "prefer page_source / find_element → tap{ref} here: refs survive scrolling and labels are exact. "
                + "OCR is for screens the tree can't read. " + hint
        } else if coverage != nil {
            hint = "The accessibility tree can't read this screen, so OCR is the right tool here. " + hint
                + " Check `channel` again on the next screen."
        }
        if !overlayText.isEmpty {
            hint += " Text drawn over the app by the system (status bar, banners, islands) is in overlay_text, not items — it isn't the app's content."
        }
        var result: [String: JSONValue] = [
            "count": .int(items.count),
            "items": .array(items),
            "coordinate_space": .string("points"),
            "timing": .object([
                "screenshot_ms": .int(Int(shotMs.rounded())),
                "ocr_ms": .int(Int(ocrMs.rounded())),
            ]),
            "hint": .string(hint),
        ]
        if !overlayText.isEmpty { result["overlay_text"] = .array(overlayText) }
        // A captcha drawn outside the tree is only in the pixels (its coverage can be near zero).
        let tBlock = nowMonotonic
        flagBlockers(items.compactMap(Self.ocrScreenText), bid: resolveForegroundBundleId(), overlayShown: false, into: &result)
        let blockMs = (nowMonotonic - tBlock) * 1000
        if blockMs > 300 { iCTRLUITests.logBuffer.append(String(format: "🐢 screen_text blockers=%.0fms", blockMs)) }
        if let c = coverage {
            // Text missing from the tree overrides labelled-area coverage.
            if let share = textShare, share < 0.4 {
                result["channel"] = .object([
                    "ax_coverage": .double((c * 100).rounded() / 100),
                    "tree_text_share": .double((share * 100).rounded() / 100),
                    "recommended": .string("ocr"),
                    "why": .string("Most text on this screen is not in the accessibility tree: read it with " +
                                   "screen_text and tap by coordinate. Check again on the next screen."),
                ])
            } else if let share = textShare, share >= 0.6, c < Self.treeCoverageThreshold {
                result["channel"] = .object([
                    "ax_coverage": .double((c * 100).rounded() / 100),
                    "tree_text_share": .double((share * 100).rounded() / 100),
                    "recommended": .string("tree"),
                    "why": .string("\(Int(share * 100))% of the text read here is in the accessibility tree: use " +
                                   "page_source / find_element → tap{ref}, which need no OCR and give refs."),
                ])
            } else {
                result["channel"] = Self.screenChannel(c, textItems: coverageBody.map {
                    Self.contentTextCount($0, height: pointSize.height) } ?? 0)
            }
        }
        return (result, nil)
    }

    private func findElementInfo(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        guard let elementId = cmd.elementId, !elementId.trimmingCharacters(in: .whitespaces).isEmpty else {
            return (nil, JSONRPCError(
                code: -32602,
                message: "find_element requires 'element_id' (the accessibility label or identifier to search for). " +
                    "'element_type' alone is only a filter and cannot select an element by itself. " +
                    "Next: call page_source to read the visible labels, then retry as " +
                    "find_element{element_id:\"<label>\", element_type:\"textfield\", match:\"contains\"}. " +
                    "Full parameter list: GET /schema.",
                data: nil))
        }

        let matchMode = (cmd.matchMode ?? "exact").lowercased()
        guard let (element, match, index) = locateElement(query: elementId, type: cmd.elementType,
                                                          bundleId: cmd.bundleId, matchMode: matchMode) else {
            if let err = lastLocateError { return (nil, err) }
            if let hit = slowTreeHit {
                let f = hit.frame
                return ([
                    "exists": .bool(true),
                    "label": .string(hit.label),
                    "value": .string(hit.value),
                    "element_type": .string(Self.elementTypeName(hit.elementType)),
                    "x": .double(f.minX), "y": .double(f.minY), "width": .double(f.width), "height": .double(f.height),
                    "center_x": .double(f.midX), "center_y": .double(f.midY),
                    "visibility": .string(hit.visibility),
                    "hint": .string(coordsOnlyNote ?? slowTreeNote(cmd.bundleId ?? resolveForegroundBundleId())),
                ], nil)
            }
            let base = "No element matching label/id '\(elementId)'" +
                (cmd.elementType.map { " of type '\($0)'" } ?? "")
            if foregroundIsWebViewHost() {
                return (nil, JSONRPCError(code: -32602, message: base + "." + Self.webViewAdvice, data: nil))
            }
            // A system alert over the app is why nothing matched (an alert left
            // by a fresh install can make every lookup fail until it is answered).
            // Say so before anything else.
            if cmd.bundleId != "com.apple.springboard", resolveForegroundBundleId() == "com.apple.springboard" {
                let buttons = alertButtons().map { $0.label }.filter { !$0.isEmpty }
                if !buttons.isEmpty {
                    let title = alertTitle().map { "\"\($0)\" " } ?? ""
                    return (nil, JSONRPCError(code: -32602, message: base + ": a system alert \(title)covers the screen " +
                        "(buttons: \(buttons.map { "'\($0)'" }.joined(separator: ", "))). Answer it first — " +
                        "find_element{element_id:\"<button>\", bundle_id:\"com.apple.springboard\"} → tap{ref} — then look again.",
                        data: nil))
                }
            }
            // Say what IS there. "Not found" alone sends a caller round the same
            // loop — try contains, try a shorter substring, try page_source —
            // when the useful fact is usually that the control is a custom view
            // reporting no label at all, and coordinates are the only way in.
            var diag = ""
            if let near = nearbyLabels(limit: 6), !near.isEmpty {
                diag = " On screen right now: " + near.map { "'\($0)'" }.joined(separator: ", ")
                     + ". If the text you want is visible but not listed, it belongs to a custom"
                     + " control that reports no accessibility label — find its frame in page_source"
                     + " and tap by coordinate instead."
            }
            return (nil, JSONRPCError(
                code: -32602,
                message: base +
                    ". It may be off-screen (page{direction}, then find_element again), or the label differs from on-screen text — check page_source. Try match:'contains'."
                    + diag,
                data: nil
            ))
        }

        // Answer from the snapshot the lookup already walked. Every property
        // read on the live element re-resolves it across the whole tree: on a
        // long timeline the ~8 reads below cost several times the lookup itself,
        // ran find_element past its 6s limit and stalled the queue behind it.
        // Live reads are left for the fallback paths, which have no snapshot hit.
        let t0 = nowMonotonic
        let snap = lastLocateScan?.candidates.first
        let frame = snap?.frame ?? element.frame
        let elementType = snap?.elementType ?? element.elementType
        let ref = makeRef(ElementRef(bundleId: cmd.bundleId ?? resolveForegroundBundleId(),
                                     match: match, elementType: cmd.elementType, index: index,
                                     createdAt: nowMonotonic))
        // Surface the actual element type so the caller can tell a real text field
        // from a button that merely looks like a search bar. Many app home screens
        // show a search "bar" that is actually a Button/StaticText — tapping it
        // navigates to a search page where the REAL TextField lives.
        let typeName = Self.elementTypeName(elementType)
        let isTextInput = elementType == .textField
            || elementType == .searchField
            || elementType == .secureTextField
        var result: [String: JSONValue] = [
            "exists": .bool(true),
            // From the snapshot, "hittable" is "its centre is in the content
            // area" — the same test the ranking uses; it can't see an overlay.
            "hittable": .bool(snap.map { $0.inView } ?? element.safeIsHittable),
            "ref": .string(ref),
            "element_type": .string(typeName),
            "is_text_input": .bool(isTextInput),
            "x": .double(frame.origin.x),
            "y": .double(frame.origin.y),
            "width": .double(frame.width),
            "height": .double(frame.height),
            "center_x": .double(frame.midX),
            "center_y": .double(frame.midY),
            "label": .string(snap?.label ?? element.label),
            "value": .string(snap?.value ?? (element.value as? String ?? "")),
        ]
        // Say which of several look-alikes this is, and whether it can be acted
        // on. `hittable` alone was there before and still got ignored — the
        // caller tapped an off-screen "8月25日" because nothing said a visible
        // "9月25日" had matched too.
        if let scan = lastLocateScan, let best = scan.candidates.first {
            result["visibility"] = .string(best.visibility)
            // A labelled button and its own label text match the same query at
            // the same place; listing that twin as an "alternative" (match_count
            // 2 on every such find) is pure noise.
            func same(_ a: LocateHit, _ b: LocateHit) -> Bool {
                abs(a.frame.midX - b.frame.midX) < 4 && abs(a.frame.midY - b.frame.midY) < 4
            }
            var distinct: [LocateHit] = [best]
            for c in scan.candidates.dropFirst() where !distinct.contains(where: { same($0, c) }) { distinct.append(c) }
            let others = distinct.dropFirst().prefix(4)
            if !others.isEmpty {
                result["alternatives"] = .array(others.map { $0.summary })
                result["match_count"] = .int(distinct.count)
            }
            if !best.inView {
                result["hint"] = .string(
                    "This match is \(best.visibility == "partial" ? "only partly on screen" : "OFF screen") " +
                    "(center \(Int(best.frame.midX)),\(Int(best.frame.midY))) and no in-view element matched. " +
                    "Bring it into view with scroll_to_element{element_id:\"\(elementId)\"" +
                    (matchMode == "contains" ? ", match:\"contains\"" : "") + "} before tapping.")
            } else if !others.isEmpty {
                result["hint"] = .string(
                    "\(scan.candidates.count) elements matched; this is the best in-view one. " +
                    "If it is the wrong one, use a more specific element_id (see alternatives).")
            }
        }
        // Nudge the caller when they were probably looking for an input field but
        // matched a button (the classic "fake search bar" trap).
        // Only when it looks like a search or input box: on every other button
        // (a tab, a list row) the note was noise in each reply.
        let label = (snap?.label ?? element.label).lowercased()
        let looksLikeInput = ["search", "搜索", "查找", "输入", "find", "type", "enter", "请输入"].contains { label.contains($0) }
        if !isTextInput, looksLikeInput,
           (elementType == .button || elementType == .staticText || elementType == .other) {
            result["note"] = .string(
                "This is a \(typeName), NOT a text field. If you're trying to type/search: tap it to open the search page, read again until the search page and keyboard are up, then locate the REAL input field with find_element{element_id:\"<its placeholder text>\", element_type:\"textfield\", match:\"contains\"} before typing. (element_id is required — element_type alone only filters.)"
            )
        }
        iCTRLUITests.logBuffer.append("🔎 find_element result \(snap == nil ? "live" : "snapshot") " +
                                      "build=\(Int((nowMonotonic - t0) * 1000))ms")
        return (result, nil)
    }

    /// find_and_tap — like tap_element, but always uses the native
    /// `XCUIElement.tap()` (no synthesized-event shortcut). Slower but
    /// works on SwiftUI List/ForEach rows that ignore synthesized taps —
    /// exactly the case Minis's Debug Server forwards to us. Same match
    /// semantics as tap_element (element_id may be a label OR identifier,
    /// optional match:'contains' for partial substring).
    private func findAndTap(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        guard let elementId = cmd.elementId, !elementId.trimmingCharacters(in: .whitespaces).isEmpty else {
            return (nil, JSONRPCError(code: -32602, message: "find_and_tap requires an 'element_id' (accessibility label or identifier); pair with match:'contains' for partial text.", data: nil))
        }
        let matchMode = (cmd.matchMode ?? "exact").lowercased()
        guard let (element, match, _) = locateElement(query: elementId, type: cmd.elementType,
                                                     bundleId: cmd.bundleId, matchMode: matchMode) else {
            if let err = lastLocateError { return (nil, err) }
            if let hit = slowTreeHit, hit.inView {
                let f = hit.frame
                tapTargetFrame = f
                let r = fastHandler.fastTap(x: f.midX, y: f.midY)
                if r.1 != nil { return r }
                return (["message": .string("Tapped '\(hit.label.isEmpty ? hit.value : hit.label)' at (\(Int(f.midX)),\(Int(f.midY))) from the tree snapshot"),
                         "hint": .string(coordsOnlyNote ?? slowTreeNote(cmd.bundleId ?? resolveForegroundBundleId()))], nil)
            }
            return (nil, JSONRPCError(
                code: -32602,
                message: "find_and_tap: no element matching '\(elementId)'\(cmd.elementType.map { " of type '\($0)'" } ?? ""). Try match:'contains', or a different label from page_source.",
                data: nil
            ))
        }
        // fast:false — the original behaviour, kept as the escape hatch this
        // method historically existed for: native XCUIElement.tap() resolves the
        // element at hit time and works on SwiftUI Lists, where a synthesized
        // event reports success but the tap never lands (so the automatic
        // fallback below cannot catch it). Slow — quiescence waits on both
        // sides — but reliable.
        if cmd.fast == false {
            let f = element.frame
            let label = element.label
            if !element.safeIsHittable, let why = notHittableAdvice(label: label, frame: f) {
                return (nil, JSONRPCError(
                    code: -32602,
                    message: "find_and_tap: element '\(elementId)' can't be tapped: " + why,
                    data: ["x": .double(f.midX), "y": .double(f.midY)]
                ))
            }
            element.tap()
            return ([
                "message": .string("find_and_tap '\(label.isEmpty ? elementId : label)' via native XCUIElement.tap() (fast:false)"),
                "matched": .string(String(describing: match)),
                "frame": .object([
                    "x": .double(f.origin.x), "y": .double(f.origin.y),
                    "w": .double(f.width),    "h": .double(f.height),
                ]),
            ], nil)
        }

        // Phase-timed tail, two round trips instead of three. The 热榜 incident
        // put 9.3s of a 14.9s call here: frame + label + isHittable, each
        // re-running the live query (~3s apiece on an 856-node tree). The live
        // frame read stays — it is the existence check (throws if the element
        // vanished) and the tap aims at it, exactly as before. isHittable stays —
        // covering does NOT move a frame, so no probe can replace it. The label
        // read is gone: it only decorates the reply text, and locate's snapshot
        // already carries it. Comparing live vs snapshot frame is logged as
        // stable/drift telemetry — real-world drift rates are what will tell us
        // whether the frame read itself can ever be safely dropped.
        var tail: [String] = []
        var ts = nowMonotonic
        let f = element.frame
        tail.append("frame=\(Int((nowMonotonic - ts) * 1000))ms")
        if let sf = lastLocateSnapFrame {
            let stable = abs(sf.midX - f.midX) <= 2 && abs(sf.midY - f.midY) <= 2
            tail.append(stable ? "stable" : "drift(\(Int(sf.midX)),\(Int(sf.midY))→\(Int(f.midX)),\(Int(f.midY)))")
        } else {
            tail.append("no-snap")
        }
        // Cosmetic only — never worth a live round trip.
        let label = lastLocateSnapLabel ?? ""

        ts = nowMonotonic
        let hittable = element.safeIsHittable
        tail.append("hittable=\(Int((nowMonotonic - ts) * 1000))ms")

        if !hittable, let why = notHittableAdvice(label: label, frame: f) {
            iCTRLUITests.logBuffer.append("🎯 find_and_tap tail [\(tail.joined(separator: " "))] ✗not-hittable")
            return (nil, JSONRPCError(
                code: -32602,
                message: "find_and_tap: element '\(elementId)' can't be tapped: " + why,
                data: ["x": .double(f.midX), "y": .double(f.midY)]
            ))
        }

        // Synthesized tap at the element's own centre, same as tap(ref:) does.
        // XCUIElement.tap() waits for quiescence and post-event settling, which
        // measured ~7.6s here — the single most expensive part of find_and_tap,
        // costing more than locating the element. Fall back to the native tap
        // when synthesis fails, since that path still works on SwiftUI Lists
        // where synthesized events don't land.
        let (cx, cy) = humanizedPoint(in: f)
        ts = nowMonotonic
        if cmd.bundleId != "com.apple.springboard", let err = alertRaisedBeforeTouch() { return (nil, err) }
        tapTargetFrame = f
        let synth = fastHandler.fastTap(x: cx, y: cy)
        let usedNative = synth.1 != nil
        if usedNative { element.tap() }
        tail.append("tap=\(Int((nowMonotonic - ts) * 1000))ms\(usedNative ? "(native)" : "")")
        iCTRLUITests.logBuffer.append("🎯 find_and_tap tail [\(tail.joined(separator: " "))]")
        return ([
            "message": .string("find_and_tap '\(label.isEmpty ? elementId : label)' via " +
                               (usedNative ? "native XCUIElement.tap()" : "synthesized tap at (\(Int(cx)),\(Int(cy)))")),
            "matched": .string(String(describing: match)),
            "frame": .object([
                "x": .double(f.origin.x), "y": .double(f.origin.y),
                "w": .double(f.width),    "h": .double(f.height),
            ]),
        ], nil)
    }

    private func tapElement(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        guard let elementId = cmd.elementId, !elementId.trimmingCharacters(in: .whitespaces).isEmpty else {
            return (nil, JSONRPCError(code: -32602, message: "tap_element requires an 'element_id' (accessibility label or identifier)", data: nil))
        }

        let matchMode = (cmd.matchMode ?? "exact").lowercased()
        guard let (element, _, _) = locateElement(query: elementId, type: cmd.elementType,
                                                  bundleId: cmd.bundleId, matchMode: matchMode) else {
            if let err = lastLocateError { return (nil, err) }
            if let hit = slowTreeHit, hit.inView {
                let f = hit.frame
                tapTargetFrame = f
                let r = fastHandler.fastTap(x: f.midX, y: f.midY)
                if r.1 != nil { return r }
                return (["message": .string("Tapped '\(hit.label.isEmpty ? hit.value : hit.label)' at (\(Int(f.midX)),\(Int(f.midY))) from the tree snapshot"),
                         "hint": .string(coordsOnlyNote ?? slowTreeNote(cmd.bundleId ?? resolveForegroundBundleId()))], nil)
            }
            return (nil, JSONRPCError(
                code: -32602,
                message: "No element matching '\(elementId)'\(cmd.elementType.map { " of type '\($0)'" } ?? ""). " +
                    "The label may differ from on-screen text (check page_source), or the element needs scrolling into view (page{direction}, then find again). Try match:'contains', or fall back to screenshot + coordinate tap.",
                data: nil
            ))
        }
        if !element.safeIsHittable, let why = notHittableAdvice(label: element.label, frame: element.frame) {
            let f = element.frame
            return (nil, JSONRPCError(
                code: -32602,
                message: "Element '\(elementId)' can't be tapped: " + why,
                data: ["x": .double(f.midX), "y": .double(f.midY)]
            ))
        }

        // Tap by synthesized event a few pt off the element's center (fast, no
        // post-event settling, slightly humanized) rather than XCUIElement.tap(),
        // which can run ~4s when the tap navigates and has coincided with teardown.
        let f = element.frame
        let label = element.label
        let (tx, ty) = humanizedPoint(in: f)
        if cmd.bundleId != "com.apple.springboard", let err = alertRaisedBeforeTouch() { return (nil, err) }
        tapTargetFrame = f
        let r = fastHandler.fastTap(x: tx, y: ty)
        if r.1 != nil { element.tap() }   // fallback only if synthesized tap failed
        return (["message": .string("Tapped element '\(label.isEmpty ? elementId : label)' at (\(Int(tx)),\(Int(ty)))")], nil)
    }

    private func findElement(id: String, type: String?) -> XCUIElement {
        switch type?.lowercased() {
        case "button":               return app.buttons[id]
        case "textfield", "text_field": return app.textFields[id]
        case "textview", "text_view":   return app.textViews[id]
        case "label", "static_text":    return app.staticTexts[id]
        case "image":                return app.images[id]
        case "cell":                 return app.cells[id]
        case "switch":               return app.switches[id]
        case "icon":                 return app.icons[id]
        default:
            return app.descendants(matching: .any).matching(identifier: id).firstMatch
        }
    }

    // MARK: - Drag

    private func drag(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        if let params = cmd.dragPathParams {
            let (path, error) = ContinuousDragPath.parse(params, screenSize: pointSize.size)
            if let error = error { return (nil, error) }
            guard let path = path else { return (nil, .internalError) }
            let record = XCSynthesizedEventRecord(name: "Continuous Path Drag")
            let touch = XCPointerEventPath(forTouchAt: path.points[0], offset: 0.0)
            touch.pressDown(atOffset: 0.0)
            for sample in path.samples {
                touch.move(to: sample.point, atOffset: sample.offset)
            }
            touch.liftUp(atOffset: path.duration + 0.05)
            record.add(touch)
            do {
                try record.synthesize()
                return (["message": .string("Dragged continuous path through \(path.points.count) points"),
                         "screen": coordinateHint], nil)
            } catch {
                return (nil, .serverError("Continuous drag failed: \(error.localizedDescription)"))
            }
        }
        // Endpoints can be given as coordinates OR as refs (from_ref/to_ref),
        // which resolve to the element's center. Refs take precedence.
        var fromX = cmd.fromX, fromY = cmd.fromY, toX = cmd.toX, toY = cmd.toY
        if let r = cmd.fromRef {
            let (el, err) = resolveRefForAction(r)
            if let err = err { return (nil, err) }
            fromX = Double(el!.frame.midX); fromY = Double(el!.frame.midY)
        }
        if let r = cmd.toRef {
            let (el, err) = resolveRefForAction(r)
            if let err = err { return (nil, err) }
            toX = Double(el!.frame.midX); toY = Double(el!.frame.midY)
        }
        guard let fromX = fromX, let fromY = fromY, let toX = toX, let toY = toY else {
            return (nil, JSONRPCError(
                code: -32602,
                message: "drag requires from_x/from_y/to_x/to_y (points) or from_ref/to_ref (element refs). " +
                    "For a simple flick use 'swipe' instead.",
                data: nil
            ))
        }
        if let err = validateCoordinate(x: fromX, y: fromY, context: "drag start") { return (nil, err) }
        if let err = validateCoordinate(x: toX, y: toY, context: "drag end") { return (nil, err) }

        let duration = cmd.duration ?? 0.5

        let eventRecord = XCSynthesizedEventRecord(name: "Drag")
        let startPoint = CGPoint(x: fromX, y: fromY)
        let endPoint = CGPoint(x: toX, y: toY)
        let eventPath = XCPointerEventPath(forTouchAt: startPoint, offset: 0.0)
        eventPath.pressDown(atOffset: 0.0)
        eventPath.move(to: endPoint, atOffset: duration)
        eventPath.liftUp(atOffset: duration + 0.05)
        eventRecord.add(eventPath)

        do {
            try eventRecord.synthesize()
            return ([
                "message": .string("Dragged from (\(fromX),\(fromY)) to (\(toX),\(toY))"),
                "screen": coordinateHint,
            ], nil)
        } catch {
            return (nil, .serverError("Drag failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - Wait

    private func wait(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        let duration = cmd.duration ?? 1.0
        usleep(useconds_t(duration * 1_000_000))
        return (["message": .string("Waited \(duration)s")], nil)
    }
}
