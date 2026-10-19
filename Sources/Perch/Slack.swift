import AppKit
import Observation

/// Someone or somewhere to message on Slack.
struct SlackTarget: Identifiable, Hashable {
    let workspace: String
    let id: String
    let name: String
    let channel: Bool
    /// Their profile picture, or the workspace's icon for a channel.
    var picture: URL?
    var label: String { channel ? "#\(name)" : name }
}

/// Everyone and every channel the user can message, per workspace, for search.
@Observable
final class SlackDirectory {
    static let shared = SlackDirectory()
    var targets: [SlackTarget] = []

    func matching(_ q: String) -> [SlackTarget] {
        let q = q.lowercased()
        return targets.filter { $0.name.lowercased().contains(q) }
            .sorted { a, b in
                let (x, y) = (a.name.lowercased().hasPrefix(q), b.name.lowercased().hasPrefix(q))
                return x != y ? x : a.name.count < b.name.count
            }
    }
}

/// One message in a Slack conversation, as shown in the notch.
struct SlackLine: Identifiable, Equatable {
    let id: String
    var sender: String
    let mine: Bool
    let text: String
    var picture: URL?
    var files: [SlackFile] = []
    /// WhatsApp only: when it was sent, and for the user's own messages the ticks (1 sent,
    /// 2 delivered, 3 read).
    var time: Date?
    var ticks: Int?
}

/// A file shared in a Slack message. Its links need the workspace's key to open.
struct SlackFile: Identifiable, Equatable {
    let id: String
    let workspace: String
    let name: String
    let image: Bool
    /// A small preview, for pictures.
    let thumb: URL?
    let url: URL?
    let link: URL?
    /// Slack's short name for the kind of file, like "csv" or "pdf".
    var kind = ""
    var size = 0
    /// A small preview picture that came with the message, shown while the full one loads.
    var preview: Data?

    static func list(_ event: [String: Any], workspace: String) -> [SlackFile] {
        (event["files"] as? [[String: Any]] ?? []).compactMap { f in
            guard let id = f["id"] as? String, f["mode"] as? String != "tombstone" else { return nil }
            let mime = f["mimetype"] as? String ?? ""
            return SlackFile(id: id, workspace: workspace,
                             name: f["name"] as? String ?? f["title"] as? String ?? "File",
                             image: mime.hasPrefix("image/"),
                             thumb: (f["thumb_480"] as? String ?? f["thumb_360"] as? String).flatMap(URL.init(string:)),
                             url: (f["url_private_download"] as? String ?? f["url_private"] as? String).flatMap(URL.init(string:)),
                             link: (f["permalink"] as? String).flatMap(URL.init(string:)),
                             kind: f["filetype"] as? String ?? (f["name"] as? String).map { ($0 as NSString).pathExtension } ?? "",
                             size: f["size"] as? Int ?? 0)
        }
    }
}

/// The open Slack conversations' recent messages, kept live as new ones arrive.
@Observable
final class SlackConversations {
    static let shared = SlackConversations()
    /// By "workspace:channel".
    var lines: [String: [SlackLine]] = [:]
    /// The channel a direct message to a person lives in, once known, by "workspace:user".
    var dmChannel: [String: String] = [:]
    var loading = Set<String>()

    func key(_ workspace: String, _ channel: String) -> String { "\(workspace):\(channel)" }
}

/// One Slack message worth a banner.
struct SlackAlert: Identifiable, Equatable {
    let id: String
    let workspace: String
    let priority: Int
    let team: String
    let channel: String
    let place: String
    let sender: String
    let text: String
    let ts: String
    /// The thread it belongs to, if any. A reply goes into the same thread.
    var thread: String?
    var direct = false
    /// Who sent it, by Slack id, for finding the conversation with them.
    var senderID = ""
    /// The sender's profile picture (or the posting app's icon).
    var picture: URL?

