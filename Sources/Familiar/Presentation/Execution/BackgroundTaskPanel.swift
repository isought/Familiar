import AppKit
import Combine
import SwiftUI

@MainActor final class BackgroundTaskPanelController: NSObject, NSWindowDelegate {
    private let store: BackgroundTaskStore
    private let panel: BackgroundTaskPanel
    private var observation: AnyCancellable?
    private var focusObservation: AnyCancellable?
    private var morningObservation: AnyCancellable?
    private var screenObservation: NSObjectProtocol?
    private var hiddenForForegroundGrant = false
    private var requestedVisible = false
    private var expanded = false
    private var positioned = false
    private var adjustingFrame = false

    init(store: BackgroundTaskStore, hideFromScreenShare: Bool, morning: MorningStore? = nil,
         onCancelQueued: ((UUID) -> Void)? = nil, onOpenCard: ((UUID) -> Void)? = nil) {
        self.store = store
        panel = BackgroundTaskPanel(hideFromScreenShare: hideFromScreenShare)
        super.init()
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: BackgroundTaskPanelView(store: store, feed: store.feed,
            onCancelQueued: onCancelQueued, onOpenCard: onOpenCard))
        if let morning {
            store.syncMorning(morning.workItems, message: morning.queueMessage)
            morningObservation = morning.$workspace.combineLatest(morning.$queueMessage)
                .receive(on: RunLoop.main).sink { [weak store] workspace, message in
                    store?.syncMorning(workspace.workItems, message: message)
                }
        }
        observation = store.$isVisible.combineLatest(store.$isExpanded)
            // Published emits before storing its value. Resizing synchronously can force SwiftUI
            // to lay out the old compact body, leaving a completed task blank until another update.
            .receive(on: RunLoop.main)
            .sink { [weak self] visible, expanded in
                guard let self else { return }
                self.requestedVisible = visible
                self.expanded = expanded
                self.updatePanel()
            }
        focusObservation = store.explicitOpenRequests.receive(on: RunLoop.main).sink { [weak self] in
            guard let self, self.store.isVisible, !self.hiddenForForegroundGrant else { return }
            // A deliberate Open can accept keyboard focus without activating Familiar or its chat.
            // Do not retain this intent: restoring the panel after a mouse grant must stay passive.
            self.requestedVisible = self.store.isVisible
            self.expanded = self.store.isExpanded
            self.updatePanel()
            self.panel.makeKeyAndOrderFront(nil)
        }
        screenObservation = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePanel() }
        }
    }

    func setHiddenForForegroundGrant(_ hidden: Bool) {
        hiddenForForegroundGrant = hidden
        updatePanel()
    }

    func updateSharing(_ hideFromScreenShare: Bool) {
        panel.sharingType = hideFromScreenShare ? .none : .readOnly
    }

    /// A handoff can animate toward the dock before the visibility subscriber runs.
    var landingFrame: NSRect? {
        guard let visible = presentationScreen?.visibleFrame else { return nil }
        if positioned { return clamped(panel.frame, to: visible) }
        return NSRect(x: visible.maxX - 340, y: visible.maxY - 104, width: 320, height: 84)
    }

    func close() {
        observation?.cancel()
        observation = nil
        focusObservation?.cancel()
        focusObservation = nil
        morningObservation?.cancel()
        morningObservation = nil
        if let screenObservation { NotificationCenter.default.removeObserver(screenObservation) }
        screenObservation = nil
        panel.orderOut(nil)
        panel.close()
    }

    func windowDidMove(_ notification: Notification) {
        // Allow the drag to cross between displays; constrain the final position after mouse-up.
        guard !adjustingFrame, NSEvent.pressedMouseButtons == 0 else { return }
        keepOnScreen()
    }

    fileprivate func finishedDragging() { keepOnScreen() }

    private func updatePanel() {
        guard requestedVisible, !hiddenForForegroundGrant else {
            panel.orderOut(nil)
            return
        }
        let size = expanded ? NSSize(width: 360, height: 400) : NSSize(width: 320, height: 84)
        let visible = presentationScreen?.visibleFrame
        var frame = panel.frame
        if !positioned, let visible {
            frame = NSRect(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20,
                           width: size.width, height: size.height)
            positioned = true
        } else {
            frame = NSRect(x: frame.maxX - size.width, y: frame.maxY - size.height,
                           width: size.width, height: size.height)
        }
        adjustingFrame = true
        panel.setFrame(clamped(frame, to: visible), display: true)
        adjustingFrame = false
        panel.orderFrontRegardless()
    }

    private func keepOnScreen() {
        let frame = clamped(panel.frame, to: presentationScreen?.visibleFrame)
        guard frame != panel.frame else { return }
        adjustingFrame = true
        panel.setFrame(frame, display: true)
        adjustingFrame = false
    }

    private func clamped(_ frame: NSRect, to visible: NSRect?) -> NSRect {
        guard let visible else { return frame }
        var result = frame
        result.size.width = min(result.width, visible.width)
        result.size.height = min(result.height, visible.height)
        result.origin.x = min(max(result.minX, visible.minX), visible.maxX - result.width)
        result.origin.y = min(max(result.minY, visible.minY), visible.maxY - result.height)
        return result
    }

    /// The preview belongs on a user's display even when the target's key window
    /// makes AppKit's `main` screen point at Familiar's virtual workspace.
    private var presentationScreen: NSScreen? {
        let screens = NSScreen.screens.filter {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value != VirtualDisplayWorkspace.activeDisplayID
        }
        return screens.first { $0 === panel.screen } ?? screens.first { $0 === NSScreen.main } ?? screens.first
    }
}

