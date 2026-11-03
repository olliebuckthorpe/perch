import AppKit
import Network
import ImageIO
import SwiftUI
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
    /// What the screen knows this line by. A message shown the moment it is sent keeps its place
    /// when the real copy comes back under another id, so it animates in once, not twice.
    var viewID: String = ""
    var viewKey: String { viewID.isEmpty ? id : viewID }
    var sender: String
    let mine: Bool
    var text: String
    /// Slack only: the text with its formatting and links kept, as Slack's own markup.
    var rich = ""
    /// Slack only: changed since it was sent.
    var edited = false
    var picture: URL?
    var files: [SlackFile] = []
    /// WhatsApp only: when it was sent, and for the user's own messages the ticks (1 sent,
    /// 2 delivered, 3 read).
    var time: Date?
    var ticks: Int?
    /// Reactions on it, by who reacted ("me" for the user).
    var reactions: [String: String] = [:]
    /// WhatsApp only: the message this one replies to.
    var quote: SlackQuote?
    /// Slack only: reactions, as Slack counts them.
    var slackReactions: [SlackReaction] = []
    /// Slack only: the thread under this message, as Slack summarises it.
    var replyCount = 0
    var replyAt: Date?
    var repliers: [URL] = []
}

/// One reaction on a Slack message: the emoji, Slack's name for it, how many, and whether the
/// user is one of them.
struct SlackReaction: Equatable, Hashable {
    let name: String
    let emoji: String
    var count: Int
    var mine: Bool
}

/// The message a reply quotes: who sent it and a line of what it said.
struct SlackQuote: Equatable {
    let id: String
    let sender: String
    let text: String
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
    /// Open threads, parent first, by "workspace:channel:thread ts".
    var threads: [String: [SlackLine]] = [:]

    func key(_ workspace: String, _ channel: String) -> String { "\(workspace):\(channel)" }

    /// A conversation's lines as just loaded, keeping each line where the screen already has it:
    /// sent-just-now lines become their real copies, and anything not back yet stays.
    func replace(_ key: String, with loaded: [SlackLine]) {
        var fresh = loaded.map { l -> SlackLine in var l = l; if l.viewID.isEmpty { l.viewID = l.id }; return l }
        let old = lines[key] ?? []
        let known = Dictionary(old.map { ($0.id, $0.viewKey) }, uniquingKeysWith: { a, _ in a })
        for i in fresh.indices { if let v = known[fresh[i].id], !v.isEmpty { fresh[i].viewID = v } }
        var waiting: [SlackLine] = []
        for local in old where local.id.hasPrefix("local-") {
            if let i = Self.copy(of: local, in: fresh) {
                fresh[i].viewID = local.viewID
            } else if Date().timeIntervalSince(local.time ?? .distantPast) < 60 {
                waiting.append(local)
            }
        }
        lines[key] = fresh + waiting
    }

    /// The real copy of a message shown the moment it was sent: the user's own, with the same
    /// words once Slack's formatting is set aside, or else their first one from just after it.
    /// Never one that already stands for another line on screen.
    static func copy(of local: SlackLine, in lines: [SlackLine]) -> Int? {
        func plain(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let words = plain(local.text)
        let sent = local.time ?? .distantPast
        // Only the user's own lines not already standing for another, and a picture only for a
        // picture: a photo with no caption must never be taken for an older one.
        let free = lines.indices.filter { lines[$0].mine && lines[$0].viewKey == lines[$0].id && !lines[$0].id.hasPrefix("local-")
            && lines[$0].files.isEmpty == local.files.isEmpty }
        let recent = free.filter { (lines[$0].time ?? .distantPast) >= sent.addingTimeInterval(-5) }
        if !words.isEmpty, let i = recent.last(where: { plain(lines[$0].text) == words }) ?? free.last(where: { plain(lines[$0].text) == words }) {
            return i
        }
        return recent.first
    }

    /// A message arriving live: if it is the real copy of one just sent, it takes that one's
    /// place on screen instead of appearing twice.
    func arrive(_ key: String, _ line: SlackLine) {
        guard lines[key]?.contains(where: { $0.id == line.id }) != true else { return }
        if line.mine, let locals = lines[key]?.indices.filter({ lines[key]![$0].id.hasPrefix("local-") }), let first = locals.first {
            var real = line
            real.viewID = lines[key]![first].viewID
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { lines[key]![first] = real }
            return
        }
        lines[key]?.append(line)
    }

    /// A message the user just sent, shown at once while it goes.
    func showSent(_ key: String, text: String, whatsapp: Bool, quote: SlackQuote? = nil, sender: String = "You", picture: URL? = nil,
                  files: [SlackFile] = []) {
        let id = "local-\(UUID().uuidString)"
        let line = SlackLine(id: id, viewID: id, sender: sender, mine: true, text: text, picture: picture, files: files,
                             time: Date(), ticks: whatsapp ? 0 : nil, quote: quote)
        withAnimation(.sendSpring) {
            if lines[key] == nil { lines[key] = [] }
            lines[key]?.append(line)
        }
    }
}

extension SlackFile {
    /// A file just attached and being sent, shown in the chat at once: a picture shows from a
    /// small copy made here, until the real one comes back.
    static func sending(_ url: URL, workspace: String) -> SlackFile {
        let ext = url.pathExtension.lowercased()
        let image = ["jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "bmp"].contains(ext)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return SlackFile(id: "local-\(UUID().uuidString)", workspace: workspace, name: url.lastPathComponent, image: image,
                         thumb: nil, url: url, link: nil, kind: ext, size: size, preview: image ? smallCopy(url) : nil)
    }

