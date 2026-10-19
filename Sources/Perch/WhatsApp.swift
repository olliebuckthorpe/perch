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

    @ObservationIgnored private var helper: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var waiting: [Int: (Any?) -> Void] = [:]
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private var media: [String: String] = [:]
    @ObservationIgnored private var wanted = false
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
        case "loggedOut":
            state = .loggedOut
            linked = false
            chats = []
        case "synced":
            loadChats(seed: false)
        case "read":
            if let chat = o["chat"] as? String {
                NotchUI.shared.slackUnread["\(Self.workspace):\(chat)"] = nil
                if let i = chats.firstIndex(where: { $0.id == chat }) { chats[i].unread = 0 }
            }
        case "message":
            arrived(o)
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
        guard let chat = o["chat"] as? String else { return }
        let line = Self.line(o, chat: chat)
        let store = SlackConversations.shared
        let key = store.key(Self.workspace, chat)
        if store.lines[key] != nil, store.lines[key]?.contains(where: { $0.id == line.id }) != true {
            store.lines[key]?.append(line)
        }
        let group = o["group"] as? Bool ?? false
        let name = o["chatName"] as? String ?? "WhatsApp"
        if let i = chats.firstIndex(where: { $0.id == chat }) {
            chats[i].ts = Date()
            chats[i].last = line.text
            chats[i].name = name
        } else {
            chats.insert(WhatsAppChat(id: chat, name: name, group: group, ts: Date(), unread: 0, last: line.text), at: 0)
        }
        guard o["fromMe"] as? Bool != true else { return }
        // Reading it right now in the notch: it is read on the phone too.
        let ui = NotchUI.shared
        if ui.expanded, !ui.cardsOnly, ui.slackTarget?.workspace == Self.workspace, ui.slackTarget?.id == chat {
            markRead(chat)
            return
        }
        let sender = o["senderName"] as? String ?? name
        var alert = SlackAlert(id: "wa-\(o["id"] as? String ?? UUID().uuidString)", workspace: Self.workspace, priority: 1,
                               team: "", channel: chat, place: group ? name : "WhatsApp",
                               sender: group ? sender : name, text: line.text.isEmpty ? Self.label(o["kind"] as? String) : line.text,
                               ts: o["id"] as? String ?? "")
        alert.direct = !group
        alert.senderID = chat
        alert.picture = avatars[chat]
        avatar(chat)
        // Direct chats and small groups notify like they do on the phone. Big groups and
        // Communities only when someone @s the user or replies to them; the rest wait, unread.
        let size = o["groupSize"] as? Int ?? 0
        let crowd = o["community"] as? Bool == true || size > Self.smallGroup
        if !group || !crowd || o["mentionsMe"] as? Bool == true {
            NotchUI.shared.slack(alert)
        } else {
            NotchUI.shared.noteSlack(alert)
        }
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
            files.append(SlackFile(id: id, workspace: workspace, name: name, image: kind == "image" || kind == "sticker",
                                   thumb: url, url: url, link: nil,
                                   kind: ext.isEmpty ? (label(kind)) : ext, size: 0))
        }
        return SlackLine(id: id, sender: mine ? "You" : (m["senderName"] as? String ?? ""), mine: mine,
                         text: m["text"] as? String ?? "", picture: nil, files: files)
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
                                    unread: r["unread"] as? Int ?? 0, last: last)
            }
            // Unread chats from the last few days wait in the sidebar, as if they had just arrived.
            if seed {
                let ui = NotchUI.shared
                for chat in self.chats where chat.unread > 0 && chat.ts > Date().addingTimeInterval(-3 * 86400) {
                    let t = chat.target
                    let key = "\(Self.workspace):\(chat.id)"
                    if !ui.slackRecent.contains(where: { $0.workspace == t.workspace && $0.id == t.id }) { ui.slackRecent.insert(t, at: 0) }
                    ui.slackUnread[key] = chat.unread
                }
            }
            // The recent ones are read in for search.
            for (i, chat) in self.chats.prefix(40).enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.2) { [weak self] in self?.history(chat.target) }
            }
            for chat in self.chats.prefix(30) { self.avatar(chat.id) }
        }
    }

    private func avatar(_ chat: String) {
        guard avatars[chat] == nil else { return }
        request("avatar", ["chat": chat]) { [weak self] data in
            if let s = (data as? [String: Any])?["url"] as? String, let url = URL(string: s) { self?.avatars[chat] = url }
        }
    }

    // MARK: What the Slack screens ask for

    func history(_ target: SlackTarget) {
        let store = SlackConversations.shared
        let key = store.key(Self.workspace, target.id)
        request("history", ["chat": target.id, "limit": 80]) { data in
            guard let rows = data as? [[String: Any]] else {
                if store.lines[key] == nil { store.lines[key] = [] }
                return
            }
            store.lines[key] = rows.map { Self.line($0, chat: target.id) }
        }
    }

    func send(to target: SlackTarget, text: String, files: [URL], done: @escaping (Bool) -> Void) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func after(_ ok: Bool) {
            done(ok)
            if ok { history(target) }
        }
        guard !files.isEmpty else {
            return request("send", ["chat": target.id, "text": message]) { after($0 != nil) }
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
