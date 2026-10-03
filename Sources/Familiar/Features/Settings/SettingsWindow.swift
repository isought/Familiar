import FamiliarRuntime
import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published var connectionMode = "api" {
        didSet { if connectionMode == "api" { loadAPIKeyIfNeeded() } }
    }
    @Published var claudePath = "" {
        didSet { connectionStatus = "" }
    }
    @Published var claudeModel = ""
    @Published var claudeEffort = "medium"
    @Published var connectionStatus = ""
    @Published var checkingConnection = false
    @Published var apiKey = ""
    @Published var model = ""
    @Published var effort = "medium"
    @Published var apiBaseURL = ""
    @Published var hotkey = ""
    @Published var wandHoldSeconds = 0.8
    @Published var attachScreenshotOnText = true
    @Published var screenshotMode = "auto"
    @Published var hideFromScreenShare = false
    @Published var notesShortcut = true
    @Published var startAtLogin = false
    @Published var allowControl = false
    @Published var controlInBackground = true
    @Published var backgroundVirtualDisplay = false
    @Published var backgroundPreciseClicks = false
    @Published var mascotStyle = "innocent"
    @Published var packSecrets: [PackSecret] = []
    @Published var toolsRepo = ""
    @Published var toolsRepoToken = ""
    @Published var message = ""

    struct PackSecret: Identifiable {
        let id: String            // env var name
        let packNames: [String]
        var value: String
    }

    var toolsDir = ""
    var toolsRepoBranch = "main"
    private var savedToolsRepo = ""
    private var savedToolsRepoToken = ""
    private var loadedConfig = Config()
    private var apiKeyLoaded = false

    /// The team-tools address or token differ from what is saved.
    var toolsRepoChanged: Bool {
        toolsRepo.trimmingCharacters(in: .whitespacesAndNewlines) != savedToolsRepo
            || toolsRepoToken.trimmingCharacters(in: .whitespacesAndNewlines) != savedToolsRepoToken
    }

    private func loadAPIKeyIfNeeded() {
        guard !apiKeyLoaded else { return }
        apiKey = loadedConfig.apiKey.isEmpty ? (Secrets.get("ANTHROPIC_API_KEY") ?? "") : loadedConfig.apiKey
        apiKeyLoaded = true
    }

    func load(config: Config, packs: [ToolPack]) {
        loadedConfig = config
        apiKeyLoaded = false
        apiKey = config.apiKey
        connectionMode = config.connectionMode == "claudeCode" ? "claudeCode" : "api"
        claudePath = config.claudePath
        claudeModel = config.claudeModel
        claudeEffort = ["low", "medium", "high"].contains(config.effort) ? config.effort : "high"
        connectionStatus = ""
        model = config.model
        effort = config.effort
        apiBaseURL = config.apiBaseURL
        hotkey = config.hotkey
        wandHoldSeconds = config.wandHoldSeconds
        attachScreenshotOnText = config.attachScreenshotOnText
        screenshotMode = config.screenshotMode
        hideFromScreenShare = config.hideFromScreenShare
        notesShortcut = config.notesShortcut
        startAtLogin = SMAppService.mainApp.status == .enabled
        allowControl = config.allowControl
        controlInBackground = config.controlInBackground
        backgroundVirtualDisplay = config.backgroundVirtualDisplay
        backgroundPreciseClicks = config.backgroundPreciseClicks
        mascotStyle = config.mascotStyle
        toolsDir = config.resolvedToolsDir.path
        toolsRepo = config.toolsRepo
        toolsRepoBranch = LinkedToolsUpdater.branch(config)
        toolsRepoToken = Secrets.get(LinkedTools.tokenKey) ?? ""
        savedToolsRepo = toolsRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        savedToolsRepoToken = toolsRepoToken
        var byKey: [String: [String]] = [:]
        for p in packs { for k in p.requires { byKey[k, default: []].append(p.name) } }
        packSecrets = byKey.keys.sorted().map { key in
            var value = Secrets.get(key) ?? ""
            if value.isEmpty {   // legacy: a bare `token` file inside a pack folder that needs this key
                for p in packs where p.requires.contains(key) {
                    if let t = try? String(contentsOf: p.dir.appendingPathComponent("token"), encoding: .utf8),
                       let first = t.split(separator: "\n").first, !first.contains("=") { value = first.trimmingCharacters(in: .whitespaces); break }
                }
            }
            return PackSecret(id: key, packNames: byKey[key] ?? [], value: value)
        }
        message = ""
    }

    func checkConnection() async {
        guard !checkingConnection else { return }
        checkingConnection = true
        connectionStatus = ""
        defer { checkingConnection = false }
        var config = loadedConfig
        config.connectionMode = "claudeCode"
        config.claudePath = claudePath.trimmingCharacters(in: .whitespacesAndNewlines)
        config.claudeModel = claudeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        config.effort = claudeEffort
        let checkedPath = claudePath
        let status = await ClaudeCodeClient.authenticationStatus(config: config)
        if claudePath == checkedPath { connectionStatus = status }
    }

    /// Returns the updated config; secrets go to the Keychain, never into the file.
    func save(into config: Config) -> Config {
        var c = config
        message = ""
        c.connectionMode = connectionMode
        c.claudePath = claudePath.trimmingCharacters(in: .whitespacesAndNewlines)
        c.claudeModel = claudeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if connectionMode == "api" {
            if Secrets.set("ANTHROPIC_API_KEY", apiKey) {
                c.apiKey = ""
            } else {
                message = "Could not save the API key to the Keychain."
            }
        }
        c.model = model.trimmingCharacters(in: .whitespaces)
        c.effort = connectionMode == "claudeCode" ? claudeEffort : effort
        c.apiBaseURL = apiBaseURL.trimmingCharacters(in: .whitespaces)
        c.hotkey = hotkey.trimmingCharacters(in: .whitespaces)
        c.wandHoldSeconds = max(0.3, min(3, wandHoldSeconds))
        c.attachScreenshotOnText = screenshotMode != "never"
        c.screenshotMode = screenshotMode
        c.hideFromScreenShare = hideFromScreenShare
        c.notesShortcut = notesShortcut
        c.allowControl = allowControl
        c.controlInBackground = controlInBackground
        c.backgroundVirtualDisplay = backgroundVirtualDisplay
        c.backgroundPreciseClicks = backgroundPreciseClicks
        c.mascotStyle = mascotStyle
        for s in packSecrets where !Secrets.set(s.id, s.value) { message = "Could not save \(s.id) to the Keychain." }
        c.toolsRepo = RepoAddress.cleaned(toolsRepo)   // the plain address: credentials pasted into it are never kept
        toolsRepo = c.toolsRepo
        savedToolsRepo = c.toolsRepo
        if Secrets.set(LinkedTools.tokenKey, toolsRepoToken) {
            savedToolsRepoToken = toolsRepoToken.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            message = "Could not save the team tools token to the Keychain."
        }
        do {
            if startAtLogin, SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            if !startAtLogin, SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Start at login: \(error.localizedDescription)"
        }
        c.save()
        if message.isEmpty { message = "Saved." }
        return c
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    var linkedTools: LinkedToolsUpdater?
    let onSave: () -> Void
    let onOpenTools: () -> Void
    let onReloadTools: () -> Void

    var body: some View {
        Form {
            Section("Claude") {
                Picker("Connection", selection: $model.connectionMode) {
                    Text("API key").tag("api")
                    Text("Local Claude CLI").tag("claudeCode")
                }
                if model.connectionMode == "claudeCode" {
                    Text("Uses your installed Claude Code and its existing login. Requests share your Claude Code usage allowance.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Claude executable (optional)", text: $model.claudePath, prompt: Text("Find automatically"))
                    TextField("Model (optional)", text: $model.claudeModel, prompt: Text("Claude Code default"))
                    Picker("Effort", selection: $model.claudeEffort) {
                        ForEach(["low", "medium", "high"], id: \.self) { Text($0) }
                    }
                    HStack {
                        Text("To sign in, run `claude auth login` in Terminal.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(model.checkingConnection ? "Checking…" : "Check connection") {
                            Task { await model.checkConnection() }
                        }
                        .disabled(model.checkingConnection)
                    }
                    if !model.connectionStatus.isEmpty {
                        Text(model.connectionStatus).font(.caption).textSelection(.enabled)
                    }
                } else {
                    SecureField("API key", text: $model.apiKey)
                    TextField("Model", text: $model.model)
                    Picker("Effort", selection: $model.effort) {
                        ForEach(["low", "medium", "high", "xhigh", "max"], id: \.self) { Text($0) }
                    }
                    TextField("Gateway base URL (optional)", text: $model.apiBaseURL, prompt: Text("https://api.anthropic.com"))
                }
            }
            Section("Team tools from GitHub") {
                TextField("Repository", text: $model.toolsRepo, prompt: Text(RepoAddress.example))
                SecureField("Token", text: $model.toolsRepoToken)
                if let linkedTools { LinkedToolsRow(updater: linkedTools, model: model, onSave: onSave) }
                Text("Noteling keeps a copy of this repository's \(model.toolsRepoBranch) branch and checks for changes every 10 minutes. A tool in your own folder with the same name wins.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tool packs") {
                if model.packSecrets.isEmpty {
                    Text("No pack declares a required secret. Add `requires: [NAME]` to a pack's SKILL.md and it will appear here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach($model.packSecrets) { $s in
                    VStack(alignment: .leading, spacing: 2) {
                        SecureField(s.id, text: $s.value)
                        Text("used by " + s.packNames.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(model.toolsDir).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Open folder", action: onOpenTools)
                    Button("Reload", action: onReloadTools)
                }
            }
            Section("Behaviour") {
                TextField("Pen hotkey", text: $model.hotkey, prompt: Text("control+option+space"))
                HStack {
                    Text("Hold to pick up the pen")
                    Slider(value: $model.wandHoldSeconds, in: 0.3...2.0, step: 0.1)
                    Text(String(format: "%.1fs", model.wandHoldSeconds)).monospacedDigit().frame(width: 36)
                }
                Picker("Screenshot with typed questions", selection: $model.screenshotMode) {
                    Text("Auto (when the question is about the screen)").tag("auto")
                    Text("Always").tag("always")
                    Text("Never").tag("never")
                }
                Toggle("Hide the bubble from screenshots and screen shares", isOn: $model.hideFromScreenShare)
                Toggle("Press ⌥ Option twice to show or hide your notes on the screen", isOn: $model.notesShortcut)
                Toggle("Start Noteling at login", isOn: $model.startAtLogin)
                Toggle("Allow Noteling to control the mouse and keyboard when asked", isOn: $model.allowControl)
                Toggle("Do things in the window you asked from, keeping your mouse and keyboard", isOn: $model.controlInBackground)
                    .disabled(!model.allowControl)
                Toggle("Use a separate display for background tasks (experimental)", isOn: $model.backgroundVirtualDisplay)
                    .disabled(!model.allowControl || !model.controlInBackground)
                Text("Moves the task window off your screen while Noteling works. Returns it when the task ends.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Precise clicks in the background (experimental)", isOn: $model.backgroundPreciseClicks)
                    .disabled(!model.allowControl || !model.controlInBackground)
                Text("Lets Noteling click exact spots in a window behind your work through a private macOS path. Off, it only presses controls it can name and asks for the mouse for anything else.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Character brows", selection: $model.mascotStyle) {
                    Text("Innocent").tag("innocent")
                    Text("Innocent v1").tag("innocentV1")
                    Text("Innocent v3 (experiment)").tag("innocentV3")
                    Text("Innocent v4 (Bashful)").tag("innocentV4")
                    Text("Sharp").tag("sharp")
                }
            }
            Section {
                HStack {
                    Text(model.message).font(.caption).foregroundStyle(model.message == "Saved." ? .green : .orange)
                    Spacer()
                    Button("Save", action: onSave).keyboardShortcut(.defaultAction)
                }
                Text(Secrets.store == .file
                     ? "Secrets are stored owner-only in ~/.noteling/secrets.json (dev build) and handed to pack scripts only as environment variables."
                     : "Secrets are stored in your macOS Keychain and handed to pack scripts only as environment variables.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 700)
    }
}

/// The linked copy's status, kept current while Settings is open, which team packs your own folder overrides, and
/// Update now. Unsaved changes to the address or token are saved first; saving them checks right away.
private struct LinkedToolsRow: View {
    @ObservedObject var updater: LinkedToolsUpdater
    @ObservedObject var model: SettingsModel
    let onSave: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    let line = updater.checking ? "Checking for changes…" : updater.status(now: context.date)
                    if !line.isEmpty {
                        Text(line).font(.caption).foregroundStyle(updater.record?.lastError == nil || updater.checking ? Color.secondary : Color.orange)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    let own = updater.overriddenPacks()
                    if !own.isEmpty {
                        Text("\(own.joined(separator: ", ")): your own folder's \(own.count == 1 ? "copy is" : "copies are") used, not the team's.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer()
            Button(model.toolsRepoChanged ? "Save and update" : "Update now") {
                if model.toolsRepoChanged { onSave() } else { Task { await updater.check() } }
            }
            .disabled(updater.checking || (model.toolsRepo.isEmpty && !model.toolsRepoChanged))
        }
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    let model = SettingsModel()

    func show(config: Config, packs: [ToolPack], linkedTools: LinkedToolsUpdater? = nil, onSave: @escaping () -> Void,
              onOpenTools: @escaping () -> Void, onReloadTools: @escaping () -> Void) {
        model.load(config: config, packs: packs)
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Noteling Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model, linkedTools: linkedTools, onSave: onSave,
                                                                 onOpenTools: onOpenTools, onReloadTools: onReloadTools))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
