import Carbon.HIToolbox

/// Global hotkey via Carbon. Works without Accessibility permission.
final class HotKey {
    /// Parses "control+option+space", "cmd+shift+k", "ctrl+alt+f5" into Carbon key code + modifiers.
    static func parse(_ spec: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        let parts = spec.lowercased().split(whereSeparator: { $0 == "+" || $0 == " " || $0 == "-" }).map(String.init)
        guard let keyName = parts.last else { return nil }
        var mods: UInt32 = 0
        for m in parts.dropLast() {
            switch m {
            case "control", "ctrl", "^": mods |= UInt32(controlKey)
            case "option", "alt", "opt", "⌥": mods |= UInt32(optionKey)
            case "command", "cmd", "⌘": mods |= UInt32(cmdKey)
            case "shift", "⇧": mods |= UInt32(shiftKey)
            default: return nil
            }
        }
        let named: [String: Int] = ["space": kVK_Space, "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape, "esc": kVK_Escape,
                                    "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
                                    "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12, "`": kVK_ANSI_Grave, "/": kVK_ANSI_Slash, ".": kVK_ANSI_Period]
        let letters = "abcdefghijklmnopqrstuvwxyz"
        let letterCodes = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J,
                           kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T,
                           kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z]
        let digitCodes = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        var code: Int?
        if let c = named[keyName] { code = c }
        else if keyName.count == 1, let ch = keyName.first, let i = letters.firstIndex(of: ch) { code = letterCodes[letters.distance(from: letters.startIndex, to: i)] }
        else if keyName.count == 1, let d = Int(keyName) { code = digitCodes[d] }
        guard let code, mods != 0 else { return nil }
        return (UInt32(code), mods)
    }

    private static var registry: [UInt32: HotKey] = [:]
    private static var handlerInstalled = false

    private var ref: EventHotKeyRef?
    private let id: UInt32
    private let callback: () -> Void

    init(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.callback = callback
        self.id = UInt32(HotKey.registry.count + 1)
        HotKey.registry[id] = self
        HotKey.installHandlerIfNeeded()
        let hkID = EventHotKeyID(signature: OSType(0x53444B48), id: id) // 'SDKH'
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        Log.info("hotkey registered (status \(status))")
    }

    /// Explicit release: the registry holds a strong reference, so deinit alone never runs.
    func unregister() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        HotKey.registry[id] = nil
    }

    deinit { unregister() }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            DispatchQueue.main.async { HotKey.registry[hkID.id]?.callback() }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
