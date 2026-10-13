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

    func send(_ agent: Agent, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let node, let cli, !text.isEmpty else { return }
        agent.sending = true
        agent.status = .working
        agent.detail = "You: \(oneLine(text))"
        Shell.run(node, [cli, "agents", "send", agent.sessionID, text]) { [weak self, weak agent] code, _ in
            if code != 0 {
                agent?.sending = false
                agent?.detail = "Message did not send"
            }
            self?.scheduleRefresh()
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
