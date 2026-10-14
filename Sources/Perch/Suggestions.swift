import Foundation
import Observation

/// A guess at what the user will say next, shown faintly in the reply box (Tab takes it), the
/// way Claude Code suggests the next prompt. Made only for the chat that is open, once per
/// new message from the agent, with the smallest model and a stripped-down request.
@Observable
final class Suggestions {
    static let shared = Suggestions()

    /// Agent id to (the message it answers, the suggestion).
    private(set) var made: [String: (after: String, text: String)] = [:]
    @ObservationIgnored private var asked = Set<String>()

    func text(for agent: Agent) -> String? {
        guard let last = agent.thread.last, !last.fromUser, let s = made[agent.id], s.after == last.id else { return nil }
        return s.text
    }

    func want(_ agent: Agent) {
        guard let last = agent.thread.last, !last.fromUser, last.id != "latest" || agent.thread.count == 1,
              !asked.contains(last.id), let exe = Shell.find("claude") else { return }
        asked.insert(last.id)
        let mine = agent.thread.last(where: \.fromUser)?.text ?? ""
        let ask = """
        Below is the end of a chat between a user and their AI assistant. Write the user's most likely next \
        message: short (under 12 words), casual, in their voice, British spelling. Reply with that message only. \
        If nothing obviously needs saying next, reply with the single word NONE.

        User said: \(String(mine.suffix(600)))

        Assistant replied: \(String(last.text.suffix(1500)))
        """
        let args = ["-p", ask, "--model", "haiku", "--system-prompt", "You predict the user's next chat message.",
                    "--tools", "", "--strict-mcp-config", "--disable-slash-commands"]
        let id = agent.id, after = last.id
        Shell.run(exe, args, cwd: "\(Shell.home)/.perch", env: ["PERCH_SKIP": "1"]) { [weak self] code, out in
            let text = oneLine(out.trimmingCharacters(in: .whitespacesAndNewlines), max: 90)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“” "))
            guard code == 0, !text.isEmpty, text.uppercased() != "NONE" else { return }
            self?.made[id] = (after, text)
        }
    }
}
