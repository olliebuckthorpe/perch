import Foundation

/// An email an agent has drafted for the user to check before it goes out.
struct EmailDraft: Equatable {
    /// What kind of thing this is a draft of: "email", "Slack message", and so on.
    var noun = "email"
    var from = ""
    var to: [String] = []
    var cc: [String] = []
    var subject = ""
    var body = ""
    /// Grok Bot's own record of what happened to it: "sent", or nil while it is still a draft.
    var sendState: String?
    /// A later draft replaced this one before it was sent.
    var superseded = false
}

/// A question an agent put to the user as a set of options to pick from.
struct ChoiceWidget: Equatable {
    struct Option: Equatable {
        let label: String
        let value: String
        let detail: String
    }
    var prompt = ""
    var options: [Option] = []
}

/// A Grok bot asking permission before it does something (delete a calendar event, say).
/// A secure form a Grok bot sends, whose answers go straight into a website through Grok Bot
/// (a check-in page, a sign-in) and never through the chat.
struct GrokForm: Equatable {
    struct Field: Equatable {
        let id: String
        let label: String
        let type: String
        let required: Bool
        let secret: Bool
        let defaultValue: String
        let options: [(label: String, value: String)]
        static func == (a: Field, b: Field) -> Bool { a.id == b.id && a.label == b.label && a.type == b.type }
    }
    let title: String
    let instruction: String
    let domain: String
    let fields: [Field]
    /// How it ended: "fill_failed" and so on; nil while it waits for the user.
    let resolution: String?
    /// Fields that did not make it into the page.
    let missed: [String]
}

struct GrokApproval: Equatable {
    var requestId: String
    var tool: String
    var summary: String
    var reason: String
    var command: String
    /// "approved", "denied", "always", or nil while it is still waiting.
    var status: String?
}

struct ChatMessage: Identifiable, Equatable {
    var id: String
    let fromUser: Bool
    let text: String
    var reactions: [String] = []
    var email: EmailDraft?
    var choice: ChoiceWidget?
    var approval: GrokApproval?
    /// A bot asking for a secret (an API key, say): its label and what it is for.
    var secret: (label: String, detail: String, provided: Bool)?
    /// Pictures a bot attached to a message, as paths on its own computer.
    var boxImages: [String] = []
    /// The bot handing its computer over for a step it needs the user for (scanning a QR code,
    /// signing in): what to do, and how it ended ("handed_back" and so on), nil while waiting.
    var handoff: (instruction: String, resolution: String?)?
    var form: GrokForm?
    /// A bot asking for an app to be linked so one of its triggers can fire (Slack, say), and why.
    var listener: (platform: String, reason: String)?

    static func == (a: ChatMessage, b: ChatMessage) -> Bool {
        a.id == b.id && a.fromUser == b.fromUser && a.text == b.text && a.reactions == b.reactions && a.email == b.email
            && a.choice == b.choice && a.approval == b.approval && a.fileName == b.fileName && a.filePath == b.filePath
            && a.peerName == b.peerName && a.peerOutbound == b.peerOutbound && a.secret?.label == b.secret?.label && a.secret?.provided == b.secret?.provided
            && a.boxImages == b.boxImages && a.handoff?.instruction == b.handoff?.instruction && a.handoff?.resolution == b.handoff?.resolution
            && a.listener?.platform == b.listener?.platform && a.form == b.form
    }
    /// Set when this is one agent talking to another, not part of the conversation with the user.
    /// A file the agent attached: its name, and where it lives on the agent's own computer.
    var fileName: String?
    var filePath: String?
    var peerName: String?
    var peerOutbound = false
}

/// Loads the recent conversation for an agent, from wherever that kind of agent keeps it.
enum Threads {
    /// One at a time and low priority: reading transcripts should never compete with the interface.
    private static let queue = DispatchQueue(label: "perch.threads", qos: .utility)

    /// A message sent from the notch is shown at once, then the agent's own record of it arrives
    /// under a different id. Keeping the original id means the bubble stays where it is instead
    /// of being removed and re-added, which is what made sending look jumpy.
    static func keepingLocalIDs(_ loaded: [ChatMessage], from current: [ChatMessage]) -> [ChatMessage] {
        var loaded = loaded
        for local in current where local.id.hasPrefix("local-") {
            if let i = loaded.lastIndex(where: { $0.fromUser && $0.text == local.text && !$0.id.hasPrefix("local-") }) {
                loaded[i].id = local.id
                matched.insert(local.id)
            }
        }
        return loaded
    }

    /// Notch-sent messages that the agent's own record has since caught up with.
    private static var matched = Set<String>()

    /// Messages typed in the notch that the agent's record does not have yet. One that has
    /// been matched once is never counted again: without that, a message came back as "not
    /// sent yet" as soon as it scrolled out of the recent history, and was drawn again on
    /// every refresh.
    static func unsent(in current: [ChatMessage], loaded: [ChatMessage]) -> [ChatMessage] {
        let ids = Set(loaded.map(\.id))
        let texts = Set(loaded.filter(\.fromUser).map(\.text))
        var seen = Set<String>()
        return current.filter {
            $0.id.hasPrefix("local-") && !ids.contains($0.id) && !matched.contains($0.id)
                && !texts.contains($0.text) && seen.insert($0.id).inserted
        }
    }

