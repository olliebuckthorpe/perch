import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A one-line "Done … · Now …" summary of where a chat's work has got to, written by Apple's
/// on-device model (macOS 26 and later): free, private, a second or two. Only for the chat on
/// screen, and only when something new has been said. Without the model, nothing is written and
/// the status line falls back to the step list or the latest update.
@MainActor
final class ProgressSummary {
    static let shared = ProgressSummary()

    /// The summary for each chat, and the message it was written up to.
    private(set) var lines: [String: (upTo: String, text: String)] = [:]
    private var running: Task<Void, Never>?

    static let instructions = """
        Summarise where a piece of work has got to, from the recent messages between a user and the agent \
        doing it. Write exactly: Done: <the main things completed, specific> · Now: <what the agent is doing \
        or waiting on right now>. Name the real things (files, features, steps), never say "the user" or \
        "the agent". Under 25 words.
        """

    /// Writes a fresh summary for `agent` if its latest message has moved on since the last one.
    func refresh(_ agent: Agent, messages: [ChatMessage]) {
        guard let last = messages.last?.id, lines[agent.id]?.upTo != last else { return }
        let excerpt = Self.excerpt(agent, messages)
        guard !excerpt.isEmpty else { return }
        running?.cancel()
        running = Task { [weak self] in
            // A burst of updates settles first, so one summary is written for it, not five.
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let text = await Self.write(excerpt), !Task.isCancelled else { return }
            self?.lines[agent.id] = (last, text)
            agent.progress = text
        }
    }

    /// The last stretch of the chat as plain lines, with the step list on top when there is one.
    private static func excerpt(_ agent: Agent, _ messages: [ChatMessage]) -> String {
        var out: [String] = []
        if !agent.steps.isEmpty {
            out.append("Steps: " + agent.steps.map { "[\($0.status == "completed" ? "done" : $0.status == "in_progress" ? "doing" : "todo")] \($0.subject)" }
                .joined(separator: "; "))
        }
        for m in messages.suffix(14) where !m.text.isEmpty {
            var t = m.text
            if let r = t.range(of: Threads.replyMarker) { t = String(t[r.upperBound...]) }
            t = RelayKey.unsigned(t)
            t = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !t.isEmpty else { continue }
            out.append((m.fromUser ? "User: " : "Agent: ") + String(t.prefix(400)))
        }
        return String(out.joined(separator: "\n").suffix(3500))
    }

    private static func write(_ excerpt: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            let session = LanguageModelSession(instructions: instructions)
            guard let reply = try? await session.respond(to: "Recent messages:\n\(excerpt)\n\nProgress note:") else { return nil }
            let text = reply.content.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " · ")
                .replacingOccurrences(of: ". · ", with: " · ")
            return text.isEmpty ? nil : String(text.prefix(220))
        }
        #endif
        return nil
    }
}
