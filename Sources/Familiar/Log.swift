import Foundation

enum Log {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let queue = DispatchQueue(label: "familiar.log")
    private static var handle: FileHandle? = {
        let url = Config.dir.appendingPathComponent("familiar.log")
        try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        h?.seekToEndOfFile()
        return h
    }()

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            FileHandle.standardError.write(line.data(using: .utf8)!)
            handle?.write(line.data(using: .utf8)!)
        }
    }
}
