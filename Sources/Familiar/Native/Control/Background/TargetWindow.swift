import AppKit
import ApplicationServices
import ScreenCaptureKit

enum TargetError: LocalizedError, Equatable {
    case noFrontmostApp
    case refused(String)          // TargetPolicy message, shown to the model verbatim
    case noWindow(String)         // app name
    case permission(String)       // message

    var errorDescription: String? {
        switch self {
        case .noFrontmostApp: return "No app is in front to work in."
        case .refused(let m): return m
        case .noWindow(let app): return "\(app) has no window I can work in."
        case .permission(let m): return m
        }
    }
}

enum TargetPolicy {
    static let terminalMessage = "I don't type into terminals or shells, even in the background: a keystroke there runs a command."

    /// Noteling's own bundle id. The fallback is the shipped id, so the policy holds in tests too (Bundle.main is xctest there).
    static let selfBundleID = Bundle.main.bundleIdentifier ?? "app.noteling.mac"
    /// Every id this app has shipped under, so it never drives an older copy of itself either.
    static let ownBundleIDs: Set<String> = [selfBundleID, "app.noteling.mac", "com.isought.familiar"]

    static let terminalBundles: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.github.wez.wezterm",
        "net.kovidgoyal.kitty", "org.alacritty", "com.mitchellh.ghostty", "co.zeit.hyper",
    ]
    static let securityBundles: Set<String> = [
        "com.apple.systempreferences", "com.apple.SecurityAgent", "com.apple.keychainaccess",
    ]

    /// Bundle ids Noteling never drives in the background (terminals, itself, security UI).
    static let refusedBundles: Set<String> = terminalBundles.union(securityBundles).union(ownBundleIDs)

    /// Editors whose embedded terminals are refused by focused element (VS Code, Xcode, Cursor, Zed, JetBrains).
    static let editorBundles: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.visualstudio.code.oss", "com.vscodium",
        "com.apple.dt.Xcode", "com.todesktop.230313mzl4w4u92" /* Cursor */, "dev.zed.Zed", "dev.zed.Zed-Preview",
        "com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.WebStorm", "com.jetbrains.PyCharm",
        "com.jetbrains.pycharm", "com.jetbrains.CLion", "com.jetbrains.goland", "com.jetbrains.rubymine",
        "com.jetbrains.rider", "com.jetbrains.AppCode", "com.jetbrains.PhpStorm", "com.jetbrains.datagrip",
        "com.jetbrains.fleet", "com.google.android.studio",
    ]

    /// Words that mark an embedded terminal in an editor's focused path (VS Code "Terminal 1, zsh", Xcode "Console",
    /// JetBrains "Terminal" tool window). Whole words, case-insensitive, so "Terminate build" does not match.
    private static let terminalWords: Set<String> = ["terminal", "shell", "console", "tty", "pty"]

    /// Pure. `focusedPath` = titles/descriptions/roles of the focused element and its ancestors (innermost first).
    static func refusal(bundleID: String?, appName: String, focusedPath: [String]) -> String? {
        let id = bundleID ?? ""
        if ownBundleIDs.contains(id) { return "I don't drive Noteling itself." }
        if terminalBundles.contains(id) { return terminalMessage }
        if securityBundles.contains(id) { return "I don't work in \(appName) in the background: it holds permissions and passwords, so it's yours to click." }
        if editorBundles.contains(id), focusedPath.contains(where: mentionsTerminal) { return terminalMessage }
        return nil
    }

    private static func mentionsTerminal(_ s: String) -> Bool {
        let words = s.lowercased().split { !$0.isLetter && !$0.isNumber }
        return words.contains { terminalWords.contains(String($0)) }
    }
}

struct TargetWindow {
    enum Toolkit: String { case appKit, chromium, webKit, electron, unknown }

    struct Descriptor: Identifiable, Equatable {
        let id: Int               // CGWindowID
        let pid: pid_t
        let appName: String
        let bundleID: String
        let title: String
        let isOnScreen: Bool
        let isMinimized: Bool

        /// "12: Chrome — New Report (minimized)" style line for the model.
        var line: String {
            var s = "\(id): \(appName)"
            if !title.isEmpty { s += " — \(title)" }
            if isMinimized { s += " (minimized)" } else if !isOnScreen { s += " (off screen)" }
            return s
        }
    }