    /// The conversation it came from, as somewhere to reply: the channel, or the person for a DM.
    var target: SlackTarget {
        if workspace == WhatsAppSource.workspace {
            let chat = WhatsAppSource.shared.chats.first { $0.id == channel }
            return chat?.target ?? SlackTarget(workspace: workspace, id: channel, name: direct ? sender : place, channel: false, picture: picture)
        }
        if direct {
            let person = SlackDirectory.shared.targets.first { $0.workspace == workspace && $0.id == senderID && !$0.channel }
            return person ?? SlackTarget(workspace: workspace, id: senderID, name: sender, channel: false, picture: picture)
        }
        let known = SlackDirectory.shared.targets.first { $0.workspace == workspace && $0.id == channel && $0.channel }
        let name = place.hasPrefix("#") ? String(place.dropFirst()) : place
        return known ?? SlackTarget(workspace: workspace, id: channel, name: name, channel: true, picture: nil)
    }

    /// Opens the conversation in the Slack app.
    var link: URL? {
        if workspace == WhatsAppSource.workspace { return URL(string: "whatsapp://") }
        var parts = URLComponents(string: "slack://channel")
        parts?.queryItems = [URLQueryItem(name: "team", value: team), URLQueryItem(name: "id", value: channel)]
        return parts?.url
    }
}

/// Read-only Slack: a live connection per workspace (Socket Mode), turning direct messages,
/// @mentions and (where asked for) alerts posted by apps into notch banners.
///
/// Each workspace has its own small private Slack app; its two keys sit in
/// `~/.perch/slack/<name>.json`, saved there by `slack/add-workspace.sh`. Perch never
/// posts anything.
final class SlackSource {
    static let shared = SlackSource()
    /// Each workspace's connection state, for checking it is live.
    static var status: [String: String] = [:]
    private let dir = "\(Shell.home)/.perch/slack"
    private var links: [String: Workspace] = [:]
    private var timer: Timer?

    /// Sends a reply as the user: in a thread, into that thread; to a mention in a channel, as a
    /// reply in a thread under it; to a direct message, straight into the conversation.
    func reply(to alert: SlackAlert, text: String, done: @escaping (Bool) -> Void) {
        if alert.workspace == WhatsAppSource.workspace { return WhatsAppSource.shared.send(to: alert.target, text: text, files: [], done: done) }
        guard let link = links.values.first(where: { $0.name == alert.workspace }) else { return done(false) }
        link.post(channel: alert.channel, text: text, thread: alert.thread ?? (alert.direct ? nil : alert.ts), done: done)
    }

    /// A fresh message to a person or channel, as the user, with any files attached.
    func send(to target: SlackTarget, text: String, files: [URL] = [], done: @escaping (Bool) -> Void) {
        if target.workspace == WhatsAppSource.workspace { return WhatsAppSource.shared.send(to: target, text: text, files: files, done: done) }
        guard let link = links.values.first(where: { $0.name == target.workspace }) else { return done(false) }
        link.send(to: target, text: text, files: files, done: done)
    }

    /// Opens a conversation in the Slack app.
    func open(_ target: SlackTarget) {
        if target.workspace == WhatsAppSource.workspace { return WhatsAppSource.shared.openApp() }
        links.values.first(where: { $0.name == target.workspace })?.open(target)
    }

    /// Fetches a shared file's contents with the workspace's key. Nil when the key can't read files.
    func fetch(_ url: URL, workspace: String, done: @escaping (Data?) -> Void) {
        if workspace == WhatsAppSource.workspace { return WhatsAppSource.shared.fetch(url, done: done) }
        guard let link = links.values.first(where: { $0.name == workspace }) else { return done(nil) }
        link.fetch(url, done: done)
    }

    /// Loads a conversation's recent messages into `SlackConversations`.
    func history(for target: SlackTarget) {
        if target.workspace == WhatsAppSource.workspace { return WhatsAppSource.shared.history(target) }
        links.values.first(where: { $0.name == target.workspace })?.history(for: target)
    }

