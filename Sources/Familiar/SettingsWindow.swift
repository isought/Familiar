import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published var apiKey = ""
    @Published var model = ""
    @Published var effort = "medium"
    @Published var apiBaseURL = ""
    @Published var hotkey = ""
    @Published var wandHoldSeconds = 0.8
    @Published var attachScreenshotOnText = true
    @Published var screenshotMode = "auto"
    @Published var hideFromScreenShare = false
    @Published var startAtLogin = false
    @Published var allowControl = false
    @Published var mascotStyle = "innocent"
    @Published var packSecrets: [PackSecret] = []
    @Published var message = ""

    struct PackSecret: Identifiable {
        let id: String            // env var name
        let packNames: [String]
        var value: String
    }

    var toolsDir = ""

    func load(config: Config, packs: [ToolPack]) {
        apiKey = config.apiKey.isEmpty ? (Secrets.get("ANTHROPIC_API_KEY") ?? "") : config.apiKey
        model = config.model
        effort = config.effort
        apiBaseURL = config.apiBaseURL
        hotkey = config.hotkey
        wandHoldSeconds = config.wandHoldSeconds
        attachScreenshotOnText = config.attachScreenshotOnText
        screenshotMode = config.screenshotMode
        hideFromScreenShare = config.hideFromScreenShare
        startAtLogin = SMAppService.mainApp.status == .enabled
        allowControl = config.allowControl
        mascotStyle = config.mascotStyle
        toolsDir = config.resolvedToolsDir.path
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

    /// Returns the updated config; secrets go to the Keychain, never into the file.
    func save(into config: Config) -> Config {
        var c = config
        if !Secrets.set("ANTHROPIC_API_KEY", apiKey) { message = "Could not save the API key to the Keychain." }
        c.apiKey = ""
        c.model = model.trimmingCharacters(in: .whitespaces)
        c.effort = effort
        c.apiBaseURL = apiBaseURL.trimmingCharacters(in: .whitespaces)
        c.hotkey = hotkey.trimmingCharacters(in: .whitespaces)
        c.wandHoldSeconds = max(0.3, min(3, wandHoldSeconds))
        c.attachScreenshotOnText = screenshotMode != "never"
        c.screenshotMode = screenshotMode
        c.hideFromScreenShare = hideFromScreenShare
        c.allowControl = allowControl
        c.mascotStyle = mascotStyle
        for s in packSecrets where !Secrets.set(s.id, s.value) { message = "Could not save \(s.id) to the Keychain." }
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
    let onSave: () -> Void
    let onOpenTools: () -> Void
    let onReloadTools: () -> Void

    var body: some View {
        Form {
            Section("Claude") {
                SecureField("API key", text: $model.apiKey)
                TextField("Model", text: $model.model)
                Picker("Effort", selection: $model.effort) {
                    ForEach(["low", "medium", "high", "xhigh", "max"], id: \.self) { Text($0) }
                }
                TextField("Gateway base URL (optional)", text: $model.apiBaseURL, prompt: Text("https://api.anthropic.com"))
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
                Toggle("Start Familiar at login", isOn: $model.startAtLogin)
                Toggle("Allow Familiar to control the mouse and keyboard when asked", isOn: $model.allowControl)
                Picker("Character brows", selection: $model.mascotStyle) {
                    Text("Innocent").tag("innocent")
                    Text("Innocent v1").tag("innocentV1")
                    Text("Innocent v3 (experiment)").tag("innocentV3")
                    Text("Sharp").tag("sharp")
                }
            }
            Section {
                HStack {
                    Text(model.message).font(.caption).foregroundStyle(model.message == "Saved." ? .green : .orange)
                    Spacer()
                    Button("Save", action: onSave).keyboardShortcut(.defaultAction)
                }
                Text("Secrets are stored in your macOS Keychain and handed to pack scripts only as environment variables.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 700)
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    let model = SettingsModel()

    func show(config: Config, packs: [ToolPack], onSave: @escaping () -> Void, onOpenTools: @escaping () -> Void, onReloadTools: @escaping () -> Void) {
        model.load(config: config, packs: packs)
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Familiar Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model, onSave: onSave, onOpenTools: onOpenTools, onReloadTools: onReloadTools))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
