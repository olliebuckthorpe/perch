import Foundation

/// Starts a new Codex chat the way the Codex app does: through Codex's app server, so the chat
/// is one of the app's own (it shows in its list) rather than a one-off `codex exec` run, and is
/// named there, so the app and Perch show the same title.
///
/// One app server per new chat, talked to over stdin/stdout, closed once the first turn is done.
/// After that the chat is an ordinary Codex chat: the rollout watcher follows it and replies go
/// through the queue as usual.
final class CodexStart {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 1
    private var waiting: [Int: ([String: Any]?) -> Void] = [:]
    private var threadID: String?
    private var pendingName: String?
    /// The new chat's id, once Codex has made it.
    var started: ((String) -> Void)?
    /// The first turn is over (or the start failed, with the reason).
    var finished: ((String?) -> Void)?
    private var done = false
    private static var running: [CodexStart] = []

    init?(folder: String, prompt: String, title: String) {
        guard let exe = Shell.find("codex") else { return nil }
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Shell.path
        process.environment = env
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            DispatchQueue.main.async { self?.read(chunk) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.finish("Codex stopped before replying") }
        }
        do { try process.run() } catch { return nil }
        Self.running.append(self)

        send("initialize", ["clientInfo": ["name": "perch", "version": "1"]]) { [weak self] reply in
            guard let self else { return }
            guard reply != nil else { return self.finish("Codex did not start") }
            self.notify("initialized", [:])
            // Allowed to edit files in its folder; it does not stop to ask.
            self.send("thread/start", ["cwd": folder, "sandbox": "workspace-write", "approvalPolicy": "never",
                                       "threadSource": "user"]) { [weak self] reply in
                guard let self else { return }
                guard let id = ((reply?["thread"] as? [String: Any])?["id"] as? String) else {
                    return self.finish("Codex could not start a chat")
                }
                self.threadID = id
                self.started?(id)
                self.name(self.pendingName ?? title)
                self.send("turn/start", ["threadId": id, "input": [["type": "text", "text": prompt]]]) { [weak self] reply in
                    if reply == nil { self?.finish("Codex did not take the message") }
                }
            }
        }
    }

    /// Names the chat in Codex (and so in the Codex app's list).
    func name(_ title: String) {
        guard let threadID, !done else { pendingName = title; return }
        send("thread/name/set", ["threadId": threadID, "name": title]) { _ in }
    }

    private func send(_ method: String, _ params: [String: Any], reply: @escaping ([String: Any]?) -> Void) {
        let id = nextID
        nextID += 1
        waiting[id] = reply
        write(["id": id, "method": method, "params": params])
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        write(["method": method, "params": params])
    }

    private func write(_ message: [String: Any]) {
        guard !done, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        input.fileHandleForWriting.write(data + Data([0x0A]))
    }

    private func read(_ chunk: Data) {
        buffer.append(chunk)
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<end]
            buffer.removeSubrange(buffer.startIndex...end)
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = o["id"] as? Int, let reply = waiting.removeValue(forKey: id) {
                reply(o["error"] == nil ? (o["result"] as? [String: Any] ?? [:]) : nil)
            } else if o["method"] as? String == "turn/completed" {
                // A moment for the last of it to be written down, then close.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.finish(nil) }
            }
        }
    }

    private func finish(_ problem: String?) {
        guard !done else { return }
        done = true
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        finished?(threadID == nil ? (problem ?? "Codex did not start") : nil)
        Self.running.removeAll { $0 === self }
    }

    func stop() { finish("Stopped") }
}
