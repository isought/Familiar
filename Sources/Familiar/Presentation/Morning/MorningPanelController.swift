import AppKit
import Combine
import SwiftUI
import QuartzCore

@MainActor final class MorningPanelController: NSObject, NSWindowDelegate, WindowDragHandling {
    private let store: MorningStore
    private let navigation = MorningNavigation()
    private let launcher: MorningPanel
    private let panel: MorningPanel
    private var screenObservation: NSObjectProtocol?
    private var routeObservation: AnyCancellable?
    private var flight: NSPanel?
    private var hiddenForForegroundGrant = false
    private var contentsRequested = false
    private let launcherPlacement = FloatingWindowPlacement("morningLauncher")
    private let filesPlacement = FloatingWindowPlacement("morningFiles")
    private var launcherPositioned = false
    private var filesTopLeft: NSPoint?
    private var adjustingFrame = false
    private weak var draggedWindow: NSWindow?
    private let attention: AttentionLedger?
    private var heldOpen: AttentionOpen.Held?
    var onHandoff: ((MorningWorkItem) -> Void)?
    var onTeachCalendar: (() -> Void)?
    var onDiscussCard: ((MorningCard) -> Void)?
    var handoffDestination: (() -> NSRect?)?

    /// Only the little folder is shown at launch. Opening a file is always an explicit action.
    init(store: MorningStore, hideFromScreenShare: Bool, calendarSources: CalendarStore? = nil,
         calendarRunner: CalendarCollectionRunner? = nil, cardGeneration: CardGenerationService? = nil,
         attention: AttentionLedger? = nil) {
        self.store = store
        self.attention = attention
        launcher = MorningPanel(title: "Morning folder", hideFromScreenShare: hideFromScreenShare)
        panel = MorningPanel(title: "Morning files", hideFromScreenShare: hideFromScreenShare)
        super.init()
        launcher.delegate = self
        panel.delegate = self
        launcher.hasShadow = false
        launcher.contentView = NSHostingView(rootView: MorningLauncherView(store: store, open: { [weak self] in
            guard let self else { return }
            self.panel.isVisible ? self.hideContents() : self.show(trigger: .launcher)
        }, people: { [weak self] in self?.showPeople() }))
        panel.contentView = NSHostingView(rootView: MorningFilesView(
            store: store, navigation: navigation,
            close: { [weak self] in self?.hideContents() },
            filed: { [weak self] in self?.animateHandoff() },
            handoff: { [weak self] item in
                self?.animateHandoff()
                self?.onHandoff?(item)
            }, calendarSources: calendarSources, calendarRunner: calendarRunner,
            teachCalendar: { [weak self] in self?.onTeachCalendar?() }, cardGeneration: cardGeneration,
            discussCard: { [weak self] card in self?.onDiscussCard?(card) }, attention: attention
        ))
        routeObservation = navigation.$route.combineLatest(store.$workspace)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.position() }
        position()
        launcher.orderFrontRegardless()
        screenObservation = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.position() } }
    }

    func show(trigger: AttentionOpenTrigger = .menu) {
        navigation.route = .folders
        openContents(trigger)
    }

    func showCard(id: UUID, trigger: AttentionOpenTrigger = .taskPanel) {
        navigation.route = .card(id)
        openContents(trigger)
    }

    func showPeople(trigger: AttentionOpenTrigger = .people) {
        navigation.route = .people
        openContents(trigger)
    }

    func showSources(trigger: AttentionOpenTrigger = .chat) {
        navigation.route = .sources
        openContents(trigger)
    }

    func showRun(id: UUID, sourceID: UUID? = nil, trigger: AttentionOpenTrigger = .run) {
        navigation.route = .sourceRun(runID: id, sourceID: sourceID)
        openContents(trigger)
    }

    func setHiddenForForegroundGrant(_ hidden: Bool) {
        hiddenForForegroundGrant = hidden
        if hidden {
            launcher.orderOut(nil)
            panel.orderOut(nil)
            flight?.orderOut(nil)
        } else {
            position()
            launcher.orderFrontRegardless()
            // Returning from a desktop grant must never take keyboard focus.
            if contentsRequested { panel.orderFrontRegardless() }
            if contentsRequested, let heldOpen { recordOpen(heldOpen.trigger, wasOpen: heldOpen.wasOpen) }
            heldOpen = nil
        }
    }

    func updateSharing(_ hideFromScreenShare: Bool) {
        for window in [launcher, panel] { window.sharingType = hideFromScreenShare ? .none : .readOnly }
        flight?.sharingType = hideFromScreenShare ? .none : .readOnly
    }

    func close() {
        routeObservation?.cancel()
        routeObservation = nil
        if let screenObservation { NotificationCenter.default.removeObserver(screenObservation) }
        screenObservation = nil
        for window in [launcher, panel] { window.orderOut(nil); window.close() }
        flight?.orderOut(nil)
        flight?.close()
        flight = nil
    }

    private func openContents(_ trigger: AttentionOpenTrigger) {
        // Open already, or it would be but for a desktop grant.
        let wasOpen = contentsRequested
        contentsRequested = true
        position()
        guard !hiddenForForegroundGrant else { heldOpen = AttentionOpen.hold(trigger, wasOpen: wasOpen, over: heldOpen); return }
        panel.makeKeyAndOrderFront(nil)
        recordOpen(trigger, wasOpen: wasOpen)
    }

    private func recordOpen(_ trigger: AttentionOpenTrigger, wasOpen: Bool) {
        attention?.recordOpened(trigger, route: navigation.route, desk: store.cards.filter { $0.displayDisposition == .unreviewed }.count,
                                wasOpen: wasOpen)
    }

    private func hideContents() {
        contentsRequested = false
        let route = Self.route(afterHiding: navigation.route)
        if route != navigation.route { navigation.route = route }
        panel.orderOut(nil)
    }

    /// Closing the pack leaves an attention screen, so a look at the rest ends when the person closes it, not when a
    /// later open, perhaps by chat the next day, moves the hidden pack on. Every other screen waits for the next open.
    static func route(afterHiding route: MorningNavigation.Route) -> MorningNavigation.Route {
        if case .attention = route { return .folders }
        return route
    }

    private func position() {
        guard draggedWindow == nil else { return }
        guard let initialScreen = FloatingWindowPlacement.screen(for: launcher.frame, fallback: NSScreen.main) else { return }
        let visible = initialScreen.visibleFrame
        let iconSize = NSSize(width: 86, height: 78)
        let icon = launcherPositioned ? launcher.frame : launcherPlacement.restore(size: iconSize)
            ?? NSRect(x: visible.minX + 18, y: visible.maxY - 92, width: iconSize.width, height: iconSize.height)
        let launcherScreen = FloatingWindowPlacement.screen(for: icon, fallback: initialScreen) ?? initialScreen
        adjustingFrame = true
        defer { adjustingFrame = false }
        launcher.setFrame(FloatingWindowPlacement.clamped(icon, to: launcherScreen.visibleFrame), display: true)
        launcherPositioned = true

        if filesTopLeft == nil {
            if let saved = filesPlacement.restore(size: NSSize(width: 650, height: 380)) {
                filesTopLeft = NSPoint(x: saved.minX, y: saved.maxY)
            } else {
                filesTopLeft = NSPoint(x: launcher.frame.minX, y: launcher.frame.minY - 8)
            }
        }
        guard let anchor = filesTopLeft else { return }
        let height = Self.preferredHeight(for: navigation.route, isEmpty: store.cards.isEmpty)
        let requested = NSRect(x: anchor.x, y: anchor.y - height, width: 650, height: height)
        let screen = FloatingWindowPlacement.screen(for: requested, fallback: launcherScreen) ?? launcherScreen
        panel.setFrame(FloatingWindowPlacement.clamped(requested, to: screen.visibleFrame), display: true)
    }

    func windowDidMove(_ notification: Notification) {
        guard !adjustingFrame, draggedWindow == nil, NSEvent.pressedMouseButtons == 0,
              let window = notification.object as? NSWindow else { return }
        finishedDragging(window)
    }

    func beganDragging(_ window: NSWindow) { draggedWindow = window }

    func finishedDragging(_ window: NSWindow) {
        guard !adjustingFrame, window === launcher || window === panel,
              let screen = FloatingWindowPlacement.screen(for: window.frame) else { return }
        draggedWindow = nil
        adjustingFrame = true
        window.setFrame(FloatingWindowPlacement.clamped(window.frame, to: screen.visibleFrame), display: true)
        adjustingFrame = false
        if window === launcher {
            launcherPositioned = true
            launcherPlacement.save(window.frame)
        } else {
            filesTopLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            filesPlacement.save(window.frame)
        }
        position()
    }

    static func preferredHeight(for route: MorningNavigation.Route, isEmpty: Bool = false) -> CGFloat {
        switch route {
        case .folders: return 640
        case .folder: return 480
        case .people, .person: return 560
        case .editFolder: return 260
        case .card: return 470   // three parts: what it is, what it means for you, what you can do
        case .editCard, .editPerson, .sources, .sourceRuns, .sourceRun, .latestRun: return 680
        case .attention: return 680   // the rest and the week
        }
    }

    /// The flight is a receipt: callers reach this only after the local save has succeeded.
    private func animateHandoff() {
        guard !hiddenForForegroundGrant, let destination = handoffDestination?() else { return }
        let physicalScreens = NSScreen.screens.filter {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value != VirtualDisplayWorkspace.activeDisplayID
        }
        guard physicalScreens.contains(where: { $0.frame.intersects(destination) }) else { return }
        flight?.orderOut(nil)
        flight?.close()
        let start = NSRect(x: panel.frame.midX - 56, y: panel.frame.midY - 38, width: 112, height: 76)
        let note = NSPanel(contentRect: start, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        note.level = .floating
        note.backgroundColor = .clear
        note.isOpaque = false
        note.hasShadow = true
        note.ignoresMouseEvents = true
        note.isReleasedWhenClosed = false
        note.hidesOnDeactivate = false
        note.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        note.sharingType = panel.sharingType
        note.contentView = NSHostingView(rootView:
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: "checkmark").foregroundStyle(Pad.penInk)
                RoundedRectangle(cornerRadius: 1).fill(Pad.inkSoft.opacity(0.3)).frame(height: 3)
                RoundedRectangle(cornerRadius: 1).fill(Pad.inkSoft.opacity(0.2)).frame(width: 48, height: 3)
            }.padding(14).frame(width: 112, height: 76)
                .background(Pad.tabPaper).clipShape(RoundedRectangle(cornerRadius: 6))
        )
        flight = note
        note.orderFrontRegardless()
        let endpoint = NSRect(x: destination.midX - 24, y: destination.midY - 18, width: 48, height: 36)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : 0.65
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { note.animator().setFrame(endpoint, display: true) }
            note.animator().alphaValue = 0
        } completionHandler: { [weak self, weak note] in
            MainActor.assumeIsolated {
                note?.orderOut(nil)
                note?.close()
                if self?.flight === note { self?.flight = nil }
            }
        }
    }
}

private final class MorningPanel: NSPanel {
    init(title: String, hideFromScreenShare: Bool) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 650, height: 680),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        self.title = title
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        sharingType = hideFromScreenShare ? .none : .readOnly
        animationBehavior = .utilityWindow
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
