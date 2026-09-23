import Foundation

struct Config: Codable {
    var apiKey: String = ""
    var apiBaseURL: String = ""              // e.g. a corporate gateway; empty = api.anthropic.com
    var apiHeaders: [String: String] = [:]   // extra headers for the gateway
    var model: String = "claude-opus-5"
    var effort: String = "medium"
    var maxTokens: Int = 4096
    var watcherEnabled: Bool = true
    var watcherIntervalSeconds: Double = 2
    var maxImageLongEdge: Int = 1568
    var attachScreenshotOnText: Bool = true
    var screenshotReuseSeconds: Double = 0   // >0: reuse the last screenshot for follow-ups on the same screen within this window
    var hideFromScreenShare: Bool = false    // true = bubble invisible in screenshots, screen shares and recordings
    var toolsDir: String = ""                // empty = ~/.familiar/tools
    var docsStuffLimitChars: Int = 24000
    var uvPath: String = ""                  // empty = bundled uv, then ~/.local/bin, homebrew
    var wandHoldSeconds: Double = 0.8        // hold the bubble this long to charge the wand
    var hotkey: String = "control+option+space"
    var allowControl: Bool = false           // let Familiar move the mouse and type when asked to do something
    var env: [String: String] = [:]          // non-secret variables handed to every script (secrets go to the Keychain)
    var bubbleX: Double? = nil               // remembered bubble position (bottom-left, screen points)
    var bubbleY: Double? = nil

    static var dir: URL {
        if let h = ProcessInfo.processInfo.environment["FAMILIAR_HOME"], !h.isEmpty { return URL(fileURLWithPath: (h as NSString).expandingTildeInPath) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".familiar")
    }
    static var file: URL { dir.appendingPathComponent("config.json") }

    var resolvedApiKey: String? {
        if let k = Secrets.get("ANTHROPIC_API_KEY") { return k }
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
        return nil
    }

    var resolvedToolsDir: URL {
        toolsDir.isEmpty ? Config.dir.appendingPathComponent("tools") : URL(fileURLWithPath: (toolsDir as NSString).expandingTildeInPath)
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? d.apiKey
        apiBaseURL = try c.decodeIfPresent(String.self, forKey: .apiBaseURL) ?? d.apiBaseURL
        apiHeaders = try c.decodeIfPresent([String: String].self, forKey: .apiHeaders) ?? d.apiHeaders
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        effort = try c.decodeIfPresent(String.self, forKey: .effort) ?? d.effort
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? d.maxTokens
        watcherEnabled = try c.decodeIfPresent(Bool.self, forKey: .watcherEnabled) ?? d.watcherEnabled
        watcherIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .watcherIntervalSeconds) ?? d.watcherIntervalSeconds
        maxImageLongEdge = try c.decodeIfPresent(Int.self, forKey: .maxImageLongEdge) ?? d.maxImageLongEdge
        attachScreenshotOnText = try c.decodeIfPresent(Bool.self, forKey: .attachScreenshotOnText) ?? d.attachScreenshotOnText
        screenshotReuseSeconds = try c.decodeIfPresent(Double.self, forKey: .screenshotReuseSeconds) ?? d.screenshotReuseSeconds
        hideFromScreenShare = try c.decodeIfPresent(Bool.self, forKey: .hideFromScreenShare) ?? d.hideFromScreenShare
        toolsDir = try c.decodeIfPresent(String.self, forKey: .toolsDir) ?? d.toolsDir
        docsStuffLimitChars = try c.decodeIfPresent(Int.self, forKey: .docsStuffLimitChars) ?? d.docsStuffLimitChars
        uvPath = try c.decodeIfPresent(String.self, forKey: .uvPath) ?? d.uvPath
        wandHoldSeconds = try c.decodeIfPresent(Double.self, forKey: .wandHoldSeconds) ?? d.wandHoldSeconds
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        allowControl = try c.decodeIfPresent(Bool.self, forKey: .allowControl) ?? d.allowControl
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? d.env
        bubbleX = try c.decodeIfPresent(Double.self, forKey: .bubbleX)
        bubbleY = try c.decodeIfPresent(Double.self, forKey: .bubbleY)
    }

    /// One-time move of the pre-rename home folder (`~/.sidekick`) to `~/.familiar`.
    static func migrateLegacyHome() {
        let fm = FileManager.default
        let legacy = fm.homeDirectoryForCurrentUser.appendingPathComponent(".sidekick")
        guard !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) else { return }
        do {
            try fm.moveItem(at: legacy, to: dir)
            let oldLog = dir.appendingPathComponent("sidekick.log")
            if fm.fileExists(atPath: oldLog.path) { try? fm.moveItem(at: oldLog, to: dir.appendingPathComponent("familiar.log")) }
        } catch {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func load() -> Config {
        migrateLegacyHome()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file), let cfg = try? JSONDecoder().decode(Config.self, from: data) {
            cfg.save()   // rewrite so new keys show up with defaults
            return cfg
        }
        let cfg = Config()
        cfg.save()
        return cfg
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: Config.file)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Config.file.path)
        }
    }
}
