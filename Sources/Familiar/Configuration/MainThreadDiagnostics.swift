import Darwin
import Foundation

/// Pure monotonic-clock state, kept separate from timers and process sampling so
/// the watchdog's once-per-episode behavior can be tested without hanging an app.
struct MainThreadStallDetector {
    struct Poll: Equatable {
        var heartbeat: UInt64?
        var stalledFor: TimeInterval?
    }
    private struct Pending {
        let token: UInt64
        let enqueuedAt: TimeInterval
        var reported = false
    }
    let threshold: TimeInterval
    let suspensionGap: TimeInterval
    private var pending: Pending?
    private var nextToken: UInt64 = 0
    private var previousPoll: TimeInterval?

    init(threshold: TimeInterval = 3, suspensionGap: TimeInterval = 5) {
        self.threshold = threshold
        self.suspensionGap = suspensionGap
    }

    mutating func poll(at now: TimeInterval) -> Poll {
        // A sleeping/suspended process did not get a chance to service either
        // queue. Start a fresh observation instead of diagnosing that as a hang.
        if let previousPoll, now - previousPoll > suspensionGap { pending = nil }
        previousPoll = now
        if var current = pending {
            guard !current.reported, now - current.enqueuedAt >= threshold else { return Poll() }
            current.reported = true
            pending = current
            return Poll(stalledFor: now - current.enqueuedAt)
        }
        nextToken &+= 1
        pending = Pending(token: nextToken, enqueuedAt: now)
        return Poll(heartbeat: nextToken)
    }

    /// Returns a recovery duration only for an episode that was actually reported.
    mutating func acknowledge(_ token: UInt64, at now: TimeInterval) -> TimeInterval? {
        guard let current = pending, current.token == token else { return nil }
        pending = nil
        return current.reported ? max(0, now - current.enqueuedAt) : nil
    }
}

/// Explicitly started by the installed app. Marks accept only fixed phase names
/// and counts; prompts, replies, URLs, screenshots and credentials cannot enter
/// these diagnostic breadcrumbs. All disk and sampler work stays off the main queue.
final class MainThreadDiagnostics: @unchecked Sendable {
    enum Phase: String, Codable {
        case appReady, chatSubmitted, contextReady, executionStarted
        case providerReplyReceived, executionReturned, presentationStarted
        case transcriptUpdated, requestFinished, chatPanelShown, chatScrollRequested
        case taskPanelUpdated, watchReviewShown
    }
    static let shared = MainThreadDiagnostics()

    private struct Breadcrumb: Codable {
        let at: Date
        let phase: Phase
        let itemCount: Int?
        let characterCount: Int?
    }
    private struct Event: Codable {
        let at: Date
        let kind: String
        let blockedSeconds: TimeInterval?
        let phase: Phase?
        let itemCount: Int?
        let characterCount: Int?
        let recentPhases: [Breadcrumb]?
        let report: String?
    }

    private let lock = NSLock()
    private let heartbeatQueue = DispatchQueue(label: "familiar.main-heartbeat", qos: .utility)
    private let ioQueue = DispatchQueue(label: "familiar.hang-diagnostics", qos: .utility)
    private let samplerQueue = DispatchQueue(label: "familiar.hang-sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var detector = MainThreadStallDetector()
    private var generation: UInt64 = 0
    private var samplingActive = false
    private var breadcrumbs: [Breadcrumb] = []
    private let directory: URL
    private let maximumReports = 5
    private let maximumReportBytes = 2 * 1024 * 1024
    private let maximumLogBytes = 256 * 1024

    init(directory: URL = Config.dir.appendingPathComponent("diagnostics/main-thread", isDirectory: true)) {
        self.directory = directory
    }

    func start() {
        lock.lock()
        guard timer == nil else { lock.unlock(); return }
        generation &+= 1
        let session = generation
        detector = MainThreadStallDetector()
        let source = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        timer = source
        source.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.tick(session: session) }
        source.resume()
        lock.unlock()
    }

    func stop() {
        lock.lock()
        generation &+= 1
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }

    /// Cheap enough for transition points on the main thread. The in-memory ring
    /// survives a later UI stall; formatting and appending happen on the IO queue.
    func mark(_ phase: Phase, itemCount: Int? = nil, characterCount: Int? = nil) {
        let breadcrumb = Breadcrumb(at: Date(), phase: phase,
            itemCount: itemCount.map { max(0, $0) }, characterCount: characterCount.map { max(0, $0) })
        lock.lock()
        guard timer != nil else { lock.unlock(); return }
        breadcrumbs.append(breadcrumb)
        if breadcrumbs.count > 20 { breadcrumbs.removeFirst(breadcrumbs.count - 20) }
        lock.unlock()
        enqueue(Event(at: breadcrumb.at, kind: "phase", blockedSeconds: nil, phase: phase,
            itemCount: breadcrumb.itemCount, characterCount: breadcrumb.characterCount,
            recentPhases: nil, report: nil))
    }

