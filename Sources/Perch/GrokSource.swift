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

    func start() {
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

            let running = (raw["isRunning"] as? Bool ?? false) || (raw["isRunningTurn"] as? Bool ?? false)
            let awaiting = !(raw["awaitingUserResponse"] is NSNull) && raw["awaitingUserResponse"] != nil
            // Reading a chat in the notch is reading it; do not let a stale count bring the badge back.
            let open = NotchUI.shared.expanded && NotchUI.shared.selectedID == agent.id
            let unread = open ? 0 : raw["unreadCount"] as? Int ?? 0
            let preview = raw["lastMessagePreview"] as? String ?? ""
            if let ms = raw["lastActivityAt"] as? Double { agent.lastActivity = Date(timeIntervalSince1970: ms / 1000) }

            let status: AgentStatus = awaiting ? .needsYou : running ? .working : unread > 0 ? .unread : .idle
            let newlyLoud = (status == .needsYou && agent.status != .needsYou) || unread > agent.unread
            agent.unread = unread
            agent.status = status
            agent.lastMessage = preview
            agent.detail = running && preview.isEmpty ? "Working" : oneLine(preview)
            if newlyLoud && NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Self.bundleID {
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
        UserDefaults.standard.set(store.grokBots.map { ["id": $0.sessionID, "name": $0.name, "color": $0.avatarColor ?? ""] },
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
                    if let text = message["content"] as? String, !text.isEmpty {
                        return ChatMessage(id: id, fromUser: false, text: text, reactions: reactions)
                    }
                    if message["type"] as? String == "email-draft", let d = message["draft"] as? [String: Any] {
                        let draft = EmailDraft(from: d["from"] as? String ?? "", to: d["to"] as? [String] ?? [],
                                               cc: d["cc"] as? [String] ?? [], subject: d["subject"] as? String ?? "",
                                               body: d["body"] as? String ?? "", sendState: e["draftSendState"] as? String)
                        return ChatMessage(id: id, fromUser: false, text: draft.body, reactions: reactions, email: draft)
                    }
                    if message["type"] as? String == "attachment", let url = message["url"] as? String {
                        let path = url.hasPrefix("file://") ? String(url.dropFirst(7)) : url
                        let name = message["file_name"] as? String ?? URL(fileURLWithPath: path).lastPathComponent
                        return ChatMessage(id: id, fromUser: false, text: name, reactions: reactions, fileName: name, filePath: path)
                    }
                    if message["type"] as? String == "secret-request", let r = message["secretRequest"] as? [String: Any] {
                        let label = r["label"] as? String ?? "A secret"
                        return ChatMessage(id: id, fromUser: false, text: label, reactions: reactions,
                                           secret: (label, r["description"] as? String ?? ""))
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
                            let draft = EmailDraft(noun: noun, to: to.isEmpty ? [] : [to], subject: "", body: body,
                                                   sendState: e["draftSendState"] as? String)
                            return ChatMessage(id: id, fromUser: false, text: body, reactions: reactions, email: draft)
                        }
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
        agent.addLocal(Self.withPictures(text, files.map(\.path)))
        agent.status = .working
        agent.detail = text.isEmpty ? "You sent an image" : "You: \(oneLine(text))"

        func post(_ paths: [String]) {
            var body: [String: Any] = ["agentId": agent.sessionID, "prompt": prompt, "clientNonce": nonce]
            if let replyTo { body["replyToId"] = replyTo }
            if !paths.isEmpty {
                body["attachmentPaths"] = paths
                body["attachmentNames"] = files.map(\.name)
            }
            request("sendPrompt", body) { [weak self, weak agent] reply in
                if reply == nil { agent?.detail = "Message did not send. Is Grok Bot open?" }
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
