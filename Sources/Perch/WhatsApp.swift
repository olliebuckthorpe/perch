import AppKit
import Observation

/// One WhatsApp chat, as the helper lists it.
struct WhatsAppChat: Identifiable, Equatable {
    let id: String
    var name: String
    var group: Bool
    var ts: Date
    var unread: Int
    var last: String
    var size = 0
    var community = false
    /// The last message was the user's own, and how far it got (ticks).
    var lastMine = false
    var lastTicks = 0
    var lastKind = "text"
    var lastPreview: Data?

    /// A big group or part of a Community: only worth hearing about when it is talking to the user.
    var crowd: Bool { group && (community || size > WhatsAppSource.smallGroup) }

    /// As a conversation the Slack screens can show: WhatsApp reuses them.
    var target: SlackTarget {
        SlackTarget(workspace: WhatsAppSource.workspace, id: id, name: name, channel: false,
                    picture: WhatsAppSource.shared.avatars[id])
    }
}

/// Perch's WhatsApp, through `perch-whatsapp`: a small helper (built on whatsmeow) that joins the
/// user's WhatsApp as a linked device, like WhatsApp Web, and keeps everything on the Mac.
///
/// Chats appear as conversations in the same screens as Slack (the sidebar, banners, the chat
/// view, search), told apart by the workspace name "whatsapp". Nothing is marked read until the
/// chat is opened here, and nothing is ever sent except what the user types.
@Observable
final class WhatsAppSource {
    static let shared = WhatsAppSource()
    static let workspace = "whatsapp"
    /// Groups this size or smaller notify for every message.
    static let smallGroup = 15

    enum State: Equatable {
        case off, starting, scan(String), ready, loggedOut, failed(String)
    }

    private(set) var state: State = .off
    private(set) var chats: [WhatsAppChat] = []
    private(set) var avatars: [String: URL] = [:]
    /// Who is typing in each chat, and until when (each signal lasts a few seconds unless renewed).
    private(set) var typing: [String: (who: String, audio: Bool, group: Bool, until: Date)] = [:]
    /// Chats open on screen right now; Perch is online on WhatsApp only while there is one.
    @ObservationIgnored private var watching: [String: Int] = [:]

    /// A chat opened: be online and listen for typing in it.
    func watch(_ chat: String) {
        watching[chat, default: 0] += 1
        request("watch", ["chat": chat])
    }

    /// A chat closed: once none are open, offline again so the phone keeps its notifications.
    func unwatch(_ chat: String) {
        watching[chat] = max(0, (watching[chat] ?? 1) - 1)
        if watching[chat] == 0 { watching[chat] = nil; typing[chat] = nil }
        if watching.isEmpty { request("unwatch") }
    }

    /// What to show under a chat's name while someone there is typing.
    func typingLine(_ chat: String) -> String? {
        guard let t = typing[chat], t.until > Date() else { return nil }
        let doing = t.audio ? "recording audio…" : "typing…"
        return t.group ? "\(t.who.split(separator: " ").first.map(String.init) ?? t.who) is \(doing)" : doing
    }
    /// Everyone in the user's WhatsApp contacts, for search.
    private(set) var contacts: [(id: String, lid: String, name: String)] = []
    @ObservationIgnored private var contactsTimer: Timer?

    @ObservationIgnored private var helper: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var waiting: [Int: (Any?) -> Void] = [:]
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private var media: [String: String] = [:]
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var reactionNotices: [String: (text: String, at: Date)] = [:]
    private static let folder = "\(Shell.home)/.perch/whatsapp"

    /// Linked before, so it starts with Perch.
    var linked: Bool {
        get { UserDefaults.standard.bool(forKey: "whatsappLinked") }
        set { UserDefaults.standard.set(newValue, forKey: "whatsappLinked") }
    }

    func start() {
        guard linked || wanted else { return }
        launch()
    }

    /// The user asked to connect: start the helper, which shows a QR code to scan.
    func connect() {
        wanted = true
        launch()
    }

    func disconnect() {
        request("logout") { [weak self] _ in
            self?.wanted = false
            self?.linked = false
            self?.helper?.terminate()
            self?.state = .off
            self?.chats = []
        }
    }

    // MARK: Helper process

