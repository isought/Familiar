import Foundation

struct SubprocessResult {
    let code: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

enum Subprocess {
    private final class Box { var out = Data(); var err = Data(); var resumed = false; var timedOut = false; let lock = NSLock() }

    static func run(_ exe: String, _ args: [String], stdin: Data? = nil, cwd: URL? = nil,
                    env extra: [String: String] = [:], timeout: TimeInterval = 60) async throws -> SubprocessResult {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.currentDirectoryURL = cwd
            var env = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            env["PATH"] = [env["PATH"] ?? "", "/usr/local/bin", "/opt/homebrew/bin", "\(home)/.local/bin", "/usr/bin", "/bin"].joined(separator: ":")
            for (k, v) in extra { env[k] = v }
            p.environment = env

            let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            p.standardInput = inPipe

            let box = Box()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async { let d = outPipe.fileHandleForReading.readDataToEndOfFile(); box.lock.lock(); box.out = d; box.lock.unlock(); group.leave() }
            group.enter()
            DispatchQueue.global().async { let d = errPipe.fileHandleForReading.readDataToEndOfFile(); box.lock.lock(); box.err = d; box.lock.unlock(); group.leave() }

            p.terminationHandler = { proc in
                group.wait()
                box.lock.lock()
                if box.resumed { box.lock.unlock(); return }
                box.resumed = true
                let result = SubprocessResult(code: proc.terminationStatus,
                                              stdout: String(decoding: box.out, as: UTF8.self),
                                              stderr: String(decoding: box.err, as: UTF8.self),
                                              timedOut: box.timedOut)
                box.lock.unlock()
                cont.resume(returning: result)
            }

            do { try p.run() } catch {
                cont.resume(throwing: error)
                return
            }
            if let stdin { inPipe.fileHandleForWriting.write(stdin) }
            try? inPipe.fileHandleForWriting.close()

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning {
                    box.lock.lock(); box.timedOut = true; box.lock.unlock()
                    p.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
                }
            }
        }
    }
}