private final class BackgroundTaskPanel: NSPanel {
    init(hideFromScreenShare: Bool) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 84),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        title = "Background Tasks"
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

/// Compact execution status is always useful; screenshots and results are available only when opened.
struct BackgroundTaskPanelView: View {
    @ObservedObject var store: BackgroundTaskStore
    @ObservedObject var feed: PeekFeed
    var onCancelQueued: ((UUID) -> Void)? = nil
    var onOpenCard: ((UUID) -> Void)? = nil

    private var showingLive: Bool { store.isShowingActiveTask }
    private var needsDecision: Bool {
        guard showingLive else { return false }
        switch feed.phase {
        case .asking, .confirming: return true
        default: return false
        }
    }
    private var title: String {
        showingLive ? store.activeTask?.title ?? "Background task"
            : store.selectedRecord?.title ?? store.selectedMorningWork?.action.title ?? "Background tasks"
    }
    private var state: String {
        guard showingLive else {
            return store.selectedRecord?.outcome.label ?? store.selectedMorningWork?.status.label ?? "Ready"
        }
        switch feed.phase {
        case .asking, .confirming: return "Needs you"
        case .thinking: return "Thinking"
        case .foreground: return "Using the desktop"
        case .done: return "Finishing"
        case .stopped: return "Stopping"
        case .idle, .working: return "Working"
        }
    }
    private var stateColor: Color {
        if needsDecision { return Color(red: 0.65, green: 0.34, blue: 0.07) }
        if store.selectedRecord?.outcome == .failed { return Pad.redInk }
        return showingLive ? Pad.penInk : Pad.inkSoft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            statusRow
            if store.isExpanded {
                Divider().overlay(Pad.tabEdge.opacity(0.4)).padding(.top, 10)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if showingLive {
                            PeekNoteView(feed: feed, decisionFirst: true, showsStop: false)
                        } else if let record = store.selectedRecord {
                            result(record)
                        } else if let work = store.selectedMorningWork {
                            savedWork(work)
                        }
                        if let message = store.queueMessage {
                            Text(message).font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if store.queuedCount > 0 {
                            queue
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                if let active = store.activeTask, !showingLive {
                    Button { store.selectTask(id: active.id) } label: {
                        Label("Back to current task", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Pad.penInk)
                    .padding(.horizontal, 14).padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LinearGradient(colors: [Pad.tabPaper, Pad.fieldPaper], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Pad.tabEdge.opacity(0.65), lineWidth: 1))
        .foregroundStyle(Pad.ink)
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(Pad.penInk)
                Text("Background task").font(HandFont.font(size: 13))
                Spacer(minLength: 0)
            }
            .background(TaskPanelDragArea())
            historyMenu
            Button { store.toggleExpanded() } label: {
                Image(systemName: store.isExpanded ? "chevron.up" : "chevron.down")
            }
            .help(store.isExpanded ? "Collapse task" : "Open task")
            .accessibilityLabel(store.isExpanded ? "Collapse task" : "Open task")
            Button { store.dismiss() } label: { Image(systemName: "xmark") }
                .help(showingLive ? "Hide task · execution continues" : "Hide task")
                .accessibilityLabel(showingLive ? "Hide task; execution continues" : "Hide task")
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Pad.inkSoft)
        .padding(.horizontal, 14).padding(.top, 10)
    }

    private var statusRow: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 5) {
                    Circle().fill(stateColor).frame(width: 5, height: 5)
                    Text(state).foregroundStyle(stateColor)
                    if showingLive, feed.step > 0 {
                        Text("· step \(feed.step)").foregroundStyle(Pad.inkSoft)
                    } else if let record = store.selectedRecord {
                        Text("· \(duration(record.elapsed))").foregroundStyle(Pad.inkSoft)
                    }
                    if store.queuedCount > 0 {
                        Text("· \(store.queuedCount) waiting").foregroundStyle(Pad.inkSoft)
                    }
                }
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if needsDecision && !store.isExpanded {
                Button("Review") { store.toggleExpanded() }
                    .buttonStyle(TaskActionStyle(accent: true))
            }
            if showingLive {
                Button("Stop") { feed.onStop?() }
                    .buttonStyle(TaskActionStyle(accent: false))
                    .help("Stop this task")
            } else if !store.isExpanded {
                Button("View") { store.toggleExpanded() }
                    .buttonStyle(TaskActionStyle(accent: false))
            }
        }
        .padding(.horizontal, 14).padding(.top, 9)
    }

    private var historyMenu: some View {
        Menu {
            if let active = store.activeTask {
                Button("Working · \(menuTitle(active.title))") { store.selectTask(id: active.id) }
                if !store.history.isEmpty { Divider() }
            }
            ForEach(store.history) { record in
                Button("\(record.outcome.label) · \(menuTitle(record.title))") { store.selectTask(id: record.id) }
            }
            let saved = store.morningWork.reversed().filter { item in
                item.id != store.activeTask?.id && !store.history.contains(where: { $0.id == item.id })
            }
            if !saved.isEmpty {
                Divider()
                ForEach(saved) { item in
                    Button("\(item.status.label) · \(menuTitle(item.action.title))") { store.selectTask(id: item.id) }
                }
            }
            if !store.hasTasks { Text("No recent tasks") }
        } label: { Image(systemName: "clock.arrow.circlepath") }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recent background tasks")
        .accessibilityLabel("Recent background tasks")
    }

    private func result(_ record: BackgroundTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TaskResultText(text: record.text.isEmpty ? record.outcome.label : record.text)
                .font(.system(size: 12.5)).lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let frame = record.frame {
                Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Pad.tabEdge.opacity(0.6)))
                    .accessibilityLabel("Last view of \(record.appName.isEmpty ? "the task window" : record.appName)")
            }
            if !record.metaLine.isEmpty {
                Text(record.metaLine).font(.system(size: 10.5)).foregroundStyle(Pad.inkSoft)
            }
            if let work = store.morningWork.first(where: { $0.id == record.id }) {
                openCardButton(work)
                Text(!work.status.isPending && work.result == record.text
                     ? "The result is saved with your file."
                     : "This result is available in this session. It has not been saved with your file.")
                    .font(.system(size: 10)).foregroundStyle(Pad.inkSoft)
            } else {
                Text("Recent tasks are kept until Familiar quits.")
                    .font(.system(size: 10)).foregroundStyle(Pad.inkSoft)
            }
        }
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            Text("Waiting for Familiar").font(.system(size: 11, weight: .semibold)).foregroundStyle(Pad.inkSoft)
            ForEach(store.morningWork.filter { $0.status == .queued }) { item in
                HStack(alignment: .top, spacing: 8) {
                    Button { store.selectTask(id: item.id) } label: {
                        Text(item.action.title).font(.system(size: 11)).multilineTextAlignment(.leading)
                    }.buttonStyle(.plain)
                    Spacer(minLength: 0)
                    Button { onCancelQueued?(item.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).font(.system(size: 9, weight: .semibold))
                        .accessibilityLabel("Cancel queued task: \(item.action.title)")
                }
            }
        }
    }

    private func savedWork(_ item: MorningWorkItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TaskResultText(text: item.result.isEmpty ? item.action.instruction : item.result)
                .font(.system(size: 12.5)).lineSpacing(3).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.status == .queued {
                Text("Saved in the queue. Familiar runs one task at a time when it’s ready.")
                    .font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
                Button("Cancel this task") { onCancelQueued?(item.id) }
                    .buttonStyle(TaskActionStyle(accent: false))
            }
            openCardButton(item)
        }
    }

    private func openCardButton(_ item: MorningWorkItem) -> some View {
        Button { onOpenCard?(item.cardID) } label: {
            Label("Open original file", systemImage: "doc.text")
                .font(.system(size: 11, weight: .medium))
        }.buttonStyle(.plain).foregroundStyle(Pad.penInk)
    }

    private func duration(_ elapsed: TimeInterval) -> String {
        let seconds = Int(elapsed)
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    private func menuTitle(_ title: String) -> String {
        title.count > 46 ? String(title.prefix(45)) + "…" : title
    }

}

private struct TaskActionStyle: ButtonStyle {
    var accent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 10.5, weight: .semibold)).fixedSize()
            .padding(.horizontal, 9).padding(.vertical, 5)
            .foregroundStyle(accent ? Color.white : Pad.ink)
            .background(accent ? Pad.penInk : Pad.paperDeep.opacity(configuration.isPressed ? 0.6 : 0.3),
                        in: RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct TaskPanelDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            window.performDrag(with: event)
            (window.delegate as? BackgroundTaskPanelController)?.finishedDragging()
        }
    }
}