    private func launch() {
        guard helper == nil, let path = Bundle.main.path(forResource: "perch-whatsapp", ofType: nil) else {
            if helper == nil { state = .failed("Perch is missing its WhatsApp helper") }
            return
        }
        state = .starting
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async { self?.receive(chunk) }
        }
        p.terminationHandler = { [weak self] _ in
            stdout.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.helper = nil
                self.input = nil
                self.buffer = Data()
                let stranded = self.waiting
                self.waiting = [:]
                for done in stranded.values { done(nil) }
                // Back up shortly, unless the user disconnected.
                if self.linked || self.wanted {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.start() }
                }
            }
        }
        do { try p.run() } catch {
            state = .failed("Could not start WhatsApp")
            return
        }
        helper = p
        input = stdin.fileHandleForWriting
    }

    private func receive(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = o["id"] as? Int, let done = waiting.removeValue(forKey: id) {
                done(o["ok"] as? Bool == true ? (o["data"] ?? NSNull()) : nil)
            } else if let event = o["event"] as? String {
                handle(event, o)
            }
        }
    }

    private func request(_ cmd: String, _ args: [String: Any] = [:], done: @escaping (Any?) -> Void = { _ in }) {
        guard let input else { return done(nil) }
        let id = nextID
        nextID += 1
        waiting[id] = done
        var body = args
        body["id"] = id
        body["cmd"] = cmd
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return done(nil) }
        input.write(data + Data([0x0A]))
    }

    // MARK: Events

    private func handle(_ event: String, _ o: [String: Any]) {
        switch event {
        case "qr":
            if let code = o["code"] as? String { state = .scan(code) }
        case "paired":
            state = .starting
        case "ready":
            state = .ready
            linked = true
            loadChats(seed: true)
            loadContacts()
            contactsTimer?.invalidate()
            contactsTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.loadContacts() }
        case "loggedOut":
            state = .loggedOut
            linked = false
            chats = []
        case "synced":
            loadChats(seed: false)
            loadContacts()
        case "read":
            if let chat = o["chat"] as? String {
                NotchUI.shared.slackUnread["\(Self.workspace):\(chat)"] = nil
                if let i = chats.firstIndex(where: { $0.id == chat }) { chats[i].unread = 0 }
            }
        case "message":
            arrived(o)
        case "typing":
            guard let chat = o["chat"] as? String else { break }
            if o["typing"] as? Bool == true {
                let until = Date().addingTimeInterval(8)
                typing[chat] = (o["who"] as? String ?? "", o["audio"] as? Bool ?? false, o["group"] as? Bool ?? false, until)
                // WhatsApp renews the signal while they keep typing; without that it fades.
                DispatchQueue.main.asyncAfter(deadline: .now() + 8.2) { [weak self] in
                    if let t = self?.typing[chat], t.until <= Date() { self?.typing[chat] = nil }
                }
            } else {
                typing[chat] = nil
            }
        case "reaction":
            guard let chat = o["chat"] as? String, let id = o["id"] as? String else { break }
            setReactions(chat, id, o["reactions"] as? [String: String] ?? [:])
            reactionArrived(o, chat: chat, messageID: id)
        case "status":
            // Delivered or read on the other side: the ticks move on.
            guard let chat = o["chat"] as? String, let ids = o["ids"] as? [String], let tick = o["status"] as? Int else { break }
            let store = SlackConversations.shared
            let key = store.key(Self.workspace, chat)
            if var lines = store.lines[key] {
                for i in lines.indices where ids.contains(lines[i].id) { lines[i].ticks = max(lines[i].ticks ?? 1, tick) }
                store.lines[key] = lines
            }
            if let i = chats.firstIndex(where: { $0.id == chat }), chats[i].lastMine { chats[i].lastTicks = max(chats[i].lastTicks, tick) }
        case "error":
            if case .ready = state { break }
            state = .failed(o["message"] as? String ?? "WhatsApp stopped")
        default:
            break
        }
    }

    /// A message came in (or was sent from the phone): into its open conversation, the sidebar
    /// and, when it is for the user, a banner.
    private func arrived(_ o: [String: Any]) {
        // Status updates are not chats.
        guard let chat = o["chat"] as? String, !chat.hasSuffix("@broadcast") else { return }
        let line = Self.line(o, chat: chat)
        if !line.mine { typing[chat] = nil }
        let store = SlackConversations.shared
        let key = store.key(Self.workspace, chat)
        if store.lines[key] != nil, store.lines[key]?.contains(where: { $0.id == line.id }) != true {
            store.arrive(key, line)
        }
        let group = o["group"] as? Bool ?? false
        let name = o["chatName"] as? String ?? "WhatsApp"
        if let i = chats.firstIndex(where: { $0.id == chat }) {
            chats[i].ts = Date()
            chats[i].last = line.text.isEmpty ? Self.label(o["kind"] as? String) : line.text
            chats[i].lastMine = line.mine
            chats[i].lastTicks = line.ticks ?? 1
            chats[i].lastKind = o["kind"] as? String ?? "text"
            chats[i].lastPreview = line.files.first?.preview
            reactionNotices[chat] = nil
            chats[i].name = name
        } else {
            chats.insert(WhatsAppChat(id: chat, name: name, group: group, ts: Date(), unread: 0, last: line.text.isEmpty ? Self.label(o["kind"] as? String) : line.text,
                                       lastKind: o["kind"] as? String ?? "text", lastPreview: line.files.first?.preview), at: 0)
        }
        guard o["fromMe"] as? Bool != true else { return }
        // Reading it right now in the notch: it is read on the phone too.
        let ui = NotchUI.shared
        if (ui.expanded && !ui.cardsOnly && ui.slackTarget?.workspace == Self.workspace && ui.slackTarget?.id == chat)
            || SidePanel.shared.showing(Self.workspace, chat) {
            markRead(chat)
            return
        }
        // WhatsApp already displays the conversation while its desktop app is active.
        // Leave read receipts to WhatsApp; only suppress Perch's duplicate banner.
        let sender = o["senderName"] as? String ?? name
        var alert = SlackAlert(id: "wa-\(o["id"] as? String ?? UUID().uuidString)", workspace: Self.workspace, priority: 1,
                               team: "", channel: chat, place: group ? name : "WhatsApp",
                               sender: group ? sender : name, text: line.text.isEmpty ? Self.label(o["kind"] as? String) : line.text,
                               ts: o["id"] as? String ?? "")
        alert.direct = !group
        alert.senderID = chat
        alert.picture = avatars[chat]
        alert.files = line.files
        avatar(chat)
        // Direct chats and small groups notify like they do on the phone. Big groups and
        // Communities only when someone @s the user or replies to them; the rest wait, unread.
        let size = o["groupSize"] as? Int ?? 0
        let crowd = o["community"] as? Bool == true || size > Self.smallGroup
        if let i = chats.firstIndex(where: { $0.id == chat }) {
            chats[i].size = size
            chats[i].community = o["community"] as? Bool ?? false
        }
        // Big groups and Communities stay out entirely unless they are talking to the user.
        if !group || !crowd || o["mentionsMe"] as? Bool == true {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "net.whatsapp.WhatsApp" {
                ui.noteSlack(alert)
            } else { ui.slack(alert) }
        }
    }

    private func reactionArrived(_ event: [String: Any], chat: String, messageID: String) {
        guard let emoji = event["emoji"] as? String else { return }
        let mine = event["fromMe"] as? Bool == true
        let actor = mine ? "You" : (event["actorName"] as? String ?? "Someone")
        let original = (event["originalText"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.label(event["originalKind"] as? String)
        let quote = original.isEmpty ? "a message" : "“\(oneLine(original, max: 160))”"
        let text = emoji.isEmpty ? "\(actor) removed a reaction from \(quote)" : "\(actor) reacted \(emoji) to \(quote)"
        let at = Date()
        reactionNotices[chat] = (text, at)
        if let i = chats.firstIndex(where: { $0.id == chat }) {
            chats[i].last = text
            chats[i].lastKind = "reaction"
            chats[i].lastPreview = nil
            chats[i].lastMine = false
            chats[i].ts = at
        }
        // Own reactions sync into the preview. Only reactions to our messages alert us.
        guard !mine, !emoji.isEmpty, event["originalFromMe"] as? Bool == true else { return }
        let ui = NotchUI.shared
        if ui.expanded, !ui.cardsOnly, ui.slackTarget?.workspace == Self.workspace, ui.slackTarget?.id == chat { return }
        let group = event["group"] as? Bool == true
        let name = event["chatName"] as? String ?? actor
        var alert = SlackAlert(id: "wa-reaction-\(messageID)-\(UUID().uuidString)", workspace: Self.workspace,
                               priority: 1, team: "", channel: chat, place: group ? name : "WhatsApp",
                               sender: actor, text: text, ts: messageID)
        alert.direct = !group
        alert.senderID = chat
        alert.picture = avatars[chat]
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "net.whatsapp.WhatsApp" { ui.noteSlack(alert) }
        else { ui.slack(alert) }
    }

    private static func label(_ kind: String?) -> String {
        switch kind {
        case "image": return "Photo"
        case "video": return "Video"
        case "audio": return "Voice message"
        case "sticker": return "Sticker"
        case "document": return "File"
        default: return ""
        }
    }

    /// A message as a line in the conversation view, with any picture or file attached.
    private static func line(_ m: [String: Any], chat: String) -> SlackLine {
        let id = m["id"] as? String ?? UUID().uuidString
        let kind = m["kind"] as? String ?? "text"
        let mine = m["fromMe"] as? Bool ?? false
        var files: [SlackFile] = []
        if kind != "text" {
            let url = URL(string: "perch-wa://media/\(chat)/\(id)")
            let name = (m["filename"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? label(kind)
            let ext = (name as NSString).pathExtension
            let preview = (m["thumb"] as? String).flatMap { Data(base64Encoded: $0) }
            files.append(SlackFile(id: id, workspace: workspace, name: name, image: kind == "image" || kind == "sticker",
                                   thumb: url, url: url, link: nil,
                                   kind: kind == "audio" ? "audio" : (ext.isEmpty ? label(kind) : ext), size: 0, preview: preview))
        }
        // Each person's own picture: the sender's in a group, the other person's in a direct chat.
        let who = (m["group"] as? Bool == true || chat.hasSuffix("@g.us")) ? (m["sender"] as? String ?? chat) : chat
        let time = (m["ts"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return SlackLine(id: id, sender: mine ? "You" : (m["senderName"] as? String ?? ""), mine: mine,
                         text: m["text"] as? String ?? "", picture: mine ? nil : shared.picture(for: who), files: files,
                         time: time, ticks: mine ? max(1, m["status"] as? Int ?? 1) : nil,
                         reactions: m["reactions"] as? [String: String] ?? [:],
                         quote: (m["quote"] as? [String: String]).flatMap { q in
                             q["id"].map { SlackQuote(id: $0, sender: q["sender"] ?? "",
                                                      text: (q["text"]).flatMap { $0.isEmpty ? nil : $0 } ?? label(q["kind"])) }
                         })
    }

    // MARK: Chats

    private func loadChats(seed: Bool) {
        request("chats", ["limit": 200]) { [weak self] data in
            guard let self, let rows = data as? [[String: Any]] else { return }
            self.chats = rows.compactMap { r in
                guard let id = r["chat"] as? String else { return nil }
                let last = (r["last"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Self.label(r["lastKind"] as? String)
                return WhatsAppChat(id: id, name: r["name"] as? String ?? "", group: r["group"] as? Bool ?? false,
                                    ts: Date(timeIntervalSince1970: r["ts"] as? Double ?? 0),
                                    unread: r["unread"] as? Int ?? 0, last: last,
                                    size: r["groupSize"] as? Int ?? 0, community: r["community"] as? Bool ?? false,
                                    lastMine: r["lastMine"] as? Bool ?? false, lastTicks: max(1, r["lastStatus"] as? Int ?? 1),
                                    lastKind: r["lastKind"] as? String ?? "text",
                                    lastPreview: (r["lastThumb"] as? String).flatMap { Data(base64Encoded: $0) })
            }
            for i in self.chats.indices {
                if let notice = self.reactionNotices[self.chats[i].id], notice.at >= self.chats[i].ts {
                    self.chats[i].last = notice.text
                    self.chats[i].lastKind = "reaction"
                    self.chats[i].lastPreview = nil
                    self.chats[i].lastMine = false
                    self.chats[i].ts = notice.at
                }
            }
            // Unread chats from the last few days wait in the sidebar, as if they had just arrived.
            // Only people and small groups: big groups and Communities stay out of the sidebar.
            if seed {
                let ui = NotchUI.shared
                let byID = Dictionary(self.chats.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                // Tidy what is already there: crowds, and chats filed under an old anonymous id.
                for t in ui.slackRecent where t.workspace == Self.workspace {
                    let chat = byID[t.id]
                    if chat?.crowd == true || (chat == nil && t.id.hasSuffix("@lid")) { ui.dropSlack(t) }
                }
                for chat in self.chats where chat.unread > 0 && !chat.crowd && chat.ts > Date().addingTimeInterval(-3 * 86400) {
                    let t = chat.target
                    let key = "\(Self.workspace):\(chat.id)"
                    // Cleared by the user, with nothing new since: it stays cleared.
                    if let gone = ui.slackDismissed[key], chat.ts.timeIntervalSince1970 <= gone { continue }
                    if !ui.slackRecent.contains(where: { $0.workspace == t.workspace && $0.id == t.id }) { ui.slackRecent.insert(t, at: 0) }
                    ui.slackUnread[key] = chat.unread
                    ui.slackLastAt[key] = chat.ts.timeIntervalSince1970
                }
            }
            // The recent ones are read in for search.
            for (i, chat) in self.chats.prefix(40).enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.2) { [weak self] in self?.history(chat.target) }
            }
            for chat in self.chats.prefix(30) { self.avatar(chat.id) }
        }
    }

    private func loadContacts() {
        request("contacts") { [weak self] data in
            guard let rows = data as? [[String: Any]] else { return }
            self?.contacts = rows.compactMap { r in
                guard let id = r["jid"] as? String, let name = r["name"] as? String else { return nil }
                return (id, r["lid"] as? String ?? "", name)
            }.sorted { $0.name < $1.name }
        }
    }

    /// People and chats whose names match a search: a chat already going with them if there is
    /// one, otherwise a fresh conversation to start.
    func matching(_ query: String) -> [SlackTarget] {
        let terms = ThreadSearch.terms(query)
        guard !terms.isEmpty else { return [] }
        return matching { name in
            let words = ThreadSearch.terms(name)
            return terms.allSatisfy { t in words.contains { $0.hasPrefix(t) } }
        }
    }

    /// Chats and contacts whose name passes the test, one per person. Big groups are left out.
    func matching(where matches: (String) -> Bool) -> [SlackTarget] {
        var out: [SlackTarget] = []
        var seen = Set<String>()
        for chat in chats where !chat.crowd && matches(chat.name) && seen.insert(chat.id).inserted { out.append(chat.target) }
        for c in contacts where matches(c.name) {
            if let chat = chats.first(where: { $0.id == c.id || (!c.lid.isEmpty && $0.id == c.lid) }) {
                if seen.insert(chat.id).inserted { out.append(chat.target) }
            } else if seen.insert(c.id).inserted {
                out.append(SlackTarget(workspace: Self.workspace, id: c.id, name: c.name, channel: false, picture: avatars[c.id]))
            }
        }
        return out
    }

    /// `perch-wa status` and `perch-wa send`, over Perch's owner-only socket. A send goes out
    /// as typed, straight away, just as one sent from Perch's own chat would.
    func command(_ name: String, json: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        switch name {
        case "status":
            let ready = state == .ready
            reply(["ok": true, "connected": ready, "linked": linked, "state": "\(state)"])
        case "send":
            guard state == .ready else { return reply(["ok": false, "error": "WhatsApp is not connected in Perch"]) }
            guard let chat = json["chat"] as? String, !chat.isEmpty,
                  let text = json["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return reply(["ok": false, "error": "Needs a chat id and some text"])
            }
            let name = chats.first { $0.id == chat }?.name ?? ""
            let target = SlackTarget(workspace: Self.workspace, id: chat, name: name, channel: false)
            send(to: target, text: text, files: [], replyTo: json["replyTo"] as? String) { ok in
                reply(ok ? ["ok": true, "chat": chat, "name": name] : ["ok": false, "error": "WhatsApp did not accept the message"])
            }
        default:
            reply(["ok": false, "error": "Unknown command \(name)"])
        }
    }

    /// The profile picture for a chat or person, fetched when first wanted.
    func picture(for id: String) -> URL? {
        if avatars[id] == nil { avatar(id) }
        return avatars[id]
    }

    @ObservationIgnored private var asked = Set<String>()

    private func avatar(_ chat: String) {
        guard avatars[chat] == nil, state == .ready, asked.insert(chat).inserted else { return }
        request("avatar", ["chat": chat]) { [weak self] data in
            if let s = (data as? [String: Any])?["url"] as? String, let url = URL(string: s) { self?.avatars[chat] = url }
        }
    }

    // MARK: What the Slack screens ask for

    func history(_ target: SlackTarget) {
        let store = SlackConversations.shared
        let key = store.key(Self.workspace, target.id)
        request("history", ["chat": target.id, "limit": 80]) { [weak self] data in
            guard let self else { return }
            guard let rows = data as? [[String: Any]] else {
                if store.lines[key] == nil { store.lines[key] = [] }
                return
            }
            store.replace(key, with: rows.map { Self.line($0, chat: target.id) })
            // The sidebar's preview follows the newest message, including the user's own.
            if let newest = rows.last, let i = self.chats.firstIndex(where: { $0.id == target.id }) {
                if let notice = self.reactionNotices[target.id],
                   notice.at.timeIntervalSince1970 >= (newest["ts"] as? Double ?? 0) { return }
                self.chats[i].lastKind = newest["kind"] as? String ?? "text"
                self.chats[i].lastPreview = (newest["thumb"] as? String).flatMap { Data(base64Encoded: $0) }
                let text = (newest["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Self.label(newest["kind"] as? String)
                self.chats[i].last = text
                self.chats[i].lastMine = newest["fromMe"] as? Bool ?? false
                self.chats[i].lastTicks = max(1, newest["status"] as? Int ?? 1)
                if let ts = newest["ts"] as? Double { self.chats[i].ts = max(self.chats[i].ts, Date(timeIntervalSince1970: ts)) }
            }
        }
    }

    func send(to target: SlackTarget, text: String, files: [URL], replyTo: String? = nil, done: @escaping (Bool) -> Void) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func after(_ ok: Bool) {
            done(ok)
            if ok { history(target) }
        }
        guard !files.isEmpty else {
            var body: [String: Any] = ["chat": target.id, "text": message]
            if let replyTo { body["message"] = replyTo }
            return request("send", body) { after($0 != nil) }
        }
        // Each file goes as its own message; the text rides along with the first.
        var remaining = files
        func next(_ caption: String) {
            guard !remaining.isEmpty else { return after(true) }
            let file = remaining.removeFirst()
            request("sendFile", ["chat": target.id, "path": file.path, "text": caption]) { reply in
                guard reply != nil else { return after(false) }
                next("")
            }
        }
        next(message)
    }

    /// Reacts to a message with an emoji; the same emoji again takes it away.
    func react(chat: String, id: String, emoji: String) {
        let store = SlackConversations.shared
        let current = store.lines[store.key(Self.workspace, chat)]?.first { $0.id == id }?.reactions["me"]
        let choice = current == emoji ? "" : emoji
        var all = store.lines[store.key(Self.workspace, chat)]?.first { $0.id == id }?.reactions ?? [:]
        all["me"] = choice.isEmpty ? nil : choice
        setReactions(chat, id, all)
        request("react", ["chat": chat, "message": id, "text": choice]) { [weak self] reply in
            if reply == nil { self?.history(SlackTarget(workspace: Self.workspace, id: chat, name: "", channel: false)) }
        }
    }

    private func setReactions(_ chat: String, _ id: String, _ all: [String: String]) {
        let store = SlackConversations.shared
        let key = store.key(Self.workspace, chat)
        guard var lines = store.lines[key], let i = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[i].reactions = all
        store.lines[key] = lines
    }

    func markRead(_ chat: String) {
        request("markRead", ["chat": chat])
        if let i = chats.firstIndex(where: { $0.id == chat }) { chats[i].unread = 0 }
    }

    /// A picture or file from a message, downloaded on demand and kept.
    func fetch(_ url: URL, done: @escaping (Data?) -> Void) {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard url.scheme == "perch-wa", parts.count >= 2 else { return done(nil) }
        let chat = parts[0], id = parts[1]
        if let path = media["\(chat)/\(id)"], let data = FileManager.default.contents(atPath: path) { return done(data) }
        request("download", ["chat": chat, "message": id]) { [weak self] reply in
            guard let path = (reply as? [String: Any])?["path"] as? String else { return done(nil) }
            self?.media["\(chat)/\(id)"] = path
            done(FileManager.default.contents(atPath: path))
        }
    }

    /// Opens the WhatsApp app itself.
    func openApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}
