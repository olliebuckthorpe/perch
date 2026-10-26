import AppKit

/// Claude Code and Codex share the same hook protocol, so one handler serves both.
final class CodingSessions {
    static let shared = CodingSessions()
    /// When each chat's transcript was last read for its title.
    private var titleLook: [String: Date] = [:]
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
                if agent.finishedAt == nil { agent.finishedAt = mtime }
                titled.insert(agent.id)
                Threads.load(agent)
            }
        }
    }

    /// The session title and working directory, read from the end of a Claude Code transcript.
    static func transcriptInfo(_ path: String, span: UInt64 = 400 << 10) -> (title: String?, cwd: String?, prompt: String?) {
        guard let h = FileHandle(forReadingAtPath: path) else { return (nil, nil, nil) }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > span ? size - span : 0)
        guard let data = try? h.readToEnd() else { return (nil, nil, nil) }
        var title: String?
        var cwd: String?
        var prompt: String?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            if title == nil, line.contains("\"custom-title\"") || line.contains("\"agent-name\""),
               let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                title = o["customTitle"] as? String ?? o["agentName"] as? String
            }
            if cwd == nil, line.contains("\"cwd\""), line.count < 200_000,
               let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                cwd = o["cwd"] as? String
            }
            if prompt == nil, line.contains("\"last-prompt\""),
               let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                prompt = o["lastPrompt"] as? String
            }
            if title != nil && cwd != nil { break }
        }
        return (title, cwd, prompt)
    }

    func start() {
        let sweeper = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.sweep() }
        sweeper.tolerance = 10
        SkillIndex.shared.refresh()
        indexDesktopSessions()
        let reindex = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in self?.indexDesktopSessions() }
        reindex.tolerance = 30
        for a in store.sessions {
            titled.insert(a.id)
            if a.kept { Threads.load(a) }
            for (id, text) in a.failedReplies { installCodexRetry(a, text: text, messageID: id) }
        }
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
        // Another agent handing work to Claude Code (perch-new-chat): start a chat for it.
        if req.headers["x-perch-mode"] == "newchat" {
            guard let prompt = j["prompt"] as? String, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                req.respond(Data("No prompt given".utf8))
                return
            }
            let folder = (j["folder"] as? String).flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? "\(Shell.home)/Dev"
            if let agent = startChat(prompt: prompt, folder: folder) {
                store.ping(agent)
                req.respond(Data("Started a Claude Code chat in \(folder). It will appear in the Claude app once it has replied.".utf8))
            } else {
                req.respond(Data("Could not start the chat".utf8))
            }
            return
        }
        // Claude Code's status line: not a session event, just how much of the plan is used.
        if req.headers["x-perch-mode"] == "status" {
            Usage.shared.takeClaude(j)
            req.respond()
            return
        }
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
        // Only Perch starts sessions this way, so this is one of its own chats, even after a restart.
        if headless, source == .claude, !agent.adopted, !agent.desktopBound { agent.background = true }
        agent.lastActivity = Date()
        agent.ended = false
        if Date().timeIntervalSince(agent.lastTick) > 2 {
            agent.lastTick = Date()
            agent.tick += 1
        }
        if let title = j["session_title"] as? String, !title.isEmpty {
            agent.name = title
        } else if source == .claude, let path = j["transcript_path"] as? String,
                  ["UserPromptSubmit", "Stop", "SessionStart"].contains(event)
                    || (!titled.contains(agent.id) && Date().timeIntervalSince(titleLook[agent.id] ?? .distantPast) > 60) {
            // Reading the end of the transcript for a title is not free: at turn boundaries, and
            // otherwise at most once a minute, never on every step of a busy chat.
            titleLook[agent.id] = Date()
            // Claude Code names a session a little after it starts, so look again at turn boundaries.
            let info = Self.transcriptInfo(path)
            if let title = info.title {
                agent.name = title
                titled.insert(agent.id)
            } else if let prompt = info.prompt, !agent.background || agent.name == Self.name(for: cwd, source: source) {
                // No title yet (background chats never get one): what was asked says more than a folder name.
                agent.name = oneLine(prompt, max: 44)
            }
        }

        let tool = j["tool_name"] as? String ?? ""
        let input = j["tool_input"] as? [String: Any] ?? [:]
        // Keep the conversation loaded at turn boundaries, so the chat is ready before it is opened.
        if mode == "info", ["Stop", "UserPromptSubmit", "SessionStart"].contains(event) { Threads.load(agent) }
        // The turn is over: anything typed in the notch while it ran goes in now, as a real prompt.
        if mode == "info", event == "Stop", !headless { flushQueued(agent) }

        if mode == "wait" {
            guard !headless else { req.respond(); return }
            // After a tool call the waiter doubles as the progress report.
            if event == "PostToolUse" { info(event: event, agent: agent, json: j, tool: tool, input: input, headless: headless) }
            agent.waiter?.respond()
            // Stop was pressed while a step was running: this is the first moment to say so.
            if let note = agent.stopRequested {
                agent.stopRequested = nil
                agent.waiter = nil
                req.respond(Data(note.utf8))
                return
            }
            // A chat the Claude app owns takes waiting replies through this hook, its only way in.
            // Others wait for the turn to end and get them as real prompts.
            if ownedByApp(agent), event == "Stop" || event == "SessionStart", !agent.queued.isEmpty {
                let text = agent.queued.joined(separator: Threads.queueSeparator)
                agent.queued = []
                store.save()
                relay(text, to: agent, through: req)
                return
            }
            agent.waiter = req
            agent.waiterAtRest = event == "Stop" || event == "SessionStart"
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
            if autoAllow[agent.id]?.contains(tool) == true {
                // The user chose "Always" for this tool in this chat.
                agent.status = .working
                agent.detail = Self.activity(tool: tool, input: input)
                req.respond((try? JSONSerialization.data(withJSONObject: Self.permissionReply(["behavior": "allow"]))) ?? Data())
                return
            }
            guard !hostIsFrontmost(agent) else {
                // You are in its app, so the question is on screen there. Say what it is, do not hold it.
                agent.askElsewhere = "\(Self.toolLabel(tool)): \(oneLine(detail, max: 120))"
                store.ping(agent, sound: false)
                req.respond()
                return
            }
            hold(agent, req, kind: .permission(tool: Self.toolLabel(tool), detail: detail), seconds: 285)
            agent.pending?.toolName = tool

        case ("PreToolUse", "ask"):
            let questions = Self.questions(from: input)
            guard !questions.isEmpty, !hostIsFrontmost(agent) else { req.respond(); return }
            agent.status = .needsYou
            agent.detail = questions[0].text
            hold(agent, req, kind: .question(questions: questions, rawInput: input), seconds: 285)

        case ("Stop", "stop"):
            agent.lastTurnAt = Date()
            let last = j["last_assistant_message"] as? String ?? ""
            if !last.isEmpty { agent.lastMessage = last }
            if !agent.queued.isEmpty {
                // Something was sent from the notch mid-turn: the turn ends as normal, then it goes in
                // as the next prompt, a real one, so the session treats it as the user's own words.
                let text = agent.queued.joined(separator: Threads.queueSeparator)
                agent.queued = []
                store.save()
                req.respond()
                agent.waiter?.respond()
                agent.waiter = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak agent] in
                    guard let self, let agent else { return }
                    self.resume(agent, text: text)
                }
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

    /// Follows the chat's own step list as it creates and ticks off steps, for a progress line
    /// ("3 of 6 done · Building the streams"). Read from the hooks, so it costs nothing.
    private func trackSteps(_ agent: Agent, tool: String, input: [String: Any], json j: [String: Any]) {
        switch tool {
        case "TaskCreate":
            let response = j["tool_response"].map { ($0 as? String) ?? String(describing: $0) } ?? ""
            let id = response.range(of: #"#(\d+)"#, options: .regularExpression).map { String(response[$0].dropFirst()) }
                ?? String(agent.steps.count + 1)
            let subject = input["subject"] as? String ?? ""
            agent.steps.append((id, subject, input["activeForm"] as? String ?? subject, "pending"))
        case "TaskUpdate":
            guard let id = (input["taskId"] as? String) ?? (input["taskId"] as? Int).map(String.init),
                  let i = agent.steps.firstIndex(where: { $0.id == id }) else { return }
            if let status = input["status"] as? String { agent.steps[i].status = status == "deleted" ? "completed" : status }
            if let subject = input["subject"] as? String { agent.steps[i].subject = subject }
            if let doing = input["activeForm"] as? String { agent.steps[i].doing = doing }
        case "TodoWrite":
            let todos = input["todos"] as? [[String: Any]] ?? []
            agent.steps = todos.enumerated().map { n, t in
                let subject = t["content"] as? String ?? ""
                return (String(n + 1), subject, t["activeForm"] as? String ?? subject, t["status"] as? String ?? "pending")
            }
        default: break
        }
    }

    private func info(event: String, agent: Agent, json j: [String: Any], tool: String, input: [String: Any], headless: Bool) {
        if event == "PostToolUse" { trackSteps(agent, tool: tool, input: input, json: j) }
        switch event {
        case "UserPromptSubmit":
            clearPending(agent)
            agent.askElsewhere = nil
            agent.lastTurnAt = Date()
            agent.status = .working
            agent.detail = oneLine(j["prompt"] as? String ?? "Thinking")
        case "PreToolUse":
            // The question hook owns the status while it is being held.
            if agent.pending == nil {
                agent.status = .working
                agent.detail = Self.activity(tool: tool, input: input)
            }
        case "PostToolUse":
            agent.askElsewhere = nil
            if agent.pending == nil { agent.status = .working }
        case "Notification":
            let type = j["notification_type"] as? String ?? ""
            if ["permission_prompt", "agent_needs_input", "elicitation_dialog"].contains(type), agent.pending == nil {
                if agent.status != .needsYou, !hostIsFrontmost(agent) { store.ping(agent) }
                agent.status = .needsYou
                agent.detail = oneLine(j["message"] as? String ?? "Needs you")
            }
        case "Stop":
            if agent.source == .claude { Usage.shared.claudeWorked() }
            // Claude Code: the turn ends normally and a waiter takes replies from here on.
            agent.lastTurnAt = Date()
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
            // The background run has ended, so it is safe to hand the chat to the desktop app.
            if headless { adopt(agent) }
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
        for a in store.agents where a.hostBundleID == bundle && a.pending != nil && a.codexQuestion == nil { clearPending(a) }
    }

    // MARK: Answers from the notch

    func allow(_ agent: Agent) { decide(agent, ["behavior": "allow"]) }

    /// Allow this request and every later one for the same tool in this chat, until Perch restarts.
    func allowAlways(_ agent: Agent) {
        if let tool = agent.pending?.toolName { autoAllow[agent.id, default: []].insert(tool) }
        allow(agent)
    }

    private var autoAllow: [String: Set<String>] = [:]

    private static func permissionReply(_ decision: [String: Any]) -> [String: Any] {
        ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
    }

    func deny(_ agent: Agent) { decide(agent, ["behavior": "deny", "message": "Denied from the notch."]) }

    private func decide(_ agent: Agent, _ decision: [String: Any]) {
        agent.pending?.finish(Self.permissionReply(decision))
        agent.pending = nil
        agent.status = .working
        agent.detail = decision["behavior"] as? String == "allow" ? "Allowed, carrying on" : "Denied"
    }

    func answer(_ agent: Agent, answers: [String: String]) {
        if let batch = agent.codexQuestion {
            answerCodex(agent, batch: batch, answers: answers)
            return
        }
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

    func syncCodexQuestions(_ agent: Agent, batches: [CodexQuestionBatch]) {
        let batch = batches.first { !agent.handledCodexQuestions.contains($0.callID) }
        guard let batch else {
            if agent.codexQuestion != nil {
                agent.codexQuestion = nil
                agent.codexQuestionError = nil
                agent.pending = nil
                agent.status = agent.codexWorking ? .working : .done
            }
            return
        }
        // Keep the same card and selections while unrelated transcript records arrive.
        if agent.codexQuestion == batch { return }
        if agent.pending != nil && agent.codexQuestion == nil { return }
        let questions = batch.items.map { Question(text: $0.title, header: "", options: $0.options, multiSelect: false) }
        agent.codexQuestion = batch
        agent.codexQuestionError = nil
        agent.pending = PendingRequest(kind: .question(questions: questions, rawInput: [:]), deadline: .distantFuture) { _ in }
        agent.status = .needsYou
        agent.detail = batch.items.first?.title ?? "Has a question"
        store.ping(agent)
    }

    private func answerCodex(_ agent: Agent, batch: CodexQuestionBatch, answers: [String: String]) {
        guard !agent.sending, let text = batch.reply(answers: answers) else { return }
        guard let exe = Shell.find("codex") else {
            agent.codexQuestionError = "Could not find Codex. Your answer has not been sent."
            return
        }
        agent.codexQuestionError = nil
        agent.sending = true
        Shell.run(exe, ["queue", "--thread", agent.sessionID, "--message=\(text)"], cwd: agent.cwd,
                  env: ["PERCH_HEADLESS": "1"], captureErrors: true, completion: { [weak self, weak agent] code, output in
            guard let self, let agent else { return }
            agent.sending = false
            guard code == 0 else {
                agent.codexQuestionError = "Could not send your answer. Try again. " + oneLine(output, max: 160)
                return
            }
            agent.handledCodexQuestions.insert(batch.callID)
            if agent.codexQuestion?.callID == batch.callID {
                agent.pending = nil
                agent.codexQuestion = nil
                agent.codexQuestionError = nil
                agent.status = agent.codexWorking ? .working : .done
                agent.detail = "Answer queued in Codex"
            }
            if let readable = CodexQuestionTracker.readableAnswer(text) { agent.addLocal(readable) }
            self.store.save()
        })
    }

    /// Hands the prompt back to the agent's own app.
    func dismiss(_ agent: Agent) {
        if let batch = agent.codexQuestion {
            agent.handledCodexQuestions.insert(batch.callID)
            agent.codexQuestion = nil
            agent.codexQuestionError = nil
        }
        clearPending(agent)
    }

    func reply(_ agent: Agent, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let messageID = agent.addLocal(text)
        if agent.source == .codex {
            queueCodex(agent, text: text, messageID: messageID)
            return
        }
        // Messages often come in a quick burst (two or three about the same thing). They are
        // gathered for a few seconds, each one restarting the wait, and go in together as one.
        agent.gathering.append(text)
        agent.gatherWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak agent] in
            guard let self, let agent, !agent.gathering.isEmpty else { return }
            let all = agent.gathering.joined(separator: Threads.queueSeparator)
            agent.gathering = []
            self.deliver(agent, text: all)
        }
        agent.gatherWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// Sends what was gathered by the route this chat allows.
    private func deliver(_ agent: Agent, text: String) {
        // A turn Perch started moments ago on an earlier message: stop it and start again with
        // both, so a follow-up is read with the message it follows, not as a separate job after.
        if agent.source == .claude, let runner = agent.runner, runner.isRunning,
           let started = agent.turnStartedAt, Date().timeIntervalSince(started) < 30 {
            agent.queued.append(text)
            store.save()
            agent.interrupting = true
            agent.detail = "Adding your follow-up…"
            runner.interrupt()
            return
        }
        // A chat the Claude app owns whose waiter came at the end of its turn is idle, even if its
        // status missed the turn ending (Perch restarting at that moment): in it goes, now.
        if ownedByApp(agent), let waiter = agent.waiter, agent.waiterAtRest {
            relay(text, to: agent, through: waiter)
            return
        }
        // Otherwise a busy chat finishes its turn first, so long work is never cut off halfway;
        // "Interrupt with it" is there for when that is wanted.
        if (agent.status == .working && agent.pending == nil) || agent.sending {
            // Mid-turn with no way in right now: hold it for the next opening, a moment away.
            agent.queued.append(text)
            // Written down at once: a message waiting for its turn must survive Perch restarting.
            store.save()
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
        // A chat the Claude app has open runs in the app's own process. A second copy started here
        // would work alongside it unseen, so its reply goes through the app's session instead.
        if ownedByApp(agent) {
            if let waiter = agent.waiter {
                relay(text, to: agent, through: waiter)
            } else {
                agent.queued.append(text)
                store.save()
                agent.detail = "Waiting for the Claude app's session to take it"
                wakeInApp(agent)
            }
            return
        }
        // Idle: the reply goes in as a real prompt, so the session treats it as the user's own
        // words rather than a message relayed by a hook. A hook Perch is holding for this chat is
        // let go first, quietly, so the session is not woken twice.
        if let pending = agent.pending, case .followUp = pending.kind {
            pending.finish()
            agent.pending = nil
        }
        agent.waiter?.respond()
        agent.waiter = nil
        let earlier = agent.queued
        agent.queued = []
        resume(agent, text: (earlier + [text]).joined(separator: Threads.queueSeparator))
    }

    /// The chat lives in the Claude app (it was opened there, or handed over to it).
    func ownedByApp(_ agent: Agent) -> Bool {
        agent.source == .claude && (agent.adopted || agent.hostBundleID == Self.claudeBundleID) && agent.runner == nil
    }

    /// When each chat was last reopened in the app to take a waiting reply.
    private var woken: [String: Date] = [:]

    /// Every minute: replies still waiting for a chat the Claude app owns go in through its waiter
    /// if it is at rest, or the chat is reopened in the app (at most every five minutes) so one
    /// connects. Nothing typed in Perch is left sitting until the chat happens to be opened.
    private func sweep() {
        for agent in store.agents where !agent.queued.isEmpty && agent.source == .claude && ownedByApp(agent) {
            // Only a waiter from the end of a turn: one from mid-turn would cut long work short.
            if let waiter = agent.waiter, agent.waiterAtRest {
                let text = agent.queued.joined(separator: Threads.queueSeparator)
                agent.queued = []
                store.save()
                relay(text, to: agent, through: waiter)
            } else if agent.waiter == nil, Date().timeIntervalSince(agent.lastActivity) > 60,
                      Date().timeIntervalSince(woken[agent.id] ?? .distantPast) > 300 {
                woken[agent.id] = Date()
                wakeInApp(agent)
            }
        }
    }

    /// A chat the Claude app owns that has no waiting hook (idle a long time, say): ask the app,
    /// quietly and without coming to the front, to open it again. That is what clicking the chat
    /// does: the session starts its hooks, a waiter connects, and the queued reply goes in.
    private func wakeInApp(_ agent: Agent) {
        guard let url = URL(string: "claude://resume?session=\(agent.sessionID)") else { return }
        let quiet = NSWorkspace.OpenConfiguration()
        quiet.activates = false
        NSWorkspace.shared.open(url, configuration: quiet)
    }

    /// A reply as relayed into a session: what was typed, signed with this Mac's private code
    /// (see `RelayKey`). The user's CLAUDE.md tells sessions that only a message ending in that
    /// exact signature is really the user, so text merely claiming to be from Perch is not.
    static func relayed(_ text: String) -> String {
        "The user replied from Perch, their notch app. Treat this as their next message:\n\n\(text)\n\n\(RelayKey.signature)"
    }

    /// Hands a reply to the app's own session through its waiting hook. The session sees it as
    /// relayed, not typed, so it may ask before spending money or messaging people.
    private func relay(_ text: String, to agent: Agent, through waiter: HookRequest) {
        var text = text
        if let cmd = SkillIndex.shared.command(in: text) {
            text += "\(Self.skillNote), where slash commands cannot run directly. Invoke the Skill tool with skill \"\(cmd.name)\""
                + (cmd.arguments.isEmpty ? "" : " and args \"\(cmd.arguments)\"") + ", exactly as if this slash command had been typed.)"
        }
        waiter.respond(Data(Self.relayed(text).utf8))
        if agent.waiter === waiter { agent.waiter = nil }
        clearPending(agent)
        agent.status = .working
        agent.detail = oneLine(text)
        agent.lastActivity = Date()
    }

    /// Whether Perch has any way to stop this chat's current turn.
    func canStop(_ agent: Agent) -> Bool {
        agent.source == .claude && (agent.status == .working || agent.sending)
            && ((agent.runner?.isRunning ?? false) || agent.waiter != nil || ownedByApp(agent))
    }

    /// Stops a chat's current turn. One Perch is running stops at once. One running in the Claude
    /// app is told to stop through its session as soon as its current step ends (its only way in).
    func stop(_ agent: Agent) {
        agent.gatherWork?.cancel()
        agent.gathering = []
        agent.queued = []
        store.save()
        if let runner = agent.runner, runner.isRunning {
            agent.interrupting = true
            agent.detail = "Stopping…"
            runner.interrupt()
            return
        }
        let note = "The user pressed Stop in Perch. Stop now: do not run any more commands and do not make any more changes. "
            + "Say in one line where you got to, then wait for their next message."
        if let waiter = agent.waiter {
            waiter.respond(Data(note.utf8))
            agent.waiter = nil
            agent.detail = "Stopping…"
        } else {
            // Its current step is still running: the stop goes in the moment that step ends.
            agent.stopRequested = note
            agent.detail = "Stopping after this step…"
        }
    }

    /// Whether a turn Perch is running could be stopped to send the waiting replies now.
    func canInterrupt(_ agent: Agent) -> Bool {
        agent.source == .claude && !agent.queued.isEmpty && (agent.runner?.isRunning ?? false)
    }

    /// Stops a turn Perch is running and sends the waiting replies straight away, as real prompts.
    func interrupt(_ agent: Agent) {
        guard canInterrupt(agent), let runner = agent.runner else { return }
        agent.interrupting = true
        agent.detail = "Interrupting…"
        runner.interrupt()
    }

    /// Whether replies waiting for a turn to end could go in right now instead, mid-turn.
    func canSendNow(_ agent: Agent) -> Bool { agent.source == .claude && agent.waiter != nil && !agent.queued.isEmpty }

    /// Sends waiting replies into the running turn at once, through the session's hook. The
    /// session sees them as relayed rather than typed, so it may ask before doing anything that
    /// spends money or reaches other people; waiting for the turn to end avoids that.
    func sendNow(_ agent: Agent) {
        guard let waiter = agent.waiter, !agent.queued.isEmpty else { return }
        let text = agent.queued.joined(separator: Threads.queueSeparator)
        agent.queued = []
        store.save()
        agent.waiter = nil
        waiter.respond(Data(Self.relayed(text).utf8))
    }

    /// Wakes the real session, so the reply and the answer both show up in its own chat.
    static let skillNote = "\n\n(Sent from the notch"

    /// Starts a new Claude Code session from the notch.
    ///
    /// The first turn runs in the background through the `claude` command, in auto mode, so the
    /// chat is a normal one: your prompt, then the answer. When that turn is finished the Claude
    /// desktop app is asked to adopt it. Not sooner: the app reads a chat once, at the moment it
    /// adopts it, so handing it over mid-turn leaves the app without the reply.
    @discardableResult
    func startChat(prompt: String, folder: String) -> Agent? {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        let id = UUID().uuidString.lowercased()
        let agent = store.upsert(source: .claude, sessionID: id, name: Self.quickTitle(prompt))
        agent.cwd = folder
        agent.background = true
        agent.kept = true
        agent.addLocal(prompt)
        titled.insert(agent.id)
        guard let exe = Shell.find("claude") else {
            agent.detail = "Could not find the claude command"
            return agent
        }
        makeTitle(for: prompt, exe: exe) { [weak agent] made in
            if let made { agent?.name = made }
        }
        run(agent, exe: exe, text: prompt,
            // "--name=" and "--" keep a message (or title) that starts with "-" from being read as
            // an option ("error: unknown option '- Fix …'").
            args: ["-p", "--permission-mode", "auto", "--session-id", id, "--name=\(Self.quickTitle(prompt))", "--", prompt])

        return agent
    }

    /// A title to show the moment a chat starts, from its first sentence with the asking words
    /// taken off ("can you look at the login page" is "Look at the login page"). The model's
    /// title replaces it a few seconds later.
    static func quickTitle(_ prompt: String) -> String {
        // A link reads as its site and page ("https://www.bland.ai/product/imessage?…" is
        // "bland.ai imessage"), not the raw address.
        let linked = prompt.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            guard let url = URL(string: String(word)), let host = url.host, url.scheme?.hasPrefix("http") == true else { return String(word) }
            let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let page = url.pathComponents.last { $0 != "/" }?.replacingOccurrences(of: "-", with: " ") ?? ""
            return page.isEmpty ? site : "\(site) \(page)"
        }.joined(separator: " ")
        // A list item's dash or bullet is not part of the title.
        var t = oneLine(linked, max: 200).trimmingCharacters(in: CharacterSet(charactersIn: "-*•–>").union(.whitespaces))
        if let end = t.firstIndex(where: { ".?!\n".contains($0) }), t.distance(from: t.startIndex, to: end) > 12 {
            t = String(t[..<end])
        }
        let filler = ["hey", "hi", "ok", "okay", "so", "please", "can you", "could you", "would you", "can we", "could we",
                      "i want you to", "i need you to", "i want to", "i need to", "i'd like you to", "i would like you to",
                      "let's", "lets", "just", "quickly"]
        var changed = true
        while changed {
            changed = false
            for f in filler where t.lowercased().hasPrefix(f + " ") || t.lowercased().hasPrefix(f + ",") {
                t = String(t.dropFirst(f.count + 1)).trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
                changed = true
            }
        }
        let words = t.split(separator: " ").prefix(7).joined(separator: " ")
        guard let first = words.first else { return oneLine(prompt, max: 44) }
        return first.uppercased() + words.dropFirst()
    }

    /// Starts a new Codex chat from the notch, in the background, able to edit files in its folder.
    /// It starts through Codex's app server, so it is one of the Codex app's own chats and shows in
    /// its list, named. It shows here straight away and becomes the chat the rollout watcher
    /// follows once Codex has given it an id.
    @discardableResult
    func startCodexChat(prompt: String, folder: String) -> Agent? {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        let title = Self.quickTitle(prompt)
        let starting = store.upsert(source: .codex, sessionID: "starting-\(UUID().uuidString.lowercased())", name: title)
        starting.cwd = folder
        starting.kept = true
        starting.hostBundleID = Self.codexBundleID
        starting.addLocal(prompt)
        starting.status = .working
        starting.detail = "Starting in Codex…"
        guard let start = CodexStart(folder: folder, prompt: prompt, title: title) else {
            starting.status = .done
            starting.detail = "Could not find the codex command"
            return starting
        }
        var chat: Agent?
        start.started = { [weak self, weak starting] id in
            guard let self, let starting else { return }
            let real = self.store.upsert(source: .codex, sessionID: id, name: starting.name)
            real.name = starting.name
            real.cwd = folder
            real.kept = true
            real.hostBundleID = Self.codexBundleID
            real.thread = starting.thread
            real.status = .working
            real.detail = oneLine(prompt)
            chat = real
            if NotchUI.shared.selectedID == starting.id { NotchUI.shared.selectedID = real.id }
            self.store.remove(starting)
            self.store.save()
        }
        start.finished = { [weak starting] problem in
            if let chat {
                if chat.status == .working { chat.status = .done }
                Threads.load(chat)
            } else if let starting {
                starting.status = .done
                starting.detail = problem ?? "Codex did not start"
            }
        }
        // A tidier title from the small model, given to Codex too, once it has one.
        if let claude = Shell.find("claude") {
            makeTitle(for: prompt, exe: claude) { made in
                guard let made else { return }
                (chat ?? starting).name = made
                start.name(made)
            }
        }
        return starting
    }

    /// Asks a small, fast model for a short title for a chat that opens with `prompt`. Started
    /// without MCP servers, skills or settings, which it has no use for.
    private func makeTitle(for prompt: String, exe: String, completion: @escaping (String?) -> Void) {
        let ask = "Write a short title for a chat that starts with the request below. 3 to 6 words, sentence case, "
            + "no quotes, no full stop. Reply with the title only.\n\nRequest: \(String(prompt.prefix(1200)))"
        let empty = "\(Shell.home)/.perch/no-mcp.json"
        if !FileManager.default.fileExists(atPath: empty) { try? Data("{\"mcpServers\":{}}".utf8).write(to: URL(fileURLWithPath: empty)) }
        Shell.run(exe, ["-p", "--model", "haiku", "--strict-mcp-config", "--mcp-config", empty, "--disable-slash-commands",
                        "--no-session-persistence", "--setting-sources", "", ask],
                  cwd: "\(Shell.home)/.perch", env: ["PERCH_SKIP": "1"]) { code, output in
            let line = oneLine(output.trimmingCharacters(in: .whitespacesAndNewlines), max: 60)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.“” "))
            completion(code == 0 && line.count > 2 ? line : nil)
        }
    }

    /// Records a title in the session the way Claude Code does, so every app that lists it agrees.
    private func writeTitle(_ title: String, sessionID: String) {
        let root = "\(Shell.home)/.claude/projects"
        let fm = FileManager.default
        guard let project = (try? fm.contentsOfDirectory(atPath: root))?
                .first(where: { fm.fileExists(atPath: "\(root)/\($0)/\(sessionID).jsonl") }),
              let handle = FileHandle(forWritingAtPath: "\(root)/\(project)/\(sessionID).jsonl") else { return }
        defer { try? handle.close() }
        let lines: [[String: Any]] = [
            ["type": "custom-title", "customTitle": title, "sessionId": sessionID],
            ["type": "agent-name", "agentName": title, "sessionId": sessionID],
        ]
        _ = try? handle.seekToEnd()
        for line in lines {
            if let data = try? JSONSerialization.data(withJSONObject: line) { handle.write(data + Data([0x0A])) }
        }
    }

    /// Asks the Claude desktop app to take on a chat that was started from the notch, so it
    /// appears in the app's own list. Done between turns, never while the session is running,
    /// and without pulling the app to the front.
    private func adopt(_ agent: Agent) {
        guard agent.background, !agent.adopted, agent.source == .claude,
              let url = URL(string: "claude://resume?session=\(agent.sessionID)") else { return }
        agent.adopted = true
        agent.hostBundleID = Self.claudeBundleID
        // The chat's name goes into the session first, so it arrives in the app already titled.
        writeTitle(agent.name, sessionID: agent.sessionID)
        let quiet = NSWorkspace.OpenConfiguration()
        quiet.activates = false
        NSWorkspace.shared.open(url, configuration: quiet)
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
        let agent = store.upsert(source: entry.source, sessionID: entry.id, name: entry.title)
        agent.transcriptPath = entry.path
        agent.cwd = entry.cwd
        agent.hostBundleID = entry.source == .codex ? Self.codexBundleID : Self.claudeBundleID
        agent.lastActivity = Date()
        agent.kept = true
        titled.insert(agent.id)
        store.save()
        return agent
    }

    /// Queue through the running Codex daemon. Resuming in a new process would collide
    /// with the desktop app's writer even when its visible turn is idle.
    private func queueCodex(_ agent: Agent, text: String, messageID: String) {
        guard let exe = Shell.find("codex") else {
            failCodexDelivery(agent, text: text, messageID: messageID, reason: "Could not find the codex command")
            return
        }
        agent.unsent[messageID] = nil
        agent.sending = true
        agent.detail = "Sending to Codex…"
        Shell.run(exe, ["queue", "--thread", agent.sessionID, "--message=\(text)"], cwd: agent.cwd,
                  env: ["PERCH_HEADLESS": "1"], captureErrors: true, completion: { [weak self, weak agent] code, output in
            guard let self, let agent else { return }
            agent.sending = false
            guard code == 0 else {
                self.failCodexDelivery(agent, text: text, messageID: messageID,
                                       reason: oneLine(output, max: 400))
                return
            }
            agent.failedReplies[messageID] = nil
            agent.unsent[messageID] = nil
            agent.lastActivity = Date()
            agent.detail = "Message queued in Codex"
            // Only accepted rollout messages belong in history. Queued or cancelled messages
            // must not linger as optimistic delivered bubbles.
            agent.thread.removeAll { $0.id == messageID }
            CodexQueue.shared.refresh(agent)
            // Queue acknowledgement is not an assistant response. The rollout watcher
            // supplies lifecycle and answer updates from the existing owner.
            if let pending = agent.pending, case .followUp = pending.kind { self.clearPending(agent) }
            self.store.save()
            Threads.load(agent)
        })
    }

    private func installCodexRetry(_ agent: Agent, text: String, messageID: String) {
        agent.unsent[messageID] = { [weak self, weak agent] in
            guard let self, let agent else { return }
            self.queueCodex(agent, text: text, messageID: messageID)
        }
    }

    private func failCodexDelivery(_ agent: Agent, text: String, messageID: String, reason: String) {
        agent.detail = reason.isEmpty ? "Could not queue the message in Codex. Try again." : reason
        agent.failedReplies[messageID] = text
        installCodexRetry(agent, text: text, messageID: messageID)
        store.save()
    }

    /// The turn is long over, so continue the session in the background instead.
    private func resume(_ agent: Agent, text: String) {
        if agent.source == .codex {
            let id = agent.thread.last(where: { $0.fromUser && $0.text == text })?.id ?? agent.addLocal(text)
            queueCodex(agent, text: text, messageID: id)
            return
        }
        let tool = "claude"
        guard let exe = Shell.find(tool) else {
            agent.detail = "Could not find the \(tool) command"
            return
        }
        // A chat started here whose first run never got going has nothing to resume yet.
        let neverStarted = agent.background && agent.transcriptPath == nil
        // Chats started from the notch run in auto mode, so they do not stop to ask at every step.
        let auto = agent.background ? ["--permission-mode", "auto"] : []
        let args = neverStarted ? ["-p"] + auto + ["--session-id", agent.sessionID, "--", text]
                                : ["-p"] + auto + ["--resume", agent.sessionID, "--", text]
        run(agent, exe: exe, text: text, args: args)
    }

    private func run(_ agent: Agent, exe: String, text: String, args: [String]) {
        agent.turnStartedAt = Date()
        agent.sending = true
        agent.status = .working
        agent.detail = oneLine(text)
        agent.lastActivity = Date()
        agent.runner = Shell.run(exe, args, cwd: agent.cwd, env: ["PERCH_HEADLESS": "1"], captureErrors: true) { [weak self, weak agent] code, output in
            guard let self, let agent else { return }
            agent.sending = false
            agent.runner = nil
            agent.lastActivity = Date()
            if agent.interrupting {
                // Stopped to make way for what the user just sent (or just stopped): that goes in now.
                agent.interrupting = false
                agent.status = .done
                agent.detail = agent.queued.isEmpty ? "Stopped" : agent.detail
                Threads.load(agent)
                if !agent.queued.isEmpty {
                    let next = agent.queued.joined(separator: Threads.queueSeparator)
                    agent.queued = []
                    self.store.save()
                    self.resume(agent, text: next)
                }
                return
            }
            let reply = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if code != 0 {
                agent.status = .done
                let tool = agent.source == .codex ? "codex" : "claude"
                let errorLine = reply.components(separatedBy: .newlines).last(where: {
                    $0.hasPrefix("ERROR:") || $0.hasPrefix("Error:") || $0.hasPrefix("error:")
                }) ?? reply
                let why = errorLine.isEmpty
                    ? "Could not run \(tool) (exit \(code)). Check \(tool) login status in Terminal."
                    : oneLine(errorLine, max: 400)
                agent.detail = why
                agent.thread.append(ChatMessage(id: "error-\(UUID().uuidString)", fromUser: false, text: "_\(why)_"))
            } else if !reply.isEmpty {
                agent.lastMessage = reply
                agent.status = .done
                agent.detail = oneLine(reply)
                AgentStore.shared.ping(agent)
                Threads.load(agent)
            }
            if code == 0 { self.adopt(agent) }
            // Anything typed while it was busy goes in as the next turn.
            if code == 0, !agent.queued.isEmpty {
                let next = agent.queued.joined(separator: Threads.queueSeparator)
                agent.queued = []
                self.resume(agent, text: next)
            }
        }
    }

    /// The rollout watcher can finish a Codex turn even when no stop hook is installed.
    func flushQueued(_ agent: Agent) {
        guard !agent.sending, agent.pending == nil, !agent.queued.isEmpty, !ownedByApp(agent) else { return }
        let next = agent.queued.joined(separator: Threads.queueSeparator)
        agent.queued = []
        store.save()
        // A hook Perch is holding is let go first, so the session is not woken twice.
        agent.waiter?.respond()
        agent.waiter = nil
        resume(agent, text: next)
    }

    func open(_ agent: Agent) {
        if agent.background, let url = URL(string: "claude://resume?session=\(agent.sessionID)") {
            // A chat started in the notch: ask Claude to bring it in.
            NSWorkspace.shared.open(url)
            return
        }
        if agent.source == .claude, !agent.background || agent.adopted {
            func go() -> Bool {
                guard let local = desktopIDs[agent.sessionID],
                      let url = URL(string: "claude://code/continue?session=\(local)") else { return false }
                // Straight to this exact chat in the Claude app, not just the app.
                NSWorkspace.shared.open(url)
                return true
            }
            if go() { return }
            // Not in the lookup yet (a brand new chat): bring Claude forward now, and land on the
            // chat a moment later once it has been found.
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.claudeBundleID) {
                NSWorkspace.shared.openApplication(at: app, configuration: .init())
            }
            indexDesktopSessions { _ = go() }
            return
        }
        guard let bundle = agent.hostBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    // MARK: Helpers

    private var desktopIDs: [String: String] = [:]
    private var indexing = false

    /// The Claude desktop app keeps its own id for each chat. This builds the lookup from Claude
    /// Code session id to that id, off the main thread, by reading the small records the app
    /// keeps. It is done ahead of time so opening a chat never has to wait for it.
    private func indexDesktopSessions(then done: (() -> Void)? = nil) {
        guard !indexing else { return }
        indexing = true
        DispatchQueue.global(qos: .utility).async {
            let root = "\(Shell.home)/Library/Application Support/Claude/claude-code-sessions"
            var found: [String: String] = [:]
            func value(_ key: String, in text: String) -> String? {
                guard let k = text.range(of: "\"\(key)\":\"") else { return nil }
                let rest = text[k.upperBound...]
                return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
            }
            if let walker = FileManager.default.enumerator(atPath: root) {
                for case let file as String in walker where file.hasSuffix(".json") {
                    // The two ids sit near the top of each record; no need to read or parse the rest.
                    guard let handle = FileHandle(forReadingAtPath: "\(root)/\(file)") else { continue }
                    let head = (try? handle.read(upToCount: 16 << 10)) ?? Data()
                    try? handle.close()
                    let text = String(decoding: head, as: UTF8.self)
                    if let cli = value("cliSessionId", in: text), let local = value("sessionId", in: text) { found[cli] = local }
                }
            }
            DispatchQueue.main.async {
                self.desktopIDs = found
                self.indexing = false
                done?()
            }
        }
    }

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
        if let q = input["query"] as? String { return q }
        // Anything else: the simple fields, one per line, instead of raw JSON.
        let lines = input.keys.sorted().compactMap { key -> String? in
            if let s = input[key] as? String, !s.isEmpty { return "\(key): \(oneLine(s, max: 140))" }
            if let n = input[key] as? NSNumber { return "\(key): \(n)" }
            return nil
        }
        if !lines.isEmpty { return lines.prefix(6).joined(separator: "\n") }
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