    /// When each chat's transcript was last read, by the file's own modified time.
    private static var read: [String: Date] = [:]

    static let replyMarker = "Treat this as their next message:\n\n"

    /// Between messages that were held while the agent was busy and then delivered together,
    /// so the chat can still show them as the separate messages they were.
    static let queueSeparator = "\n\n(next message)\n\n"

    static func load(_ agent: Agent) {
        switch agent.source {
        case .grok:
            GrokSource.shared.loadThread(agent)
        case .claude, .codex:
            guard let path = agent.transcriptPath else { return }
            // Re-reading a transcript that has not changed since the last read is wasted work, and
            // it is what made flicking between chats feel heavy.
            let stamp = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            if let stamp, read[agent.id] == stamp, !agent.thread.isEmpty { return }
            read[agent.id] = stamp
            let codex = agent.source == .codex
            queue.async {
                let (messages, context) = parse(path, codex: codex)
                DispatchQueue.main.async { [weak agent] in
                    guard let agent, !messages.isEmpty else { return }
                    if let context {
                        if agent.contextUsed != context.used { agent.contextUsed = context.used }
                        agent.contextModel = context.model
                    }
                    let messages = keepingLocalIDs(messages, from: agent.thread)
                    // Keep anything just sent from the notch that the file has not caught up with.
                    let unsent = unsent(in: agent.thread, loaded: messages)
                    var thread = messages + unsent
                    // The transcript can trail the session by a moment, so make sure the answer
                    // the session just gave is there even if the file has not caught up.
                    let latest = agent.lastMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    if agent.status == .done, !latest.isEmpty,
                       !messages.suffix(4).contains(where: { !$0.fromUser && $0.text.prefix(80) == latest.prefix(80) }) {
                        thread.append(ChatMessage(id: "latest", fromUser: false, text: latest))
                    }
                    if thread != agent.thread { agent.thread = thread }
                }
            }
        }
    }

