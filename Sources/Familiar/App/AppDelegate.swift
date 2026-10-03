import AppKit
import Carbon.HIToolbox
import Combine
import FamiliarRuntime
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = Config.load()
    private var statusItem: NSStatusItem!
    private var panel: BubblePanel!
    private var taskPanel: BackgroundTaskPanelController!
    private let morning = MorningStore()
    private let calendarSources = CalendarStore()
    private let attention = AttentionLedger(inBackground: true)
    private var calendarReader: CalendarCollectionRunner!
    private var morningPanel: MorningPanelController!
    private var morningTasks: MorningTaskRunner!
    private var cardGeneration: CardGenerationService!
    private var hotKey: HotKey?
    private let watcher = ContextWatcher()
    private var runner: ScriptRunner!
    private var registry: ToolRegistry!
    private var assistant: Assistant!
    private let shell = ShellState()
    private let wand = WandController()
    private let notesStore = NotesStore()
    private let notesShortcut = NotesShortcut()
    private let notesUsage = NotesUsageLog()
    private let hideHint = HideHint()
    private let origami = OrigamiFlightController()
    private let settings = SettingsWindowController()
    private let watchDraftWindow = WatchDraftWindowController()
    private var watchList: WatchListFeature?
    private var savedBubbleFrame: NSRect?
    private var dragOffset: NSPoint?     // cursor position relative to the panel origin while dragging
    private let control = ComputerController()
    private let activities = NativeActivityGate()
    private lazy var desktop = DesktopExecutionService(control: control, activities: activities)
    private let execution = ExecutionCoordinator()
    private lazy var recorder = WatchRecorder(config: config, watcher: watcher)
    private lazy var learning = WatchLearnComposition.make(recorder: recorder, registry: registry, activities: activities, calendarStore: calendarSources, config: { [weak self] in self?.config ?? Config() })
    private var bubbleWasVisibleBeforeControl = false
    private var cancellables = Set<AnyCancellable>()

    private var watcherMenuItem: NSMenuItem!
    private var hideMenuItem: NSMenuItem!
    private var screenPermItem: NSMenuItem!
    private var axPermItem: NSMenuItem!
    private var toolsMenuItem: NSMenuItem!
    private var watchMenuItem: NSMenuItem!
    private var stopWorkMenuItem: NSMenuItem!
    private var tasksMenuItem: NSMenuItem!
    private var origamiMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Noteling launching (bundle: \(Bundle.main.bundleIdentifier ?? "none"), config: \(Config.file.path))")
        seedToolsIfMissing()
        MascotStyle.current = MascotStyle(rawValue: config.mascotStyle) ?? .innocent
        Secrets.store = Secrets.Store(rawValue: config.secretsStore) ?? (Signing.isDeveloperID ? .keychain : .file)
        Log.info("signing: \(Signing.description); secrets: \(Secrets.store.rawValue)")
        runner = ScriptRunner(config: config)
        registry = ToolRegistry(root: config.resolvedToolsDir, runner: runner)
        // A tools folder of one's own gives its notes up once; one outside Noteling's folder may be shared, so its
        // notes are copied and the file stays for the others.
        let ownTools = config.resolvedToolsDir.standardizedFileURL.path.hasPrefix(Config.dir.standardizedFileURL.path)
        notesStore.moveNotes(fromPacksIn: config.resolvedToolsDir, rename: ownTools)
        registry.notesStore = notesStore
        assistant = Assistant(config: config, watcher: watcher, registry: registry, shell: shell, learning: learning, execution: execution, desktop: desktop)
        assistant.onStartWand = { [weak self] in self?.startWand() }
        assistant.onCancelWand = { [weak self] in if self?.wand.isActive == true { self?.wand.cancel() } }
        assistant.onOpenWatchDraft = { [weak self] title, markdown in
            guard let self else { return }
            self.watchDraftWindow.show(title: title, markdown: markdown, hideFromScreenShare: self.config.hideFromScreenShare)
        }
        shell.onHideBubble = { [weak self] in self?.hideBubbleWithHint() }
        shell.onDragBubble = { [weak self] phase in
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
        shell.onOpenSettings = { [weak self] in self?.openSettings() }
        if let w = config.cardWidth, let h = config.cardHeight, w >= 340, h >= 400 {
            shell.cardSize = NSSize(width: w, height: h)
        }
        shell.onResizeCard = { [weak self] size, done in
            guard let self else { return }
            self.shell.cardSize = size
            if self.shell.expanded { self.panel.resizeKeepingTopLeft(to: size) }
            if done { self.config.cardWidth = size.width; self.config.cardHeight = size.height; self.config.save() }
        }
        shell.onToggleLarge = { [weak self] in
            guard let self else { return }
            let large = BubblePanel.largeExpandedSize
            let target = self.shell.cardSize.height >= large.height - 1 ? BubblePanel.defaultExpandedSize : large
            self.shell.onResizeCard?(target, true)
        }
        assistant.onSetControlLane = { [weak self] allow, background in
            guard let self else { return }
            self.config.allowControl = allow
            self.config.controlInBackground = background
            self.config.save()
            self.assistant.reconfigure(self.config)
            self.morningTasks?.wake()
            self.cardGeneration?.start()
            Log.info("control lane: allow=\(allow) background=\(background)")
        }
        shell.onPoke = { [weak self] in
            guard let self, self.config.pokeHintsShown < 3 else { return }
            self.config.pokeHintsShown += 1
            self.config.save()
            self.hideHint.show(under: self.panel.frame, title: "Double-click to chat", subtitle: "Hold the note to pick up the pen", seconds: 2.5) { [weak self] in
                self?.shell.expanded = true
            }
        }
        runner.extraEnv = config.env
        control.maxLongEdge = config.maxImageLongEdge
        control.hideFromScreenShare = config.hideFromScreenShare
        control.preciseClicks = config.backgroundPreciseClicks
        control.virtualDisplayEnabled = config.backgroundVirtualDisplay
        control.onCaption = { [weak self] c in
            guard let self else { return }
            guard self.control.lane != .background else { return }
            self.assistant.status = c
        }
        // Desktop tasks have their own surface; starting or finishing one never opens chat.
        control.onBackgroundTaskBegin = { [weak self] in
            self?.desktop.executor.backgroundDidBegin()
        }
        control.onBegin = { [weak self] in
            guard let self else { return }
            self.origami.cancel()
            if self.control.lane == .background {
                self.desktop.executor.nativeDidBegin()
                return
            }
            self.morningPanel?.setHiddenForForegroundGrant(true)
            self.bubbleWasVisibleBeforeControl = self.panel.isVisible
            self.shell.expanded = false
            self.panel.orderOut(nil)          // keep our own windows out of the way of clicks
        }
        control.onEnd = { [weak self] in
            guard let self else { return }
            self.morningPanel?.setHiddenForForegroundGrant(false)
            if self.control.lane == .background {
                self.taskPanel.setHiddenForForegroundGrant(false)
                return
            }
            if self.bubbleWasVisibleBeforeControl { self.panel.orderFrontRegardless() }
            self.shell.expanded = true
        }
        control.onGrant = { [weak self] entering in
            guard let self else { return }
            self.taskPanel.setHiddenForForegroundGrant(entering)
            self.morningPanel?.setHiddenForForegroundGrant(entering)
            if entering {
                self.bubbleWasVisibleBeforeControl = self.panel.isVisible
                self.panel.orderOut(nil)
            } else {
                if self.bubbleWasVisibleBeforeControl { self.panel.orderFrontRegardless() }
            }
        }

        setupEditMenu()
        setupPanel()
        morningTasks = MorningTaskRunner(store: morning, desktop: desktop, registry: registry,
                                        activities: activities, config: { [weak self] in self?.config ?? Config() })
        calendarReader = CalendarCollectionRunner(store: calendarSources, desktop: desktop, registry: registry,
                                                  activities: activities, config: { [weak self] in self?.config ?? Config() })
        calendarSources.refreshSavedWorkflows(root: registry.root)
        taskPanel = BackgroundTaskPanelController(
            store: desktop.tasks, hideFromScreenShare: config.hideFromScreenShare, morning: morning,
            onCancelQueued: { [weak self] id in self?.morningTasks.cancel(id: id) },
            onOpenCard: { [weak self] id in self?.morningPanel.showCard(id: id) })
        cardGeneration = CardGenerationService(morning: morning, sources: calendarSources, desktop: desktop,
                                               config: { [weak self] in self?.config ?? Config() })
        cardGeneration.onSorted = { [weak self] observations, runIDs in
            guard let self else { return }
            self.attention.recordSorted(observations, runIDs: runIDs, runs: self.calendarSources.runStore, cards: self.morning.cards)
        }
        attention.onTaught = { [weak self] facts, change in try? self?.morning.teach(facts, change) }
        attention.backfill(receipts: morning.workspace.cardGenerations ?? [], sources: calendarSources, cards: morning.cards)
        attention.watch(morning)
        calendarReader.trackedItems = { [weak self] sourceID in self?.morning.trackedItems(sourceID: sourceID) ?? [] }
        calendarReader.openSource = { await SourcePageOpener().prepare($0) }
        calendarReader.onRunFinished = { [weak self] runID in _ = self?.cardGeneration.generate(runID: runID) }
        calendarReader.sortedRunIDs = { [weak self] in Set((self?.morning.workspace.cardGenerations ?? []).flatMap(\.runIDs)) }
        let cardConversation = CardConversation(store: morning)
        cardConversation.onHandoff = { [weak self] _ in self?.morningTasks.wake() }
        assistant.cardConversation = cardConversation
        let sourceConversation = SourceConversation(store: calendarSources)
        sourceConversation.isRunning = { [weak self] in self?.calendarReader.isRunning ?? false }
        sourceConversation.sourceScripts = { [weak self] in
            guard let registry = self?.registry else { return [] }
            return registry.sourceScripts().map { pack, script in
                SourceScript(id: script.id, pack: pack.name, description: script.description,
                             missingSecrets: registry.missingRequirements(for: [pack]).first?.keys ?? [])
            }
        }
        assistant.onOpenSettings = { [weak self] in self?.openSettings() }
        assistant.sourceConversation = sourceConversation
        assistant.onOpenSources = { [weak self] in self?.morningPanel.showSources() }
        assistant.onRunSource = { [weak self] id in self?.runSavedSource(id) }
        morningPanel = MorningPanelController(store: morning, hideFromScreenShare: config.hideFromScreenShare,
                                             calendarSources: calendarSources, calendarRunner: calendarReader, cardGeneration: cardGeneration,
                                             attention: attention)
        morningPanel.onDiscussCard = { [weak self] card in
            guard let self, self.assistant.discussCard(card) else { return }
            self.openChat()
        }
        morningPanel.onTeachCalendar = { [weak self] in
            guard let self else { return }
            if !self.panel.isVisible { self.showBubble() }
            self.assistant.startWatching(source: true)
        }
        morningPanel.handoffDestination = { [weak self] in self?.taskPanel.landingFrame }
        morningPanel.onHandoff = { [weak self] _ in
            guard let self else { return }
            self.morningTasks.wake()
        }
        setupStatusItem()
        setupHotKey()
        setupWatcher()
        setupWand()
        setupWatchList()
        requestPermissionsOnFirstRun()
        Task {
            await registry.reload()
            assistant.notesHere = registry.notes(for: watcher.current)
            Secrets.migrateKeychainToFile(keys: (config.connectionMode == "api" ? ["ANTHROPIC_API_KEY"] : []) + registry.packs.flatMap(\.requires))
            if !assistant.hasConnection { assistant.reconfigure(config) }   // pick up a migrated key
            morningTasks.start()
            cardGeneration.start()
            watchList?.start()   // only once the packs are loaded, so no check runs before its script is known
        }

        if !assistant.hasConnection {
            Log.info(ConversationBackend.setupMessage(config: config))
        }
        MainThreadDiagnostics.shared.start()
        MainThreadDiagnostics.shared.mark(.appReady)
    }

    // MARK: setup

    /// Standard application and Edit menus provide native Quit and text-editing shortcuts.
    private func setupEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        appItem.submenu = NSMenu()
        let openMorning = NSMenuItem(title: "Morning Files…", action: #selector(menuShowMorning), keyEquivalent: "")
        openMorning.target = self
        appItem.submenu?.addItem(openMorning)
        let openPeople = NSMenuItem(title: "Who’s Who…", action: #selector(menuShowPeople), keyEquivalent: "")
        openPeople.target = self
        appItem.submenu?.addItem(openPeople)
        let openTasks = NSMenuItem(title: "Background Tasks…", action: #selector(menuShowTasks), keyEquivalent: "")
        openTasks.target = self
        appItem.submenu?.addItem(openTasks)
        let openChatItem = NSMenuItem(title: "Open Chat", action: #selector(openChat), keyEquivalent: "")
        openChatItem.target = self
        appItem.submenu?.addItem(openChatItem)
        appItem.submenu?.addItem(.separator())
        appItem.submenu?.addItem(NSMenuItem(title: "Quit Noteling", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]; edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        edit.addItem(.separator())
        let find = NSMenuItem(title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        edit.addItem(find)
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    private func setupPanel() {
        panel = BubblePanel(hideFromScreenShare: config.hideFromScreenShare)
        let host = NSHostingView(rootView: BubbleView(state: assistant, shell: shell, onOrigami: { [weak self] in self?.takeOrigamiFlight() }))
        host.frame = NSRect(origin: .zero, size: BubblePanel.collapsedSize)
        panel.contentView = host
        if let x = config.bubbleX, let y = config.bubbleY,
           NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(NSPoint(x: x + 42, y: y + 42)) }) {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.placeAtBottomRight()
        }
        panel.orderFrontRegardless()

        shell.$expanded
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] expanded in
                guard let self else { return }
                if self.origami.isFlying {
                    if expanded { self.origami.cancel() } else { return }
                }
                self.panel.resize(to: expanded ? self.shell.cardSize : BubblePanel.collapsedSize, animate: false)
                if expanded {
                    if self.shell.consumeQuietExpand() { self.panel.orderFrontRegardless() } else { self.panel.makeKeyAndOrderFront(nil) }
                } else { self.panel.orderFrontRegardless(); self.panel.resignKey() }
            }
            .store(in: &cancellables)

        assistant.$chatBusy.combineLatest(learning.$phase)
            .receive(on: RunLoop.main)
            .sink { [weak self] chatBusy, phase in
                if chatBusy || phase == .recording || phase == .stopping || phase == .summarizing || phase == .saving { self?.origami.cancel() }
            }
            .store(in: &cancellables)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let img = NSImage(systemSymbolName: "pencil.tip", accessibilityDescription: "Noteling") {
            img.isTemplate = true
            statusItem.button?.image = img
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: "Morning Files…", action: #selector(menuShowMorning), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Who’s Who…", action: #selector(menuShowPeople), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Point the Pen   ⌃⌥Space", action: #selector(menuWand), keyEquivalent: ""))
        watchMenuItem = NSMenuItem(title: "Watch Me", action: #selector(menuWatch), keyEquivalent: "")
        menu.addItem(watchMenuItem)
        stopWorkMenuItem = NSMenuItem(title: "Stop Working", action: #selector(menuStopWork), keyEquivalent: "")
        stopWorkMenuItem.isHidden = true
        menu.addItem(stopWorkMenuItem)
        tasksMenuItem = NSMenuItem(title: "Background Tasks…", action: #selector(menuShowTasks), keyEquivalent: "")
        menu.addItem(tasksMenuItem)
        menu.addItem(NSMenuItem(title: "Watch List…", action: #selector(showWatchList), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Chat", action: #selector(openChat), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show Bubble", action: #selector(menuShowBubble), keyEquivalent: ""))
        hideMenuItem = NSMenuItem(title: "Hide Bubble", action: #selector(menuHideBubble), keyEquivalent: "")
        menu.addItem(hideMenuItem)
        origamiMenuItem = NSMenuItem(title: "Fold into a Crane", action: #selector(takeOrigamiFlight), keyEquivalent: "")
        menu.addItem(origamiMenuItem)
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
        menu.addItem(NSMenuItem(title: "Quit Noteling", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func setupHotKey() {
        hotKey?.unregister()
        hotKey = nil
        let spec = config.hotkey.isEmpty ? "control+option+space" : config.hotkey
        guard let (code, mods) = HotKey.parse(spec) else { Log.info("hotkey: cannot parse \"\(spec)\""); return }
        hotKey = HotKey(keyCode: code, modifiers: mods) { [weak self] in
            guard let self else { return }
            if self.assistant.watching { self.stopWatchingAndShow() }
            else if self.desktop.executor.stopActive() { }
            else if self.control.active, self.control.lane == .background { self.control.stop(reason: HotKey.display(self.config.hotkey)) }
            else if self.wand.isActive { self.wand.cancel() }
            else { self.startWand() }
        }
    }

    private func setupWatcher() {
        watcher.onChange = { [weak self] ctx in
            guard let self else { return }
            if self.wand.isShowingNotes { self.wand.hideNotes() }   // another page: its notes go with it
            let here = self.registry.notes(for: ctx)
            self.assistant.notesHere = here
            if !here.isEmpty {
                self.notesUsage.record("arrive", counts: ["notes": here.count, "warnings": here.filter(\.isWarning).count], notes: here.map(\.id))
            }
            guard !self.assistant.watching else { return }   // the line reads "Watching…" while recording
            self.assistant.contextLine = ctx.summaryLine
        }
        if config.watcherEnabled { watcher.start(interval: config.watcherIntervalSeconds) } else { assistant.contextLine = "Watcher off" }
    }

    private func setupWand() {
        wand.onPick = { [weak self] target in
            guard let self else { return }
            if !self.panel.isVisible { self.showBubble() }
            self.assistant.wandPick(target)
        }
        wand.sceneProvider = { [weak self] in self?.watcher.sample() ?? self?.watcher.current }
        wand.notesProvider = { [weak self] ctx in self?.registry.notes(for: ctx) ?? [] }
        wand.author = { [weak self] in self.map { NoteStore.author($0.config) } ?? NSFullUserName() }
        wand.onNoteSave = { [weak self] note in self?.assistant.saveNote(note) }
        wand.onNoteDelete = { [weak self] id in self?.assistant.deleteNote(id) }
        assistant.onNotesChanged = { [weak self] in
            guard let self else { return }
            self.assistant.notesHere = self.registry.notes(for: self.watcher.current)
        }
        assistant.notesUsage = notesUsage
        assistant.onShowNotes = { [weak self] in self?.toggleNotes(via: "badge") }
        wand.checksProvider = { [weak self] ctx in
            // Scripts of the packs for this scene that need no arguments: what a note's claim can be tested with.
            guard let self else { return [] }
            return self.registry.select(for: ctx).active.flatMap { pack in
                pack.scripts.filter { ($0.inputSchema["required"] as? [String] ?? []).isEmpty }.map { script in
                    NoteEditor.CheckChoice(script: script.id, title: "\(script.id.components(separatedBy: "__").last ?? script.id) (\(pack.name))")
                }
            }
        }
        wand.onPlaced = { [weak self] placed, notOnScreen, shown in
            self?.notesUsage.record("placed", counts: ["placed": placed, "notOnScreen": notOnScreen], tags: ["mode": shown ? "shown" : "pen"])
        }
        wand.hideFromScreenShare = config.hideFromScreenShare
        notesShortcut.onPress = { [weak self] in self?.toggleNotes(via: "shortcut") }
        if config.notesShortcut { notesShortcut.start() }
    }

    private func startWand() {
        origami.cancel()
        guard !assistant.watching else { assistant.startWand(); return }   // no-op with a status line
        guard !assistant.busy else { shell.expanded = true; return }
        shell.expanded = false
        wand.activate()
    }

    private func requestPermissionsOnFirstRun() {
        if !Permissions.accessibilityGranted { Permissions.requestAccessibility() }
        if !Permissions.screenRecordingGranted { Permissions.requestScreenRecording() }
        Log.info("permissions: screen=\(Permissions.screenRecordingGranted) accessibility=\(Permissions.accessibilityGranted)")
    }

    /// First run: copy the bundled example tool packs to ~/.noteling/tools and retire the old knowledge folder.
    private func seedToolsIfMissing() {
        let fm = FileManager.default
        let dir = config.resolvedToolsDir
        if !fm.fileExists(atPath: dir.path), let bundled = Bundle.main.resourceURL?.appendingPathComponent("tools"), fm.fileExists(atPath: bundled.path) {
            try? fm.copyItem(at: bundled, to: dir)
            Log.info("seeded example tool packs into \(dir.path)")
        }
        // A pack added in an update (such as Mail) reaches existing installs; edited or removed packs are left alone.
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("tools"), fm.fileExists(atPath: bundled.path) {
            for name in ToolRegistry.addMissingPacks(from: bundled, to: dir) { Log.info("added tool pack \(name) to \(dir.path)") }
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
        watchMenuItem.title = assistant.watching ? "Stop Watching   ⌃⌥Space" : "Watch Me"
        let working = desktop.tasks.activeTask != nil || (control.active && control.lane == .background)
        stopWorkMenuItem.isHidden = !working
        stopWorkMenuItem.title = desktop.tasks.activeTask != nil ? "Stop Current Task   \(HotKey.display(config.hotkey))"
            : "Stop Working in \(assistant.peek.appName)   \(HotKey.display(config.hotkey))"
        tasksMenuItem.isEnabled = desktop.tasks.hasTasks
        hideMenuItem.isEnabled = panel.isVisible || origami.isFlying
        origamiMenuItem.title = origami.isFlying ? "Land Noteling   Esc" : "Fold into a Crane"
        origamiMenuItem.isEnabled = origami.isFlying || canTakeOrigamiFlight
        let scripts = registry.packs.reduce(0) { $0 + $1.scripts.count }
        let missing = registry.missingRequirements(for: registry.packs)
        toolsMenuItem.title = missing.isEmpty
            ? "Tools: \(registry.packs.count) packs, \(scripts) scripts — Reload"
            : "Tools: \(missing.map { "\($0.pack.name) needs \($0.keys.joined(separator: ", "))" }.joined(separator: "; ")) — open Settings"
        screenPermItem.title = "Screen Recording: " + (Permissions.screenRecordingGranted ? "granted ✓" : "not granted — click to fix")
        axPermItem.title = "Accessibility: " + (Permissions.accessibilityGranted ? "granted ✓" : "not granted — click to fix")
    }

    @objc private func menuWand() { startWand() }
    @objc private func menuStopWork() {
        if !desktop.executor.stopActive() { control.stop(reason: "menu") }
    }
    @objc private func menuShowTasks() { desktop.tasks.show() }
    @objc private func menuShowMorning() { morningPanel.show() }
    @objc private func menuShowPeople() { morningPanel.showPeople() }
    @objc private func menuWatch() {
        if assistant.watching { stopWatchingAndShow() } else { assistant.startWatching() }
    }

    /// The pad comes back for the "what were you doing?" note even when the bubble was hidden in the menu bar.
    private func stopWatchingAndShow() {
        assistant.stopWatching()
        if !panel.isVisible { showBubble() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        cardGeneration?.stop()
        calendarReader?.shutdown()
        morningTasks?.shutdown()
        guard control.isBorrowingOffscreenInput else { return .terminateNow }
        execution.cancel()
        Task { @MainActor in
            await control.endAfterInputReturns()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Quitting mid-recording leaves nothing behind: the unfinished recording and any draft still under review go.
    func applicationWillTerminate(_ notification: Notification) {
        MainThreadDiagnostics.shared.stop()
        cardGeneration?.stop()
        origami.cancel()
        calendarReader?.shutdown()
        morningTasks?.shutdown()
        morningPanel?.close()
        watchDraftWindow.close()
        watchList?.stop()
        execution.cancel()
        control.end()          // never leave a ghost cursor behind
        taskPanel.close()
        assistant.abortWatching()
    }
    @objc private func openChat() {
        origami.cancel()
        if !panel.isVisible { showBubble() }
        shell.expanded = true
        MainThreadDiagnostics.shared.mark(.chatPanelShown, itemCount: assistant.transcript.count)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let panel else { return true }
        openChat()
        sender.activate()
        panel.makeKeyAndOrderFront(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func menuHideBubble() { if panel.isVisible || origami.isFlying { hideBubbleWithHint() } }

    private var canTakeOrigamiFlight: Bool {
        !assistant.busy && !assistant.watching && !control.active && !wand.isActive
    }

    @objc private func takeOrigamiFlight() {
        if origami.isFlying { origami.cancel(); return }
        guard canTakeOrigamiFlight else { return }
        hideHint.dismiss(animated: false)
        shell.expanded = false
        // Collapse synchronously before measuring home. The published resize skips a flight already in progress.
        panel.resize(to: BubblePanel.collapsedSize, animate: false)
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let home = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let started = origami.start(home: home, screen: screen, hideFromScreenShare: config.hideFromScreenShare) { [weak self] in
            guard let self else { return }
            // A disconnected/resized display must not leave even part of the note beyond the desktop.
            let center = CGPoint(x: self.panel.frame.midX, y: self.panel.frame.midY)
            let screens = NSScreen.screens
            let destination = screens.first { $0.visibleFrame.contains(center) } ?? screens.min {
                hypot($0.visibleFrame.midX - center.x, $0.visibleFrame.midY - center.y)
                    < hypot($1.visibleFrame.midX - center.x, $1.visibleFrame.midY - center.y)
            }
            if let bounds = destination?.visibleFrame {
                let frame = self.panel.frame
                self.panel.setFrameOrigin(CGPoint(
                    x: min(max(frame.minX, bounds.minX), max(bounds.minX, bounds.maxX - frame.width)),
                    y: min(max(frame.minY, bounds.minY), max(bounds.minY, bounds.maxY - frame.height))
                ))
            }
            self.panel.orderFrontRegardless()
            Log.info("origami: returned home")
        }
        if started {
            panel.orderOut(nil)
            Log.info("origami: folding for a flight")
        }
    }

    /// Always available: bring the bubble back, or if it is already on screen, bring it to the front and hop.
    @objc private func menuShowBubble() {
        origami.cancel()
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
        origami.cancel()
        shell.expanded = false
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
        origami.cancel()
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

    /// Shows the notes on the screen in front, or puts them away, and notes how it was asked for.
    private func toggleNotes(via: String) {
        guard !wand.isActive else { return }
        if wand.isShowingNotes {
            wand.hideNotes()
            notesUsage.record("hide", tags: ["via": via])
        } else {
            notesUsage.record("show", counts: ["notes": assistant.notesHere.count], tags: ["via": via])
            wand.showNotes()
        }
    }

    @objc private func reloadTools() {
        Task {
            await registry.reload()
            notesStore.reload()
            assistant.notesHere = registry.notes(for: watcher.current)
        }
    }

    @objc private func openSettings() {
        origami.cancel()
        settings.show(config: config, packs: registry.packs, onSave: { [weak self] in
            guard let self else { return }
            self.config = self.settings.model.save(into: self.config)
            self.assistant.reconfigure(self.config)
            self.runner.extraEnv = self.config.env
            self.setupHotKey()
            MascotStyle.current = MascotStyle(rawValue: self.config.mascotStyle) ?? .innocent
            self.panel.sharingType = self.config.hideFromScreenShare ? .none : .readOnly
            self.taskPanel.updateSharing(self.config.hideFromScreenShare)
            self.morningPanel.updateSharing(self.config.hideFromScreenShare)
            self.watchDraftWindow.updateSharing(self.config.hideFromScreenShare)
            self.watchList?.window.updateSharing(self.config.hideFromScreenShare)
            self.control.maxLongEdge = self.config.maxImageLongEdge
            self.control.hideFromScreenShare = self.config.hideFromScreenShare
            self.control.preciseClicks = self.config.backgroundPreciseClicks
            self.control.virtualDisplayEnabled = self.config.backgroundVirtualDisplay
            self.wand.hideFromScreenShare = self.config.hideFromScreenShare
            if self.config.notesShortcut { self.notesShortcut.start() } else { self.notesShortcut.stop() }
            self.morningTasks.wake()
            self.cardGeneration?.start()
            Log.info("settings saved (connection: \(self.config.connectionMode), ready: \(self.assistant.hasConnection), hotkey: \(self.config.hotkey))")
        }, onOpenTools: { [weak self] in self?.openTools() }, onReloadTools: { [weak self] in self?.reloadTools() })
    }
    @objc private func openTools() { NSWorkspace.shared.open(config.resolvedToolsDir) }
    @objc private func openConfig() { NSWorkspace.shared.open(Config.file) }
    @objc private func openLog() { NSWorkspace.shared.open(Config.logFile) }

    /// The chat's Run now tab: read one saved source, then show its progress in Manage sources.
    private func runSavedSource(_ id: UUID) {
        let started: Task<Void, Never>?
        if let source = calendarSources.readingSources.first(where: { $0.id == id }) {
            started = calendarReader.collect(source: source)
        } else if let source = calendarSources.sources.first(where: { $0.id == id }) {
            started = calendarReader.collect(source: source, day: Date())
        } else {
            assistant.status = "That job is no longer in your sources."
            return
        }
        assistant.status = started == nil ? (calendarReader.error ?? "That job could not start.") : "Reading your source. Progress is in Manage sources."
        morningPanel.showSources()
    }
    @objc private func fixScreenPermission() { if !Permissions.requestScreenRecording() { Permissions.openScreenRecordingSettings() } }
    @objc private func fixAXPermission() { Permissions.requestAccessibility(); Permissions.openAccessibilitySettings() }

    // MARK: watch list

    /// Items checked on a schedule by a pack's `watch:` script: the chat's tools, the alerts and the window. The
    /// schedule starts once the packs have loaded (in `applicationDidFinishLaunching`).
    private func setupWatchList() {
        let feature = WatchListFeature(registry: registry)
        feature.notifier.activate()
        feature.notifier.onOpen = { [weak self] watchID, key in self?.openWatchedItem(watchID: watchID, key: key) }
        feature.window.onWhy = { [weak self] watchID, key in self?.explainWatchedItem(watchID: watchID, key: key) }
        assistant.watchList = feature.conversation
        assistant.onOpenWatchList = { [weak self] in self?.showWatchList() }
        watchList = feature
    }

    @objc private func showWatchList() {
        watchList?.window.show(hideFromScreenShare: config.hideFromScreenShare)
    }

    /// A clicked notification explains its item in the chat while it is still red or grey; otherwise the window shows it.
    private func openWatchedItem(watchID: UUID, key: String) {
        guard watchList?.store.watch(id: watchID)?.item(key)?.needsExplaining == true else { showWatchList(); return }
        explainWatchedItem(watchID: watchID, key: key)
    }

    private func explainWatchedItem(watchID: UUID, key: String) {
        guard let watch = watchList?.store.watch(id: watchID), let item = watch.item(key) else { showWatchList(); return }
        openChat()
        assistant.explainWatched(watch, item: item)
    }
}
