import Foundation
import Testing
@testable import Familiar

@Suite
struct TargetPolicyTests {

    @Test
    func chromesInvisibleStripsAreNotWindows() {
        let gmail = CGRect(x: 100, y: 60, width: 1400, height: 900)
        // Chrome with no window open still owns four 1710x34 strips and a 500x500 box, all off screen and untitled.
        #expect(TargetWindow.isHelperSurface(title: "", onScreen: false, bounds: CGRect(x: 0, y: 0, width: 1710, height: 34), axFrames: []))
        #expect(TargetWindow.isHelperSurface(title: "", onScreen: false, bounds: CGRect(x: 0, y: 607, width: 500, height: 500), axFrames: [gmail]))
        // A minimized window keeps its Accessibility window; one on another desktop keeps its title.
        #expect(!TargetWindow.isHelperSurface(title: "", onScreen: false, bounds: gmail, axFrames: [gmail.offsetBy(dx: 0.5, dy: 0)]))
        #expect(!TargetWindow.isHelperSurface(title: "Inbox - Gmail", onScreen: false, bounds: gmail, axFrames: []))
        #expect(!TargetWindow.isHelperSurface(title: "", onScreen: true, bounds: gmail, axFrames: []))
    }

    @Test
    func refusedBundlesCoverTerminalsAndSecurityUI() {
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.github.wez.wezterm",
                   "net.kovidgoyal.kitty", "org.alacritty", "com.mitchellh.ghostty", "co.zeit.hyper",
                   "com.apple.systempreferences", "com.apple.SecurityAgent", "com.apple.keychainaccess"] {
            #expect(TargetPolicy.refusedBundles.contains(id))
            #expect(TargetPolicy.refusal(bundleID: id, appName: "X", focusedPath: []) != nil)
        }
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty"] {
            #expect(TargetPolicy.refusal(bundleID: id, appName: "Terminal", focusedPath: []) == TargetPolicy.terminalMessage)
        }
        #expect(TargetPolicy.refusal(bundleID: "com.apple.systempreferences", appName: "System Settings", focusedPath: [])?.contains("System Settings") == true)
    }

    @Test
    func selfBundleIsRefused() {
        #expect(TargetPolicy.refusedBundles.contains(TargetPolicy.selfBundleID))
        #expect(TargetPolicy.refusedBundles.contains("com.isought.familiar"))
        #expect(TargetPolicy.refusedBundles.contains("app.noteling.mac"))
        #expect(TargetPolicy.refusal(bundleID: TargetPolicy.selfBundleID, appName: "Noteling", focusedPath: []) != nil)
        #expect(TargetPolicy.refusal(bundleID: "com.isought.familiar", appName: "Familiar", focusedPath: []) != nil)
        #expect(TargetPolicy.refusal(bundleID: "app.noteling.mac", appName: "Noteling", focusedPath: []) != nil)
    }

    @Test
    func ordinaryAppsPass() {
        #expect(TargetPolicy.refusal(bundleID: "com.google.Chrome", appName: "Chrome", focusedPath: ["Search", "AXTextField", "AXWebArea"]) == nil)
        #expect(TargetPolicy.refusal(bundleID: nil, appName: "Mystery", focusedPath: []) == nil)
        // A browser page titled "Terminal" is not a shell.
        #expect(TargetPolicy.refusal(bundleID: "com.google.Chrome", appName: "Chrome", focusedPath: ["Terminal", "AXWebArea"]) == nil)
    }

    @Test
    func editorsRefuseOnlyTheirEmbeddedTerminals() {
        let editors = ["com.microsoft.VSCode", "com.apple.dt.Xcode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.jetbrains.intellij"]
        for id in editors {
            #expect(TargetPolicy.editorBundles.contains(id))
            #expect(TargetPolicy.refusal(bundleID: id, appName: "Editor", focusedPath: ["main.swift", "AXTextArea", "Editor", "AXGroup"]) == nil)
            #expect(TargetPolicy.refusal(bundleID: id, appName: "Editor", focusedPath: ["Terminal 1, zsh", "AXTextArea", "Terminal", "AXGroup"]) == TargetPolicy.terminalMessage)
        }
        #expect(TargetPolicy.refusal(bundleID: "com.apple.dt.Xcode", appName: "Xcode", focusedPath: ["AXTextArea", "Console", "AXScrollArea"]) == TargetPolicy.terminalMessage)
        // Whole words only: "Terminate" is not "terminal".
        #expect(TargetPolicy.refusal(bundleID: "com.microsoft.VSCode", appName: "Code", focusedPath: ["Terminate build", "AXButton"]) == nil)
    }

    @Test
    func descriptorLine() {
        let base = TargetWindow.Descriptor(id: 12, pid: 1, appName: "Chrome", bundleID: "com.google.Chrome", title: "New Report", isOnScreen: false, isMinimized: true)
        #expect(base.line == "12: Chrome — New Report (minimized)")
        let visible = TargetWindow.Descriptor(id: 7, pid: 1, appName: "Notes", bundleID: "com.apple.Notes", title: "", isOnScreen: true, isMinimized: false)
        #expect(visible.line == "7: Notes")
        let hidden = TargetWindow.Descriptor(id: 9, pid: 1, appName: "Mail", bundleID: "com.apple.mail", title: "Inbox", isOnScreen: false, isMinimized: false)
        #expect(hidden.line == "9: Mail — Inbox (off screen)")
    }

    @Test
    func toolkitFromBundleID() {
        #expect(TargetWindow.toolkit(bundleID: "com.google.Chrome", bundleURL: nil) == .chromium)
        #expect(TargetWindow.toolkit(bundleID: "com.brave.Browser", bundleURL: nil) == .chromium)
        #expect(TargetWindow.toolkit(bundleID: "com.apple.Safari", bundleURL: nil) == .webKit)
        #expect(TargetWindow.toolkit(bundleID: "com.apple.Notes", bundleURL: nil) == .appKit)
        #expect(TargetWindow.toolkit(bundleID: "", bundleURL: nil) == .unknown)
    }
}