    private func tick(session: UInt64) {
        lock.lock()
        guard timer != nil, generation == session else { lock.unlock(); return }
        let observation = detector.poll(at: ProcessInfo.processInfo.systemUptime)
        let recent = breadcrumbs
        let shouldSample = observation.stalledFor != nil && !samplingActive
        if shouldSample { samplingActive = true }
        lock.unlock()
        if let token = observation.heartbeat {
            // Exactly one heartbeat is outstanding, so a blocked main thread
            // cannot accumulate an unbounded list of watchdog callbacks.
            DispatchQueue.main.async { [weak self] in self?.acknowledge(token, session: session) }
        }
        if let duration = observation.stalledFor {
            let report = shouldSample ? "stall-\(Self.timestamp(Date()))-\(UUID().uuidString.prefix(8)).sample.txt" : nil
            let event = Event(at: Date(), kind: "main-thread-stalled", blockedSeconds: duration,
                phase: recent.last?.phase, itemCount: recent.last?.itemCount,
                characterCount: recent.last?.characterCount, recentPhases: recent, report: report)
            ioQueue.async { [weak self] in
                guard let self else { return }
                self.append(event) // Persist the timeout before starting a subprocess.
                Log.info("[main-thread] stalled duration=\(String(format: "%.1f", duration))s phase=\(recent.last?.phase.rawValue ?? "none") report=\(report ?? "sampler-busy")")
                if let report { self.samplerQueue.async { [weak self] in self?.sample(report: report) } }
            }
        }
    }

    private func acknowledge(_ token: UInt64, session: UInt64) {
        lock.lock()
        guard timer != nil, generation == session else { lock.unlock(); return }
        let duration = detector.acknowledge(token, at: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        if let duration {
            enqueue(Event(at: Date(), kind: "main-thread-recovered", blockedSeconds: duration,
                phase: nil, itemCount: nil, characterCount: nil, recentPhases: nil, report: nil))
        }
    }

    private func enqueue(_ event: Event) {
        ioQueue.async { [weak self] in self?.append(event) }
    }

    private func append(_ event: Event) {
        do {
            try prepareDirectory()
            let url = directory.appendingPathComponent("events.jsonl")
            let fm = FileManager.default
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
               size.intValue >= maximumLogBytes {
                let previous = directory.appendingPathComponent("events.previous.jsonl")
                try? fm.removeItem(at: previous)
                try fm.moveItem(at: url, to: previous)
            }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var bytes = try encoder.encode(event)
            bytes.append(0x0A)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
            if event.kind == "main-thread-stalled" { try handle.synchronize() }
        } catch {
            Log.info("[main-thread] diagnostic-write-failed")
        }
    }

    private func sample(report: String) {
        defer { lock.lock(); samplingActive = false; lock.unlock() }
        let destination = directory.appendingPathComponent(report)
        do {
            try prepareDirectory()
            rotateReports()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "2", "10", "-file", destination.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let terminated = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in terminated.signal() }
            try process.run()
            var timedOut = false
            if terminated.wait(timeout: .now() + 8) == .timedOut {
                timedOut = true
                if process.isRunning { process.terminate() }
                if terminated.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = terminated.wait(timeout: .now() + 1)
                }
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            limitReportSize(destination)
            let succeeded = !timedOut && !process.isRunning && process.terminationStatus == 0
            enqueue(Event(at: Date(), kind: succeeded ? "sample-saved" : timedOut ? "sample-timed-out" : "sample-failed",
                blockedSeconds: nil, phase: nil, itemCount: nil, characterCount: nil, recentPhases: nil, report: report))
        } catch {
            enqueue(Event(at: Date(), kind: "sample-unavailable", blockedSeconds: nil,
                phase: nil, itemCount: nil, characterCount: nil, recentPhases: nil, report: report))
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    private func rotateReports() {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("stall-") && $0.lastPathComponent.hasSuffix(".sample.txt") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files.prefix(max(0, files.count - maximumReports + 1)) { try? fm.removeItem(at: file) }
    }

    private func limitReportSize(_ url: URL) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
              size.intValue > maximumReportBytes,
              let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        try? handle.truncate(atOffset: UInt64(maximumReportBytes))
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }
}
