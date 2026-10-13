import AppKit

/// Grok Bot agents, read through the `grokbot` CLI that ships with the Claude Code plugin.
/// That CLI talks to Grok Bot's private host API, so an app update can break this.
final class GrokSource {
    static let shared = GrokSource()
    static let bundleID = "com.anysphere.sand"

    private let store = AgentStore.shared
    private var node: String?
    private var cli: String?
    private var events: Process?
    private var refreshing = false
    private var refreshQueued = false
    private var debounce: DispatchWorkItem?
    private var timer: Timer?

    func start() {
        node = Shell.find("node")
        cli = Self.locateCLI()
        guard node != nil, cli != nil else {
            store.grokError = node == nil ? "Node was not found" : "The grokbot plugin was not found"
            return
        }
        refresh()
        streamEvents()
        // Safety net in case the event stream drops something.
        timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 10
    }

    func stop() { events?.terminate() }

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

    private func streamEvents() {
        guard let node, let cli else { return }
        events = Shell.run(node, [cli, "events"], onOutput: { [weak self] _ in
            self?.scheduleRefresh()
        }, completion: { [weak self] _, _ in
            // The stream ends when the host restarts or the Mac sleeps. Pick it back up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self?.streamEvents() }
        })
    }

    private func scheduleRefresh() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func refresh() {
        guard let node, let cli else { return }
        guard !refreshing else { refreshQueued = true; return }
        refreshing = true
        Shell.run(node, [cli, "agents", "list", "--json"]) { [weak self] code, output in
            guard let self else { return }
            self.refreshing = false
            if code == 0, let list = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]] {
                self.store.grokError = nil
                self.apply(list)
            } else {
                self.store.grokError = "Grok Bot is not reachable"
            }
            if self.refreshQueued {
                self.refreshQueued = false
                self.scheduleRefresh()
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
            let unread = raw["unreadCount"] as? Int ?? 0
            let preview = raw["lastMessagePreview"] as? String ?? ""
            if let ms = raw["lastActivityAt"] as? Double { agent.lastActivity = Date(timeIntervalSince1970: ms / 1000) }

            let status: AgentStatus = awaiting ? .needsYou : running ? .working : unread > 0 ? .unread : .idle
            let newlyLoud = (status == .needsYou && agent.status != .needsYou) || unread > agent.unread
            agent.unread = unread
            agent.status = status
            if !agent.sending || !running {
                agent.lastMessage = preview
                agent.detail = running && preview.isEmpty ? "Working" : oneLine(preview)
            }
            if !running { agent.sending = false }
            if newlyLoud && NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Self.bundleID {
                store.ping(agent)
            }
        }
        for a in store.grokBots where !live.contains(a.id) { store.remove(a) }
    }

    func send(_ agent: Agent, text: String, files: [Attachment] = []) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let node, let cli, !(text.isEmpty && files.isEmpty) else { return }
        agent.sending = true
        agent.addLocal(text.isEmpty ? "(image)" : text)
        agent.status = .working
        agent.detail = text.isEmpty ? "You sent an image" : "You: \(oneLine(text))"
        guard files.isEmpty else {
            upload(files, to: agent, done: []) { [weak self, weak agent] paths in
                guard let self, let agent else { return }
                guard let paths else {
                    agent.sending = false
                    agent.detail = "Image did not upload"
                    return
                }
                let body: [String: Any] = [
                    "agentId": agent.sessionID, "prompt": text.isEmpty ? "See the attached image." : text,
                    "clientNonce": UUID().uuidString.lowercased(),
                    "attachmentPaths": paths, "attachmentNames": files.map(\.name),
                ]
                self.call(["gw", "sendPrompt", Self.json(body)]) { [weak agent] code, _ in
                    if code != 0 {
                        agent?.sending = false
                        agent?.detail = "Message did not send"
                    }
                    self.scheduleRefresh()
                }
            }
            return
        }
        Shell.run(node, [cli, "agents", "send", agent.sessionID, text]) { [weak self, weak agent] code, _ in
            if code != 0 {
                agent?.sending = false
                agent?.detail = "Message did not send"
            }
            self?.scheduleRefresh()
        }
    }

    private func call(_ args: [String], completion: @escaping (Int32, String) -> Void) {
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
        call(["cursor", "rpc", "UploadGrokBotAgentAttachmentChunk", Self.json(body)]) { [weak self] code, output in
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

    func loadThread(_ agent: Agent) {
        call(["agents", "tail", agent.sessionID, "-n", "40", "--json"]) { [weak agent] code, output in
            guard code == 0, let agent,
                  let root = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
                  let entries = root["entries"] as? [[String: Any]] else { return }
            let messages: [ChatMessage] = entries.compactMap { e in
                let id = e["id"] as? String ?? UUID().uuidString
                switch e["kind"] as? String {
                case "message":
                    guard let text = e["content"] as? String, !text.isEmpty else { return nil }
                    return ChatMessage(id: id, fromUser: e["role"] as? String == "user", text: text)
                case "send-message":
                    guard let text = (e["message"] as? [String: Any])?["content"] as? String, !text.isEmpty else { return nil }
                    return ChatMessage(id: id, fromUser: false, text: text)
                default:
                    return nil
                }
            }
            if !messages.isEmpty { agent.thread = messages }
        }
    }

    func markRead(_ agent: Agent) {
        guard let node, let cli, agent.unread > 0 else { return }
        agent.unread = 0
        if agent.status == .unread { agent.status = .idle }
        Shell.run(node, [cli, "agents", "read", agent.sessionID]) { [weak self] _, _ in self?.scheduleRefresh() }
    }

    func open(_ agent: Agent) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}
