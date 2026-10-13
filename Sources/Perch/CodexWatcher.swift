import Foundation

/// Codex writes every session to a rollout file. Watching those shows Codex sessions
/// (desktop app included) even when its hooks have not been trusted yet.
final class CodexWatcher {
    private let store = AgentStore.shared
    private let root = "\(Shell.home)/.codex/sessions"
    private let indexPath = "\(Shell.home)/.codex/session_index.jsonl"
    private var timer: Timer?
    private var seen: [String: Date] = [:]
    private var meta: [String: (id: String, cwd: String?, user: Bool)] = [:]
    private var names: [String: String] = [:]
    private var indexStamp: Date?

    func start() {
        guard FileManager.default.fileExists(atPath: root) else { return }
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.scan() }
        timer?.tolerance = 1
    }

    private func scan() {
        let fm = FileManager.default
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy/MM/dd"
        let now = Date()
        for day in [now, now.addingTimeInterval(-86400)] {
            let dir = "\(root)/\(fmt.string(from: day))"
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".jsonl") {
                let path = "\(dir)/\(f)"
                guard let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                      now.timeIntervalSince(mtime) < 3 * 3600, seen[path] != mtime else { continue }
                seen[path] = mtime
                update(path: path, mtime: mtime)
            }
        }
    }

    private func update(path: String, mtime: Date) {
        if meta[path] == nil { meta[path] = readMeta(path) }
        guard let m = meta[path], m.user else { return }
        guard let tail = readTail(path) else { return }

        var lifecycle: String?
        var lastMessage: String?
        var lastTool: String?
        for line in tail.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any], let type = payload["type"] as? String else { continue }
            switch type {
            case "task_started", "task_complete", "turn_aborted":
                if lifecycle == nil {
                    lifecycle = type
                    if let msg = payload["last_agent_message"] as? String, lastMessage == nil { lastMessage = msg }
                }
            case "function_call", "custom_tool_call":
                if lastTool == nil { lastTool = payload["name"] as? String }
            default: break
            }
            if lifecycle != nil { break }
        }

        refreshNames()
        let fresh = Date().timeIntervalSince(mtime) < 600
        let agent = store.upsert(source: .codex, sessionID: m.id,
                                 name: CodingSessions.name(for: m.cwd, source: .codex))
        if let n = names[m.id] { agent.name = n }
        agent.cwd = m.cwd
        if agent.hostBundleID == nil { agent.hostBundleID = CodingSessions.codexBundleID }
        agent.lastActivity = mtime
        guard agent.pending == nil else { return }

        switch lifecycle {
        case "task_started":
            agent.status = fresh ? .working : .idle
            agent.detail = lastTool.map { "Using \(CodingSessions.toolLabel($0))" } ?? "Working"
        case "task_complete", "turn_aborted":
            let wasWorking = agent.status == .working
            if let lastMessage, !lastMessage.isEmpty {
                agent.lastMessage = lastMessage
                agent.detail = oneLine(lastMessage)
            } else if lifecycle == "turn_aborted" {
                agent.detail = "Stopped"
            }
            agent.status = fresh ? .done : .idle
            if wasWorking { store.ping(agent) }
        default:
            // No lifecycle marker in the tail: a long turn that is still writing.
            if fresh, agent.status != .needsYou { agent.status = .working }
        }
    }

    private func readMeta(_ path: String) -> (id: String, cwd: String?, user: Bool)? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        // The first line carries the base instructions, so it can be large.
        var data = Data()
        while data.count < 2 << 20, let chunk = try? h.read(upToCount: 64 << 10), !chunk.isEmpty {
            data.append(chunk)
            if chunk.contains(0x0A) { break }
        }
        guard let line = data.split(separator: 0x0A).first,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let p = obj["payload"] as? [String: Any], let id = p["id"] as? String else { return nil }
        let threadSource = p["thread_source"] as? String ?? "user"
        return (id, p["cwd"] as? String, threadSource == "user")
    }

    private func readTail(_ path: String, bytes: UInt64 = 96 << 10) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > bytes ? size - bytes : 0)
        guard let data = try? h.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func refreshNames() {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: indexPath))?[.modificationDate] as? Date
        guard stamp != indexStamp, let text = try? String(contentsOfFile: indexPath, encoding: .utf8) else { return }
        indexStamp = stamp
        for line in text.split(separator: "\n").suffix(200) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = o["id"] as? String, let name = o["thread_name"] as? String else { continue }
            names[id] = name
        }
    }
}