    func start() {
        scan()
        // New workspaces are picked up without restarting.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.scan() }
        timer?.tolerance = 2
        // Waking from sleep: the old connections are almost certainly dead.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.links.values.forEach { $0.reconnect() } }
        }
        // What was said since, for search: every half hour.
        let rewarm = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            self?.links.values.forEach { $0.warmAll() }
        }
        rewarm.tolerance = 120
    }

    private func scan() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir))?.filter { $0.hasSuffix(".json") } ?? []
        for file in files where links[file] == nil {
            guard let data = FileManager.default.contents(atPath: "\(dir)/\(file)"),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let app = o["app"] as? String, let user = o["user"] as? String else { continue }
            let w = Workspace(name: o["name"] as? String ?? file, priority: o["priority"] as? Int ?? 9,
                              apps: (o["alerts"] as? String ?? "apps") == "apps", appToken: app, userToken: user)
            links[file] = w
            w.connect()
        }
    }
}

private final class Workspace {
    let name: String
    let priority: Int
    let apps: Bool
    private let appToken: String
    private let userToken: String
    private var me = ""
    private var team = ""
    private var socket: URLSessionWebSocketTask?
    private var names: [String: String] = [:]
    private var pictures: [String: URL] = [:]
    private var teamIcon: URL?
    /// Emoji shortcodes to the characters, learned from the messages that use them.
    private var emoji: [String: String] = [:]
    private var places: [String: String] = [:]
    private var retry: TimeInterval = 2
    /// When the user last wrote in each conversation, from Slack's own timestamps.
    private var lastMine: [String: Double] = [:]
    private var heartbeat: Timer?

    init(name: String, priority: Int, apps: Bool, appToken: String, userToken: String) {
        self.name = name
        self.priority = priority
        self.apps = apps
        self.appToken = appToken
        self.userToken = userToken
    }

    /// Which direct message channel belongs to which person, so DMs open without asking Slack each time.
    private func directMessages(_ cursor: String?, then: (() -> Void)? = nil) {
        var params = ["limit": "200", "types": "im"]
        if let cursor { params["cursor"] = cursor }
        api("users.conversations", token: userToken, params) { [weak self] o in
            guard let self else { return }
            let store = SlackConversations.shared
            for c in o?["channels"] as? [[String: Any]] ?? [] {
                if let id = c["id"] as? String, let user = c["user"] as? String { store.dmChannel["\(self.name):\(user)"] = id }
            }
            if let next = (o?["response_metadata"] as? [String: Any])?["next_cursor"] as? String, !next.isEmpty {
                self.directMessages(next, then: then)
            } else if let then {
                then()
            } else {
                self.warm()
            }
        }
    }

    /// The conversation's channel id: a channel's own, or a direct message's once opened.
    private func channel(for target: SlackTarget, done: @escaping (String?) -> Void) {
        if target.channel { return done(target.id) }
        let store = SlackConversations.shared
        if let known = store.dmChannel["\(name):\(target.id)"], !known.contains(":dm:") { return done(known) }
        api("conversations.open", token: userToken, ["users": target.id]) { [weak self] o in
            guard let self else { return done(nil) }
            if let id = (o?["channel"] as? [String: Any])?["id"] as? String {
                store.dmChannel["\(self.name):\(target.id)"] = id
                return done(id)
            }
            // Opening needs a permission the key may not have; an existing conversation can still be found.
            self.directMessages(nil) { done(store.dmChannel["\(self.name):\(target.id)"]) }
        }
    }

    func open(_ target: SlackTarget) {
        channel(for: target) { [weak self] channel in
            guard let self else { return }
            var parts = URLComponents(string: target.channel || channel != nil ? "slack://channel" : "slack://user")
            parts?.queryItems = [URLQueryItem(name: "team", value: self.team),
                                 URLQueryItem(name: "id", value: channel ?? target.id)]
            if let url = parts?.url { NSWorkspace.shared.open(url) }
        }
    }

