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
    let sender: String
    let mine: Bool
    let text: String
    var picture: URL?
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
    /// The sender's profile picture (or the posting app's icon).
    var picture: URL?

    /// Opens the conversation in the Slack app.
    var link: URL? {
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
        guard let link = links.values.first(where: { $0.name == alert.workspace }) else { return done(false) }
        link.post(channel: alert.channel, text: text, thread: alert.thread ?? (alert.direct ? nil : alert.ts), done: done)
    }

    /// A fresh message to a person or channel, as the user, with any files attached.
    func send(to target: SlackTarget, text: String, files: [URL] = [], done: @escaping (Bool) -> Void) {
        guard let link = links.values.first(where: { $0.name == target.workspace }) else { return done(false) }
        link.send(to: target, text: text, files: files, done: done)
    }

    /// Loads a conversation's recent messages into `SlackConversations`.
    func history(for target: SlackTarget) {
        links.values.first(where: { $0.name == target.workspace })?.history(for: target)
    }

    func start() {
        scan()
        // New workspaces are picked up without restarting.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.scan() }
        timer?.tolerance = 2
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
    private var places: [String: String] = [:]
    private var retry: TimeInterval = 2

    init(name: String, priority: Int, apps: Bool, appToken: String, userToken: String) {
        self.name = name
        self.priority = priority
        self.apps = apps
        self.appToken = appToken
        self.userToken = userToken
    }

    /// The conversation's channel id: a channel's own, or a direct message's once opened.
    private func channel(for target: SlackTarget, done: @escaping (String?) -> Void) {
        if target.channel { return done(target.id) }
        let store = SlackConversations.shared
        if let known = store.dmChannel["\(name):\(target.id)"] { return done(known) }
        api("conversations.open", token: userToken, ["users": target.id]) { [weak self] o in
            let id = (o?["channel"] as? [String: Any])?["id"] as? String
            if let id, let self { store.dmChannel["\(self.name):\(target.id)"] = id }
            done(id)
        }
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

    func history(for target: SlackTarget) {
        let store = SlackConversations.shared
        channel(for: target) { [weak self] channel in
            guard let self, let channel else { return }
            let key = store.key(self.name, channel)
            store.loading.insert(key)
            self.api("conversations.history", token: self.userToken, ["channel": channel, "limit": "40"]) { [weak self] o in
                guard let self else { return }
                store.loading.remove(key)
                let raw = (o?["messages"] as? [[String: Any]] ?? []).reversed()
                var lines: [SlackLine] = []
                let group = DispatchGroup()
                for m in raw {
                    guard m["subtype"] as? String != "channel_join" else { continue }
                    let user = m["user"] as? String ?? ""
                    let ts = m["ts"] as? String ?? UUID().uuidString
                    let bot = (m["bot_profile"] as? [String: Any])?["name"] as? String ?? m["username"] as? String
                    let i = lines.count
                    lines.append(SlackLine(id: ts, sender: bot ?? self.names[user] ?? "", mine: user == self.me,
                                           text: self.tidy(m["text"] as? String ?? "", event: m), picture: self.pictures[user]))
                    if bot == nil, self.names[user] == nil, !user.isEmpty {
                        group.enter()
                        self.resolve(sender: user, botName: nil, channel: channel, direct: true) { who, _ in
                            lines[i] = SlackLine(id: ts, sender: who, mine: user == self.me, text: lines[i].text, picture: self.pictures[user])
                            group.leave()
                        }
                    }
                }
                group.notify(queue: .main) { store.lines[key] = lines }
            }
        }
    }

    /// A message arriving live goes into its conversation if that conversation is loaded.
    private func record(_ event: [String: Any], channel: String, sender: String, who: String) {
        let store = SlackConversations.shared
        let key = store.key(name, channel)
        guard store.lines[key] != nil, let ts = event["ts"] as? String,
              store.lines[key]?.contains(where: { $0.id == ts }) != true else { return }
        store.lines[key]?.append(SlackLine(id: ts, sender: who, mine: sender == me,
                                           text: tidy(event["text"] as? String ?? "", event: event), picture: pictures[sender]))
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
        }
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
        guard sender != me else { return }
        let body = event["text"] as? String ?? ""
        let kind = event["channel_type"] as? String ?? ""
        let direct = kind == "im" || kind == "mpim"
        let mentioned = body.contains("<@\(me)>")
        let fromApp = event["bot_id"] != nil || subtype == "bot_message"
        guard direct || mentioned || (apps && fromApp) else { return }

        let ts = event["ts"] as? String ?? ""
        resolve(sender: sender, botName: (event["bot_profile"] as? [String: Any])?["name"] as? String ?? event["username"] as? String,
                channel: channel, direct: direct) { [weak self] who, place in
            guard let self else { return }
            var alert = SlackAlert(id: "\(self.name)-\(ts)", workspace: self.name, priority: self.priority, team: self.team,
                                   channel: channel, place: place, sender: who, text: self.tidy(body, event: event), ts: ts)
            alert.thread = event["thread_ts"] as? String
            alert.direct = direct
            let botIcons = (event["bot_profile"] as? [String: Any])?["icons"] as? [String: Any]
            alert.picture = (botIcons?["image_72"] as? String ?? botIcons?["image_48"] as? String).flatMap(URL.init(string:))
                ?? self.pictures[sender]
            NotchUI.shared.slack(alert)
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
    private func tidy(_ text: String, event: [String: Any]) -> String {
        var s = text
        if s.isEmpty, let blocks = event["attachments"] as? [[String: Any]] {
            s = blocks.compactMap { $0["text"] as? String ?? $0["fallback"] as? String }.joined(separator: " ")
        }
        s = s.replacingOccurrences(of: #"<([^|>]+)\|([^>]+)>"#, with: "$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<@[A-Z0-9]+>"#, with: "@you", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<(https?://[^>]+)>"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        return oneLine(s, max: 200)
    }
}
