import CFNetwork
import Foundation

/// What tool-pack scripts need to reach the network the way Safari does on this Mac: the proxy set in System Settings
/// and the certificates the Mac trusts, including one a company installs for its proxy. Python and uv read neither
/// from macOS by themselves, so behind a company proxy a script would fail where the browser works.
enum ScriptNetwork {
    /// The environment scripts (and uv, when it fetches Python or a script's packages) get. Settings' own `env` map
    /// still wins over every name here, so a proxy that must not be used for some hosts can be fixed with NO_PROXY.
    static func environment(proxy: [String: String], certificates: URL?) -> [String: String] {
        var env = proxy
        env["UV_NATIVE_TLS"] = "1"   // uv trusts the Mac's certificates, not only its built-in list
        if let certificates {
            env["SSL_CERT_FILE"] = certificates.path
            env["REQUESTS_CA_BUNDLE"] = certificates.path
        }
        return env
    }

    /// The proxy variables for System Settings' proxies (`CFNetworkCopySystemProxySettings`), for fixed proxies.
    /// Automatic configuration (a PAC file) is resolved separately, for one address on the internet.
    static func proxyEnvironment(_ settings: [String: Any]) -> [String: String] {
        func on(_ key: String) -> Bool { (settings[key] as? NSNumber)?.boolValue ?? false }
        func proxy(_ host: String, _ port: String) -> String? {
            guard let h = settings[host] as? String, !h.isEmpty else { return nil }
            let p = (settings[port] as? NSNumber)?.intValue
            return "http://\(h)" + (p.map { ":\($0)" } ?? "")
        }
        var env: [String: String] = [:]
        if on("HTTPEnable"), let p = proxy("HTTPProxy", "HTTPPort") { env["HTTP_PROXY"] = p; env["http_proxy"] = p }
        if on("HTTPSEnable"), let p = proxy("HTTPSProxy", "HTTPSPort") { env["HTTPS_PROXY"] = p; env["https_proxy"] = p }
        guard !env.isEmpty else { return [:] }
        return env.merging(bypass(settings)) { a, _ in a }
    }

    /// NO_PROXY from the hosts System Settings sends direct, written the way Python and uv read it.
    static func bypass(_ settings: [String: Any]) -> [String: String] {
        var hosts = (settings["ExceptionsList"] as? [String] ?? []).map { host in
            host.hasPrefix("*.") ? String(host.dropFirst()) : host   // "*.corp.example.com" → ".corp.example.com"
        }
        if (settings["ExcludeSimpleHostnames"] as? NSNumber)?.boolValue == true || hosts.isEmpty {
            hosts += ["localhost", "127.0.0.1", "::1"]
        }
        var seen = Set<String>()
        let list = hosts.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ",")
        return list.isEmpty ? [:] : ["NO_PROXY": list, "no_proxy": list]
    }

    /// The proxy a PAC file picks for one internet address, as proxy variables; none when it says DIRECT or can't run.
    static func pacEnvironment(_ settings: [String: Any], probe: URL = URL(string: "https://www.example.com/")!) async -> [String: String] {
        guard (settings["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true,
              let pac = (settings["ProxyAutoConfigURLString"] as? String).flatMap(URL.init(string:)) else { return [:] }
        guard let proxies = await runPAC(pac, for: probe),
              let first = proxies.first(where: { ($0[kCFProxyTypeKey as String] as? String) == (kCFProxyTypeHTTP as String)
                                                 || ($0[kCFProxyTypeKey as String] as? String) == (kCFProxyTypeHTTPS as String) }),
              let host = first[kCFProxyHostNameKey as String] as? String else { return [:] }
        let port = (first[kCFProxyPortNumberKey as String] as? NSNumber)?.intValue
        let url = "http://\(host)" + (port.map { ":\($0)" } ?? "")
        return ["HTTP_PROXY": url, "http_proxy": url, "HTTPS_PROXY": url, "https_proxy": url].merging(bypass(settings)) { a, _ in a }
    }

    private final class PACBox { var continuation: CheckedContinuation<[[String: Any]]?, Never>?; var source: CFRunLoopSource? }

    @MainActor
    private static func runPAC(_ pac: URL, for target: URL) async -> [[String: Any]]? {
        await withCheckedContinuation { (continuation: CheckedContinuation<[[String: Any]]?, Never>) in
            let box = PACBox()
            box.continuation = continuation
            var context = CFStreamClientContext(version: 0, info: Unmanaged.passRetained(box).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let source = CFNetworkExecuteProxyAutoConfigurationURL(pac as CFURL, target as CFURL, { info, proxies, error in
                let box = Unmanaged<PACBox>.fromOpaque(info).takeRetainedValue()
                if let source = box.source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
                let list = error == nil ? (proxies as? [[String: Any]]) : nil
                box.continuation?.resume(returning: list)
                box.continuation = nil
            }, &context)
            box.source = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            // A PAC file that never answers must not hold scripts back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard let pending = box.continuation else { return }
                box.continuation = nil
                if let source = box.source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
                pending.resume(returning: nil)
            }
        }
    }

    /// The certificates this Mac trusts for everyone (Apple's roots and those an administrator installed, such as a
    /// company proxy's), as one PEM file for Python. Nil when they can't be read.
    static func exportCertificates(to file: URL) -> URL? {
        var pem = ""
        for keychain in ["/System/Library/Keychains/SystemRootCertificates.keychain", "/Library/Keychains/System.keychain"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["find-certificate", "-a", "-p", keychain]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { continue }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0 { pem += String(decoding: data, as: UTF8.self) }
        }
        guard pem.contains("BEGIN CERTIFICATE") else { return nil }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try pem.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch { return nil }
    }

    /// Everything above for this Mac, now. Reads System Settings, may run a PAC file, and writes the certificates.
    static func current(certificates file: URL = Config.dir.appendingPathComponent("run/certificates.pem")) async -> [String: String] {
        let settings = (CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]) ?? [:]
        var proxy = proxyEnvironment(settings)
        if proxy.isEmpty { proxy = await pacEnvironment(settings) }
        let certificates = await Task.detached(priority: .utility) { exportCertificates(to: file) }.value
        let env = environment(proxy: proxy, certificates: certificates)
        Log.info("scripts network: proxy \(proxy["HTTPS_PROXY"].map { "via \(URL(string: $0)?.host ?? "?")" } ?? "none")"
                 + ((settings["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true ? " (auto-config)" : "")
                 + ", certificates \(certificates == nil ? "default" : "from this Mac")")
        return env
    }
}