    func fetch(_ url: URL, done: @escaping (Data?) -> Void) {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(userToken)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            // Without file access Slack answers with its sign-in page instead of the file.
            let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            let ok = (response as? HTTPURLResponse)?.statusCode == 200 && !type.hasPrefix("text/html")
            DispatchQueue.main.async { done(ok ? data : nil) }
        }.resume()
    }

    func send(to target: SlackTarget, text: String, files: [URL], done: @escaping (Bool) -> Void) {
        channel(for: target) { [weak self] channel in
            guard let self, let channel else { return done(false) }
            if files.isEmpty { return self.post(channel: channel, text: text, thread: nil, done: done) }
            self.upload(files, to: channel, comment: text, done: done)
        }
    }

    /// Slack's file upload: ask for a place to put each file, send it there, then share them all
    /// into the conversation in one go with the message as the comment.
    private func upload(_ files: [URL], to channel: String, comment: String, done: @escaping (Bool) -> Void) {
        var ids: [[String: String]] = []
        func next(_ i: Int) {
            guard i < files.count else {
                guard let data = try? JSONSerialization.data(withJSONObject: ids),
                      let list = String(data: data, encoding: .utf8) else { return done(false) }
                var params = ["files": list, "channel_id": channel]
                if !comment.isEmpty { params["initial_comment"] = comment }
                return api("files.completeUploadExternal", token: userToken, params) { done($0 != nil) }
            }
            let file = files[i]
            guard let data = try? Data(contentsOf: file) else { return done(false) }
            api("files.getUploadURLExternal", token: userToken, ["filename": file.lastPathComponent, "length": String(data.count)]) { o in
                guard let o, let url = (o["upload_url"] as? String).flatMap(URL.init(string:)), let id = o["file_id"] as? String else { return done(false) }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                URLSession.shared.uploadTask(with: req, from: data) { _, response, _ in
                    DispatchQueue.main.async {
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return done(false) }
                        ids.append(["id": id, "title": file.lastPathComponent])
                        next(i + 1)
                    }
                }.resume()
            }
        }
        next(0)
    }

    func history(for target: SlackTarget, attempt: Int = 0) {
        let store = SlackConversations.shared
        channel(for: target) { [weak self] channel in
            guard let self else { return }
            guard let channel else {
                // Couldn't find the conversation. Show it empty rather than loading forever.
                let key = "\(self.name):dm:\(target.id)"
                if attempt < 2 { return DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.history(for: target, attempt: attempt + 1) } }
                store.dmChannel["\(self.name):\(target.id)"] = key
                store.lines[store.key(self.name, key)] = store.lines[store.key(self.name, key)] ?? []
                return
            }
            let key = store.key(self.name, channel)
            store.loading.insert(key)
            self.api("conversations.history", token: self.userToken, ["channel": channel, "limit": "80"]) { [weak self] o in
                guard let self else { return }
                guard let o else {
                    // Slack sometimes refuses when asked too quickly. Keep what is shown and try again.
                    if attempt < 3 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt + 1) * 1.5) { self.history(for: target, attempt: attempt + 1) }
                    } else {
                        store.loading.remove(key)
                        if store.lines[key] == nil { store.lines[key] = [] }
                    }
                    return
                }
                store.loading.remove(key)
                let raw = (o["messages"] as? [[String: Any]] ?? []).reversed()
                    .filter { $0["subtype"] as? String != "channel_join" }
                let build = { [weak self] () -> [SlackLine] in
                    guard let self else { return [] }
                    return raw.map { m in
                        let user = m["user"] as? String ?? ""
                        let bot = (m["bot_profile"] as? [String: Any])?["name"] as? String ?? m["username"] as? String
                        return SlackLine(id: m["ts"] as? String ?? UUID().uuidString,
                                         sender: bot ?? self.names[user] ?? (user == self.me ? "You" : ""),
                                         mine: user == self.me,
                                         text: self.tidy(m["text"] as? String ?? "", event: m, full: true),
                                         picture: self.pictures[user], files: SlackFile.list(m, workspace: self.name))
                    }
                }
                // Shown straight away; names Perch doesn't know yet fill in as they arrive.
                store.lines[key] = build()
                var unknown = Set<String>()
                for m in raw {
                    if let user = m["user"] as? String, m["bot_profile"] == nil, !user.isEmpty { unknown.insert(user) }
                    let text = m["text"] as? String ?? ""
                    for match in text.matches(of: #/<@([A-Z0-9]+)/#) { unknown.insert(String(match.1)) }
                }
                unknown = unknown.filter { $0 != self.me && self.names[$0] == nil }
                guard !unknown.isEmpty else { return }
                let group = DispatchGroup()
                for user in unknown {
                    group.enter()
                    self.resolve(sender: user, botName: nil, channel: channel, direct: true) { _, _ in group.leave() }
                }
                group.notify(queue: .main) { store.lines[key] = build() }
            }
        }
    }

    /// Recent conversations load quietly once connected, so opening one is instant.
    private func warm() {
        for target in NotchUI.shared.slackRecent where target.workspace == name { history(for: target) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.warmAll() }
    }

    /// Every channel and direct message, loaded quietly one at a time so search can read them.
    /// Spaced out to stay well inside Slack's limits.
    func warmAll() {
        let store = SlackConversations.shared
        let directory = SlackDirectory.shared.targets.filter { $0.workspace == name }
        let people = Dictionary(directory.filter { !$0.channel }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var targets = directory.filter(\.channel)
        for (key, _) in store.dmChannel where key.hasPrefix("\(name):") {
            if let person = people[String(key.dropFirst(name.count + 1))] { targets.append(person) }
        }
        for (i, target) in targets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.5) { [weak self] in self?.history(for: target) }
        }
    }

    /// A message arriving live goes into its conversation if that conversation is loaded.
    private func record(_ event: [String: Any], channel: String, sender: String, who: String) {
        let store = SlackConversations.shared
        let key = store.key(name, channel)
        guard store.lines[key] != nil, let ts = event["ts"] as? String,
              store.lines[key]?.contains(where: { $0.id == ts }) != true else { return }
        store.lines[key]?.append(SlackLine(id: ts, sender: who, mine: sender == me,
                                           text: tidy(event["text"] as? String ?? "", event: event, full: true), picture: pictures[sender],
                                           files: SlackFile.list(event, workspace: name)))
    }

    /// Loads the people and channels in this workspace for search.
    private func loadDirectory() {
        var found: [SlackTarget] = []
        func people(_ cursor: String?) {
            var params = ["limit": "200"]
            if let cursor { params["cursor"] = cursor }
            api("users.list", token: userToken, params) { [weak self] o in
                guard let self else { return }
                for u in o?["members"] as? [[String: Any]] ?? [] {
                    guard u["deleted"] as? Bool != true, u["is_bot"] as? Bool != true, let id = u["id"] as? String,
                          id != "USLACKBOT", id != self.me else { continue }
                    let profile = u["profile"] as? [String: Any]
                    let name = (profile?["real_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        ?? profile?["display_name"] as? String ?? u["name"] as? String ?? id
                    let picture = (profile?["image_72"] as? String ?? profile?["image_48"] as? String).flatMap(URL.init(string:))
                    if let picture { self.pictures[id] = picture }
                    self.names[id] = name
                    found.append(SlackTarget(workspace: self.name, id: id, name: name, channel: false, picture: picture))
                }
                if let next = (o?["response_metadata"] as? [String: Any])?["next_cursor"] as? String, !next.isEmpty {
                    people(next)
                } else {
                    channels(nil)
                }
            }
        }
        func channels(_ cursor: String?) {
            var params = ["limit": "200", "exclude_archived": "true", "types": "public_channel,private_channel"]
            if let cursor { params["cursor"] = cursor }
            api("users.conversations", token: userToken, params) { [weak self] o in
                guard let self else { return }
                for c in o?["channels"] as? [[String: Any]] ?? [] {
                    guard let id = c["id"] as? String, let name = c["name"] as? String else { continue }
                    found.append(SlackTarget(workspace: self.name, id: id, name: name, channel: true, picture: self.teamIcon))
                }
                if let next = (o?["response_metadata"] as? [String: Any])?["next_cursor"] as? String, !next.isEmpty {
                    channels(next)
                } else {
                    let dir = SlackDirectory.shared
                    dir.targets = dir.targets.filter { $0.workspace != self.name } + found
                    self.directMessages(nil)
                }
            }
        }
        people(nil)
    }

    func post(channel: String, text: String, thread: String?, done: @escaping (Bool) -> Void) {
        var params = ["channel": channel, "text": text]
        if let thread { params["thread_ts"] = thread }
        api("chat.postMessage", token: userToken, params) { o in done(o != nil) }
    }

    private func api(_ method: String, token: String, _ params: [String: String] = [:], done: @escaping ([String: Any]?) -> Void) {
        var parts = URLComponents(string: "https://slack.com/api/\(method)")!
        if !params.isEmpty { parts.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: parts.url!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let o = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { done(o?["ok"] as? Bool == true ? o : nil) }
        }.resume()
    }

    func connect() {
        if me.isEmpty {
            // Who the user is in this workspace: their own messages never become banners.
            api("auth.test", token: userToken) { [weak self] o in
                guard let self else { return }
                self.me = o?["user_id"] as? String ?? ""
                self.team = o?["team_id"] as? String ?? ""
                if self.me.isEmpty { self.later() } else {
                    self.api("team.info", token: self.userToken) { [weak self] o in
                        let icon = (o?["team"] as? [String: Any])?["icon"] as? [String: Any]
                        self?.teamIcon = (icon?["image_88"] as? String ?? icon?["image_68"] as? String).flatMap(URL.init(string:))
                        self?.loadDirectory()
                    }
                    self.connect()
                }
            }
            return
        }
        api("apps.connections.open", token: appToken) { [weak self] o in
            guard let self, let url = (o?["url"] as? String).flatMap(URL.init(string:)) else {
                SlackSource.status[self?.name ?? "?"] = "could not open a connection"
                self?.later()
                return
            }
            SlackSource.status[self.name] = "connected"
            let socket = URLSession.shared.webSocketTask(with: url)
            self.socket = socket
            self.retry = 2
            socket.resume()
            self.receive(socket)
            self.beat(socket)
        }
    }

    /// A connection can die silently (the Mac slept, the network changed) and Slack then holds
    /// messages back until Perch notices. A ping every 30 seconds notices within moments.
    private func beat(_ socket: URLSessionWebSocketTask) {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] timer in
            guard let self, self.socket === socket else { return timer.invalidate() }
            var answered = false
            socket.sendPing { error in
                DispatchQueue.main.async { if error == nil { answered = true } }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.socket === socket, !answered else { return }
                SlackSource.status[self.name] = "stopped answering, reconnecting"
                self.reconnect()
            }
        }
        heartbeat?.tolerance = 5
    }

    /// Straight onto a fresh connection, dropping the old one.
    func reconnect() {
        socket?.cancel()
        socket = nil
        heartbeat?.invalidate()
        retry = 2
        connect()
    }

    private func later() {
        let wait = retry
        retry = min(retry * 2, 300)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.connect() }
    }

    private func receive(_ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.socket === socket else { return }
                switch result {
                case .failure:
                    SlackSource.status[self.name] = "dropped, reconnecting"
                    self.socket = nil
                    self.later()
                case .success(let message):
                    if case .string(let text) = message { self.handle(text, on: socket) }
                    self.receive(socket)
                }
            }
        }
    }

    private func handle(_ text: String, on socket: URLSessionWebSocketTask) {
        guard let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        if let envelope = o["envelope_id"] as? String {
            socket.send(.string("{\"envelope_id\":\"\(envelope)\"}")) { _ in }
        }
        if o["type"] as? String == "disconnect" {
            // Slack rotates connections now and then: open a fresh one.
            socket.cancel()
            self.socket = nil
            connect()
            return
        }
        if let type = o["type"] as? String { SlackSource.status[name + " last"] = type }
        guard o["type"] as? String == "events_api",
              let event = (o["payload"] as? [String: Any])?["event"] as? [String: Any],
              event["type"] as? String == "message" else { return }
        let subtype = event["subtype"] as? String
        guard subtype == nil || subtype == "bot_message" || subtype == "thread_broadcast" || subtype == "file_share" else { return }
        let sender = event["user"] as? String ?? ""
        guard let channel = event["channel"] as? String else { return }
        // Every message keeps an open conversation current, including your own from elsewhere.
        let loaded = SlackConversations.shared.lines[SlackConversations.shared.key(name, channel)] != nil
        if loaded {
            let bot = (event["bot_profile"] as? [String: Any])?["name"] as? String ?? event["username"] as? String
            resolve(sender: sender, botName: bot, channel: channel, direct: true) { [weak self] who, _ in
                self?.record(event, channel: channel, sender: sender, who: who)
            }
        }
        // The user's own messages: anything in that conversation from before is already answered.
        if sender == me, let ts = event["ts"] as? String {
            lastMine[channel] = max(Double(ts) ?? 0, lastMine[channel] ?? 0)
            return
        }
        let body = event["text"] as? String ?? ""
        let kind = event["channel_type"] as? String ?? ""
        let direct = kind == "im" || kind == "mpim"
        let mentioned = body.contains("<@\(me)>")
        let fromApp = event["bot_id"] != nil || subtype == "bot_message"
        guard direct || mentioned || (apps && fromApp) else { return }

        let ts = event["ts"] as? String ?? ""
        // Slack resends messages that could not be delivered while the connection was down. A
        // banner for something minutes old, or already replied to, is just noise.
        let sent = Double(ts) ?? 0
        if (lastMine[channel] ?? 0) > sent { return }
        // Old ones still go in the sidebar, just without a banner.
        let stale = Date().timeIntervalSince1970 - sent > 90
        resolve(sender: sender, botName: (event["bot_profile"] as? [String: Any])?["name"] as? String ?? event["username"] as? String,
                channel: channel, direct: direct) { [weak self] who, place in
            guard let self else { return }
            var alert = SlackAlert(id: "\(self.name)-\(ts)", workspace: self.name, priority: self.priority, team: self.team,
                                   channel: channel, place: place, sender: who, text: self.tidy(body, event: event), ts: ts)
            alert.thread = event["thread_ts"] as? String
            alert.direct = direct
            alert.senderID = sender
            let botIcons = (event["bot_profile"] as? [String: Any])?["icons"] as? [String: Any]
            alert.picture = (botIcons?["image_72"] as? String ?? botIcons?["image_48"] as? String).flatMap(URL.init(string:))
                ?? self.pictures[sender]
            if stale { NotchUI.shared.noteSlack(alert) } else { NotchUI.shared.slack(alert) }
        }
    }

    private func resolve(sender: String, botName: String?, channel: String, direct: Bool,
                         done: @escaping (String, String) -> Void) {
        func finish(_ who: String) {
            if direct { return done(who, "Direct message") }
            if let place = places[channel] { return done(who, place) }
            api("conversations.info", token: userToken, ["channel": channel]) { [weak self] o in
                let name = ((o?["channel"] as? [String: Any])?["name"] as? String).map { "#\($0)" } ?? "a channel"
                self?.places[channel] = name
                done(who, name)
            }
        }
        if let botName { return finish(botName) }
        if let known = names[sender] { return finish(known) }
        api("users.info", token: userToken, ["user": sender]) { [weak self] o in
            let user = o?["user"] as? [String: Any]
            let profile = user?["profile"] as? [String: Any]
            let name = (profile?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? profile?["real_name"] as? String ?? user?["name"] as? String ?? "Someone"
            self?.names[sender] = name
            if let p = (profile?["image_72"] as? String).flatMap(URL.init(string:)) { self?.pictures[sender] = p }
            finish(name)
        }
    }

    /// Slack's markup into plain text: links and mentions to their labels.
    /// A few everyday shortcodes for messages that arrive without Slack's emoji record.
    private static let common: [String: String] = [
        "slightly_smiling_face": "🙂", "smile": "😄", "smiley": "😃", "grinning": "😀", "joy": "😂", "wink": "😉",
        "blush": "😊", "thumbsup": "👍", "+1": "👍", "-1": "👎", "thumbsdown": "👎", "pray": "🙏", "clap": "👏",
        "raised_hands": "🙌", "wave": "👋", "ok_hand": "👌", "muscle": "💪", "eyes": "👀", "fire": "🔥", "tada": "🎉",
        "heart": "❤️", "white_check_mark": "✅", "heavy_check_mark": "✔️", "x": "❌", "warning": "⚠️", "rocket": "🚀",
        "100": "💯", "thinking_face": "🤔", "sweat_smile": "😅", "rolling_on_the_floor_laughing": "🤣", "sob": "😭",
        "sunglasses": "😎", "heart_eyes": "😍", "upside_down_face": "🙃", "pensive": "😔", "point_up": "☝️",
        "point_right": "👉", "star": "⭐", "sparkles": "✨", "memo": "📝", "calendar": "📅", "email": "📧",
    ]

    /// Slack's own record of each emoji a message uses, with its real character.
    private func learnEmoji(_ node: Any) {
        if let list = node as? [Any] { return list.forEach(learnEmoji) }
        guard let o = node as? [String: Any] else { return }
        if o["type"] as? String == "emoji", let name = o["name"] as? String, let code = o["unicode"] as? String {
            let chars = code.split(separator: "-").compactMap { UInt32($0, radix: 16).flatMap(Unicode.Scalar.init) }
            if !chars.isEmpty {
                var text = ""
                text.unicodeScalars.append(contentsOf: chars)
                if let tone = o["skin_tone"] as? Int { emoji["\(name)::skin-tone-\(tone)"] = text } else { emoji[name] = text }
            }
        }
        for key in ["blocks", "elements"] { if let child = o[key] { learnEmoji(child) } }
    }

    private func tidy(_ text: String, event: [String: Any], full: Bool = false) -> String {
        var s = text
        if let blocks = event["blocks"] { learnEmoji(blocks) }
        for match in s.matches(of: #/:([a-z0-9_+\-']+)(::skin-tone-[2-6])?:/#).reversed() {
            let name = String(match.1), tone = match.2.map(String.init) ?? ""
            if let char = emoji[name + tone] ?? emoji[name] ?? Self.common[name] { s.replaceSubrange(match.range, with: char) }
        }
        // Mentions read as the person's name, and as "you" only when they are.
        for match in s.matches(of: #/<@([A-Z0-9]+)(?:\|([^>]*))?>/#).reversed() {
            let id = String(match.1)
            let who = id == me ? "you" : names[id] ?? match.2.map(String.init) ?? "someone"
            s.replaceSubrange(match.range, with: "@" + who)
        }
        if s.isEmpty, let blocks = event["attachments"] as? [[String: Any]] {
            s = blocks.compactMap { $0["text"] as? String ?? $0["fallback"] as? String }.joined(separator: " ")
        }
        s = s.replacingOccurrences(of: #"<([^|>]+)\|([^>]+)>"#, with: "$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<(https?://[^>]+)>"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        return full ? s.trimmingCharacters(in: .whitespacesAndNewlines) : oneLine(s, max: 200)
    }
}
