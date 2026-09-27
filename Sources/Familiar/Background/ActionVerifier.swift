import AppKit
import ApplicationServices

/// What a verification decided. `unverifiable` is success with a note (the caller says so and moves on);
/// only `noEffect` makes the action ladder fall to its next rung.
enum Verdict: Equatable {
    case confirmed(String)      // evidence
    case unverifiable(String)   // reason; treated as success with a note, never a fall-through
    case noEffect(String)       // evidence; the ladder falls to the next rung
}

/// The state around one element before and after an action: the Accessibility facts that should move when the
/// action worked, plus a coarse grey thumbnail of the screen around the point so a change the AX tree does not
/// echo (Electron, canvas apps, scrolled content) still counts.
struct AXSnapshot: Equatable {
    var value: String?
    var focused: Bool?
    var selectedRange: [Int]?          // [location, length]; an array so the struct stays Equatable for free
    var appFocusedElementID: String?   // a stable description of kAXFocusedUIElement (role+title+frame)
    var windowTitle: String?
    var windowCount: Int = 0
    var cropGrey: [UInt8]?             // 16x12 grey samples of the crop around the point
    var windowGrey: [UInt8]?           // 64x40 grey samples of the whole window: a press usually changes things elsewhere
}

enum ActionVerifier {
    enum Expectation: Equatable { case anyChange, focusOn, valueContains(String), valueChanged, scrolled }

    /// The crop taken around the action point, in capture pixels, and the grid it is reduced to.
    static let cropSize = CGSize(width: 160, height: 120)
    static let greyGrid = (w: 16, h: 12)
    static let windowGrid = (w: 64, h: 40)

    // MARK: Pure

