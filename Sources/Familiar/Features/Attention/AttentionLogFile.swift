import Darwin
import Foundation

/// The attention ledger on disk: one JSON line per event, appended and never rewritten, in an owner-only folder.
/// Nothing here leaves the Mac. A line torn by a crash is skipped on read and sealed off before the next append.
struct AttentionLogFile {
    let url: URL

    /// Writes every line in one append, then fsyncs. The folder is kept 0700 and the file 0600. Every error it
    /// throws is a POSIX one, so a caller can report its number and nothing else.
    func append(_ events: [AttentionEvent]) throws {
        guard !events.isEmpty else { return }
        var lines = Data()
        do {
            for event in events {
                lines.append(try event.line())
                lines.append(Self.newline)
            }
        } catch {
            throw Self.error(url, EINVAL)   // a value JSON cannot hold, such as a NaN; nothing is written
        }
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        } catch {
            // Foundation wraps the POSIX error it met; a folder someone else owns is EPERM, not Cocoa's 513.
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            throw Self.error(url, underlying.flatMap { $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil } ?? EIO)
        }

        // Read access is only for checking the last byte; with O_APPEND every write still lands at the end.
        let descriptor = open(url.path, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.error(url) }
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else { throw Self.error(url) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Self.error(url) }
        if info.st_size > 0 {
            var last: UInt8 = 0
            guard pread(descriptor, &last, 1, info.st_size - 1) == 1 else { throw Self.error(url) }
            if last != Self.newline { lines.insert(Self.newline, at: lines.startIndex) }   // seal a torn line
        }
        try lines.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw Self.error(url) }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw Self.error(url) }
    }

    /// Every line that decodes, in file order. Torn lines, lines from a newer schema and unknown types are
    /// counted as skipped rather than failing the whole file. A missing file reads as empty.
    static func read(_ url: URL) -> (events: [AttentionEvent], skipped: Int) {
        guard let data = try? Data(contentsOf: url) else { return ([], 0) }
        var events: [AttentionEvent] = []
        var skipped = 0
        for line in data.split(separator: newline) {
            if let event = try? AttentionEvent(line: Data(line)) { events.append(event) } else { skipped += 1 }
        }
        return (events, skipped)
    }

    private static let newline = UInt8(ascii: "\n")

    /// The POSIX error, `errno` unless given. A caller reports only its number, never the file's content.
    private static func error(_ url: URL, _ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
}
