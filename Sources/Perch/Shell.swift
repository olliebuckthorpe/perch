import Foundation

/// Subprocess helper. A GUI app does not inherit the shell PATH, so build one that
/// covers where node, claude and codex normally live.
enum Shell {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static let path: String = {
        var dirs = ["\(home)/.local/bin"]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            let newest = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            dirs += newest.map { "\(nvm)/\($0)/bin" }
        }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return dirs.joined(separator: ":")
    }()

    static func find(_ tool: String) -> String? {
        for dir in path.split(separator: ":") {
            let p = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Runs a process off the main thread. `onOutput` fires on the main queue as chunks arrive;
    /// `completion` fires on the main queue with the exit code and everything written to stdout.
    @discardableResult
    static func run(
        _ exe: String, _ args: [String], cwd: String? = nil, env extra: [String: String] = [:],
        onOutput: ((String) -> Void)? = nil, completion: ((Int32, String) -> Void)? = nil
    ) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd, FileManager.default.fileExists(atPath: cwd) {
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        for (k, v) in extra { env[k] = v }
        p.environment = env

        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice

        var collected = Data()
        let lock = NSLock()
        out.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            if completion != nil {
                lock.lock(); collected.append(chunk); lock.unlock()
            }
            if let onOutput, let s = String(data: chunk, encoding: .utf8) {
                DispatchQueue.main.async { onOutput(s) }
            }
        }
        p.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            let rest = (try? out.fileHandleForReading.readToEnd()) ?? nil
            lock.lock()
            if let rest { collected.append(rest) }
            let text = String(data: collected, encoding: .utf8) ?? ""
            lock.unlock()
            DispatchQueue.main.async { completion?(proc.terminationStatus, text) }
        }
        do { try p.run() } catch {
            DispatchQueue.main.async { completion?(-1, "") }
            return nil
        }
        return p
    }
}
