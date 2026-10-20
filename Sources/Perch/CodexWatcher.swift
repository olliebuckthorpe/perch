import Foundation
import SQLite3

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
    private let questionQueue = DispatchQueue(label: "perch.codex-questions", qos: .utility)
    private let questionScanner = CodexQuestionScanner()

    func start() {
        guard FileManager.default.fileExists(atPath: root) else { return }
        lastUsage()
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.scan() }
        timer?.tolerance = 1
    }

    /// Usage from the most recent session of the last few days, so there is something to show
    /// before Codex is next used.
    private func lastUsage() {
        let fm = FileManager.default
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy/MM/dd"
        for back in 0..<7 {
            let dir = "\(root)/\(fmt.string(from: Date().addingTimeInterval(Double(-back) * 86400)))"
            guard let newest = (try? fm.contentsOfDirectory(atPath: dir))?.filter({ $0.hasSuffix(".jsonl") }).sorted().last else { continue }
            let path = "\(dir)/\(newest)"
            if let tail = readTail(path), let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
                takeUsage(tail, at: mtime)
            }
            return
        }
    }

    private func scan() {
        let fm = FileManager.default
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy/MM/dd"
        let now = Date()
        // Resumed threads retain their original rollout directory, which may be months old.
        var paths = Set(store.sessions.filter { $0.source == .codex }.compactMap(\.transcriptPath))
        for day in [now, now.addingTimeInterval(-86400)] {
            let dir = "\(root)/\(fmt.string(from: day))"
            for file in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".jsonl") {
                paths.insert("\(dir)/\(file)")
            }
        }
        for path in paths {
            guard let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(mtime) < 3 * 3600, seen[path] != mtime else { continue }
            seen[path] = mtime
            update(path: path, mtime: mtime)
        }
    }

    private func update(path: String, mtime: Date) {
        if meta[path] == nil { meta[path] = readMeta(path) }
        guard let tail = readTail(path) else { return }
        takeUsage(tail, at: mtime)
        guard let m = meta[path], m.user else { return }

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
        agent.transcriptPath = path
        if agent.hostBundleID == nil { agent.hostBundleID = CodingSessions.codexBundleID }
        agent.lastActivity = mtime
        if let lifecycle { agent.codexWorking = lifecycle == "task_started" }
        questionQueue.async { [weak agent, questionScanner] in
            let batches = questionScanner.scan(path)
            DispatchQueue.main.async {
                guard let agent else { return }
                CodingSessions.shared.syncCodexQuestions(agent, batches: batches)
            }
        }
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
            CodingSessions.shared.flushQueued(agent)
        default:
            // No lifecycle marker in the tail: a long turn that is still writing.
            if fresh, agent.status != .needsYou { agent.status = .working }
        }
    }

    /// Every turn records how much of the plan is used. The newest record is the one to show.
    private func takeUsage(_ tail: String, at: Date) {
        for line in tail.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let limits = Self.find("rate_limits", in: o) else { continue }
            Usage.shared.takeCodex(limits, at: at)
            return
        }
    }

    private static func find(_ key: String, in value: Any) -> [String: Any]? {
        guard let d = value as? [String: Any] else { return nil }
        if let hit = d[key] as? [String: Any] { return hit }
        for v in d.values { if let hit = find(key, in: v) { return hit } }
        return nil
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
        if stamp != indexStamp, let text = try? String(contentsOfFile: indexPath, encoding: .utf8) {
            indexStamp = stamp
            for line in text.split(separator: "\n").suffix(200) {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let id = o["id"] as? String, let name = o["thread_name"] as? String else { continue }
                names[id] = name
            }
        }
        refreshStateNames()
    }

    /// Codex keeps chat names in its state database too (the Codex app's own list reads them
    /// there), so a chat named or renamed there is named the same here. Read only.
    private var stateStamp: Date?
    private func refreshStateNames() {
        let base = "\(Shell.home)/.codex/state_5.sqlite"
        let stamp = [base, base + "-wal"].compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }.max()
        guard let stamp, stamp != stateStamp else { return }
        stateStamp = stamp
        var db: OpaquePointer?
        guard sqlite3_open_v2(base, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        var statement: OpaquePointer?
        let query = "SELECT id, name FROM threads WHERE name IS NOT NULL AND name != '' ORDER BY updated_at DESC LIMIT 300"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let name = sqlite3_column_text(statement, 1) else { continue }
            names[String(cString: id)] = String(cString: name)
        }
        // Chats already showing take their name now, not only when they next change.
        let known = names
        DispatchQueue.main.async {
            for agent in AgentStore.shared.agents where agent.source == .codex {
                if let name = known[agent.sessionID], agent.name != name { agent.name = name }
            }
        }
    }
}