    /// The picture scaled down to a sensible size and saved as JPEG data.
    static func smallCopy(_ url: URL, longest: Int = 900) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: longest,
              ] as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
}

/// One Slack message worth a banner.
struct SlackAlert: Identifiable, Equatable {
    let id: String
    let workspace: String
    let priority: Int
    let team: String
    let channel: String
    let place: String
    var sender: String
    let text: String
    let ts: String
    /// The thread it belongs to, if any. A reply goes into the same thread.
    var thread: String?
    /// The message this one replies under, when it is a reply in a thread.
    var threadParent: String? { thread.flatMap { $0 == ts ? nil : $0 } }
    /// Earlier messages from the same conversation that arrived while this banner was up,
    /// oldest first, so a burst of messages reads as one banner.
    var earlier: [String] = []
    var direct = false
    /// Who sent it, by Slack id, for finding the conversation with them.
    var senderID = ""
    /// The sender's profile picture (or the posting app's icon).
    var picture: URL?

    /// Attachment metadata and local previews carried by the notification.
    var files: [SlackFile] = []

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

    /// The user's name in a workspace, for picking out mentions of them.
    func myName(in workspace: String) -> String? { links.values.first { $0.name == workspace }?.myName }
    func myPicture(in workspace: String) -> URL? { links.values.first { $0.name == workspace }?.myPicture }

    /// Sends a reply as the user, as Slack does: to a reply in a thread, into that thread;
    /// anything else, straight into the conversation.
    func reply(to alert: SlackAlert, text: String, done: @escaping (Bool) -> Void) {
        if alert.workspace == WhatsAppSource.workspace { return WhatsAppSource.shared.send(to: alert.target, text: text, files: [], done: done) }
        guard let link = links.values.first(where: { $0.name == alert.workspace }) else { return done(false) }
        link.post(channel: alert.channel, text: text, thread: alert.threadParent, done: done)
    }

    /// Adds or takes away the user's reaction on a Slack message.
    func react(_ target: SlackTarget, ts: String, name: String, add: Bool) {
        links.values.first(where: { $0.name == target.workspace })?.react(target, ts: ts, name: name, add: add)
    }

    /// Slack threads: load one, reply in one, and where its lines are kept.
    func thread(_ target: SlackTarget, ts: String) {
        links.values.first(where: { $0.name == target.workspace })?.thread(target, ts: ts)
    }
    func replyInThread(_ target: SlackTarget, ts: String, text: String, broadcast: Bool = false, done: @escaping (Bool) -> Void) {
        guard let link = links.values.first(where: { $0.name == target.workspace }) else { return done(false) }
        link.replyInThread(target, ts: ts, text: text, broadcast: broadcast, done: done)
    }
    func edit(_ target: SlackTarget, ts: String, text: String, done: @escaping (Bool) -> Void) {
        guard let link = links.values.first(where: { $0.name == target.workspace }) else { return done(false) }
        link.edit(target, ts: ts, text: text, done: done)
    }
    func delete(_ target: SlackTarget, ts: String, done: @escaping (Bool) -> Void) {
        guard let link = links.values.first(where: { $0.name == target.workspace }) else { return done(false) }
        link.delete(target, ts: ts, done: done)
    }
    func threadKey(_ target: SlackTarget, ts: String) -> String? {
        links.values.first(where: { $0.name == target.workspace })?.threadKey(target, ts: ts)
    }

    /// Read in Perch is read in Slack (and on WhatsApp). `upTo` is a message to mark up to when
    /// the conversation itself is not loaded (a banner answered).
    func markRead(_ target: SlackTarget, upTo: String? = nil) {
        if target.workspace == WhatsAppSource.workspace { return WhatsAppSource.shared.markRead(target.id) }
        links.values.first(where: { $0.name == target.workspace })?.markRead(target, upTo: upTo)
    }

    /// How far the user had read in Slack itself, as a message time.
    func lastRead(_ target: SlackTarget, done: @escaping (Double?) -> Void) {
        guard let link = links.values.first(where: { $0.name == target.workspace }) else { return done(nil) }
        link.lastRead(target, done: done)
    }

