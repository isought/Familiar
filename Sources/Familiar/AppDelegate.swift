import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = Config.load()
    private var statusItem: NSStatusItem!
    private var panel: BubblePanel!
    private var hotKey: HotKey?
    private let watcher = ContextWatcher()
    private var runner: ScriptRunner!
    private var registry: ToolRegistry!
    private var assistant: Assistant!
    private let wand = WandController()
    private let hideHint = HideHint()
    private let settings = SettingsWindowController()
    private var savedBubbleFrame: NSRect?
    private var dragOffset: NSPoint?     // cursor position relative to the panel origin while dragging
    private let control = ComputerController()
    private var bubbleWasVisibleBeforeControl = false
    private var cancellables = Set<AnyCancellable>()

    private var watcherMenuItem: NSMenuItem!
    private var hideMenuItem: NSMenuItem!
    private var screenPermItem: NSMenuItem!
    private var axPermItem: NSMenuItem!
    private var toolsMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Familiar launching (bundle: \(Bundle.main.bundleIdentifier ?? "none"), config: \(Config.file.path))")
        seedToolsIfMissing()
        runner = ScriptRunner(config: config)
        registry = ToolRegistry(root: config.resolvedToolsDir, runner: runner)
        assistant = Assistant(config: config, watcher: watcher, registry: registry)
        assistant.onStartWand = { [weak self] in self?.startWand() }
        assistant.onHideBubble = { [weak self] in self?.hideBubbleWithHint() }
        assistant.onDragBubble = { [weak self] phase in
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            switch phase {
            case .moved:
                if self.dragOffset == nil {
                    self.dragOffset = NSPoint(x: mouse.x - self.panel.frame.origin.x, y: mouse.y - self.panel.frame.origin.y)
                }
                let o = self.dragOffset!
                self.panel.setFrameOrigin(NSPoint(x: mouse.x - o.x, y: mouse.y - o.y))
            case .ended:
                self.dragOffset = nil
                self.config.bubbleX = self.panel.frame.origin.x
                self.config.bubbleY = self.panel.frame.origin.y
                self.config.save()
            }
        }
        assistant.onOpenSettings = { [weak self] in self?.openSettings() }
        runner.extraEnv = config.env
        control.maxLongEdge = config.maxImageLongEdge
        control.onCaption = { [weak self] c in self?.assistant.status = c }
        control.onBegin = { [weak self] in
            guard let self else { return }
            self.bubbleWasVisibleBeforeControl = self.panel.isVisible
            self.assistant.expanded = false
            self.panel.orderOut(nil)          // keep our own windows out of the way of clicks
        }
        control.onEnd = { [weak self] in
            guard let self else { return }
            if self.bubbleWasVisibleBeforeControl { self.panel.orderFrontRegardless() }
            self.assistant.expanded = true
        }
        assistant.control = control

        setupPanel()
        setupStatusItem()
        setupHotKey()
        setupWatcher()
        setupWand()
        requestPermissionsOnFirstRun()
        Task { await registry.reload() }

        if !assistant.hasApiKey {
            Log.info("no API key found; set \"apiKey\" in \(Config.file.path) or export ANTHROPIC_API_KEY")
        }
    }

    // MARK: setup

    private func setupPanel() {
        panel = BubblePanel(hideFromScreenShare: config.hideFromScreenShare)
        let host = NSHostingView(rootView: BubbleView(state: assistant))
        host.frame = NSRect(origin: .zero, size: BubblePanel.collapsedSize)
        panel.contentView = host
        if let x = config.bubbleX, let y = config.bubbleY,
           NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(NSPoint(x: x + 32, y: y + 32)) }) {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.placeAtBottomRight()
        }
        panel.orderFrontRegardless()

        assistant.$expanded
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] expanded in
                guard let self else { return }
                self.panel.resize(to: expanded ? BubblePanel.expandedSize : BubblePanel.collapsedSize, animate: false)
                if expanded { self.panel.makeKeyAndOrderFront(nil) } else { self.panel.orderFrontRegardless(); self.panel.resignKey() }
            }
            .store(in: &cancellables)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let img = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Familiar") {
            img.isTemplate = true
            statusItem.button?.image = img
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: "Point the Wand   ⌃⌥Space", action: #selector(menuWand), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Chat", action: #selector(openChat), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show Bubble", action: #selector(menuShowBubble), keyEquivalent: ""))
        hideMenuItem = NSMenuItem(title: "Hide Bubble", action: #selector(menuHideBubble), keyEquivalent: "")
        menu.addItem(hideMenuItem)
        menu.addItem(.separator())
        watcherMenuItem = NSMenuItem(title: "Watcher: On", action: #selector(toggleWatcher), keyEquivalent: "")
        menu.addItem(watcherMenuItem)
        toolsMenuItem = NSMenuItem(title: "Tools: …", action: #selector(reloadTools), keyEquivalent: "")
        menu.addItem(toolsMenuItem)
        menu.addItem(NSMenuItem(title: "Open Tools Folder", action: #selector(openTools), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Open Config File", action: #selector(openConfig), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: ""))
        menu.addItem(.separator())
        screenPermItem = NSMenuItem(title: "Screen Recording: …", action: #selector(fixScreenPermission), keyEquivalent: "")
        axPermItem = NSMenuItem(title: "Accessibility: …", action: #selector(fixAXPermission), keyEquivalent: "")
        menu.addItem(screenPermItem)
        menu.addItem(axPermItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Familiar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func setupHotKey() {
        hotKey = nil
        let spec = config.hotkey.isEmpty ? "control+option+space" : config.hotkey
        guard let (code, mods) = HotKey.parse(spec) else { Log.info("hotkey: cannot parse \"\(spec)\""); return }
        hotKey = HotKey(keyCode: code, modifiers: mods) { [weak self] in
            guard let self else { return }
            if self.wand.isActive { self.wand.cancel() } else { self.startWand() }
        }
    }

    private func setupWatcher() {
        watcher.onChange = { [weak self] ctx in self?.assistant.contextLine = ctx.summaryLine }
        if config.watcherEnabled { watcher.start(interval: config.watcherIntervalSeconds) } else { assistant.contextLine = "Watcher off" }
    }

    private func setupWand() {
        wand.onPick = { [weak self] target in
            guard let self else { return }
            if !self.panel.isVisible { self.showBubble() }
            self.assistant.wandPick(target)
        }
    }

    private func startWand() {
        guard !assistant.busy else { assistant.expanded = true; return }
        assistant.expanded = false
        wand.activate()
    }

    private func requestPermissionsOnFirstRun() {
        if !Permissions.accessibilityGranted { Permissions.requestAccessibility() }
        if !Permissions.screenRecordingGranted { Permissions.requestScreenRecording() }
        Log.info("permissions: screen=\(Permissions.screenRecordingGranted) accessibility=\(Permissions.accessibilityGranted)")
    }

    /// First run: copy the bundled example tool packs to ~/.familiar/tools and retire the old knowledge folder.
    private func seedToolsIfMissing() {
        let fm = FileManager.default
        let dir = config.resolvedToolsDir
        if !fm.fileExists(atPath: dir.path), let bundled = Bundle.main.resourceURL?.appendingPathComponent("tools"), fm.fileExists(atPath: bundled.path) {
            try? fm.copyItem(at: bundled, to: dir)
            Log.info("seeded example tool packs into \(dir.path)")
        }
        let legacy = Config.dir.appendingPathComponent("knowledge")
        let seededNames: Set<String> = ["expense-reports.md", "hr-portal.md", "vpn-and-access.md"]
        if let files = try? fm.contentsOfDirectory(atPath: legacy.path), !files.isEmpty, Set(files).isSubset(of: seededNames) {
            try? fm.removeItem(at: legacy)
            Log.info("removed old example knowledge folder (docs now live in tools/<pack>/docs)")
        }
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        watcherMenuItem.title = watcher.isRunning ? "Watcher: On" : "Watcher: Off"
        hideMenuItem.isEnabled = panel.isVisible
        let scripts = registry.packs.reduce(0) { $0 + $1.scripts.count }
        let missing = registry.missingRequirements(for: registry.packs)
        toolsMenuItem.title = missing.isEmpty
            ? "Tools: \(registry.packs.count) packs, \(scripts) scripts — Reload"
            : "Tools: \(missing.map { "\($0.pack.name) needs \($0.keys.joined(separator: ", "))" }.joined(separator: "; ")) — open Settings"
        screenPermItem.title = "Screen Recording: " + (Permissions.screenRecordingGranted ? "granted ✓" : "not granted — click to fix")
        axPermItem.title = "Accessibility: " + (Permissions.accessibilityGranted ? "granted ✓" : "not granted — click to fix")
    }

    @objc private func menuWand() { startWand() }
    @objc private func openChat() {
        if !panel.isVisible { showBubble() }
        assistant.expanded = true
    }

    @objc private func menuHideBubble() { if panel.isVisible { hideBubbleWithHint() } }

    /// Always available: bring the bubble back, or if it is already on screen, bring it to the front and hop.
    @objc private func menuShowBubble() {
        if panel.isVisible {
            panel.orderFrontRegardless()
            hop()
        } else {
            showBubble()
        }
    }

    private func hop() {
        let home = panel.frame
        var up = home; up.origin.y += 18
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16; ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.panel.animator().setFrame(up, display: true)
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22; ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.panel.animator().setFrame(home, display: true)
            }
        })
    }

    /// Screen rect of the menu bar icon, if it is on screen.
    private var statusItemRect: NSRect? {
        guard let b = statusItem.button, let w = b.window else { return nil }
        return w.convertToScreen(b.convert(b.bounds, to: nil))
    }

    /// Fly the bubble into the menu bar icon, pulse the icon, and show a callout saying where it went.
    private func hideBubbleWithHint() {
        assistant.expanded = false
        wand.deactivate()
        guard let target = statusItemRect else { panel.orderOut(nil); return }
        let start = panel.frame
        savedBubbleFrame = start
        let end = NSRect(x: target.midX - 10, y: target.minY - 6, width: 20, height: 20)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.panel.animator().setFrame(end, display: true)
            self.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.panel.setFrame(start, display: false)
            self.hideHint.show(under: target) { [weak self] in self?.showBubble() }
            self.pulseStatusItem(remaining: 3)
        })
    }

    private func showBubble() {
        hideHint.dismiss(animated: true)
        guard !panel.isVisible else { return }
        let dest = savedBubbleFrame ?? panel.frame
        if let target = statusItemRect {
            panel.setFrame(NSRect(x: target.midX - 10, y: target.minY - 6, width: 20, height: 20), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.panel.animator().setFrame(dest, display: true)
                self.panel.animator().alphaValue = 1
            }
        } else {
            panel.setFrame(dest, display: true)
            panel.orderFrontRegardless()
        }
    }

    private func pulseStatusItem(remaining: Int) {
        guard remaining > 0, let b = statusItem.button else { return }
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.22; b.animator().alphaValue = 0.15 }, completionHandler: {
            NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.22; b.animator().alphaValue = 1 }, completionHandler: { [weak self] in
                self?.pulseStatusItem(remaining: remaining - 1)
            })
        })
    }

    @objc private func toggleWatcher() {
        if watcher.isRunning { watcher.stop(); assistant.contextLine = "Watcher off" } else { watcher.start(interval: config.watcherIntervalSeconds) }
        config.watcherEnabled = watcher.isRunning
        config.save()
    }

    @objc private func reloadTools() { Task { await registry.reload() } }

    @objc private func openSettings() {
        settings.show(config: config, packs: registry.packs, onSave: { [weak self] in
            guard let self else { return }
            self.config = self.settings.model.save(into: self.config)
            self.assistant.reconfigure(self.config)
            self.runner.extraEnv = self.config.env
            self.setupHotKey()
            self.panel.sharingType = self.config.hideFromScreenShare ? .none : .readOnly
            Log.info("settings saved (key: \(self.assistant.hasApiKey ? "set" : "missing"), hotkey: \(self.config.hotkey))")
        }, onOpenTools: { [weak self] in self?.openTools() }, onReloadTools: { [weak self] in self?.reloadTools() })
    }
    @objc private func openTools() { NSWorkspace.shared.open(config.resolvedToolsDir) }
    @objc private func openConfig() { NSWorkspace.shared.open(Config.file) }
    @objc private func openLog() { NSWorkspace.shared.open(Config.dir.appendingPathComponent("familiar.log")) }
    @objc private func fixScreenPermission() { if !Permissions.requestScreenRecording() { Permissions.openScreenRecordingSettings() } }
    @objc private func fixAXPermission() { Permissions.requestAccessibility(); Permissions.openAccessibilitySettings() }
}