    private static func parse(_ path: String, codex: Bool) -> ([ChatMessage], (used: Int, model: String?)?) {
        guard let h = FileHandle(forReadingAtPath: path) else { return ([], nil) }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        // Codex writes generated pictures into its file in full, a few megabytes each, so read
        // further back for it or a single picture pushes the conversation out of reach.
        let span: UInt64 = codex ? 12 << 20 : 1 << 20
        try? h.seek(toOffset: size > span ? size - span : 0)
        guard let data = try? h.readToEnd() else { return ([], nil) }
        var out: [ChatMessage] = []
        var context: (used: Int, model: String?)?
        for (i, line) in String(decoding: data, as: UTF8.self).split(separator: "\n").enumerated() {
            // A picture Codex made: too big to read whole, so just find where it was saved.
            if codex, line.contains("image_gen.generation"), line.contains("item_completed"),
               let r = line.range(of: #""savedPath":"([^"]+)""#, options: .regularExpression) {
                let path = String(line[r].dropFirst(13).dropLast())
                out.append(ChatMessage(id: "img-\(path)", fromUser: false, text: "[Image attached, saved at \(path)]"))
                continue
            }
            guard line.count < 400_000,
                  let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let id = o["uuid"] as? String ?? "line-\(i)"
            // Each main-thread reply records what it was sent: that total is the context in use.
            if !codex, o["type"] as? String == "assistant", o["isSidechain"] as? Bool != true,
               let message = o["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] {
                let parts = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                let used = parts.compactMap { (usage[$0] as? NSNumber)?.intValue }.reduce(0, +)
                if used > 0 { context = (used, message["model"] as? String) }
            }
            if let m = codex ? codexMessage(o) : claudeMessage(o, raw: line) {
                // One message can be logged twice; show it once.
                if m.user, out.suffix(4).contains(where: { $0.fromUser && $0.text == m.text }) { continue }
                let pieces = m.user ? m.text.components(separatedBy: queueSeparator.trimmingCharacters(in: .newlines))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } : [m.text]
                for (n, piece) in pieces.enumerated() {
                    out.append(ChatMessage(id: pieces.count > 1 ? "\(id)-\(n)" : id, fromUser: m.user, text: piece))
                }
            }
        }
        return (Array(out.suffix(40)), context)
    }

    private static func claudeMessage(_ o: [String: Any], raw: Substring) -> (user: Bool, text: String)? {
        // A reply sent from the notch reaches the session as hook feedback, not a normal prompt.
        // The transcript records it several times over (queue bookkeeping, the delivery, the
        // agent's own commands quoting it), so only take it from where it is actually delivered.
        if raw.contains("replied from Perch") {
            let kind = o["type"] as? String
            let queued = kind == "attachment" && (o["attachment"] as? [String: Any])?["type"] as? String == "queued_command"
            guard kind == "user" || queued, let s = findString(o, containing: replyMarker),
                  let r = s.range(of: replyMarker) else { return nil }
            var text = String(s[r.upperBound...])
            for closing in ["</system-reminder>", "&lt;/system-reminder"] {
                if let end = text.range(of: closing) { text = String(text[..<end.lowerBound]) }
            }
            // Drop the note Perch adds to spell out a slash command, leaving what was typed.
            if let note = text.range(of: CodingSessions.skillNote) { text = String(text[..<note.lowerBound]) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (true, text)
        }
        guard let type = o["type"] as? String, type == "user" || type == "assistant",
              o["isSidechain"] as? Bool != true, o["isMeta"] as? Bool != true,
              let message = o["message"] as? [String: Any] else { return nil }
        var text = ""
        var files: [String] = []
        if let s = message["content"] as? String {
            text = s
        } else if let blocks = message["content"] as? [[String: Any]] {
            text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                .joined(separator: "\n\n")
            for block in blocks {
                // Pictures pasted into the chat.
                if type == "user", block["type"] as? String == "image",
                   let source = block["source"] as? [String: Any], let data = source["data"] as? String,
                   let saved = savedPicture(data, kind: source["media_type"] as? String) {
                    files.append(saved)
                }
                // Files Claude handed over, and ones it wrote somewhere the user keeps things.
                if type == "assistant", block["type"] as? String == "tool_use", let input = block["input"] as? [String: Any] {
                    switch block["name"] as? String {
                    case "SendUserFile":
                        let list = input["files"] as? [String] ?? (input["files"] as? String).map { [$0] } ?? []
                        files += list.filter { FileManager.default.fileExists(atPath: $0) }
                    case "Write":
                        if let path = input["file_path"] as? String, isKept(path), FileManager.default.fileExists(atPath: path) {
                            files.append(path)
                        }
                    default: break
                    }
                }
            }
        }
        // Files attached in the Claude app arrive as @"path" in the message.
        if type == "user" {
            for match in text.matches(of: #/@"([^"]+)"|@(/[^\s]+)/#).reversed() {
                let path = String(match.1 ?? match.2 ?? "")
                guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { continue }
                files.insert(path, at: 0)
                text.replaceSubrange(match.range, with: "")
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Skip the machinery: tool results, injected reminders, slash-command wrappers.
        if text.hasPrefix("<") || text.hasPrefix("[Request interrupted") { text = "" }
        let notes = Array(NSOrderedSet(array: files)).compactMap { $0 as? String }.map { path in
            let image = ["png", "jpg", "jpeg", "gif", "heic", "webp"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
            return "[\(image ? "Image" : "File") attached, saved at \(path)]"
        }
        let full = ([text] + notes).filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !full.isEmpty else { return nil }
        return (type == "user", full)
    }

    /// Somewhere the user keeps their own files, as opposed to a project's code or a scratch folder.
    private static func isKept(_ path: String) -> Bool {
        let home = Shell.home
        return ["\(home)/Downloads/", "\(home)/Desktop/", "\(home)/Documents/", "\(home)/Dev/reports/"].contains { path.hasPrefix($0) }
    }

    /// A picture pasted into a Claude chat, kept as a file so it can be shown and saved.
    private static func savedPicture(_ base64: String, kind: String?) -> String? {
        let dir = "\(Shell.home)/.perch/cache/pictures"
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in base64.utf8.prefix(4096) { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        let ext = kind == "image/jpeg" ? "jpg" : kind == "image/gif" ? "gif" : kind == "image/webp" ? "webp" : "png"
        let path = "\(dir)/pasted-\(String(hash, radix: 16))-\(base64.count).\(ext)"
        if FileManager.default.fileExists(atPath: path) { return path }
        guard let data = Data(base64Encoded: base64) else { return nil }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) ? path : nil
    }

    private static func codexMessage(_ o: [String: Any]) -> (user: Bool, text: String)? {
        guard o["type"] as? String == "response_item", let p = o["payload"] as? [String: Any] else { return nil }
        if let batch = CodexQuestionBatch.from(p) { return (false, batch.summary) }
        guard p["type"] as? String == "message", let role = p["role"] as? String,
              role == "user" || role == "assistant", let blocks = p["content"] as? [[String: Any]] else { return nil }
        // Pictures the user attached arrive as `<image ... path="...">` markers among the text.
        var words: [String] = [], pictures: [String] = []
        for case let t as String in blocks.map({ $0["text"] }) {
            if let answer = CodexQuestionTracker.readableAnswer(t) {
                words.append(answer)
            } else if t.hasPrefix("<image"), let r = t.range(of: #"path="([^"]+)""#, options: .regularExpression) {
                pictures.append("[Image attached, saved at \(t[r].dropFirst(6).dropLast())]")
            } else if !t.hasPrefix("<"), !t.hasPrefix("\n# Files mentioned") {
                words.append(t)
            }
        }
        let text = (words + pictures).joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return (role == "user", text)
    }

    private static func findString(_ value: Any, containing needle: String) -> String? {
        if let s = value as? String { return s.contains(needle) ? s : nil }
        if let d = value as? [String: Any] {
            for v in d.values { if let s = findString(v, containing: needle) { return s } }
        }
        if let a = value as? [Any] {
            for v in a { if let s = findString(v, containing: needle) { return s } }
        }
        return nil
    }
}
