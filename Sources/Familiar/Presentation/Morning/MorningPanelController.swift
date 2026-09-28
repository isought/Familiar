import AppKit
import Combine
import SwiftUI
import QuartzCore

@MainActor final class MorningPanelController: NSObject {
    private let store: MorningStore
    private let navigation = MorningNavigation()
    private let launcher: MorningPanel
    private let panel: MorningPanel
    private var screenObservation: NSObjectProtocol?
    private var routeObservation: AnyCancellable?
    private var flight: NSPanel?
    private var hiddenForForegroundGrant = false
    private var contentsRequested = false
    var onHandoff: ((MorningWorkItem) -> Void)?
    var handoffDestination: (() -> NSRect?)?

    /// Only the little folder is shown at launch. Opening a file is always an explicit action.
    init(store: MorningStore, hideFromScreenShare: Bool) {
        self.store = store
        launcher = MorningPanel(title: "Morning folder", hideFromScreenShare: hideFromScreenShare)
        panel = MorningPanel(title: "Morning files", hideFromScreenShare: hideFromScreenShare)
        super.init()
        launcher.hasShadow = false
        launcher.contentView = NSHostingView(rootView: MorningLauncherView(store: store, open: { [weak self] in
            guard let self else { return }
            self.panel.isVisible ? self.hideContents() : self.show()
        }, people: { [weak self] in self?.showPeople() }))
        panel.contentView = NSHostingView(rootView: MorningFilesView(
            store: store, navigation: navigation,
            close: { [weak self] in self?.hideContents() },
            filed: { [weak self] in self?.animateHandoff() },
            handoff: { [weak self] item in
                self?.animateHandoff()
                self?.onHandoff?(item)
            }
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

    func show() {
        navigation.route = .folders
        openContents()
    }

    func showCard(id: UUID) {
        navigation.route = .card(id)
        openContents()
    }

    func showPeople() {
        navigation.route = .people
        openContents()
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

    private func openContents() {
        contentsRequested = true
        position()
        guard !hiddenForForegroundGrant else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    private func hideContents() { contentsRequested = false; panel.orderOut(nil) }

    private var userScreen: NSScreen? {
        let screens = NSScreen.screens.filter {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value != VirtualDisplayWorkspace.activeDisplayID
        }
        return screens.first { $0 === launcher.screen } ?? screens.first { $0 === NSScreen.main } ?? screens.first
    }

    private func position() {
        guard let visible = userScreen?.visibleFrame else { return }
        let icon = NSRect(x: visible.minX + 18, y: visible.maxY - 92, width: 86, height: 78)
        launcher.setFrame(icon, display: true)
        let width = min(CGFloat(650), visible.width - 36)
        let height = min(Self.preferredHeight(for: navigation.route, isEmpty: store.cards.isEmpty), visible.height - 118)
        panel.setFrame(NSRect(x: visible.minX + 18, y: icon.minY - height - 8, width: width, height: height), display: true)
    }

    static func preferredHeight(for route: MorningNavigation.Route, isEmpty: Bool = false) -> CGFloat {
        switch route {
        case .folders: return isEmpty ? 540 : 380
        case .folder: return 480
        case .people, .person: return 560
        case .editFolder: return 260
        case .card, .editCard, .editPerson: return 680
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
        sharingType = hideFromScreenShare ? .none : .readOnly
        animationBehavior = .utilityWindow
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