    let pid: pid_t
    let bundleID: String
    let appName: String
    let cgWindowID: CGWindowID
    let axApp: AXUIElement
    let axWindow: AXUIElement
    let toolkit: Toolkit
    private(set) var backingScale: CGFloat
    private(set) var scWindow: SCWindow?
    private(set) var frameCG: CGRect        // last known, CG global (top-left origin)
    private(set) var title: String
    var sharedWithHuman = false             // the human was in this same app when the job started
    var axDegraded = false                  // Chromium/Electron exposed no web tree after warm-up

    // MARK: Resolution

    /// The window of the frontmost app: focused window, else main window. Refuses per TargetPolicy and when the
    /// frontmost app is Noteling.
    static func resolveFrontmost() async -> Result<TargetWindow, TargetError> {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .failure(.noFrontmostApp) }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return .failure(.refused("I don't drive Noteling itself.")) }
        guard Permissions.accessibilityGranted else { return .failure(.permission(accessibilityMessage)) }
        let axApp = application(app.processIdentifier)
        guard let axWindow = AX.element(axApp, kAXFocusedWindowAttribute) ?? AX.element(axApp, kAXMainWindowAttribute) else {
            return .failure(.noWindow(app.localizedName ?? "The app"))
        }
        return await build(app: app, axApp: axApp, axWindow: axWindow, cgWindowID: nil)
    }

    /// Any window by id (from `list()`), same checks.
    static func resolve(windowID: CGWindowID) async -> Result<TargetWindow, TargetError> {
        guard let win = cgWindows().first(where: { $0.id == windowID }) else { return .failure(.noWindow("That window")) }
        if win.pid == ProcessInfo.processInfo.processIdentifier { return .failure(.refused("I don't drive Noteling itself.")) }
        guard let app = NSRunningApplication(processIdentifier: win.pid) else { return .failure(.noWindow(win.owner)) }
        guard Permissions.accessibilityGranted else { return .failure(.permission(accessibilityMessage)) }
        let axApp = application(win.pid)
        // Minimized and hidden windows are still in kAXWindows; match by frame, title breaks ties.
        guard let axWindow = closest(to: win.bounds, title: win.name, in: axWindows(of: axApp)) else {
            return .failure(.noWindow(app.localizedName ?? win.owner))
        }
        return await build(app: app, axApp: axApp, axWindow: axWindow, cgWindowID: windowID)
    }

    /// Candidate windows for the model: layer-0 windows with a title or an owner name, excluding Noteling, sorted
    /// front to back; includes off-screen and minimized ones, but not helper surfaces (see isHelperSurface).
    static func list() -> [Descriptor] {
        let me = ProcessInfo.processInfo.processIdentifier
        var axCache: [pid_t: [AXWindowInfo]] = [:]
        var out: [Descriptor] = []
        for w in cgWindows() where w.pid != me && (!w.name.isEmpty || !w.owner.isEmpty) {
            // Tiny layer-0 windows are helpers (Chrome's 1x1 offscreen surfaces, tooltips); not a place to work.
            guard w.bounds.width >= 32, w.bounds.height >= 32 else { continue }
            let app = NSRunningApplication(processIdentifier: w.pid)
            var minimized = false
            if !w.onScreen, Permissions.accessibilityGranted {   // on-screen windows can't be minimized
                if axCache[w.pid] == nil { axCache[w.pid] = axWindows(of: application(w.pid, timeout: 0.3)) }
                let axWins = axCache[w.pid] ?? []
                if isHelperSurface(title: w.name, onScreen: w.onScreen, bounds: w.bounds, axFrames: axWins.compactMap(\.frame)) { continue }
                minimized = closestInfo(to: w.bounds, title: w.name, in: axWins)?.minimized ?? false
            }
            out.append(Descriptor(id: Int(w.id), pid: w.pid, appName: app?.localizedName ?? w.owner,
                                  bundleID: app?.bundleIdentifier ?? "", title: w.name,
                                  isOnScreen: w.onScreen, isMinimized: minimized))
        }
        // The window server lists front to back; keep that order, on-screen windows first.
        return out.enumerated().sorted { a, b in
            if a.element.isOnScreen != b.element.isOnScreen { return a.element.isOnScreen }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// An off-screen, untitled window with no Accessibility window at its frame is a helper surface, not a window
    /// anyone sees or Noteling can work in. Chrome keeps several even with no window open (toolbar strips across the
    /// top of the screen, a 500-point box); listing them sent the reader through five "off screen" windows.
    static func isHelperSurface(title: String, onScreen: Bool, bounds: CGRect, axFrames: [CGRect]) -> Bool {
        !onScreen && title.isEmpty && !axFrames.contains { distance($0, bounds) <= 8 }
    }

    private static let accessibilityMessage = "Accessibility permission is off. Open System Settings → Privacy & Security → Accessibility and enable Noteling."

    private static func build(app: NSRunningApplication, axApp: AXUIElement, axWindow: AXUIElement, cgWindowID: CGWindowID?) async -> Result<TargetWindow, TargetError> {
        let pid = app.processIdentifier
        let appName = app.localizedName ?? app.bundleIdentifier ?? "The app"
        let bundleID = app.bundleIdentifier ?? ""
        if let why = TargetPolicy.refusal(bundleID: bundleID, appName: appName, focusedPath: focusedPath(axApp: axApp)) {
            return .failure(.refused(why))
        }
        guard let frame = axFrameCG(axWindow), frame.width > 0, frame.height > 0 else { return .failure(.noWindow(appName)) }
        guard let windowID = cgWindowID ?? windowID(pid: pid, near: frame) else { return .failure(.noWindow(appName)) }
        let scWindow: SCWindow?
        do { scWindow = try await ScreenCapture.shareableWindow(id: windowID) }
        catch { return .failure(.permission(error.localizedDescription)) }
        let appKitRect = CGRect(origin: CaptureSpace.appKit(CGPoint(x: frame.minX, y: frame.maxY)), size: frame.size)
        let scale = NSScreen.screens.first { $0.frame.intersects(appKitRect) }?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        return .success(TargetWindow(pid: pid, bundleID: bundleID, appName: appName, cgWindowID: windowID,
                                     axApp: axApp, axWindow: axWindow,
                                     toolkit: toolkit(bundleID: bundleID, bundleURL: app.bundleURL),
                                     backingScale: scale, scWindow: scWindow, frameCG: frame,
                                     title: AX.string(axWindow, kAXTitleAttribute) ?? ""))
    }

    /// Pure given its inputs. Bundle id prefixes for the Chromium family, Safari is WebKit, an app bundle carrying
    /// the Electron framework is Electron, anything else with a bundle is AppKit.
    static func toolkit(bundleID: String, bundleURL: URL?) -> Toolkit {
        let chromium = ["com.google.Chrome", "org.chromium", "com.brave", "com.microsoft.edgemac"]
        if chromium.contains(where: { bundleID.hasPrefix($0) }) { return .chromium }
        if bundleID.hasPrefix("com.apple.Safari") { return .webKit }
        if let u = bundleURL,
           FileManager.default.fileExists(atPath: u.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) {
            return .electron
        }
        return bundleID.isEmpty && bundleURL == nil ? .unknown : .appKit
    }

    // MARK: State

    /// Re-read kAXPosition/kAXSize/kAXTitle. False when the AX window is gone (kAXErrorInvalidUIElement or no size).
    mutating func refresh() -> Bool {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        let pe = AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
        let se = AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
        if pe == .invalidUIElement || se == .invalidUIElement { return false }
        switch se {
        case .success:
            guard let size = Self.size(sizeRef), size.width > 0, size.height > 0 else { return false }
            if pe == .success, let pos = Self.point(posRef) { frameCG = CGRect(origin: pos, size: size) }
            else { frameCG.size = size }
        case .noValue, .attributeUnsupported: return false
        default: break   // a timeout is not "gone"; keep the last known frame
        }
        if let t = AX.string(axWindow, kAXTitleAttribute) { title = t }
        // A task may move between a Retina monitor and a virtual display. Reusing
        // its old scale would map fresh screenshot coordinates to the wrong point.
        func overlap(_ screen: NSScreen) -> CGFloat {
            let rect = frameCG.intersection(CaptureSpace.cg(screen.frame))
            return rect.isNull ? 0 : rect.width * rect.height
        }
        let screen = NSScreen.screens.max { overlap($0) < overlap($1) }
        if let screen, frameCG.intersects(CaptureSpace.cg(screen.frame)) { backingScale = screen.backingScaleFactor }
        return true
    }

    /// Re-fetch the SCWindow for cgWindowID (nil if gone). Cheap (~10 ms).
    mutating func refreshSCWindow() async {
        scWindow = await fetchSCWindow()
    }

    /// Non-mutating pair for owners that keep the target in an actor-isolated property, where Swift forbids a
    /// mutating async call: `target.setSCWindow(await target.fetchSCWindow())`.
    func fetchSCWindow() async -> SCWindow? {
        (try? await ScreenCapture.shareableWindow(id: cgWindowID)) ?? nil
    }

    mutating func setSCWindow(_ w: SCWindow?) { scWindow = w }

    var isMinimized: Bool { Self.bool(axWindow, kAXMinimizedAttribute) ?? false }
    var isMain: Bool { Self.bool(axWindow, kAXMainAttribute) ?? false }
    var isOnScreen: Bool { scWindow?.isOnScreen ?? false }

    func space(maxLongEdge: Int) -> CaptureSpace {
        CaptureSpace.window(frameCG: frameCG, backingScale: backingScale, maxLongEdge: maxLongEdge)
    }

    var descriptor: Descriptor {
        Descriptor(id: Int(cgWindowID), pid: pid, appName: appName, bundleID: bundleID, title: title,
                   isOnScreen: isOnScreen, isMinimized: isMinimized)
    }

    // MARK: Elements

    /// The AX element under a CG global point in this app, climbing to the nearest ancestor that lists
    /// `kAXPressAction` when `pressable` is true.
    func element(atCG p: CGPoint, pressable: Bool) -> AXUIElement? {
        // A fresh application element so the short timeout doesn't stick to the shared axApp.
        let app = Self.application(pid, timeout: 0.3)
        var out: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &out) == .success, var el = out else { return nil }
        guard pressable else { return el }
        for _ in 0..<12 {
            if Self.actions(of: el).contains(kAXPressAction) { return el }
            guard let parent = AX.element(el, kAXParentAttribute) else { return nil }
            el = parent
        }
        return nil
    }

    /// Titles/descriptions/roles of the focused element and its ancestors, innermost first (for TargetPolicy).
    func focusedPath() -> [String] { Self.focusedPath(axApp: axApp) }

    private static func focusedPath(axApp: AXUIElement) -> [String] {
        guard var el = AX.element(axApp, kAXFocusedUIElementAttribute) else { return [] }
        var path: [String] = []
        for _ in 0..<24 {
            for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXRoleAttribute] {
                if let s = AX.string(el, attr), !s.isEmpty { path.append(s) }
            }
            guard let parent = AX.element(el, kAXParentAttribute) else { break }
            el = parent
        }
        return path
    }

    // MARK: Accessibility warm-up (Chromium/Electron)

    struct AXWarmUp { var manual: Bool?; var enhanced: Bool? }   // previous values, to restore

    private static let manualAttr = "AXManualAccessibility", enhancedAttr = "AXEnhancedUserInterface"

    /// Chromium builds its AX tree lazily: setting these app attributes asks for the full tree, then the web area
    /// takes a moment to appear. Sets axDegraded when none appears. No-op for other toolkits.
    mutating func warmUpAccessibility() async -> AXWarmUp {
        let (previous, degraded) = await probeAccessibility()
        axDegraded = degraded
        return previous
    }

    /// Non-mutating form of `warmUpAccessibility` (same reason as `fetchSCWindow`); the owner stores `degraded`
    /// into `axDegraded` itself.
    func probeAccessibility() async -> (warm: AXWarmUp, degraded: Bool) {
        guard toolkit == .chromium || toolkit == .electron else { return (AXWarmUp(), false) }
        let previous = AXWarmUp(manual: Self.bool(axApp, Self.manualAttr), enhanced: Self.bool(axApp, Self.enhancedAttr))
        for attr in [Self.manualAttr, Self.enhancedAttr] {
            let r = AXUIElementSetAttributeValue(axApp, attr as CFString, kCFBooleanTrue)
            // -25205 attributeUnsupported / -25208 actionUnsupported: older Chromium builds lack one of the two.
            if r != .success, r != .attributeUnsupported, r != .actionUnsupported { Log.info("target: set \(attr) failed \(r.rawValue)") }
        }
        var found = false
        for _ in 0..<8 {
            if Self.hasWebArea(under: axWindow) { found = true; break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if !found { Log.info("target: no AXWebArea in \(appName) after warm-up; AX degraded") }
        return (previous, !found)
    }

    func restoreAccessibility(_ w: AXWarmUp) {
        guard toolkit == .chromium || toolkit == .electron else { return }
        // Unreadable before means we turned it on; back to off so the app stops paying for the full tree.
        AXUIElementSetAttributeValue(axApp, Self.manualAttr as CFString, (w.manual ?? false) ? kCFBooleanTrue : kCFBooleanFalse)
        AXUIElementSetAttributeValue(axApp, Self.enhancedAttr as CFString, (w.enhanced ?? false) ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// Breadth-first, depth ≤ 8, with a node budget because a Chromium tree can be tens of thousands of elements.
    private static func hasWebArea(under root: AXUIElement) -> Bool {
        var level = [root], budget = 3000
        for _ in 0...8 {
            var next: [AXUIElement] = []
            for el in level {
                budget -= 1
                if budget < 0 { return false }
                if AX.string(el, kAXRoleAttribute) == "AXWebArea" { return true }
                next.append(contentsOf: AX.children(el))
            }
            if next.isEmpty { return false }
            level = next
        }
        return false
    }

    // MARK: AX helpers

    private static func application(_ pid: pid_t, timeout: Float = 1.0) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)   // on the app element it covers every element of that app
        return app
    }

    private static func point(_ v: CFTypeRef?) -> CGPoint? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    private static func size(_ v: CFTypeRef?) -> CGSize? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    private static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v else { return nil }
        return (v as? NSNumber)?.boolValue
    }

    private static func actions(of el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    /// kAXPosition is already CG global (top-left origin), so no flip.
    private static func axFrameCG(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let p = point(posRef), let s = size(sizeRef) else { return nil }
        return CGRect(origin: p, size: s)
    }

    private struct AXWindowInfo { let element: AXUIElement; let frame: CGRect?; let title: String; let minimized: Bool }

    private static func axWindows(of axApp: AXUIElement) -> [AXWindowInfo] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &v) == .success,
              let wins = v as? [AXUIElement] else { return [] }
        return wins.map { AXWindowInfo(element: $0, frame: axFrameCG($0), title: AX.string($0, kAXTitleAttribute) ?? "",
                                       minimized: bool($0, kAXMinimizedAttribute) ?? false) }
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    private static func closestInfo(to bounds: CGRect, title: String, in wins: [AXWindowInfo]) -> AXWindowInfo? {
        wins.min { a, b in
            let da = a.frame.map { distance($0, bounds) } ?? .greatestFiniteMagnitude
            let db = b.frame.map { distance($0, bounds) } ?? .greatestFiniteMagnitude
            if da != db { return da < db }
            return !title.isEmpty && a.title == title && b.title != title
        }
    }

    private static func closest(to bounds: CGRect, title: String, in wins: [AXWindowInfo]) -> AXUIElement? {
        closestInfo(to: bounds, title: title, in: wins)?.element
    }

    // MARK: Window server

    private struct CGWin {
        let id: CGWindowID; let pid: pid_t; let layer: Int; let alpha: Double; let bounds: CGRect
        let name: String; let owner: String; let onScreen: Bool
    }

    /// Layer-0, visible (alpha > 0.05) windows, front to back, on and off screen.
    private static func cgWindows() -> [CGWin] {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { w in
            guard let id = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return nil }
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard layer == 0, alpha > 0.05 else { return nil }
            return CGWin(id: id, pid: pid, layer: layer, alpha: alpha, bounds: bounds,
                         name: w[kCGWindowName as String] as? String ?? "",
                         owner: w[kCGWindowOwnerName as String] as? String ?? "",
                         onScreen: (w[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false)
        }
    }

    /// The pid's window whose bounds sit closest to the AX frame.
    private static func windowID(pid: pid_t, near frame: CGRect) -> CGWindowID? {
        cgWindows().filter { $0.pid == pid }.min { distance($0.bounds, frame) < distance($1.bounds, frame) }?.id
    }
}

enum TargetEvent: Equatable {
    case destroyed, minimized, deminiaturized, moved, resized, titleChanged(String), focusedWindowChanged,
         sheetCreated, windowCreated, appTerminated, appActivated, appHidden, spaceChanged
}

/// AXObserver on the target's window and app plus NSWorkspace notifications; callbacks on the main thread.
/// Note: app activation arrives from both AX and NSWorkspace, so `.appActivated` can repeat; owners should tolerate it.
@MainActor final class TargetWatch {
    /// The refcon target. Holds the watch weakly so a callback after the watch died (stop() never called) is a no-op.
    private final class Box { weak var watch: TargetWatch? }

    private let target: TargetWindow
    private let onEvent: (TargetEvent) -> Void
    private var observer: AXObserver?
    private var box: Unmanaged<Box>?
    private var registered: [(AXUIElement, String)] = []
    private var tokens: [NSObjectProtocol] = []

    private static let windowNotifications = [
        kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        kAXWindowMovedNotification, kAXWindowResizedNotification, kAXTitleChangedNotification,
    ]
    private static let appNotifications = [
        kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification, kAXSheetCreatedNotification,
        kAXApplicationHiddenNotification, kAXApplicationActivatedNotification,
    ]

    init(target: TargetWindow, onEvent: @escaping (TargetEvent) -> Void) {
        self.target = target
        self.onEvent = onEvent
        installWorkspace()

        let callback: AXObserverCallback = { _, element, name, refcon in
            guard let refcon else { return }
            let box = Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue()
            // The run loop source lives on the main run loop, so this is the main thread.
            MainActor.assumeIsolated { box.watch?.handle(name as String, element: element) }
        }
        var obs: AXObserver?
        let err = AXObserverCreate(target.pid, callback, &obs)
        guard err == .success, let obs else { Log.info("target: AXObserverCreate failed \(err.rawValue) for pid \(target.pid)"); return }
        observer = obs
        let b = Box(); b.watch = self
        let box = Unmanaged.passRetained(b)
        self.box = box
        for name in Self.windowNotifications where AXObserverAddNotification(obs, target.axWindow, name as CFString, box.toOpaque()) == .success {
            registered.append((target.axWindow, name))
        }
        for name in Self.appNotifications where AXObserverAddNotification(obs, target.axApp, name as CFString, box.toOpaque()) == .success {
            registered.append((target.axApp, name))
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    func stop() {
        if let observer {
            for (el, name) in registered { AXObserverRemoveNotification(observer, el, name as CFString) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        registered = []
        observer = nil
        box?.release()
        box = nil
        for t in tokens { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        tokens = []
    }

    private func handle(_ name: String, element: AXUIElement) {
        let event: TargetEvent?
        switch name {
        case kAXUIElementDestroyedNotification: event = .destroyed
        case kAXWindowMiniaturizedNotification: event = .minimized
        case kAXWindowDeminiaturizedNotification: event = .deminiaturized
        case kAXWindowMovedNotification: event = .moved
        case kAXWindowResizedNotification: event = .resized
        case kAXTitleChangedNotification: event = .titleChanged(AX.string(element, kAXTitleAttribute) ?? "")
        case kAXFocusedWindowChangedNotification: event = .focusedWindowChanged
        case kAXWindowCreatedNotification: event = .windowCreated
        case kAXSheetCreatedNotification: event = .sheetCreated
        case kAXApplicationHiddenNotification: event = .appHidden
        case kAXApplicationActivatedNotification: event = .appActivated
        default: event = nil
        }
        if let event { onEvent(event) }
    }

    private func installWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let pid = target.pid
        func pidOf(_ n: Notification) -> pid_t? {
            (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
        }
        func observe(_ name: Notification.Name, _ event: TargetEvent, pidMatch: Bool) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard !pidMatch || pidOf(n) == pid else { return }
                MainActor.assumeIsolated { self?.onEvent(event) }
            })
        }
        observe(NSWorkspace.didTerminateApplicationNotification, .appTerminated, pidMatch: true)
        observe(NSWorkspace.didActivateApplicationNotification, .appActivated, pidMatch: true)
        observe(NSWorkspace.didHideApplicationNotification, .appHidden, pidMatch: true)
        observe(NSWorkspace.activeSpaceDidChangeNotification, .spaceChanged, pidMatch: false)
    }
}