    /// Downsample to `w`x`h` grey (average luminance per cell), rows top to bottom.
    static func grey(_ image: CGImage, w: Int, h: Int) -> [UInt8] {
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        // High-quality interpolation averages the source pixels under each cell, so a cell reads as the mean luminance
        // of its patch rather than one arbitrary pixel; that is what makes a hairline caret cheap and a button dear.
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.data else { return [] }
        let bytes = base.assumingMemoryBound(to: UInt8.self), bpr = ctx.bytesPerRow
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w { out[(h - 1 - y) * w + x] = bytes[y * bpr + x] }   // CG rows run bottom-up
        }
        return out
    }

    /// True when more than `fraction` of the samples differ by more than `threshold`.
    /// On the 16x12 grid a caret (2-3 px wide) darkens at most two or three cells by a third, while a pressed
    /// button, a focus ring or a menu recolours a dozen; 2 % of 192 samples is four cells, which sits between them.
    static func differs(_ a: [UInt8], _ b: [UInt8], threshold: Int = 24, fraction: Double = 0.02) -> Bool {
        guard !a.isEmpty, a.count == b.count else { return a.count != b.count }
        var changed = 0
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > threshold { changed += 1 }
        return Double(changed) > fraction * Double(a.count)
    }

    /// Decide from two snapshots. `trustAX` is false for toolkits whose AX echo lags or lies (Electron): there an
    /// AX-only change is reported as `.unverifiable` unless the screen crop moved too. This reports facts only; a key
    /// press with no visible effect is the caller's call to soften.
    static func verdict(before: AXSnapshot, after: AXSnapshot, expecting: Expectation, trustAX: Bool = true) -> Verdict {
        let axChanges = changes(before, after)
        let screen = screenChanged(before, after)     // nil when either side had no crop
        let screenMoved = screen == true

        // An AX fact satisfied the expectation; corroborate it for untrusted toolkits.
        func fromAX(_ evidence: String) -> Verdict {
            if trustAX || screenMoved { return .confirmed(screenMoved ? evidence + "; the screen changed" : evidence) }
            return .unverifiable(evidence + ", but this app's accessibility echo is unreliable and the screen around the point did not change")
        }
        // Nothing usable from AX; fall back to the screen.
        func fromScreen(_ noAX: String) -> Verdict {
            switch screen {
            case true: return .unverifiable("\(noAX); the screen around the point changed")
            case false: return .noEffect("\(noAX); the screen around the point looks the same")
            case nil: return .noEffect("\(noAX); no screen crop to compare")
            }
        }

        switch expecting {
        case .anyChange:
            if screenMoved {
                return .confirmed(axChanges.isEmpty ? "the screen around the point changed" : axChanges.joined(separator: ", ") + "; the screen changed")
            }
            if !axChanges.isEmpty { return fromAX(axChanges.joined(separator: ", ")) }
            return .noEffect(screen == nil ? "no accessibility change; no screen crop to compare" : "nothing changed: accessibility state and the screen around the point are the same")

        case .focusOn:
            switch after.focused {
            case true:
                return fromAX(before.focused == true ? "the element was already focused" : "the element reports focus")
            case false:
                return .noEffect(after.appFocusedElementID != before.appFocusedElementID
                                 ? "the element is not focused; focus went to \(after.appFocusedElementID ?? "nothing")"
                                 : "the element is not focused")
            case nil:
                if let id = after.appFocusedElementID, id != before.appFocusedElementID {
                    return trustAX || screenMoved
                        ? .unverifiable("the element does not report focus, but the app's focused element became \(id)")
                        : fromScreen("focus state unreadable")
                }
                return fromScreen("focus state unreadable")
            }

        case .valueContains(let s):
            guard let v = after.value else { return fromScreen("value unreadable") }
            if contains(v, s) { return fromAX("value now contains “\(clip(s))”") }
            return .noEffect(before.value == v ? "value unchanged: \(quote(v))" : "value changed to \(quote(v)) but does not contain “\(clip(s))”")

        case .valueChanged:
            guard let v = after.value else { return fromScreen("value unreadable") }
            if v != before.value { return fromAX("value changed to \(quote(v))") }
            if !trustAX, screenMoved { return .unverifiable("value reads unchanged, but this app's accessibility echo is unreliable and the screen around the point changed") }
            return .noEffect("value unchanged: \(quote(v))" + (screenMoved ? " (the screen around the point changed)" : ""))

        case .scrolled:
            // AX carries no scroll position we can trust across toolkits, so scrolling is judged by the screen alone.
            switch screen {
            case true: return .confirmed("the content around the point moved")
            case false: return .noEffect("the content around the point looks the same" + (axChanges.isEmpty ? "" : " (\(axChanges.joined(separator: ", ")))"))
            case nil: return axChanges.isEmpty ? .unverifiable("no screen crop to compare") : .unverifiable("no screen crop to compare; " + axChanges.joined(separator: ", "))
            }
        }
    }

    // MARK: Live

    /// Reads the AX state (messaging timeout 0.3 s) and, when `cropAroundCG` is given, a 160x120 px crop around it
    /// from a fresh per-window capture. Every read is optional: a dead element or a failed capture yields nils, never a throw.
    static func snapshot(target: TargetWindow, element: AXUIElement?, cropAroundCG: CGPoint?) async -> AXSnapshot {
        var s = AXSnapshot()
        // A fresh application element: shortening the timeout on the target's shared `axApp` would stick to every later read.
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        if let element {
            AXUIElementSetMessagingTimeout(element, 0.3)
            s.value = valueString(element)
            s.focused = bool(element, kAXFocusedAttribute)
            s.selectedRange = range(element, kAXSelectedTextRangeAttribute)
        }
        s.appFocusedElementID = AX.element(app, kAXFocusedUIElementAttribute).map(describe)
        s.windowTitle = AX.string(target.axWindow, kAXTitleAttribute)
        s.windowCount = elements(app, kAXWindowsAttribute).count
        let greys = await screenGreys(target: target, aroundCG: cropAroundCG)
        s.windowGrey = greys.window
        s.cropGrey = greys.crop
        return s
    }

    /// Polls `after` at the given delays and returns the first verdict that is not `noEffect`, else the last `noEffect`.
    static func verify(before: AXSnapshot, expecting: Expectation, pollMs: [Int] = [80, 200, 400], trustAX: Bool = true,
                       after: () async -> AXSnapshot) async -> Verdict {
        var last = Verdict.noEffect("not checked")
        var elapsed = 0
        for at in pollMs {
            let wait = max(0, at - elapsed)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000) }
            elapsed += wait
            last = verdict(before: before, after: await after(), expecting: expecting, trustAX: trustAX)
            if case .noEffect = last { continue }
            return last
        }
        return last
    }

    // MARK: - Private

    /// Human-readable list of the AX facts that moved between two snapshots.
    private static func changes(_ a: AXSnapshot, _ b: AXSnapshot) -> [String] {
        var out: [String] = []
        if a.value != b.value { out.append("value changed to \(quote(b.value))") }
        if a.focused != b.focused { out.append(b.focused == true ? "the element gained focus" : "the element lost focus") }
        if a.selectedRange != b.selectedRange, let r = b.selectedRange, r.count == 2 { out.append("selection moved to \(r[0])+\(r[1])") }
        if a.appFocusedElementID != b.appFocusedElementID { out.append("focus moved to \(b.appFocusedElementID ?? "nothing")") }
        if a.windowTitle != b.windowTitle { out.append("window title is now \(quote(b.windowTitle))") }
        if a.windowCount != b.windowCount { out.append("windows \(a.windowCount) → \(b.windowCount)") }
        return out
    }

    /// The crop around the point, or the whole window, moved. Nil when neither side has anything to compare.
    /// The window grid has 2560 cells and three of them changing by a quarter counts: a two-digit readout or a
    /// checkbox tick is that small, while a blinking caret stays under one cell at this scale.
    private static func screenChanged(_ a: AXSnapshot, _ b: AXSnapshot) -> Bool? {
        var seen = false, moved = false
        if let x = a.cropGrey, let y = b.cropGrey { seen = true; moved = moved || differs(x, y) }
        if let x = a.windowGrey, let y = b.windowGrey { seen = true; moved = moved || differs(x, y, threshold: 24, fraction: 0.001) }
        return seen ? moved : nil
    }

    /// Typed text tolerant of the target's whitespace and case normalisation.
    private static func contains(_ value: String, _ needle: String) -> Bool {
        if value.contains(needle) { return true }
        guard let v = NoteAnchor.norm(value), let n = NoteAnchor.norm(needle) else { return false }
        return v.contains(n)
    }

    private static func clip(_ s: String, _ n: Int = 60) -> String {
        let one = s.replacingOccurrences(of: "\n", with: "⏎")
        return one.count > n ? String(one.prefix(n)) + "…" : one
    }

    private static func quote(_ s: String?) -> String { s.map { "“\(clip($0))”" } ?? "nothing" }

    /// kAXValue as text: strings, URLs and numbers (checkbox states, sliders). Anything else is nil, not a crash.
    private static func valueString(_ el: AXUIElement) -> String? {
        if let s = AX.string(el, kAXValueAttribute) { return s }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success, let v else { return nil }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v else { return nil }
        return (v as? NSNumber)?.boolValue
    }

    private static func range(_ el: AXUIElement, _ attr: String) -> [Int]? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
        return [r.location, r.length]
    }

    private static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let arr = v as? [AXUIElement] else { return [] }
        return arr
    }

    /// Role, label and rounded frame: enough to tell "focus moved to another element" from "nothing happened",
    /// without pinning identity to the element handle itself, which toolkits recreate freely.
    private static func describe(_ el: AXUIElement) -> String {
        let role = AX.string(el, kAXRoleAttribute) ?? "?"
        let label = AX.string(el, kAXTitleAttribute) ?? AX.string(el, kAXDescriptionAttribute) ?? ""
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = WandController.axFrame(of: el, primaryMaxY: primaryMaxY).map {
            "@\(Int($0.minX.rounded())),\(Int($0.minY.rounded())) \(Int($0.width.rounded()))x\(Int($0.height.rounded()))"
        } ?? ""
        return label.isEmpty ? "\(role) \(frame)" : "\(role) “\(clip(label, 40))” \(frame)"
    }

    /// One fresh per-window capture, reduced to the whole-window grid and, around the point, the crop grid. Nils when
    /// the window cannot be captured right now (gone, no permission), which the verdict treats as "nothing to compare",
    /// never as "no change".
    private static func screenGreys(target: TargetWindow, aroundCG p: CGPoint?) async -> (window: [UInt8]?, crop: [UInt8]?) {
        var t = target
        if t.scWindow == nil { await t.refreshSCWindow() }
        guard let w = t.scWindow, let raw = try? await ScreenCapture.captureWindow(w, backingScale: t.backingScale) else { return (nil, nil) }
        let window = grey(raw.image, w: windowGrid.w, h: windowGrid.h)
        guard let p, let crop = ScreenCapture.crop(raw.image, around: raw.imagePoint(cg: p), size: cropSize) else { return (window, nil) }
        return (window, grey(crop, w: greyGrid.w, h: greyGrid.h))
    }
}