    /// A fresh message to a person or channel, as the user, with any files attached.
    func send(to target: SlackTarget, text: String, files: [URL] = [], replyTo: String? = nil, done: @escaping (Bool) -> Void) {
        if target.workspace == WhatsAppSource.workspace {
            return WhatsAppSource.shared.send(to: target, text: text, files: files, replyTo: replyTo, done: done)
        }
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
        // Slack never says when something is read in the Slack app, so ask about the
        // conversations still unread here.
        let reads = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.syncReads() }
        reads.tolerance = 10
        // The network coming back: reconnect at once rather than waiting out the backoff.
        path.pathUpdateHandler = { [weak self] update in
            guard update.status == .satisfied else { return }
            DispatchQueue.main.async { self?.links.values.forEach { $0.reconnectIfDown() } }
        }
        path.start(queue: .global(qos: .utility))
    }

    private let path = NWPathMonitor()

    /// Clears conversations read in Slack itself: Slack's read marker is at or past the newest
    /// message Perch counted as unread.
    private func syncReads() {
        let ui = NotchUI.shared
        for (key, count) in ui.slackUnread where count > 0 {
            guard let link = links.values.first(where: { key.hasPrefix("\($0.name):") }),
                  let newest = ui.slackUnreadNewest[key] else { continue }
            let id = String(key.dropFirst(link.name.count + 1))
            let target = ui.slackRecent.first { $0.workspace == link.name && $0.id == id }
                ?? SlackTarget(workspace: link.name, id: id, name: "", channel: id.hasPrefix("C") || id.hasPrefix("G"))
            link.lastRead(target) { read in
                guard let read, read >= newest - 0.000001, (ui.slackUnread[key] ?? 0) > 0 else { return }
                ui.slackUnread[key] = nil
                ui.slackUnreadNewest[key] = nil
            }
        }
    }

    /// Where the keys live: one Keychain item per workspace and kind ("expox.app", "expox.user").
    static let keychainService = "com.jonny.perch.slack"

    /// Each workspace's file holds only its name, priority and alert choice; its two keys are in
    /// the Keychain. A file still holding keys (the old way) has them moved there and removed.
    private func scan() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir))?.filter { $0.hasSuffix(".json") } ?? []
        for file in files where links[file] == nil && !reading.contains(file) {
            let path = "\(dir)/\(file)"
            guard let data = FileManager.default.contents(atPath: path),
                  var o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let name = o["name"] as? String ?? String(file.dropLast(5))
            if let app = o["app"] as? String, let user = o["user"] as? String {
                guard Keychain.set(Self.keychainService, "\(name).app", app),
                      Keychain.set(Self.keychainService, "\(name).user", user) else {
                    SlackSource.status[name] = "could not move keys to the Keychain"
                    continue
                }
                o["app"] = nil
                o["user"] = nil
                Self.writeSettings(o, to: path)
            }
            // Off the main thread: the Keychain can stop to ask for the Mac password, and the
            // whole notch froze behind that prompt.
            reading.insert(file)
            let priority = o["priority"] as? Int ?? 9, apps = (o["alerts"] as? String ?? "apps") == "apps"
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let app = Keychain.get(Self.keychainService, "\(name).app")
                let user = Keychain.get(Self.keychainService, "\(name).user")
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.reading.remove(file)
                    guard self.links[file] == nil else { return }
                    guard let app, let user else {
                        SlackSource.status[name] = "no keys in the Keychain"
                        return
                    }
                    let w = Workspace(name: name, priority: priority, apps: apps, appToken: app, userToken: user)
                    self.links[file] = w
                    w.connect()
                }
            }
        }
    }

    /// Workspaces whose keys are being read from the Keychain.
    private var reading = Set<String>()

    /// A workspace's keys handed over by `slack/add-workspace.sh` through Perch's own socket: into
    /// the Keychain, its settings into its file, and connected at once (replacing an old link).
    func save(name: String, priority: Int, alerts: String, app: String, user: String) -> Bool {
        guard app.hasPrefix("xapp-"), user.hasPrefix("xoxp-"),
              name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              Keychain.set(Self.keychainService, "\(name).app", app),
              Keychain.set(Self.keychainService, "\(name).user", user) else { return false }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = "\(name).json"
        Self.writeSettings(["name": name, "priority": priority, "alerts": alerts], to: "\(dir)/\(file)")
        links[file]?.stop()
        links[file] = nil
        scan()
        return true
    }

    private static func writeSettings(_ o: [String: Any], to path: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) else { return }
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}

private final class Workspace {
    let name: String
    let priority: Int
    let apps: Bool
    private let appToken: String
    private let userToken: String
    private var me = ""
    /// The user's own name and picture here, once known.
    var myName: String? { names[me] }
    var myPicture: URL? { pictures[me] }
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
    /// Threads the user has written in: replies there notify, as they do in Slack.
    private var myThreads = Set<String>()
    /// The newest message seen, kept across restarts, so messages missed while Perch was off or
    /// reconnecting are picked up afterwards.
    private var seen: Double {
        get { UserDefaults.standard.double(forKey: "slackSeen.\(name)") }
        set { if newValue > seen { UserDefaults.standard.set(newValue, forKey: "slackSeen.\(name)") } }
    }
    private var heartbeat: Timer?

    init(name: String, priority: Int, apps: Bool, appToken: String, userToken: String) {
        self.name = name
        self.priority = priority
        self.apps = apps
        self.appToken = appToken
        self.userToken = userToken
    }

