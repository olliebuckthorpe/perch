import AppKit
import Observation

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
    private var places: [String: String] = [:]
    private var retry: TimeInterval = 2

    init(name: String, priority: Int, apps: Bool, appToken: String, userToken: String) {
        self.name = name
        self.priority = priority
        self.apps = apps
        self.appToken = appToken
        self.userToken = userToken
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
                if self.me.isEmpty { self.later() } else { self.connect() }
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
        guard sender != me, let channel = event["channel"] as? String else { return }
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
