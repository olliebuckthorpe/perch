import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id: String
    let fromUser: Bool
    let text: String
}

/// Loads the recent conversation for an agent, from wherever that kind of agent keeps it.
enum Threads {
    static let replyMarker = "Treat this as their next message:\n\n"

    static func load(_ agent: Agent) {
        switch agent.source {
        case .grok:
            GrokSource.shared.loadThread(agent)
        case .claude, .codex:
            guard let path = agent.transcriptPath else { return }
            let codex = agent.source == .codex
            DispatchQueue.global(qos: .userInitiated).async {
                let messages = parse(path, codex: codex)
                DispatchQueue.main.async { [weak agent] in
                    guard let agent, !messages.isEmpty else { return }
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
                    agent.thread = thread
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
                out.append(ChatMessage(id: id, fromUser: m.user, text: m.text))
            }
        }
        return Array(out.suffix(40))
    }

    private static func claudeMessage(_ o: [String: Any], raw: Substring) -> (user: Bool, text: String)? {
        // A reply sent from the notch reaches the session as hook feedback, not a normal prompt.
        if raw.contains("replied from Perch"), let s = findString(o, containing: replyMarker),
           let r = s.range(of: replyMarker) {
            return (true, String(s[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
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