    /// The workspace's uploaded emoji. An alias ("alias:other") points at another one.
    private func loadCustomEmoji() {
        api("emoji.list", token: userToken) { [weak self] o in
            guard let self, let list = o?["emoji"] as? [String: String] else { return }
            var urls: [String: URL] = [:]
            for (name, value) in list where !value.hasPrefix("alias:") { urls[name] = URL(string: value) }
            for (name, value) in list where value.hasPrefix("alias:") {
                urls[name] = urls[String(value.dropFirst(6))]
            }
            SlackCustomEmoji.shared.byWorkspace[self.name] = urls
        }
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
                        return self.line(m)
                    }
                }
                // Shown straight away; names Perch doesn't know yet fill in as they arrive.
                store.replace(key, with: build())
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
                group.notify(queue: .main) { store.replace(key, with: build()) }
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
    /// One Slack message as a line, with its thread summary.
    private func line(_ m: [String: Any]) -> SlackLine {
        let user = m["user"] as? String ?? ""
        // Your own messages sent through Perch carry Perch's app name: they are still yours.
        let bot = user == me ? nil : (m["bot_profile"] as? [String: Any])?["name"] as? String ?? m["username"] as? String
        let rich = tidy(m["text"] as? String ?? "", event: m, full: true, rich: true)
        var line = SlackLine(id: m["ts"] as? String ?? UUID().uuidString,
                             sender: bot ?? names[user] ?? (user == me ? "You" : ""),
                             mine: user == me,
                             text: Self.unlinked(rich),
                             picture: pictures[user], files: SlackFile.list(m, workspace: name),
                             time: (m["ts"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) })
        line.rich = rich
        line.edited = m["edited"] != nil
        line.slackReactions = (m["reactions"] as? [[String: Any]] ?? []).compactMap { r in
            guard let name = r["name"] as? String else { return nil }
            return SlackReaction(name: name, emoji: emoji(for: name), count: r["count"] as? Int ?? 1,
                                 mine: (r["users"] as? [String])?.contains(me) == true)
        }
        if (m["thread_ts"] as? String) == (m["ts"] as? String) {
            line.replyCount = m["reply_count"] as? Int ?? 0
            line.replyAt = (m["latest_reply"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            line.repliers = (m["reply_users"] as? [String] ?? []).compactMap { pictures[$0] }
        }
        return line
    }

    /// A thread's messages, parent first, into `SlackConversations.threads`.
    func thread(_ target: SlackTarget, ts: String) {
        channel(for: target) { [weak self] channel in
            guard let self, let channel else { return }
            self.api("conversations.replies", token: self.userToken, ["channel": channel, "ts": ts, "limit": "100"]) { [weak self] o in
                guard let self, let raw = o?["messages"] as? [[String: Any]] else { return }
                let store = SlackConversations.shared
                let key = "\(store.key(self.name, channel)):\(ts)"
                store.threads[key] = raw.map { self.line($0) }
                // Names not known yet fill in once looked up.
                let unknown = Set(raw.compactMap { $0["user"] as? String }).filter { self.names[$0] == nil && !$0.isEmpty }
                guard !unknown.isEmpty else { return }
                let group = DispatchGroup()
                for user in unknown {
                    group.enter()
                    self.resolve(sender: user, botName: nil, channel: channel, direct: true) { _, _ in group.leave() }
                }
                group.notify(queue: .main) { store.threads[key] = raw.map { self.line($0) } }
            }
        }
    }

    func replyInThread(_ target: SlackTarget, ts: String, text: String, broadcast: Bool, done: @escaping (Bool) -> Void) {
        channel(for: target) { [weak self] channel in
            guard let self, let channel else { return done(false) }
            self.post(channel: channel, text: text, thread: ts, broadcast: broadcast) { ok in
                done(ok)
                if ok {
                    self.thread(target, ts: ts)
                    if broadcast { self.history(for: target) }
                }
            }
        }
    }

    /// Changes the text of one of the user's own messages.
    func edit(_ target: SlackTarget, ts: String, text: String, done: @escaping (Bool) -> Void) {
        channel(for: target) { [weak self] channel in
            guard let self, let channel else { return done(false) }
            let old = self.change(channel: channel, ts: ts) { $0.text = text; $0.rich = text; $0.edited = true }
            self.api("chat.update", token: self.userToken, ["channel": channel, "ts": ts, "text": text]) { o in
                if o == nil, let old { _ = self.change(channel: channel, ts: ts) { $0 = old } }
                done(o != nil)
            }
        }
    }

    /// Deletes one of the user's own messages.
    func delete(_ target: SlackTarget, ts: String, done: @escaping (Bool) -> Void) {
        channel(for: target) { [weak self] channel in
            guard let self, let channel else { return done(false) }
            self.api("chat.delete", token: self.userToken, ["channel": channel, "ts": ts]) { o in
                if o != nil { self.remove(channel: channel, ts: ts) }
                done(o != nil)
            }
        }
    }

    /// Changes a message wherever it is shown, in its conversation and in any thread. Returns
    /// it as it was.
    @discardableResult
    private func change(channel: String, ts: String, _ edit: (inout SlackLine) -> Void) -> SlackLine? {
        let store = SlackConversations.shared
        let key = store.key(name, channel)
        var before: SlackLine?
        if let i = store.lines[key]?.firstIndex(where: { $0.id == ts }) {
            before = store.lines[key]![i]
            edit(&store.lines[key]![i])
        }
        for (k, lines) in store.threads where k.hasPrefix(key + ":") {
            if let i = lines.firstIndex(where: { $0.id == ts }) {
                before = before ?? lines[i]
                edit(&store.threads[k]![i])
            }
        }
        return before
    }

    private func remove(channel: String, ts: String) {
        let store = SlackConversations.shared
        let key = store.key(name, channel)
        withAnimation(.easeOut(duration: 0.2)) {
            store.lines[key]?.removeAll { $0.id == ts }
            for (k, lines) in store.threads where k.hasPrefix(key + ":") && lines.contains(where: { $0.id == ts }) {
                // The message a thread hangs off stays as a placeholder while it has replies.
                if k == "\(key):\(ts)", lines.count > 1 {
                    store.threads[k]![0].text = "This message was deleted."
                    store.threads[k]![0].rich = "_This message was deleted._"
                    store.threads[k]![0].files = []
                } else {
                    store.threads[k]?.removeAll { $0.id == ts }
                    if let i = store.lines[key]?.firstIndex(where: { "\(key):\($0.id)" == k }) {
                        store.lines[key]![i].replyCount = max(0, store.lines[key]![i].replyCount - 1)
                    }
                }
            }
        }
    }

    /// Someone (or the user, elsewhere) edited or deleted a message.
    private func changed(_ event: [String: Any]) {
        guard let channel = event["channel"] as? String else { return }
        if event["subtype"] as? String == "message_deleted" {
            if let ts = event["deleted_ts"] as? String { remove(channel: channel, ts: ts) }
            return
        }
        guard var m = event["message"] as? [String: Any], let ts = m["ts"] as? String else { return }
        // A deleted thread parent comes as a change to a tombstone.
        if m["subtype"] as? String == "tombstone" { return remove(channel: channel, ts: ts) }
        if m["channel"] == nil { m["channel"] = channel }
        let fresh = line(m)
        change(channel: channel, ts: ts) { l in
            l.text = fresh.text
            l.rich = fresh.rich
            l.edited = fresh.edited
            l.files = fresh.files
        }
    }

    /// A Slack emoji name as the character, or the workspace's own name for a custom one.
    func emoji(for name: String) -> String {
        let shown = tidy(":\(name):", event: [:], full: true)
        return shown == ":\(name):" ? ":\(name):" : shown
    }

    func react(_ target: SlackTarget, ts: String, name: String, add: Bool) {
        channel(for: target) { [weak self] channel in
            guard let self, let channel else { return }
            // Shown at once; Slack's own record follows.
            self.adjust(channel: channel, ts: ts, name: name, by: self.me, add: add)
            self.api(add ? "reactions.add" : "reactions.remove", token: self.userToken,
                     ["channel": channel, "timestamp": ts, "name": name]) { _ in }
        }
    }

    /// A reaction changed on a message: its line, wherever it is shown, counts it.
    private func adjust(channel: String, ts: String, name: String, by user: String, add: Bool) {
        let store = SlackConversations.shared
        let key = store.key(self.name, channel)
        func change(_ line: inout SlackLine) {
            if let i = line.slackReactions.firstIndex(where: { $0.name == name }) {
                if user == me && line.slackReactions[i].mine == add { return }
                line.slackReactions[i].count += add ? 1 : -1
                if user == me { line.slackReactions[i].mine = add }
                if line.slackReactions[i].count <= 0 { line.slackReactions.remove(at: i) }
            } else if add {
                line.slackReactions.append(SlackReaction(name: name, emoji: emoji(for: name), count: 1, mine: user == me))
            }
        }
        if let i = store.lines[key]?.firstIndex(where: { $0.id == ts }) { change(&store.lines[key]![i]) }
        for (k, lines) in store.threads where k.hasPrefix(key + ":") {
            if let i = lines.firstIndex(where: { $0.id == ts }) { change(&store.threads[k]![i]) }
        }
    }

    /// Someone reacting live. Reactions to the user's own messages get a banner, as WhatsApp's do.
    private func reacted(_ event: [String: Any], add: Bool) {
        guard let item = event["item"] as? [String: Any], let channel = item["channel"] as? String,
              let ts = item["ts"] as? String, let name = event["reaction"] as? String,
              let user = event["user"] as? String else { return }
        adjust(channel: channel, ts: ts, name: name, by: user, add: add)
        guard add, user != me, event["item_user"] as? String == me else { return }
        resolve(sender: user, botName: nil, channel: channel, direct: true) { [weak self] who, _ in
            guard let self else { return }
            let store = SlackConversations.shared
            let original = store.lines[store.key(self.name, channel)]?.first { $0.id == ts }?.text ?? ""
            let quote = original.isEmpty ? "your message" : "“\(oneLine(original, max: 120))”"
            var alert = SlackAlert(id: "\(self.name)-reaction-\(ts)-\(name)-\(user)", workspace: self.name, priority: self.priority,
                                   team: self.team, channel: channel, place: "Reaction", sender: who,
                                   text: "Reacted \(self.emoji(for: name)) to \(quote)", ts: ts)
            alert.direct = channel.hasPrefix("D")
            alert.senderID = user
            alert.picture = self.pictures[user]
            NotchUI.shared.slack(alert)
        }
    }

    /// The thread key for a conversation, once its channel is known.
    func threadKey(_ target: SlackTarget, ts: String) -> String? {
        let store = SlackConversations.shared
        let channel = target.channel ? target.id : store.dmChannel["\(name):\(target.id)"]
        return channel.map { "\(store.key(name, $0)):\(ts)" }
    }

    private func record(_ event: [String: Any], channel: String, sender: String, who: String) {
        let store = SlackConversations.shared
        let key = store.key(name, channel)
        // A reply in a thread stays in its thread, as in Slack: the message it hangs off counts it.
        if let thread = event["thread_ts"] as? String, thread != event["ts"] as? String,
           event["subtype"] as? String != "thread_broadcast" {
            if let i = store.lines[key]?.firstIndex(where: { $0.id == thread }) {
                store.lines[key]?[i].replyCount += 1
                store.lines[key]?[i].replyAt = Date()
                if let p = pictures[sender], store.lines[key]?[i].repliers.contains(p) == false { store.lines[key]?[i].repliers.append(p) }
            }
            let threadKey = "\(key):\(thread)"
            if store.threads[threadKey] != nil, let ts = event["ts"] as? String,
               store.threads[threadKey]?.contains(where: { $0.id == ts }) != true {
                var m = event
                m["user"] = sender
                store.threads[threadKey]?.append(line(m))
            }
            return
        }
        guard store.lines[key] != nil, let ts = event["ts"] as? String else { return }
        var m = event
        m["user"] = sender
        var line = line(m)
        if !who.isEmpty && sender != me { line.sender = who }
        store.arrive(key, line)
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

    func post(channel: String, text: String, thread: String?, broadcast: Bool = false, done: @escaping (Bool) -> Void) {
        var params = ["channel": channel, "text": text]
        if let thread { params["thread_ts"] = thread }
        if thread != nil && broadcast { params["reply_broadcast"] = "true" }
        api("chat.postMessage", token: userToken, params) { o in done(o != nil) }
    }

    /// Tells Slack the conversation is read up to its newest message, as opening it in Slack does.
    func markRead(_ target: SlackTarget, upTo: String? = nil) {
        channel(for: target) { [weak self] channel in
            guard let self, let channel else { return }
            let key = SlackConversations.shared.key(self.name, channel)
            let newest = SlackConversations.shared.lines[key]?.last(where: { !$0.id.hasPrefix("local-") })?.id
            guard let ts = [newest, upTo].compactMap({ $0 }).max(by: { (Double($0) ?? 0) < (Double($1) ?? 0) }) else { return }
            self.api("conversations.mark", token: self.userToken, ["channel": channel, "ts": ts]) { _ in }
        }
    }

    /// How far the user had read in Slack itself, for opening at the first unread message.
    func lastRead(_ target: SlackTarget, done: @escaping (Double?) -> Void) {
        channel(for: target) { [weak self] channel in
            guard let self, let channel else { return done(nil) }
            self.api("conversations.info", token: self.userToken, ["channel": channel]) { o in
                done(((o?["channel"] as? [String: Any])?["last_read"] as? String).flatMap(Double.init))
            }
        }
    }

    /// Every Slack refusal, not just the latest, so a failure that keeps happening can be traced.
    private static func logError(_ line: String) {
        let path = "\(Shell.home)/.perch/slack-errors.log"
        let entry = "\(Date()) \(line)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            _ = try? handle.seekToEnd()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func api(_ method: String, token: String, _ params: [String: String] = [:], timeout: TimeInterval = 60,
                     done: @escaping ([String: Any]?) -> Void) {
        var parts = URLComponents(string: "https://slack.com/api/\(method)")!
        if !params.isEmpty {
            parts.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            // Slack reads a bare "+" as a space, which turned the 👍 reaction ("+1") into " 1" and
            // any plus sign in a message into a gap.
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        var req = URLRequest(url: parts.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let o = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { [weak self] in
                if o?["ok"] as? Bool != true, let self {
                    // Slack's reason, for working out why something did not send. Never the keys.
                    let at = Date().formatted(date: .omitted, time: .standard)
                    SlackSource.status["\(self.name) error"] = "\(at) \(method): \(o?["error"] as? String ?? "no answer")"
                    Self.logError("\(self.name) \(method): \(o?["error"] as? String ?? "no answer")")
                }
                done(o?["ok"] as? Bool == true ? o : nil)
            }
        }.resume()
    }

    func connect() {
        guard !stopped else { return }
        if me.isEmpty {
            // Who the user is in this workspace: their own messages never become banners.
            api("auth.test", token: userToken) { [weak self] o in
                guard let self else { return }
                self.me = o?["user_id"] as? String ?? ""
                // Your own name and picture, for your messages and for mentions of you.
                if !self.me.isEmpty { self.resolve(sender: self.me, botName: nil, channel: "", direct: true) { _, _ in } }
                self.team = o?["team_id"] as? String ?? ""
                if self.me.isEmpty { self.later() } else {
                    self.api("team.info", token: self.userToken) { [weak self] o in
                        let icon = (o?["team"] as? [String: Any])?["icon"] as? [String: Any]
                        self?.teamIcon = (icon?["image_88"] as? String ?? icon?["image_68"] as? String).flatMap(URL.init(string:))
                        self?.loadDirectory()
                        self?.loadCustomEmoji()
                    }
                    self.connect()
                }
            }
            return
        }
        // One connection at a time. Two open at once and Slack splits the messages between them,
        // and the ones sent to a connection Perch has stopped reading arrive minutes late.
        guard !connecting else { return }
        connecting = true
        api("apps.connections.open", token: appToken, timeout: 15) { [weak self] o in
            guard let self else { return }
            self.connecting = false
            guard !self.stopped, let url = (o?["url"] as? String).flatMap(URL.init(string:)) else {
                SlackSource.status[self.name] = "could not open a connection"
                self.later()
                return
            }
            SlackSource.status[self.name] = "connected"
            self.socket?.cancel()
            let socket = URLSession.shared.webSocketTask(with: url)
            self.socket = socket
            self.retry = 2
            socket.resume()
            self.receive(socket)
            self.beat(socket)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.catchUp() }
        }
    }

    /// Direct messages that came while Perch was off or reconnecting: into the sidebar, unread,
    /// without a banner each. Only for the last few hours, so a long absence is not a flood.
    private func catchUp() {
        let since = seen
        guard since > 0, Date().timeIntervalSince1970 - since < 6 * 3600 else { return }
        let store = SlackConversations.shared
        let channels = store.dmChannel.filter { $0.key.hasPrefix("\(name):") && !$0.value.contains(":dm:") }.map(\.value)
        for (i, channel) in Set(channels).enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.4) { [weak self] in
                guard let self else { return }
                self.api("conversations.history", token: self.userToken,
                         ["channel": channel, "oldest": String(format: "%.6f", since), "limit": "20"]) { [weak self] o in
                    for var m in ((o?["messages"] as? [[String: Any]]) ?? []).reversed() {
                        m["channel_type"] = "im"
                        self?.consider(m, channel: channel)
                    }
                }
            }
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
    /// Replaced by a newer copy (keys saved again): close the connection for good.
    private var stopped = false
    func stop() {
        stopped = true
        socket?.cancel()
        socket = nil
        heartbeat?.invalidate()
    }

    func reconnect() {
        socket?.cancel()
        socket = nil
        heartbeat?.invalidate()
        retry = 2
        connect()
    }

    private var connecting = false
    /// A retry waiting to run, so several failures do not each schedule their own.
    private var pending = false

    /// Reconnects when there is no live connection (the network just came back).
    func reconnectIfDown() {
        guard socket == nil, !connecting, !stopped else { return }
        retry = 2
        connect()
    }

    private func later() {
        guard !pending else { return }
        pending = true
        let wait = retry
        // Capped low: Slack holds messages while Perch is away, so a long wait is a late message.
        retry = min(retry * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.pending = false
            self?.connect()
        }
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
        // More than one means another copy is connected with the same key and is taking a share
        // of the messages.
        if o["type"] as? String == "hello", let count = o["num_connections"] as? Int {
            SlackSource.status[name + " connections"] = "\(count)"
            if count > 1 { Self.logError("\(name) hello: \(count) connections open") }
        }
        guard o["type"] as? String == "events_api",
              let event = (o["payload"] as? [String: Any])?["event"] as? [String: Any] else { return }
        if event["type"] as? String == "reaction_added" { return reacted(event, add: true) }
        if event["type"] as? String == "reaction_removed" { return reacted(event, add: false) }
        guard event["type"] as? String == "message" else { return }
        let subtype = event["subtype"] as? String
        if subtype == "message_changed" || subtype == "message_deleted" { return changed(event) }
        guard subtype == nil || subtype == "bot_message" || subtype == "thread_broadcast" || subtype == "file_share" else { return }
        let sender = event["user"] as? String ?? ""
        guard let channel = event["channel"] as? String else { return }
        // Every message keeps an open conversation current, including your own from elsewhere.
        let loaded = SlackConversations.shared.lines[SlackConversations.shared.key(name, channel)] != nil
        if loaded {
            let bot = sender == me ? nil : (event["bot_profile"] as? [String: Any])?["name"] as? String ?? event["username"] as? String
            resolve(sender: sender, botName: bot, channel: channel, direct: true) { [weak self] who, _ in
                self?.record(event, channel: channel, sender: sender, who: who)
            }
        }
        consider(event, channel: channel)
    }

    /// Whether a message deserves a banner (or at least a place in the sidebar), live or caught
    /// up after a reconnect.
    private func consider(_ event: [String: Any], channel: String) {
        let sender = event["user"] as? String ?? ""
        let subtype = event["subtype"] as? String
        if let ts = (event["ts"] as? String).flatMap(Double.init) { seen = ts }
        // The user's own messages: anything in that conversation from before is already answered.
        if sender == me, let ts = event["ts"] as? String {
            lastMine[channel] = max(Double(ts) ?? 0, lastMine[channel] ?? 0)
            if let thread = event["thread_ts"] as? String, thread != ts {
                myThreads.insert(thread)
                // Into the Threads list, read.
                let kind = event["channel_type"] as? String ?? ""
                let direct = kind == "im" || kind == "mpim"
                resolve(sender: sender, botName: nil, channel: channel, direct: direct) { [weak self] who, place in
                    guard let self else { return }
                    var alert = SlackAlert(id: "\(self.name)-\(ts)", workspace: self.name, priority: self.priority, team: self.team,
                                           channel: channel, place: place, sender: who, text: self.tidy(event["text"] as? String ?? "", event: event), ts: ts)
                    alert.direct = direct
                    if direct {
                        // The person the conversation is with, not the user.
                        let store = SlackConversations.shared
                        guard let person = store.dmChannel.first(where: { $0.value == channel && $0.key.hasPrefix("\(self.name):") })?
                            .key.dropFirst(self.name.count + 1) else { return }
                        alert.senderID = String(person)
                        alert.sender = self.names[String(person)] ?? ""
                    }
                    SlackThreads.shared.note(alert, thread: thread, mine: true)
                }
            }
            return
        }
        let body = event["text"] as? String ?? ""
        let kind = event["channel_type"] as? String ?? ""
        let direct = kind == "im" || kind == "mpim"
        let mentioned = body.contains("<@\(me)>")
        // As Slack does: @here and @channel, and replies in a thread you started or wrote in.
        let everyone = body.contains("<!here") || body.contains("<!channel")
        let thread = event["thread_ts"] as? String
        let inThread = thread.map { event["parent_user_id"] as? String == me || myThreads.contains($0) } ?? false
        let fromApp = event["bot_id"] != nil || subtype == "bot_message"
        guard direct || mentioned || everyone || inThread || (apps && fromApp) else { return }

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
            if let thread = alert.threadParent { SlackThreads.shared.note(alert, thread: thread, mine: false) }
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

    // Compiled once: building a pattern costs more than using it.
    nonisolated(unsafe) private static let emojiPattern = #/:([a-z0-9_+\-']+)(::skin-tone-[2-6])?:/#
    nonisolated(unsafe) private static let mentionPattern = #/<@([A-Z0-9]+)(?:\|([^>]*))?>/#
    private static let markdownLink = try! NSRegularExpression(pattern: #"\[([^\]]*)\]\((?:https?|mailto):[^)]*\)"#)

    /// Slack text as plain words, from the version with its links kept.
    static func unlinked(_ rich: String) -> String {
        guard rich.contains("](") else { return rich }
        return markdownLink.stringByReplacingMatches(in: rich, range: NSRange(rich.startIndex..., in: rich), withTemplate: "$1")
    }

    private func tidy(_ text: String, event: [String: Any], full: Bool = false, rich: Bool = false) -> String {
        var s = text
        if let blocks = event["blocks"] { learnEmoji(blocks) }
        for match in s.matches(of: Self.emojiPattern).reversed() {
            let name = String(match.1), tone = match.2.map(String.init) ?? ""
            if let char = emoji[name + tone] ?? emoji[name] ?? Self.common[name] { s.replaceSubrange(match.range, with: char) }
        }
        // Mentions read as the person's name, and as "you" only when they are.
        for match in s.matches(of: Self.mentionPattern).reversed() {
            let id = String(match.1)
            let who = names[id] ?? match.2.map(String.init) ?? (id == me ? "you" : "someone")
            s.replaceSubrange(match.range, with: "@" + who)
        }
        if s.isEmpty, let blocks = event["attachments"] as? [[String: Any]] {
            s = blocks.compactMap { $0["text"] as? String ?? $0["fallback"] as? String }.joined(separator: " ")
        }
        s = s.replacingOccurrences(of: #"<!(here|channel|everyone)(?:\|[^>]*)?>"#, with: "@$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<#[A-Z0-9]+\|([^>]+)>"#, with: "#$1", options: .regularExpression)
        if rich {
            // Links keep where they go, as Markdown, for showing them as links.
            s = s.replacingOccurrences(of: #"<((?:https?|mailto):[^|>]+)\|([^>]+)>"#, with: "[$2]($1)", options: .regularExpression)
            s = s.replacingOccurrences(of: #"<((?:https?|mailto):[^>]+)>"#, with: "[$1]($1)", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"<([^|>]+)\|([^>]+)>"#, with: "$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<(https?://[^>]+)>"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        return full ? s.trimmingCharacters(in: .whitespacesAndNewlines) : oneLine(s, max: 200)
    }
}

/// Each workspace's own emoji (the ones people upload), name to picture, so a custom reaction
/// shows as its image rather than as ":its-name:".
@Observable
final class SlackCustomEmoji {
    static let shared = SlackCustomEmoji()
    var byWorkspace: [String: [String: URL]] = [:]

    func url(_ workspace: String, _ name: String) -> URL? { byWorkspace[workspace]?[name] }
}

/// Threads the user is in, as Slack's Threads view lists them: ones they started, wrote in or
/// were mentioned in, newest reply first. Built from what arrives, and kept on disk so the list
/// survives a restart.
@Observable
final class SlackThreads {
    static let shared = SlackThreads()

    struct Followed: Codable, Identifiable, Equatable {
        /// The same as the thread's key in `SlackConversations.threads`.
        var id: String { "\(workspace):\(channel):\(ts)" }
        let workspace: String
        let channel: String
        let ts: String
        var targetID: String
        var targetName: String
        var isChannel: Bool
        var lastSender: String
        var lastText: String
        var lastAt: Date
        var unread: Int
        var target: SlackTarget {
            SlackDirectory.shared.targets.first { $0.workspace == workspace && $0.id == targetID }
                ?? SlackTarget(workspace: workspace, id: targetID, name: targetName, channel: isChannel)
        }
    }

    private(set) var all: [Followed] = []
    var unread: Int { all.reduce(0) { $0 + $1.unread } }
    private let path = "\(Shell.home)/.perch/slack-threads.json"

    init() {
        if let data = FileManager.default.contents(atPath: path),
           let saved = try? JSONDecoder().decode([Followed].self, from: data) { all = saved }
    }

    /// A reply in a thread the user is in. Theirs marks it read; anyone else's counts as unread
    /// unless that thread is on screen.
    func note(_ alert: SlackAlert, thread: String, mine: Bool) {
        let target = alert.target
        var item = Followed(workspace: alert.workspace, channel: alert.channel, ts: thread, targetID: target.id,
                            targetName: target.name, isChannel: target.channel, lastSender: mine ? "You" : alert.sender,
                            lastText: alert.text, lastAt: Date(), unread: 0)
        let viewing = NotchUI.shared.viewingThread(target, ts: thread)
        if let i = all.firstIndex(where: { $0.id == item.id }) {
            item.unread = mine || viewing ? 0 : all[i].unread + 1
            all.remove(at: i)
        } else {
            item.unread = mine || viewing ? 0 : 1
        }
        all.insert(item, at: 0)
        all = Array(all.prefix(60))
        save()
    }

    func read(_ id: String) {
        guard let i = all.firstIndex(where: { $0.id == id }), all[i].unread > 0 else { return }
        all[i].unread = 0
        save()
    }

    func unread(_ id: String) -> Int { all.first { $0.id == id }?.unread ?? 0 }

    private func save() {
        guard let data = try? JSONEncoder().encode(all) else { return }
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}
