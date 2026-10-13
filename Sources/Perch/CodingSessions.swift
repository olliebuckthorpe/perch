import AppKit

/// Claude Code and Codex share the same hook protocol, so one handler serves both.
final class CodingSessions {
    static let shared = CodingSessions()
    private let store = AgentStore.shared

    static let codexBundleID = "com.openai.codex"
    static let claudeBundleID = "com.anthropic.claudefordesktop"

    private static let terminals: [String: String] = [
        "Apple_Terminal": "com.apple.Terminal",
        "iTerm.app": "com.googlecode.iterm2",
        "vscode": "com.microsoft.VSCode",
        "ghostty": "com.mitchellh.ghostty",
        "WarpTerminal": "dev.warp.Warp-Stable",
        "kitty": "net.kovidgoyal.kitty",
        "alacritty": "org.alacritty",
    ]

    private var titled = Set<String>()

    /// Sessions that were already open before Perch launched have not sent a hook yet,
    /// so pick up the recently active ones from their transcripts.
    private func seed() {
        let root = "\(Shell.home)/.claude/projects"
        let fm = FileManager.default
        let now = Date()
        for project in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            for file in (try? fm.contentsOfDirectory(atPath: "\(root)/\(project)")) ?? [] where file.hasSuffix(".jsonl") {
                let path = "\(root)/\(project)/\(file)"
                guard let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                      now.timeIntervalSince(mtime) < 30 * 60 else { continue }
                let info = Self.transcriptInfo(path)
                // Untitled transcripts are one-off background runs, not sessions you would recognise.
                guard let title = info.title else { continue }
                let agent = store.upsert(source: .claude, sessionID: String(file.dropLast(6)), name: title)
                agent.cwd = info.cwd
                agent.transcriptPath = path
                agent.hostBundleID = Self.claudeBundleID
                agent.lastActivity = mtime
                titled.insert(agent.id)
            }
        }
    }

    /// The session title and working directory, read from the end of a Claude Code transcript.
    static func transcriptInfo(_ path: String, span: UInt64 = 400 << 10) -> (title: String?, cwd: String?) {
        guard let h = FileHandle(forReadingAtPath: path) else { return (nil, nil) }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > span ? size - span : 0)
        guard let data = try? h.readToEnd() else { return (nil, nil) }
        var title: String?
        var cwd: String?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            if title == nil, line.contains("\"custom-title\"") || line.contains("\"agent-name\""),
               let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                title = o["customTitle"] as? String ?? o["agentName"] as? String
            }
            if cwd == nil, line.contains("\"cwd\""), line.count < 200_000,
               let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                cwd = o["cwd"] as? String
            }
            if title != nil && cwd != nil { break }
        }
        return (title, cwd)
    }

    func start() {
        seed()
        // Coming back to the agent's own app means you will answer there, so let go of anything held.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundle = app.bundleIdentifier else { return }
            self?.release(host: bundle)
        }
    }

    // MARK: Hook events

    func handle(_ req: HookRequest) {
        let j = req.json
        guard let sid = j["session_id"] as? String, let event = j["hook_event_name"] as? String else {
            req.respond()
            return
        }
        let source: AgentSource = req.headers["x-perch-source"] == "codex" ? .codex : .claude
        let mode = req.headers["x-perch-mode"] ?? "info"
        let headless = req.headers["x-perch-headless"] == "1"
        let cwd = j["cwd"] as? String

        let agent = store.upsert(source: source, sessionID: sid, name: Self.name(for: cwd, source: source))
        if let cwd { agent.cwd = cwd }
        if let path = j["transcript_path"] as? String { agent.transcriptPath = path }
        if !headless { agent.hostBundleID = hostBundle(source: source, headers: req.headers) }
        agent.lastActivity = Date()
        agent.ended = false
        if let title = j["session_title"] as? String, !title.isEmpty {
            agent.name = title
        } else if source == .claude, let path = j["transcript_path"] as? String,
                  !titled.contains(agent.id) || event == "UserPromptSubmit" || event == "Stop" {
            // Claude Code names a session a little after it starts, so look again at turn boundaries.
            if let title = Self.transcriptInfo(path).title {
                agent.name = title
                titled.insert(agent.id)
            }
        }

        let tool = j["tool_name"] as? String ?? ""
        let input = j["tool_input"] as? [String: Any] ?? [:]

        if mode == "wait" {
            guard !headless else { req.respond(); return }
            // After a tool call the waiter doubles as the progress report.
            if event == "PostToolUse" { info(event: event, agent: agent, json: j, tool: tool, input: input, headless: headless) }
            agent.waiter?.respond()
            if !agent.queued.isEmpty {
                deliver(agent.queued.joined(separator: "\n\n"), to: agent, through: req)
                agent.queued = []
                return
            }
            agent.waiter = req
            req.onCancel = { [weak agent, weak req] in
                if agent?.waiter === req { agent?.waiter = nil }
            }
            return
        }

        switch (event, mode) {
        case ("PermissionRequest", "permission"):
            let detail = Self.permissionDetail(tool: tool, input: input)
            agent.status = .needsYou
            agent.detail = "Wants to use \(Self.toolLabel(tool)): \(oneLine(detail, max: 80))"
            guard !hostIsFrontmost(agent) else { store.ping(agent, sound: false); req.respond(); return }
            hold(agent, req, kind: .permission(tool: Self.toolLabel(tool), detail: detail), seconds: 285)

        case ("PreToolUse", "ask"):
            let questions = Self.questions(from: input)
            guard !questions.isEmpty, !hostIsFrontmost(agent) else { req.respond(); return }
            agent.status = .needsYou
            agent.detail = questions[0].text
            hold(agent, req, kind: .question(questions: questions, rawInput: input), seconds: 285)

        case ("Stop", "stop"):
            let last = j["last_assistant_message"] as? String ?? ""
            if !last.isEmpty { agent.lastMessage = last }
            if !agent.queued.isEmpty {
                // Something was sent from the notch mid-turn: it becomes the next prompt straight away.
                let text = agent.queued.joined(separator: "\n\n")
                agent.queued = []
                agent.status = .working
                agent.detail = oneLine(text)
                req.respond((try? JSONSerialization.data(withJSONObject: ["decision": "block", "reason": text])) ?? Data())
                return
            }
            agent.status = .done
            agent.detail = last.isEmpty ? "Finished" : oneLine(last)
            let window = Settings.replyWindow
            guard window > 0, !headless, !hostIsFrontmost(agent) else {
                clearPending(agent)
                if !hostIsFrontmost(agent) { store.ping(agent) }
                req.respond()
                return
            }
            hold(agent, req, kind: .followUp, seconds: TimeInterval(window))

        default:
            req.respond()
            info(event: event, agent: agent, json: j, tool: tool, input: input, headless: headless)
        }
    }

    private func info(event: String, agent: Agent, json j: [String: Any], tool: String, input: [String: Any], headless: Bool) {
        switch event {
        case "UserPromptSubmit":
            clearPending(agent)
            agent.status = .working
            agent.detail = oneLine(j["prompt"] as? String ?? "Thinking")
        case "PreToolUse":
            // The question hook owns the status while it is being held.
            if agent.pending == nil {
                agent.status = .working
                agent.detail = Self.activity(tool: tool, input: input)
            }
        case "PostToolUse":
            if agent.pending == nil { agent.status = .working }
        case "Notification":
            let type = j["notification_type"] as? String ?? ""
            if ["permission_prompt", "agent_needs_input", "elicitation_dialog"].contains(type), agent.pending == nil {
                if agent.status != .needsYou, !hostIsFrontmost(agent) { store.ping(agent) }
                agent.status = .needsYou
                agent.detail = oneLine(j["message"] as? String ?? "Needs you")
            }
        case "Stop":
            // Claude Code: the turn ends normally and a waiter takes replies from here on.
            let last = j["last_assistant_message"] as? String ?? ""
            if !last.isEmpty { agent.lastMessage = last }
            agent.status = .done
            agent.detail = last.isEmpty ? "Finished" : oneLine(last)
            clearPending(agent)
            guard !hostIsFrontmost(agent) else { break }
            let window = Settings.replyWindow
            if window > 0, !headless {
                // Just a prompt card; nothing is held, so it can simply time out.
                let card = PendingRequest(kind: .followUp, deadline: Date().addingTimeInterval(TimeInterval(window))) { _ in }
                agent.pending = card
                scheduleExpiry(agent, card, hardLimit: Date().addingTimeInterval(540))
            }
            store.ping(agent)
        case "StopFailure":
            agent.status = .done
            agent.detail = "Stopped with an error"
        case "SessionEnd":
            // A background reply ends its own process, not the session the user has open.
            if !headless {
                clearPending(agent)
                agent.ended = true
            }
            if agent.status == .working || agent.status == .needsYou { agent.status = .idle }
        default:
            break
        }
    }

    // MARK: Holding a hook open

    private func hold(_ agent: Agent, _ req: HookRequest, kind: PendingKind, seconds: TimeInterval) {
        clearPending(agent)
        let pending = PendingRequest(kind: kind, deadline: Date().addingTimeInterval(seconds)) { data in
            req.respond(data)
        }
        agent.pending = pending
        req.onCancel = { [weak agent] in
            if agent?.pending?.id == pending.id { agent?.pending = nil }
        }
        scheduleExpiry(agent, pending, hardLimit: Date().addingTimeInterval(max(seconds, 540)))
        store.ping(agent)
    }

    private func scheduleExpiry(_ agent: Agent, _ pending: PendingRequest, hardLimit: Date) {
        let wait = max(0.1, pending.deadline.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak agent] in
            guard let self, let agent, agent.pending?.id == pending.id else { return }
            // Still typing a follow-up: give them a little longer, up to the hook's own timeout.
            if case .followUp = pending.kind, NotchUI.shared.isDrafting(agent.id), Date() < hardLimit {
                pending.deadline = min(hardLimit, Date().addingTimeInterval(20))
                self.scheduleExpiry(agent, pending, hardLimit: hardLimit)
                return
            }
            self.clearPending(agent)
        }
    }

    private func clearPending(_ agent: Agent) {
        agent.pending?.finish()
        agent.pending = nil
    }

    private func release(host bundle: String) {
        for a in store.agents where a.hostBundleID == bundle && a.pending != nil { clearPending(a) }
    }

    // MARK: Answers from the notch

    func allow(_ agent: Agent) { decide(agent, ["behavior": "allow"]) }

    func deny(_ agent: Agent) { decide(agent, ["behavior": "deny", "message": "Denied from the notch."]) }

    private func decide(_ agent: Agent, _ decision: [String: Any]) {
        agent.pending?.finish(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]])
        agent.pending = nil
        agent.status = .working
        agent.detail = decision["behavior"] as? String == "allow" ? "Allowed, carrying on" : "Denied"
    }

    func answer(_ agent: Agent, answers: [String: String]) {
        guard let pending = agent.pending, case .question(_, let raw) = pending.kind else { return }
        var updated = raw
        updated["answers"] = answers
        pending.finish(["hookSpecificOutput": [
            "hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": updated,
        ]])
        agent.pending = nil
        agent.status = .working
        agent.detail = "Got your answer"
    }

    /// Hands the prompt back to the agent's own app.
    func dismiss(_ agent: Agent) { clearPending(agent) }

    func reply(_ agent: Agent, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        agent.addLocal(text)
        if let waiter = agent.waiter {
            deliver(text, to: agent, through: waiter)
            return
        }
        if agent.status == .working, agent.pending == nil {
            // Mid-turn with no way in right now: hold it for the next opening, a moment away.
            agent.queued.append(text)
            return
        }
        if let pending = agent.pending, case .followUp = pending.kind, agent.source == .codex {
            // The session is still waiting at the end of its turn, so this lands as its next prompt.
            pending.finish(["decision": "block", "reason": text])
            agent.pending = nil
            agent.status = .working
            agent.detail = oneLine(text)
            return
        }
        resume(agent, text: text)
    }

    /// Wakes the real session, so the reply and the answer both show up in its own chat.
    private func deliver(_ text: String, to agent: Agent, through waiter: HookRequest) {
        waiter.respond(Data("The user replied from Perch, their notch app. Treat this as their next message:\n\n\(text)".utf8))
        if agent.waiter === waiter { agent.waiter = nil }
        clearPending(agent)
        agent.status = .working
        agent.detail = oneLine(text)
        agent.lastActivity = Date()
    }

    /// Hands a new chat to the Claude desktop app, with the prompt and folder filled in.
    func newClaudeChat(prompt: String?) {
        var link = URLComponents(string: "claude://code/new")!
        var items: [URLQueryItem] = []
        if let prompt, !prompt.isEmpty { items.append(URLQueryItem(name: "q", value: prompt)) }
        // Start it where the most recent session was working.
        if let cwd = store.sessions.first(where: { $0.source == .claude && $0.cwd != nil })?.cwd {
            items.append(URLQueryItem(name: "folder", value: cwd))
        }
        if !items.isEmpty { link.queryItems = items }
        if let url = link.url { NSWorkspace.shared.open(url) }
    }

    /// Brings a session found by search into the notch so it can be read and replied to.
    func adopt(_ entry: SessionIndex.Entry) -> Agent {
        let agent = store.upsert(source: .claude, sessionID: entry.id, name: entry.title)
        agent.transcriptPath = entry.path
        agent.cwd = entry.cwd
        agent.hostBundleID = Self.claudeBundleID
        agent.lastActivity = Date()
        titled.insert(agent.id)
        return agent
    }

    /// The turn is long over, so continue the session in the background instead.
    private func resume(_ agent: Agent, text: String) {
        let tool = agent.source == .codex ? "codex" : "claude"
        guard let exe = Shell.find(tool) else {
            agent.detail = "Could not find the \(tool) command"
            return
        }
        let args = agent.source == .codex
            ? ["exec", "resume", agent.sessionID, text, "--skip-git-repo-check"]
            : ["-p", "--resume", agent.sessionID, text]
        agent.sending = true
        agent.status = .working
        agent.detail = oneLine(text)
        agent.lastActivity = Date()
        Shell.run(exe, args, cwd: agent.cwd, env: ["PERCH_HEADLESS": "1"]) { [weak agent] code, output in
            guard let agent else { return }
            agent.sending = false
            agent.lastActivity = Date()
            let reply = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if code != 0 {
                agent.status = .done
                agent.detail = "Could not reach this session. Open it and send one message first."
            } else if agent.source == .claude, !reply.isEmpty {
                agent.lastMessage = reply
                agent.status = .done
                agent.detail = oneLine(reply)
                AgentStore.shared.ping(agent)
            }
        }
    }

    func open(_ agent: Agent) {
        guard let bundle = agent.hostBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    // MARK: Helpers

    private func hostBundle(source: AgentSource, headers: [String: String]) -> String? {
        if source == .claude, headers["x-perch-entrypoint"] == "claude-desktop" { return Self.claudeBundleID }
        if let term = headers["x-perch-term"], let bundle = Self.terminals[term] { return bundle }
        return source == .codex ? Self.codexBundleID : Self.claudeBundleID
    }

    private func hostIsFrontmost(_ agent: Agent) -> Bool {
        guard let host = agent.hostBundleID else { return false }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == host
    }

    static func name(for cwd: String?, source: AgentSource) -> String {
        guard let cwd, !cwd.isEmpty else { return source.label }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    static func toolLabel(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        return tool.components(separatedBy: "__").last?.replacingOccurrences(of: "_", with: " ") ?? tool
    }

    static func activity(tool: String, input: [String: Any]) -> String {
        func file() -> String {
            let p = input["file_path"] as? String ?? input["path"] as? String ?? input["notebook_path"] as? String ?? ""
            return p.isEmpty ? "a file" : URL(fileURLWithPath: p).lastPathComponent
        }
        let command = input["command"] as? String ?? input["cmd"] as? String ?? ""
        switch tool {
        case "Bash", "shell", "exec_command", "local_shell", "exec":
            if let d = input["description"] as? String, !d.isEmpty { return oneLine(d) }
            return command.isEmpty ? "Running a command" : "Running \(oneLine(command, max: 70))"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "Editing \(file())"
        case "apply_patch": return "Editing files"
        case "Read": return "Reading \(file())"
        case "Grep", "Glob": return "Searching the code"
        case "Agent", "Task": return "Running a subagent"
        case "WebFetch", "WebSearch": return "Searching the web"
        case "AskUserQuestion": return "Asking you a question"
        default: return "Using \(toolLabel(tool))"
        }
    }

    static func permissionDetail(tool: String, input: [String: Any]) -> String {
        if let c = input["command"] as? String ?? input["cmd"] as? String { return c }
        if let f = input["file_path"] as? String { return f }
        if let u = input["url"] as? String { return u }
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return String(s.prefix(300))
    }

    static func questions(from input: [String: Any]) -> [Question] {
        (input["questions"] as? [[String: Any]] ?? []).compactMap { q in
            guard let text = q["question"] as? String else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
            return Question(text: text, header: q["header"] as? String ?? "", options: options,
                            multiSelect: q["multiSelect"] as? Bool ?? false)
        }
    }
}
