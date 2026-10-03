import AppKit
import SwiftUI

/// Every watch with its items: a status dot per item (green as expected, red not as expected, grey couldn't check),
/// what isn't as expected in plain words and what the check said, when it was checked, and Why? and Open. A watch can be
/// checked now, paused, resumed, shown in the Finder or stopped here.
struct WatchListView: View {
    @ObservedObject var store: WatchListStore
    @ObservedObject var runner: WatchListRunner
    @ObservedObject var notifier: WatchListNotifier
    let onWhy: (UUID, String) -> Void
    @State private var problem: String?
    @State private var stopping: WatchListWatch?

    static let empty = "Nothing is being watched. Ask in chat: “watch these items: …”"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.watches.isEmpty && store.unreadable.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "eye").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text(Self.empty).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        notices
                        ForEach(store.watches) { watch in section(watch) }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 300)
        .confirmationDialog(stopping.map { "Stop watching “\($0.name)”?" } ?? "", isPresented: Binding(
            get: { stopping != nil }, set: { if !$0 { stopping = nil } }), titleVisibility: .visible, presenting: stopping) { watch in
            Button("Stop watching", role: .destructive) { stop(watch) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Noteling stops checking these items and won't notify you about them again. Its folder goes to the Trash, so you can put it back.")
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let off = notifier.offReason {
            Label(off, systemImage: "bell.slash").font(.callout).foregroundStyle(.orange)
        }
        if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
        ForEach(store.unreadable.keys.sorted(), id: \.self) { folder in
            HStack(alignment: .top) {
                Label("Not watching the “\(folder)” folder. \(store.unreadable[folder] ?? "")", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                Spacer(minLength: 8)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.directory.appendingPathComponent(folder)]) }
                    .controlSize(.small)
            }
        }
    }

    private func section(_ watch: WatchListWatch) -> some View {
        let checking = runner.checking.contains(watch.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(watch.name).font(.headline).lineLimit(2)
                    Text(Self.subtitle(watch, checking: checking)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Group {
                    Button(checking ? "Checking…" : "Check now") { runner.run(watch.id) }.disabled(checking)
                    Button(watch.paused ? "Resume" : "Pause") { change(watch) { $0.paused.toggle() } }
                    if let folder = store.folder(for: watch.id) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    }
                    Button("Stop watching") { stopping = watch }
                }
                .controlSize(.small)
            }
            if let problem = store.problems[watch.id] {
                Label(problem + " Until it's fixed, the watch keeps what it had.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            VStack(spacing: 0) {
                ForEach(Array(watch.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider() }
                    row(watch, item, checking: checking)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
    }

    private func row(_ watch: WatchListWatch, _ item: WatchListItem, checking: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            dot(item).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.label).lineLimit(2).textSelection(.enabled)
                Text(Self.words(item, fields: watch.fields, checking: checking)).font(.callout)
                    .foregroundStyle(item.isRed ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                if let why = Self.why(item) {
                    Text(why).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let checked = item.checkedAt {
                    Text("Checked " + Self.time(checked)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if item.needsExplaining { Button("Why?") { onWhy(watch.id, item.key) } }
            if let url = Self.openable(item) { Button("Open") { NSWorkspace.shared.open(url) } }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func dot(_ item: WatchListItem) -> some View {
        switch item.status {
        case .asExpected?: Circle().fill(Color.green).frame(width: 10, height: 10).accessibilityLabel("As expected")
        case .notAsExpected?: Circle().fill(Color.red).frame(width: 10, height: 10).accessibilityLabel("Not as expected")
        case .couldNotCheck?: Circle().fill(Color.gray).frame(width: 10, height: 10).accessibilityLabel("Couldn't check")
        case nil: Circle().stroke(Color.gray, lineWidth: 1.5).frame(width: 10, height: 10).accessibilityLabel("Not checked yet")
        }
    }

    private func change(_ watch: WatchListWatch, _ body: (inout WatchListWatch) -> Void) {
        do { try store.change(watch.id, body); problem = nil }
        catch { problem = error.localizedDescription }
    }

    private func stop(_ watch: WatchListWatch) {
        runner.cancel(watch.id)
        do { try store.remove(watch.id); problem = nil }
        catch { problem = error.localizedDescription }
    }

    // MARK: words

    /// The row's line: its differences in plain words, "As expected", why it couldn't check, or that it hasn't been yet;
    /// and what counts (or was named) but the check didn't report.
    static func words(_ item: WatchListItem, fields: [String]? = nil, checking: Bool) -> String {
        let unreported = item.unreported(named: fields).map(WatchListRules.label).joined(separator: ", ")
        switch item.status {
        case nil: return checking ? "Checking…" : "Not checked yet"
        case .asExpected?: return "As expected" + (unreported.isEmpty ? "" : " · not reported: " + unreported)
        case .notAsExpected(let differences)?:
            return (differences.map(\.words) + (unreported.isEmpty ? [] : ["Not reported: " + unreported])).joined(separator: "\n")
        case .couldNotCheck(let reason)?: return "Couldn't check: \(reason)"
        }
    }

    /// What the check said about the item in its own words, under the differences; nothing when it said nothing.
    static func why(_ item: WatchListItem) -> String? {
        item.whyNow.isEmpty ? nil : item.whyNow.joined(separator: "\n")
    }

    static func subtitle(_ watch: WatchListWatch, checking: Bool) -> String {
        let items = "\(watch.items.count) item\(watch.items.count == 1 ? "" : "s")"
        if watch.paused { return "Paused · \(items)" }
        let every = watch.everyWords.prefix(1).uppercased() + watch.everyWords.dropFirst()
        if checking { return "\(every) · \(items) · checking now" }
        return "\(every) · \(items) · " + (watch.lastRunAt.map { "last checked " + time($0) } ?? "not checked yet")
    }

    static func time(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Only web pages open from a check's answer: never a file or another app's link.
    static func openable(_ item: WatchListItem) -> URL? {
        guard let text = item.pageURL, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}

/// The Watch List window, opened from the menu bar's Watch List… and from the chat after a watch is created.
@MainActor
final class WatchListWindowController {
    private var window: NSWindow?
    private let store: WatchListStore
    private let runner: WatchListRunner
    private let notifier: WatchListNotifier
    /// Why? on a row: the app opens the chat on that item.
    var onWhy: ((UUID, String) -> Void)?

    init(store: WatchListStore, runner: WatchListRunner, notifier: WatchListNotifier) {
        self.store = store
        self.runner = runner
        self.notifier = notifier
    }

    func show(hideFromScreenShare: Bool) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Watch List"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 420, height: 300)
            window.contentView = NSHostingView(rootView: WatchListView(store: store, runner: runner, notifier: notifier,
                                                                       onWhy: { [weak self] watch, item in self?.onWhy?(watch, item) }))
            window.center()
            self.window = window
        }
        updateSharing(hideFromScreenShare)
        Task { await notifier.refresh() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func updateSharing(_ hideFromScreenShare: Bool) {
        window?.sharingType = hideFromScreenShare ? .none : .readOnly
    }

    func close() {
        window?.orderOut(nil)
        window?.close()
    }
}
