import AppKit

/// Grok Bot agents. Talks to the Grok Bot host through one long-lived bridge process
/// (bridge/grok-bridge.mjs) that reuses the gateway client from the grokbot Claude Code
/// plugin. That client uses Grok Bot's private host API, so an app update can break this.
final class GrokSource {
    static let shared = GrokSource()
    static let bundleID = "com.anysphere.sand"

    private let store = AgentStore.shared
    private var node: String?
    private var cli: String?
    private var bridge: Process?
    private var bridgeInput: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var waiting: [Int: (Any?) -> Void] = [:]
    private var debounce: DispatchWorkItem?
    private var timer: Timer?
    /// The newest transcript entry each bot's cached thread was loaded at.
    private var threadStamp: [String: String] = [:]

    // MARK: Hidden from Perch

    /// Bots kept out of the notch, the sidebar and notifications (someone else's, say). They can
    /// still be found by search and opened from there. Grok Bot itself is not touched.
    static var hidden: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "hiddenBots") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "hiddenBots") }
    }

    func hide(_ agent: Agent) {
        Self.hidden.insert(agent.sessionID)
        agent.unread = 0
    }

    // MARK: What a working bot is doing

    /// The phrase Grok Bot shows under a working bot, from the tool it is using right now.
    /// Mirrors Grok Bot's own rules and wording. A general "working" or "thinking" gets one of
    /// a few phrases, picked when it starts and kept until the activity changes.
    private var activityPick: [String: (kind: String, phrase: String)] = [:]

    private static let thinkingPhrases = ["Thinking it through", "Mulling it over", "Putting it together"]
    private static let workingPhrases = ["Getting it done", "Making progress", "Working on it", "Handling it", "Chipping away"]

    private func activityText(_ raw: [String: Any], id: String) -> String? {
        let running = (raw["isRunning"] as? Bool ?? false) || (raw["isRunningTurn"] as? Bool ?? false)
        guard running else { activityPick[id] = nil; return nil }
        let a = raw["currentActivity"] as? [String: Any]
        let tool = a?["tool"] as? String ?? ""
        let detail = (a?["detail"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let target = a?["target"] as? String
        let kind: String
        var fixed: String?
        if a?["kind"] as? String == "thinking" {
            kind = "thinking"
        } else {
            switch tool {
            case "": kind = "working"
            case "WebSearch": kind = "searching"; fixed = "Digging around"
            case "WebFetch": kind = "reading-web"; fixed = "Doing some reading"
            case "Read", "BoxRead", "Skill": kind = "reading"; fixed = "Reading the file"
            case "MachineShell": kind = detail != nil ? "drafting" : "yours"; fixed = detail != nil ? "Jotting it down" : "Working on your computer"
            case "Shell", "BoxShell": kind = detail != nil ? "drafting" : "commands"; fixed = detail != nil ? "Jotting it down" : "Running a few commands"
            case "CopyToBox", "CopyFromBox": kind = "files"; fixed = "Moving files over"
            case "Await", "AwaitShell": kind = "waiting"; fixed = "Waiting on results"
            case "GenerateImage": kind = "photo"; fixed = "Sketching something up"
            case "GenerateVideo": kind = "video"; fixed = "Filming a clip"
            case "CloudAgent": kind = "coding"; fixed = "Writing some code"
            case "Task" where target == "computerUse", "Screenshot", "Computer", "request_box_help":
                kind = "computer"; fixed = "Clicking around"
            case "request_user_form", "RequestUserForm": kind = "you"; fixed = "Needs your input"
            case "remap_user_form_targets", "RemapUserFormTargets": kind = "browsing"; fixed = "Clicking through pages"
            case "SendToAgent", "UpdateAgent":
                kind = "bot"
                let name = target.flatMap { t in store.find("grok:\(t)")?.name }
                fixed = name.map { "Checking with \($0)" } ?? "Checking with another Bot"
            case "CreateAgent", "ReactToMessage", "SendIMessage": kind = "messaging"; fixed = "Sending a message"
            case "CheckSubscriptionUsage": kind = "usage"; fixed = "Checking your usage"
            case "FetchConnectedActivity": kind = detail == "cursor" ? "working" : "yours"; fixed = detail == "cursor" ? nil : "Working on your computer"
            default:
                if tool.hasPrefix("browser_") {
                    kind = "browsing"; fixed = "Clicking through pages"
                } else if tool == "CallMcpTool" || ["GetMcpTools", "McpAuth", "SearchPlugins", "GetPlugin", "InstallPlugin",
                            "UninstallPlugin", "GetMcpServerStatus", "AddMcpServer", "UninstallMcpServer", "AuthenticateMcpServer",
                            "RestartMcpServers", "SetMcpInstructions", "SearchMcpServers", "InstallMcpServer", "EnableTeamServer"].contains(tool) {
                    kind = "app"
                    let service = Self.serviceName(detail)
                    fixed = service.map { "Working in \($0)" } ?? "Working in a connected app"
                } else {
                    kind = "working"
                }
            }
        }
        if let fixed { activityPick[id] = (kind, fixed); return fixed }
        if let kept = activityPick[id], kept.kind == kind { return kept.phrase }
        let phrase = (kind == "thinking" ? Self.thinkingPhrases : Self.workingPhrases).randomElement()!
        activityPick[id] = (kind, phrase)
        return phrase
    }

    /// A connected app's name as Grok Bot shows it: "google-calendar" becomes "Google Calendar".
    private static func serviceName(_ raw: String?) -> String? {
        guard var s = raw, !s.isEmpty, s.lowercased() != "cursor" else { return nil }
        if let cut = s.range(of: "--", options: .backwards) { s = String(s[..<cut.lowerBound]) }
        for prefix in ["dashboard-", "user-", "cursor-"] where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        if s.hasSuffix("-xai") { s = String(s.dropLast(4)) }
        let words = s.contains(" ") ? [s] : s.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        let name = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    // MARK: Quiet phone while reading

    /// Each bot's own phone notification setting, as Grok Bot last reported it.
    private var notifying: [String: Bool] = [:]
    /// The latest message from each bot that has been announced, and any request for the user.
    private var announced: [String: String] = [:]
    private var asked: [String: String] = [:]
    /// Bots whose phone notifications Perch has paused because their chat is open in front of
    /// the user, by bot id, with when the chat was last seen open. Saved, so a crash or quit
    /// never leaves a bot silenced.
    private var paused: [String: Date] = [:] {
        didSet {
            // Seen timestamps move every two seconds; only the set of muted bots is persisted.
            if Set(paused.keys) != Set(oldValue.keys) {
                UserDefaults.standard.set(Array(paused.keys), forKey: "perchPausedBots")
            }
        }
    }
    private var quietTimer: Timer?

    /// While a bot's chat is open in the notch or the side panel and the user is at the Mac,
    /// its messages are being read as they come, so the phone stays quiet. A little after the
    /// chat closes (or the user walks away) notifications come back on.
    private func watchQuiet() {
        for id in UserDefaults.standard.stringArray(forKey: "perchPausedBots") ?? [] { paused[id] = .distantPast }
        quietTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.quietTick() }
        quietTimer?.tolerance = 0.5
    }

    private func quietTick() {
        let ui = NotchUI.shared
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        var open = Set<String>()
        if idle < 120 {
            if ui.expanded, !ui.cardsOnly, let id = ui.selectedID, id.hasPrefix("grok:") { open.insert(String(id.dropFirst(5))) }
            if let id = SidePanel.shared.agentID, id.hasPrefix("grok:") { open.insert(String(id.dropFirst(5))) }
        }
        for id in open {
            if paused[id] != nil { paused[id] = Date(); continue }
            // Only bots that notify in the first place, so a bot the user silenced stays that way.
            guard notifying[id] != false else { continue }
            paused[id] = Date()
            request("setAgentNotifyOnUpdates", ["id": id, "isEnabled": false])
        }
        for (id, seen) in paused where !open.contains(id) && Date().timeIntervalSince(seen) > 45 {
            paused[id] = nil
            notifying[id] = true
            request("setAgentNotifyOnUpdates", ["id": id, "isEnabled": true])
        }
    }

    func start() {
        watchQuiet()
        node = Shell.find("node")
        cli = Self.locateCLI()
        guard node != nil, cli != nil else {
            store.grokError = node == nil ? "Node was not found" : "The grokbot plugin was not found"
            return
        }
        // Show the bots from last time straight away; the live list replaces them in a few seconds.
        for row in UserDefaults.standard.array(forKey: "grokRoster") as? [[String: String]] ?? [] {
            guard let id = row["id"], let name = row["name"] else { continue }
            let agent = store.upsert(source: .grok, sessionID: id, name: name)
            agent.avatarColor = row["color"]
            agent.avatarShape = row["shape"].flatMap { $0.isEmpty ? nil : $0 } ?? GrokShapes.defaultName(for: id)
            agent.hostBundleID = Self.bundleID
        }
        startBridge()
        refreshUsage()
        let usageTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.refreshUsage() }
        usageTimer.tolerance = 60
        refresh()
        // Safety net in case the event stream drops something.
        timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 10
        // While a bot is at work, what it is doing changes by the second: look more often.
        let busy = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.store.grokBots.contains(where: { $0.status == .working }) else { return }
            self.refresh()
        }
        busy.tolerance = 1
    }

    func stop() { bridge?.terminate() }

    private static func locateCLI() -> String? {
        let cache = "\(Shell.home)/.claude/plugins/cache"
        let fm = FileManager.default
        var found: [(String, Date)] = []
        for market in (try? fm.contentsOfDirectory(atPath: cache)) ?? [] {
            let base = "\(cache)/\(market)/grokbot"
            for version in (try? fm.contentsOfDirectory(atPath: base)) ?? [] {
                let p = "\(base)/\(version)/cli/dist/grokbot.mjs"
                if let d = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date { found.append((p, d)) }
            }
        }
        return found.max { $0.1 < $1.1 }?.0
    }

    // MARK: Bridge

    private func startBridge() {
        guard let node, let cli, let script = Bundle.main.path(forResource: "grok-bridge", ofType: "mjs") else {
            store.grokError = "Perch is missing its Grok bridge"
            return
        }
        let src = URL(fileURLWithPath: cli).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("src").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [script, src]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Shell.path
        p.environment = env
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async { self?.receive(chunk) }
        }
        p.terminationHandler = { [weak self] _ in
            output.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.bridge = nil
                self.bridgeInput = nil
                self.buffer = Data()
                let stranded = self.waiting
                self.waiting = [:]
                for done in stranded.values { done(nil) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.startBridge() }
            }
        }
        do { try p.run() } catch {
            store.grokError = "Could not start the Grok bridge"
            return
        }
        bridge = p
        bridgeInput = input.fileHandleForWriting
    }

    private func receive(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if msg["event"] != nil {
                scheduleRefresh()
            } else if let id = msg["id"] as? Int, let done = waiting.removeValue(forKey: id) {
                done(msg["ok"] as? Bool == true ? (msg["data"] ?? NSNull()) : nil)
            }
        }
    }

    /// `completion` gets the host's reply, or nil if the call failed.
    private func request(_ command: String, _ body: [String: Any] = [:], attempt: Int = 0,
                         completion: @escaping (Any?) -> Void = { _ in }) {
        // The bridge takes a moment to start (and restarts if it drops). Wait for it instead of
        // failing, so a chat opened in that window still loads.
        if bridgeInput == nil, attempt < 8 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                self?.request(command, body, attempt: attempt + 1, completion: completion)
            }
            return
        }
        guard let bridgeInput,
              let data = try? JSONSerialization.data(withJSONObject: ["id": nextID, "command": command, "body": body]) else {
            completion(nil)
            return
        }
        waiting[nextID] = completion
        nextID += 1
        // Off the main thread: if the bridge is busy its pipe can fill, and a write that has
        // to wait must not be the interface that waits.
        writes.async { try? bridgeInput.write(contentsOf: data + Data([0x0A])) }
    }

    private let writes = DispatchQueue(label: "perch.grok.writes")

    // MARK: Roster

    private func scheduleRefresh() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func refresh() {
        request("listAgents") { [weak self] reply in
            guard let self else { return }
            let rows = reply as? [[String: Any]] ?? (reply as? [String: Any])?["agents"] as? [[String: Any]]
            if let rows {
                self.store.grokError = nil
                self.apply(rows)
            } else {
                self.store.grokError = "Grok Bot is not reachable"
            }
        }
    }

    private func apply(_ list: [[String: Any]]) {
        let visible = list
            .filter { !($0["isHiddenFromSidebar"] as? Bool ?? false) }
            .sorted { ($0["createdAt"] as? Double ?? 0) < ($1["createdAt"] as? Double ?? 0) }
        var live = Set<String>()
        for raw in visible {
            guard let id = raw["id"] as? String else { continue }
            let name = raw["name"] as? String ?? "Grok bot"
            let agent = store.upsert(source: .grok, sessionID: id, name: name)
            live.insert(agent.id)
            agent.name = name
            agent.hostBundleID = Self.bundleID
            agent.avatarColor = raw["avatarColor"] as? String ?? Palette.grokDefault(for: id)
            agent.avatarShape = (raw["avatarShape"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? GrokShapes.defaultName(for: id)

            // While Perch has a bot paused, its "off" is Perch's doing, not the user's choice.
            if let on = raw["notifyOnUpdatesEnabled"] as? Bool, paused[id] == nil { notifying[id] = on }
            agent.activity = activityText(raw, id: id)
            let running = (raw["isRunning"] as? Bool ?? false) || (raw["isRunningTurn"] as? Bool ?? false)
            let awaiting = !(raw["awaitingUserResponse"] is NSNull) && raw["awaitingUserResponse"] != nil
            // Reading a chat in the notch is reading it; do not let a stale count bring the badge back.
            let open = NotchUI.shared.expanded && NotchUI.shared.selectedID == agent.id
            let unread = open ? 0 : raw["unreadCount"] as? Int ?? 0
            let preview = raw["lastMessagePreview"] as? String ?? ""
            if let ms = raw["lastActivityAt"] as? Double {
                agent.lastActivity = Date(timeIntervalSince1970: ms / 1000)
                if agent.finishedAt == nil { agent.finishedAt = agent.lastActivity }
            }

            let status: AgentStatus = awaiting ? .needsYou : running ? .working : unread > 0 ? .unread : .idle
            // Only something genuinely new is worth a notification: a message Perch has not
            // announced before, or a fresh request for the user. An unread count bouncing back while
            // Grok Bot catches up with "read" is not new, and used to set the banner off again and again.
            let latest = raw["lastMessageId"] as? String ?? ""
            let known = announced[id]
            if known == nil { announced[id] = latest }
            // Just started: anything unread from the last few minutes still counts as new, so a
            // reply that landed while Perch was restarting is not lost.
            let recent = (raw["lastActivityAt"] as? Double).map { Date().timeIntervalSince1970 - $0 / 1000 < 180 } ?? false
            let freshMessage = !latest.isEmpty && unread > 0 && (known.map { latest != $0 } ?? recent)
            if freshMessage { announced[id] = latest }
            let awaitingKey = awaiting ? "\(latest)|asking" : ""
            let freshAsk = awaiting && asked[id] != awaitingKey
            asked[id] = awaitingKey
            let newlyLoud = (freshAsk && agent.status != .needsYou) || freshMessage
            agent.unread = unread
            agent.status = status
            agent.lastMessage = preview
            agent.detail = running && preview.isEmpty ? "Working" : oneLine(preview)
            // A hidden bot is only there to be searched for: never a notification.
            if newlyLoud && !Self.hidden.contains(id) && NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Self.bundleID {
                store.ping(agent)
            }

            // Keep every bot's conversation warm, so opening a chat is instant.
            let newest = "\(raw["newestEntryId"] as? String ?? "")|\(running)"
            if threadStamp[agent.id] != newest {
                threadStamp[agent.id] = newest
                loadThread(agent)
            }
            if open, (raw["unreadCount"] as? Int ?? 0) > 0 { request("setAgentUnread", ["id": id, "isUnread": false]) }
        }
        for a in store.grokBots where !live.contains(a.id) { store.remove(a) }
        UserDefaults.standard.set(store.grokBots.map { ["id": $0.sessionID, "name": $0.name, "color": $0.avatarColor ?? "", "shape": $0.avatarShape ?? ""] },
                                  forKey: "grokRoster")
    }

    // MARK: Conversation

    func loadThread(_ agent: Agent) {
        request("getAgentTranscriptTail", ["id": agent.sessionID, "limit": 80]) { [weak agent] reply in
            guard let agent else { return }
            let entries = reply as? [[String: Any]] ?? (reply as? [String: Any])?["entries"] as? [[String: Any]] ?? []
            var messages: [ChatMessage] = entries.compactMap { e in
                let id = e["id"] as? String ?? UUID().uuidString
                let reactions = (e["reactions"] as? [[String: Any]] ?? []).compactMap { $0["emoji"] as? String }
                switch e["kind"] as? String {
                case "message":
                    guard let text = e["content"] as? String, !text.isEmpty else { return nil }
                    // Bots brief each other in the same transcript. Those are not the user speaking,
                    // nor the bot speaking to the user, so they are marked as a side exchange.
                    if let to = (e["toAgent"] as? [String: Any])?["name"] as? String {
                        return ChatMessage(id: id, fromUser: false, text: text, reactions: reactions, peerName: to, peerOutbound: true)
                    }
                    if let from = (e["fromAgent"] as? [String: Any])?["name"] as? String {
                        return ChatMessage(id: id, fromUser: false, text: text, reactions: reactions, peerName: from, peerOutbound: false)
                    }
                    let user = e["role"] as? String == "user"
                    if user, let nonce = e["clientNonce"] as? String, let paths = Self.sentImages[nonce] {
                        return ChatMessage(id: id, fromUser: true, text: Self.withPictures(text, paths), reactions: reactions)
                    }
                    return ChatMessage(id: id, fromUser: user, text: text, reactions: reactions)
                case "send-message":
                    let message = e["message"] as? [String: Any] ?? [:]
                    if let instruction = e["boxInstruction"] as? String, !instruction.isEmpty {
                        var m = ChatMessage(id: id, fromUser: false, text: instruction, reactions: reactions)
                        m.handoff = (instruction, e["boxResolution"] as? String)
                        return m
                    }
                    if let text = message["content"] as? String, !text.isEmpty {
                        var m = ChatMessage(id: id, fromUser: false, text: text, reactions: reactions,
                                            email: EmailDraft.written(in: text))
                        m.boxImages = (message["images"] as? [[String: Any]] ?? []).compactMap { img in
                            (img["url"] as? String).map { $0.hasPrefix("file://") ? String($0.dropFirst(7)) : $0 }
                        }
                        return m
                    }
                    if message["type"] as? String == "email-draft", let d = message["draft"] as? [String: Any] {
                        var draft = EmailDraft(from: d["from"] as? String ?? "", to: d["to"] as? [String] ?? [],
                                               cc: d["cc"] as? [String] ?? [], subject: d["subject"] as? String ?? "",
                                               body: d["body"] as? String ?? "", sendState: e["draftSendState"] as? String)
                        draft.grokEntry = id
                        draft.grokPayload = (try? JSONSerialization.data(withJSONObject: message)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        return ChatMessage(id: id, fromUser: false, text: draft.body, reactions: reactions, email: draft)
                    }
                    if message["type"] as? String == "attachment", let url = message["url"] as? String {
                        let path = url.hasPrefix("file://") ? String(url.dropFirst(7)) : url
                        let name = message["file_name"] as? String ?? URL(fileURLWithPath: path).lastPathComponent
                        return ChatMessage(id: id, fromUser: false, text: name, reactions: reactions, fileName: name, filePath: path)
                    }
                    if message["type"] as? String == "user-form", let r = message["formRequest"] as? [String: Any] {
                        let fields: [GrokForm.Field] = (r["fields"] as? [[String: Any]] ?? []).compactMap { f in
                            guard let fid = f["id"] as? String else { return nil }
                            let options = (f["options"] as? [[String: Any]] ?? []).compactMap { o -> (label: String, value: String)? in
                                guard let v = o["value"] as? String else { return nil }
                                return (o["label"] as? String ?? v, v)
                            }
                            let type = f["type"] as? String ?? "text"
                            return GrokForm.Field(id: fid, label: f["label"] as? String ?? fid, type: type,
                                                  required: f["required"] as? Bool ?? false,
                                                  secret: f["secret"] as? Bool == true || type == "password",
                                                  defaultValue: f["defaultValue"] as? String ?? "", options: options)
                        }
                        let outcomes = e["formFieldOutcomes"] as? [[String: Any]] ?? []
                        let missed = outcomes.filter { $0["fillFailed"] as? Bool == true }.compactMap { o in
                            fields.first { $0.id == o["id"] as? String }?.label
                        }
                        let title = r["title"] as? String ?? "A secure form"
                        let form = GrokForm(title: title, instruction: r["instruction"] as? String ?? "",
                                            domain: r["liveHost"] as? String ?? r["domain"] as? String ?? "",
                                            fields: fields, resolution: e["formResolution"] as? String, missed: missed)
                        return ChatMessage(id: id, fromUser: false, text: title, reactions: reactions, form: form)
                    }
                    if message["type"] as? String == "secret-request", let r = message["secretRequest"] as? [String: Any] {
                        let label = r["label"] as? String ?? "A secret"
                        return ChatMessage(id: id, fromUser: false, text: label, reactions: reactions,
                                           secret: (label, r["description"] as? String ?? "", e["secretProvided"] as? Bool == true))
                    }
                    if message["type"] as? String == "auto-review-approval", let a = message["approval"] as? [String: Any],
                       let requestId = a["requestId"] as? String {
                        let params = (a["summaryCopy"] as? [String: Any])?["params"] as? [String: Any]
                        let status = a["status"] as? String
                        let approval = GrokApproval(requestId: requestId,
                                                    tool: params?["serverDisplayName"] as? String ?? (a["surface"] as? String ?? "a tool"),
                                                    summary: a["summary"] as? String ?? "", reason: a["reason"] as? String ?? "",
                                                    command: a["command"] as? String ?? "",
                                                    status: ["approved", "denied", "always"].contains(status ?? "") ? status : nil)
                        return ChatMessage(id: id, fromUser: false, text: approval.summary, reactions: reactions, approval: approval)
                    }
                    if message["type"] as? String == "widget", let w = message["widget"] as? [String: Any],
                       let raw = w["options"] as? [[String: Any]], !raw.isEmpty {
                        let options = raw.compactMap { o -> ChoiceWidget.Option? in
                            guard let label = o["label"] as? String else { return nil }
                            return .init(label: label, value: o["value"] as? String ?? label, detail: o["description"] as? String ?? "")
                        }
                        let prompt = w["prompt"] as? String ?? ""
                        return ChatMessage(id: id, fromUser: false, text: prompt, reactions: reactions,
                                           choice: ChoiceWidget(prompt: prompt, options: options))
                    }
                    // Any other draft (a Slack message, a meeting chat message): where it is going
                    // and what it says, the same way an email draft is shown.
                    if let type = message["type"] as? String, type.hasSuffix("-draft"), let d = message["draft"] as? [String: Any] {
                        func first(_ keys: [String]) -> String {
                            for k in keys { if let v = d[k] as? String, !v.isEmpty { return v } }
                            return ""
                        }
                        let body = first(["body", "text", "message", "content", "markdown"])
                        let to = first(["channelName", "channel", "conversationName", "recipientName", "recipient", "to", "meetingTitle", "title"])
                        if !body.isEmpty {
                            let noun = type == "slack-draft" ? "Slack message" : type.dropLast(6).replacingOccurrences(of: "-", with: " ") + " message"
                            var draft = EmailDraft(noun: noun, to: to.isEmpty ? [] : [to], subject: "", body: body,
                                                   sendState: e["draftSendState"] as? String)
                            draft.grokEntry = id
                            draft.grokPayload = (try? JSONSerialization.data(withJSONObject: message)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                            return ChatMessage(id: id, fromUser: false, text: body, reactions: reactions, email: draft)
                        }
                    }
                    if message["type"] as? String == "listener-connect", let platform = message["platform"] as? String {
                        return ChatMessage(id: id, fromUser: false, text: "", reactions: reactions,
                                           listener: (platform, message["reason"] as? String ?? ""))
                    }
                    if message["type"] as? String == "connector", let server = message["serverId"] as? String ?? (message["serverId"] as? NSNumber)?.stringValue {
                        var m = ChatMessage(id: id, fromUser: false, text: "", reactions: reactions)
                        m.connector = (message["connector"] as? String ?? "the connector", server)
                        return m
                    }
                    // Some other kind of card the notch cannot draw yet: say so, do not hide it.
                    guard let type = message["type"] as? String else { return nil }
                    return ChatMessage(id: id, fromUser: false, text: "_Sent a \(type.replacingOccurrences(of: "-", with: " ")). Open Grok Bot to see it._", reactions: reactions)
                default:
                    return nil
                }
            }
            guard !messages.isEmpty else { return }
            // Only the newest unsent draft is live; earlier ones were replaced by it.
            if let newest = messages.lastIndex(where: { $0.email != nil }) {
                for i in messages.indices where i < newest && messages[i].email?.sendState == nil {
                    messages[i].email?.superseded = true
                }
            }
            // A message just sent from the notch stays put until the host's copy of it arrives.
            messages = Threads.keepingLocalIDs(messages, from: agent.thread)
            // A message the host now has did get through, even if the send itself timed out
            // waiting for an answer: drop its "Not delivered" warning.
            for message in messages where message.id.hasPrefix("local-") { agent.unsent[message.id] = nil }
            let unsent = Threads.unsent(in: agent.thread, loaded: messages)
            let merged = messages + unsent
            if merged != agent.thread { agent.thread = merged }
        }
    }

    /// Which pictures went with each message sent from the notch, by the message's nonce.
    private static var sentImages: [String: [String]] {
        get { UserDefaults.standard.dictionary(forKey: "grokSentImages") as? [String: [String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "grokSentImages") }
    }

    /// The words of a message plus a note per picture, which the chat draws as the picture.
    static func withPictures(_ text: String, _ paths: [String]) -> String {
        let words = text == "See the attached image." ? "" : text
        return ([words] + paths.map { "[Image attached, saved at \($0)]" }).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Sends a prompt, trying again a few times over about ten seconds: the host sometimes
    /// refuses for a moment (after the Mac wakes, say) and then recovers.
    private func send(_ body: [String: Any], tries: Int, done: @escaping (Bool) -> Void) {
        request("sendPrompt", body) { [weak self] reply in
            if reply != nil { return done(true) }
            guard tries > 1, let self else { return done(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.send(body, tries: tries - 1, done: done) }
        }
    }

    func send(_ agent: Agent, text: String, files: [Attachment] = [], replyTo: String? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(text.isEmpty && files.isEmpty) else { return }
        let prompt = text.isEmpty ? "See the attached image." : text
        let nonce = UUID().uuidString.lowercased()
        // The host's record of a message keeps its words but not its pictures, so Perch notes
        // which pictures went with it and draws them in your bubble, now and after every reload.
        if !files.isEmpty {
            var sent = Self.sentImages
            sent[nonce] = files.map(\.path)
            Self.sentImages = sent
        }
        let localID = agent.addLocal(Self.withPictures(text, files.map(\.path)))
        agent.status = .working
        agent.detail = text.isEmpty ? "You sent an image" : "You: \(oneLine(text))"

        func post(_ paths: [String]) {
            var body: [String: Any] = ["agentId": agent.sessionID, "prompt": prompt, "clientNonce": nonce]
            if let replyTo { body["replyToId"] = replyTo }
            if !paths.isEmpty {
                body["attachmentPaths"] = paths
                body["attachmentNames"] = files.map(\.name)
            }
            send(body, tries: 3) { [weak self, weak agent] ok in
                guard let agent else { return }
                if ok {
                    agent.unsent[localID] = nil
                } else {
                    // Shown on the message itself, with a way to try again.
                    agent.detail = "A message did not send"
                    agent.unsent[localID] = { [weak self, weak agent] in
                        guard let self, let agent else { return }
                        agent.unsent[localID] = nil
                        self.send(body, tries: 3) { ok in
                            if !ok { agent.unsent[localID] = { post(paths) } }
                            self.scheduleRefresh()
                        }
                    }
                }
                self?.scheduleRefresh()
            }
        }
        guard !files.isEmpty else { post([]); return }
        upload(files, to: agent, done: []) { [weak agent] paths in
            guard let paths else {
                agent?.detail = "Image did not upload"
                return
            }
            post(paths)
        }
    }

    private var attachmentText: [String: String] = [:]

    /// The text of a file an agent attached, fetched from its box. `nil` if it is not a text file
    /// or cannot be read.
    private let boxPictures = NSCache<NSString, NSImage>()

    /// A picture from the bot's own computer (a screenshot it took, say).
    func boxImage(_ path: String, completion: @escaping (NSImage?) -> Void) {
        if let cached = boxPictures.object(forKey: path as NSString) { return completion(cached) }
        request("readAttachmentImage", ["path": path]) { [weak self] reply in
            guard let url = (reply as? [String: Any])?["dataUrl"] as? String, let comma = url.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(url[url.index(after: comma)...])), let image = NSImage(data: data) else {
                return completion(nil)
            }
            self?.boxPictures.setObject(image, forKey: path as NSString)
            completion(image)
        }
    }

    /// Copies any file from the bot's computer (a Word document, a spreadsheet) into Downloads,
    /// a piece at a time the way Grok Bot does, and gives back where it landed.
    func download(_ path: String, name: String, completion: @escaping (URL?) -> Void) {
        let piece = 256 * 1024
        var data = Data()
        func next(_ total: Int?) {
            request("readAttachmentChunk", ["path": path, "offset": data.count, "length": total == nil ? 0 : piece]) { reply in
                guard let reply = reply as? [String: Any], let size = reply["totalSize"] as? Int else { return completion(nil) }
                if total != nil {
                    let bytes = (reply["bytesBase64"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
                    if bytes.isEmpty && data.count < size { return completion(nil) }
                    data.append(bytes)
                }
                if data.count < size { return next(size) }
                completion(Self.save(data, as: name))
            }
        }
        next(nil)
    }

    /// Saves into Downloads without replacing a file already there: "Report 2.docx" and so on.
    private static func save(_ data: Data, as name: String) -> URL? {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return (try? data.write(to: url)) == nil ? nil : url
    }

    func readAttachment(_ path: String, completion: @escaping (String?) -> Void) {
        if let cached = attachmentText[path] { completion(cached); return }
        request("readAttachmentText", ["path": path]) { [weak self] reply in
            let text = (reply as? [String: Any])?["text"] as? String
            if let text { self?.attachmentText[path] = text }
            completion(text)
        }
    }

    /// Adds (or, if it is already there, removes) the user's reaction on one of the bot's messages.
    /// Hands a requested secret to the host, the same call Grok Bot's own field makes. The value
    /// goes straight to the host to be stored for the bot's box; Perch keeps no copy.
    /// Whether an app is linked for bots' triggers (the Slack connection a routine waits on).
    func listenerConnected(_ platform: String, done: @escaping (Bool?) -> Void) {
        request("getListenerIntegrations") { reply in
            let list = (reply as? [String: Any])?["integrations"] as? [[String: Any]]
            let row = list?.first { $0["platform"] as? String == platform }
            DispatchQueue.main.async { done(row.map { $0["isConnected"] as? Bool == true }) }
        }
    }

    /// Whether one of Grok Bot's connectors is signed in: nil when it cannot be told.
    func connectorReady(_ serverID: String, done: @escaping (Bool?) -> Void) {
        request("getMcpState") { reply in
            let servers = (reply as? [String: Any])?["servers"] as? [[String: Any]] ?? []
            let row = servers.first { "\($0["id"] ?? "")" == serverID }
            DispatchQueue.main.async { done(row.map { ($0["status"] as? String).map { $0 != "needsAuth" && $0 != "error" } ?? false }) }
        }
    }

    enum ConnectorStart { case opened, already, busy(minutes: Int), refused(String) }

    /// What Grok Bot's own Connect button does: asks the host for the connector's sign-in page and
    /// opens it in the browser. Nothing is linked until the user approves it there.
    func connectConnector(_ serverID: String, card: String, in agent: Agent, done: @escaping (ConnectorStart) -> Void) {
        request("authenticateMcpServer", ["serverId": serverID, "grokBotAgentId": agent.sessionID, "entryPoint": "chat_card",
                                           "cardId": card, "cardAgentId": agent.sessionID]) { reply in
            let r = reply as? [String: Any] ?? [:]
            DispatchQueue.main.async {
                switch r["status"] as? String {
                case "started":
                    guard let url = (r["authorizationUrl"] as? String).flatMap(URL.init(string:)) else {
                        return done(.refused("Grok Bot gave no sign-in page."))
                    }
                    NSWorkspace.shared.open(url)
                    done(.opened)
                case "already-authenticated":
                    done(.already)
                default:
                    let reason = r["reason"] as? [String: Any]
                    if let wait = (reason?["signInBackoff"] as? [String: Any])?["retryAfterSeconds"] as? Int {
                        return done(.busy(minutes: max(1, Int((Double(wait) / 60).rounded(.up)))))
                    }
                    done(.refused(reason?["technicalDetail"] as? String ?? "Grok Bot could not start the sign-in."))
                }
            }
        }
    }

    /// Opens the app's own sign-in page (Slack's, say) to link it for triggers, as the card in
    /// Grok Bot does. Nothing is linked until the user approves it there.
    func connectListener(_ platform: String, done: @escaping (Bool) -> Void) {
        request("getListenerConnectUrl", ["platform": platform]) { reply in
            let url = ((reply as? [String: Any])?["url"] as? String).flatMap(URL.init(string:))
            DispatchQueue.main.async {
                if let url { NSWorkspace.shared.open(url) }
                done(url != nil)
            }
        }
    }

    /// Sends a secure form's answers to Grok Bot, which types them into the page itself.
    func submitForm(_ values: [String: String], entry: String, in agent: Agent, done: @escaping (Bool) -> Void) {
        request("submitUserForm", ["entryId": entry, "values": values, "agentId": agent.sessionID]) { [weak self, weak agent] reply in
            DispatchQueue.main.async {
                done(reply != nil)
                if let agent { self?.loadThread(agent) }
            }
        }
    }

    /// Sends a bot's draft (an email, a Slack message) the way Grok Bot's own Send button does.
    func sendDraft(_ draft: EmailDraft, in agent: Agent, done: @escaping (Bool) -> Void) {
        guard !draft.grokEntry.isEmpty, let data = draft.grokPayload.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return done(false) }
        request("sendDraft", ["entryId": draft.grokEntry, "draft": payload, "agentId": agent.sessionID]) { [weak self, weak agent] reply in
            DispatchQueue.main.async {
                done(reply != nil)
                if let agent { self?.loadThread(agent) }
            }
        }
    }

    func dismissForm(entry: String, in agent: Agent, done: @escaping (Bool) -> Void) {
        request("dismissUserForm", ["entryId": entry, "mode": "dismissed", "agentId": agent.sessionID]) { [weak self, weak agent] reply in
            DispatchQueue.main.async {
                done(reply != nil)
                if let agent { self?.loadThread(agent) }
            }
        }
    }

    func submitSecret(_ value: String, entry: String, in agent: Agent, done: @escaping (Bool) -> Void) {
        request("submitSecret", ["entryId": entry, "value": value, "agentId": agent.sessionID]) { reply in
            done(reply != nil)
        }
    }

    /// Answers a bot's request for permission, as the Allow and Deny buttons in Grok Bot do.
    func resolve(_ approval: GrokApproval, entry: String, in agent: Agent, as resolution: String,
                 done: @escaping (Bool) -> Void) {
        request("resolveAutoReviewApproval", ["entryId": entry, "requestId": approval.requestId,
                                              "resolution": resolution, "agentId": agent.sessionID]) { [weak self, weak agent] reply in
            done(reply != nil)
            if let agent { self?.loadThread(agent) }
        }
    }

    func react(_ emoji: String, to messageID: String, in agent: Agent) {
        if let i = agent.thread.firstIndex(where: { $0.id == messageID }) {
            // Show it straight away; the reload below brings back the host's version.
            if let mine = agent.thread[i].reactions.firstIndex(of: emoji) {
                agent.thread[i].reactions.remove(at: mine)
            } else {
                agent.thread[i].reactions.append(emoji)
            }
        }
        request("reactToMessage", ["entryId": messageID, "emoji": emoji, "agentId": agent.sessionID]) { [weak self, weak agent] _ in
            if let agent { self?.loadThread(agent) }
        }
    }

    func markRead(_ agent: Agent) {
        guard agent.unread > 0 else { return }
        agent.unread = 0
        if agent.status == .unread { agent.status = .idle }
        request("setAgentUnread", ["id": agent.sessionID, "isUnread": false])
    }

    func open(_ agent: Agent) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    // MARK: Image upload (still through the CLI, which knows the upload service)

    /// How much of the week's Grok Bot allowance is used. Read-only, every ten minutes.
    private func refreshUsage() {
        cli(["cursor", "rpc", "--service", "aiserver.v1.DashboardService", "GetSandUsageStatus", "{}"]) { code, out in
            guard code == 0, let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else { return }
            Usage.shared.takeGrok(json)
        }
    }

    private func cli(_ args: [String], completion: @escaping (Int32, String) -> Void) {
        guard let node, let cli else { completion(-1, ""); return }
        Shell.run(node, [cli] + args, completion: completion)
    }

    private static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Uploads each image to the agent's box the way the Grok Bot app does, and hands back
    /// the paths the host stored them at. `nil` if any upload fails.
    private func upload(_ files: [Attachment], to agent: Agent, done: [String], completion: @escaping ([String]?) -> Void) {
        guard done.count < files.count else { completion(done); return }
        let file = files[done.count]
        guard let data = FileManager.default.contents(atPath: file.path) else { completion(nil); return }
        sendChunk(data, offset: 0, uploadID: UUID().uuidString.lowercased(), name: file.name, agent: agent) { [weak self] path in
            guard let self, let path else { completion(nil); return }
            self.upload(files, to: agent, done: done + [path], completion: completion)
        }
    }

    private func sendChunk(_ data: Data, offset: Int, uploadID: String, name: String, agent: Agent,
                           completion: @escaping (String?) -> Void) {
        // Each chunk travels as a command line argument, so keep it well under the limit.
        let size = 180 << 10
        let chunk = data.subdata(in: offset..<min(data.count, offset + size))
        let body: [String: Any] = [
            "agentId": agent.sessionID, "uploadId": uploadID, "fileName": name,
            "offset": String(offset), "totalSize": String(data.count), "data": chunk.base64EncodedString(),
        ]
        cli(["cursor", "rpc", "UploadGrokBotAgentAttachmentChunk", Self.json(body)]) { [weak self] code, output in
            guard code == 0, let self else { completion(nil); return }
            let reply = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any]
            let next = offset + chunk.count
            if next >= data.count {
                completion(reply?["path"] as? String)
            } else {
                self.sendChunk(data, offset: next, uploadID: uploadID, name: name, agent: agent, completion: completion)
            }
        }
    }
}
