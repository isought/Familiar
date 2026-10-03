import Foundation
import Testing
@testable import Familiar

/// Scripts reach the network the way Safari does on this Mac: the proxy from System Settings, the hosts it sends
/// direct, and the certificates the Mac trusts. Settings' own `env` still wins.
@Suite @MainActor
struct ScriptNetworkTests {
    @Test func aFixedProxyInSystemSettingsReachesScripts() {
        let settings: [String: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "proxy.corp.example.com", "HTTPPort": 8080,
            "HTTPSEnable": 1, "HTTPSProxy": "proxy.corp.example.com", "HTTPSPort": 8443,
            "ExceptionsList": ["*.corp.example.com", "10.0.0.0/8", "*.local"], "ExcludeSimpleHostnames": 1,
        ]
        let env = ScriptNetwork.proxyEnvironment(settings)
        #expect(env["HTTP_PROXY"] == "http://proxy.corp.example.com:8080" && env["http_proxy"] == env["HTTP_PROXY"])
        #expect(env["HTTPS_PROXY"] == "http://proxy.corp.example.com:8443" && env["https_proxy"] == env["HTTPS_PROXY"])
        #expect(env["NO_PROXY"] == ".corp.example.com,10.0.0.0/8,.local,localhost,127.0.0.1,::1")
        #expect(env["no_proxy"] == env["NO_PROXY"])
    }

    @Test func noProxyMeansNothingIsSet() {
        #expect(ScriptNetwork.proxyEnvironment([:]).isEmpty)
        #expect(ScriptNetwork.proxyEnvironment(["HTTPEnable": 0, "HTTPProxy": "proxy.example.com", "HTTPPort": 80]).isEmpty)
        #expect(ScriptNetwork.proxyEnvironment(["HTTPSEnable": 1, "HTTPSProxy": ""]).isEmpty)
    }

    @Test func autoConfigWithoutAFileOrSwitchedOffIsNoProxy() async {
        #expect(await ScriptNetwork.pacEnvironment([:]).isEmpty)
        #expect(await ScriptNetwork.pacEnvironment(["ProxyAutoConfigEnable": 0, "ProxyAutoConfigURLString": "http://wpad.example.com/proxy.pac"]).isEmpty)
    }

    @Test func scriptsAndUvTrustTheMacsCertificates() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("certs-\(UUID().uuidString)/certificates.pem")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let written = try #require(ScriptNetwork.exportCertificates(to: file))
        #expect(try String(contentsOf: written, encoding: .utf8).contains("-----BEGIN CERTIFICATE-----"))

        let env = ScriptNetwork.environment(proxy: ["HTTPS_PROXY": "http://proxy.example.com:8080"], certificates: written)
        #expect(env["UV_NATIVE_TLS"] == "1")
        #expect(env["SSL_CERT_FILE"] == written.path && env["REQUESTS_CA_BUNDLE"] == written.path)
        #expect(env["HTTPS_PROXY"] == "http://proxy.example.com:8080")
        #expect(ScriptNetwork.environment(proxy: [:], certificates: nil)["SSL_CERT_FILE"] == nil)
    }

    @Test func aScriptGetsTheNetworkAndSettingsEnvWins() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("script-network-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = root.appendingPathComponent("probe")
        try FileManager.default.createDirectory(at: pack.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try "---\nname: Probe\n---\nFixture.".write(to: pack.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try """
        import os
        def run() -> dict:
            \"\"\"Reports the proxy and certificate variables it was given.\"\"\"
            return {k: os.environ.get(k) for k in ("HTTPS_PROXY", "NO_PROXY", "SSL_CERT_FILE", "UV_NATIVE_TLS")}
        """.write(to: pack.appendingPathComponent("scripts/env.py"), atomically: true, encoding: .utf8)
        let runner = ScriptRunner(config: Config())
        runner.networkEnv = ["HTTPS_PROXY": "http://proxy.example.com:8080", "NO_PROXY": "localhost", "SSL_CERT_FILE": "/tmp/certs.pem", "UV_NATIVE_TLS": "1"]
        runner.extraEnv = ["NO_PROXY": "localhost,.corp.example.com"]
        let registry = ToolRegistry(root: root, runner: runner)
        await registry.reload()
        let script = try #require(registry.script(named: "probe__env"))

        let result = try #require(try await runner.result(script) as? [String: Any])
        #expect(result["HTTPS_PROXY"] as? String == "http://proxy.example.com:8080")
        #expect(result["NO_PROXY"] as? String == "localhost,.corp.example.com")   // Settings' env wins
        #expect(result["SSL_CERT_FILE"] as? String == "/tmp/certs.pem" && result["UV_NATIVE_TLS"] as? String == "1")
    }
}
