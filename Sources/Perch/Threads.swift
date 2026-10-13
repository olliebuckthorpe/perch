import Foundation

/// An email an agent has drafted for the user to check before it goes out.
struct EmailDraft: Equatable {
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

struct ChatMessage: Identifiable, Equatable {
    var id: String
    let fromUser: Bool
    let text: String
    var reactions: [String] = []
    var email: EmailDraft?
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
            }
        }
        return loaded
    }

    static let replyMarker = "Treat this as their next message:\n\n"

    static func load(_ agent: Agent) {
        switch agent.source {
        case .grok:
            GrokSource.shared.loadThread(agent)
        case .claude, .codex:
            guard let path = agent.transcriptPath else { return }
            let codex = agent.source == .codex
            queue.async {
                let messages = parse(path, codex: codex)
                DispatchQueue.main.async { [weak agent] in
                    guard let agent, !messages.isEmpty else { return }
                    let messages = keepingLocalIDs(messages, from: agent.thread)
                    // Keep anything just sent from the notch that the file has not caught up with.
                    let known = Set(messages.filter(\.fromUser).map(\.text))
                    let unsent = agent.thread.filter { $0.id.hasPrefix("local-") && !known.contains($0.text) }
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

    private static func parse(_ path: String, codex: Bool) -> [ChatMessage] {
        guard let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let span: UInt64 = 1 << 20
        try? h.seek(toOffset: size > span ? size - span : 0)
        guard let data = try? h.readToEnd() else { return [] }
        var out: [ChatMessage] = []
        for (i, line) in String(decoding: data, as: UTF8.self).split(separator: "\n").enumerated() {
            guard line.count < 400_000,
                  let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let id = o["uuid"] as? String ?? "line-\(i)"
            if let m = codex ? codexMessage(o) : claudeMessage(o, raw: line) {
                // One message can be logged twice; show it once.
                if m.user, out.suffix(4).contains(where: { $0.fromUser && $0.text == m.text }) { continue }
                out.append(ChatMessage(id: id, fromUser: m.user, text: m.text))
            }
        }
        return Array(out.suffix(40))
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
        if let s = message["content"] as? String {
            text = s
        } else if let blocks = message["content"] as? [[String: Any]] {
            text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                .joined(separator: "\n\n")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Skip the machinery: tool results, injected reminders, slash-command wrappers.
        guard !text.isEmpty, !text.hasPrefix("<"), !text.hasPrefix("[Request interrupted") else { return nil }
        return (type == "user", text)
    }

    private static func codexMessage(_ o: [String: Any]) -> (user: Bool, text: String)? {
        guard o["type"] as? String == "response_item", let p = o["payload"] as? [String: Any],
              p["type"] as? String == "message", let role = p["role"] as? String,
              role == "user" || role == "assistant", let blocks = p["content"] as? [[String: Any]] else { return nil }
        let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("<") else { return nil }
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
