import AppKit
import SwiftUI
import Observation

enum AgentSource: String {
    case grok, claude, codex

    var label: String {
        switch self {
        case .grok: return "Grok"
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

/// Ordered by how loudly the notch should show it.
enum AgentStatus: Int, Comparable {
    case idle, done, unread, working, needsYou

    static func < (a: AgentStatus, b: AgentStatus) -> Bool { a.rawValue < b.rawValue }
}

struct Question: Identifiable {
    let id = UUID()
    let text: String
    let header: String
    let options: [String]
    let multiSelect: Bool
}

enum PendingKind {
    case permission(tool: String, detail: String)
    case question(questions: [Question], rawInput: [String: Any])
    case followUp
}

/// A hook that is being held open until the user answers it in the notch.
final class PendingRequest: Identifiable {
    let id = UUID()
    let kind: PendingKind
    let createdAt = Date()
    var deadline: Date
    /// The tool a permission request is about, as the agent names it.
    var toolName: String?
    private var respond: ((Data) -> Void)?

    init(kind: PendingKind, deadline: Date, respond: @escaping (Data) -> Void) {
        self.kind = kind
        self.deadline = deadline
        self.respond = respond
    }

    /// One shot. An empty body means "no decision", so the agent's own UI takes over.
    func finish(_ json: [String: Any]? = nil) {
        let data = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        respond?(data)
        respond = nil
    }
}

@Observable
final class Agent: Identifiable {
    let id: String
    let source: AgentSource
    let sessionID: String
    var name: String
    var detail = ""
    var lastMessage = ""
    /// What a working Grok bot is doing, in Grok Bot's own words ("Clicking around").
    var activity: String?
    var status: AgentStatus = .idle
    var unread = 0
    /// How much of the context window the session's last turn used, and the model it ran on.
    var contextUsed: Int?
    var contextModel: String?
    /// The user has had this chat open since it last finished, so it stops asking for attention.
    var seen = false
    var lastActivity = Date()
    var cwd: String?
    var hostBundleID: String?
    var colorIndex = 0
    /// Grok Bot's own avatar colour id ("violet", "brown", ...), when the agent has one.
    var avatarColor: String?
    /// Grok Bot's avatar shape ("hex", "cloud"...), saved or worked out the way Grok Bot does.
    var avatarShape: String?
    var codexQuestion: CodexQuestionBatch?
    var codexQuestionError: String?
    var handledCodexQuestions = Set<String>()
    var codexWorking = false
    var codexQueue: [CodexQueuedMessage] = []
    var codexQueueError: String?
    var pending: PendingRequest?
    /// A background hook parked in an idle Claude Code session. Answering it wakes the session.
    var waiter: HookRequest?
    /// Replies sent while there was no way in. Delivered at the next opening.
    var queued: [String] = []
    /// Started from the notch and run in the background, not open in any app.
    var background = false
    /// Handed over to the Claude desktop app, so it shows in its sidebar too.
    var adopted = false
    /// Being set up to run inside the Claude desktop app, not as a background run.
    var desktopBound = false
    /// Added or started by the user on purpose. Stays in the sidebar across restarts until dismissed.
    var kept = false
    /// When a turn last started or finished: real activity, as opposed to background housekeeping.
    var lastTurnAt: Date?
    /// A permission question that is being shown in the agent's own app, not held here.
    var askElsewhere: String?
    /// Recent conversation, loaded when the agent's chat is opened.
    var thread: [ChatMessage] = []
    var transcriptPath: String?
    /// Bumped (at most every couple of seconds) as the agent works, so an open chat keeps up mid-turn.
    var tick = 0
    @ObservationIgnored var lastTick = Date.distantPast

    @discardableResult
    func addLocal(_ text: String) -> String {
        let id = "local-\(UUID().uuidString)"
        // Rises into place from the reply box, on the same spring as the chat scrolling to it.
        withAnimation(.sendSpring) {
            thread.append(ChatMessage(id: id, fromUser: true, text: text))
        }
        return id
    }

    /// Notch messages that did not get through, by their local id, with what to resend.
    var unsent: [String: () -> Void] = [:]
    /// Failed Codex deliveries survive restart and require an explicit retry.
    var failedReplies: [String: String] = [:]
    var ended = false
    var sending = false

    init(source: AgentSource, sessionID: String, name: String) {
        self.id = "\(source.rawValue):\(sessionID)"
        self.source = source
        self.sessionID = sessionID
        self.name = name
    }
}

@Observable
final class AgentStore {
    static let shared = AgentStore()

    var agents: [Agent] = []
    var grokError: String?
    /// Bumped whenever something newly wants the user, so the notch can react.
    var attention = 0
    var attentionAgentID: String?

    private var nextColor = 0
    @ObservationIgnored private var lastPing: [String: Date] = [:]

    var grokBots: [Agent] { agents.filter { $0.source == .grok } }

    var sessions: [Agent] {
        agents.filter { $0.source != .grok }.sorted {
            $0.status != $1.status ? $0.status > $1.status : $0.lastActivity > $1.lastActivity
        }
    }

    var needing: [Agent] {
        agents.filter { $0.pending != nil }.sorted { $0.pending!.createdAt < $1.pending!.createdAt }
    }

    func find(_ id: String) -> Agent? { agents.first { $0.id == id } }

    // MARK: Remembering chats across restarts

    private static let file = "\(Shell.home)/.perch/sessions.json"
    @ObservationIgnored private var lastSaved = ""

    /// Writes the coding sessions to disk if anything about them has changed.
    func save() {
        let rows: [[String: Any]] = agents.filter { $0.source != .grok }.map { a in
            var row: [String: Any] = [
                "source": a.source.rawValue, "id": a.sessionID, "name": a.name, "kept": a.kept,
                "background": a.background, "adopted": a.adopted, "at": a.lastActivity.timeIntervalSince1970,
            ]
            row["cwd"] = a.cwd
            row["transcript"] = a.transcriptPath
            row["host"] = a.hostBundleID
            if !a.queued.isEmpty { row["queued"] = a.queued }
            if !a.failedReplies.isEmpty { row["failedReplies"] = a.failedReplies }
            return row
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8), text != lastSaved else { return }
        lastSaved = text
        try? data.write(to: URL(fileURLWithPath: Self.file), options: .atomic)
    }

    /// Brings back the chats from the last run. Kept ones always; others only if still recent.
    func restore() {
        guard let data = FileManager.default.contents(atPath: Self.file),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        let now = Date()
        for row in rows {
            guard let raw = row["source"] as? String, let source = AgentSource(rawValue: raw),
                  let id = row["id"] as? String, let name = row["name"] as? String else { continue }
            let at = Date(timeIntervalSince1970: row["at"] as? Double ?? 0)
            let kept = row["kept"] as? Bool ?? false
            guard kept || NotchUI.shared.isDrafting("\(source.rawValue):\(id)") || !(row["failedReplies"] as? [String: String] ?? [:]).isEmpty || now.timeIntervalSince(at) < Self.keepFor else { continue }
            let a = upsert(source: source, sessionID: id, name: name)
            a.name = name
            a.kept = kept
            a.background = row["background"] as? Bool ?? false
            a.adopted = row["adopted"] as? Bool ?? false
            a.cwd = row["cwd"] as? String
            a.transcriptPath = row["transcript"] as? String
            a.hostBundleID = row["host"] as? String
            a.queued = row["queued"] as? [String] ?? []
            a.failedReplies = row["failedReplies"] as? [String: String] ?? [:]
            for (id, text) in a.failedReplies {
                a.thread.append(ChatMessage(id: id, fromUser: true, text: text))
            }
            a.lastActivity = at
        }
    }

    func upsert(source: AgentSource, sessionID: String, name: @autoclosure () -> String) -> Agent {
        if let a = find("\(source.rawValue):\(sessionID)") { return a }
        let a = Agent(source: source, sessionID: sessionID, name: name())
        a.colorIndex = nextColor
        nextColor += 1
        agents.append(a)
        return a
    }

    func remove(_ agent: Agent) {
        agent.pending?.finish()
        agents.removeAll { $0.id == agent.id }
    }

    func ping(_ agent: Agent, sound: Bool = true) {
        // Two sources can report the same moment (a Codex hook and its rollout file).
        let now = Date()
        if let last = lastPing[agent.id], now.timeIntervalSince(last) < 3, agent.pending == nil { return }
        lastPing[agent.id] = now
        agent.seen = false
        attentionAgentID = agent.id
        attention += 1
        if sound && Settings.sounds { Settings.playSound() }
    }

    /// Coding sessions go quiet without telling anyone. Drop the stale ones.
    /// How long a quiet chat stays in the notch.
    static let keepFor: TimeInterval = 4 * 86400

    func prune() {
        let now = Date()
        for a in agents where a.source != .grok && a.pending == nil && !a.kept && !NotchUI.shared.isDrafting(a.id) && !NotchUI.shared.pinnedChats.contains(a.id) {
            let age = now.timeIntervalSince(a.lastActivity)
            // A session that died mid-turn never says so.
            if a.status == .working, age > 30 * 60 { a.status = .idle }
            // Chats stay until they have been quiet for a few days (overnight is not long enough;
            // they used to vanish after three hours). Clear one sooner with its cross.
            if age > Self.keepFor || (a.ended && age > 2 * 86400) { remove(a) }
        }
    }
}

enum Settings {
    private static let d = UserDefaults.standard

    static var sounds: Bool {
        get { d.object(forKey: "sounds") as? Bool ?? true }
        set { d.set(newValue, forKey: "sounds") }
    }

    /// Which system sound a notification makes. The quieter, softer ones come first.
    static let soundChoices = ["Tink", "Purr", "Bottle", "Glass", "Ping", "Pop", "Submarine"]

    static var soundName: String {
        get { d.string(forKey: "soundName") ?? "Tink" }
        set { d.set(newValue, forKey: "soundName") }
    }

    /// Played at half volume: it is a nudge, not an alarm.
    /// The feel of a message going: a light tap on the trackpad, and a soft sound when
    /// sounds are on. The same everywhere a message is sent from.
    static func sentFeel() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        guard sounds, let sound = NSSound(named: "Pop")?.copy() as? NSSound else { return }
        sound.volume = 0.18
        sound.play()
    }

    static func playSound() {
        guard let sound = NSSound(named: soundName)?.copy() as? NSSound else { return }
        sound.volume = 0.5
        sound.play()
    }

    /// How long a finished session waits for a follow-up typed in the notch. 0 turns it off.
    static var replyWindow: Int {
        get { d.object(forKey: "replyWindow") as? Int ?? 60 }
        set { d.set(newValue, forKey: "replyWindow") }
    }
}

func oneLine(_ s: String, max: Int = 160) -> String {
    let flat = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    let t = flat.trimmingCharacters(in: .whitespaces)
    return t.count > max ? String(t.prefix(max)) + "…" : t
}
