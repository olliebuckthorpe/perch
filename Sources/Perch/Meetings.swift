import AppKit
import EventKit
import Observation

/// A calendar event about to start, with the link to join it.
struct Meeting: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let link: URL
    /// "Google Meet", "Zoom" and so on, for the button.
    let service: String
}

/// Two minutes before a meeting with a video link, the notch drops down with a button to join it
/// and start Granola's notes. Reads the Mac's own calendars (System Settings > Internet Accounts,
/// where Google accounts can be added), so nothing is stored by Perch.
@Observable
final class MeetingWatch {
    static let shared = MeetingWatch()

    /// Calendar access: nil until asked, then whether it was granted.
    private(set) var allowed: Bool?
    /// Calendars the Mac knows about, to tell "no access" from "no calendars added".
    private(set) var calendarCount = 0
    /// What macOS said when asked, for diagnosing.
    @ObservationIgnored private(set) var why = ""

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var timer: Timer?
    /// Meetings already announced, so each pops up once.
    @ObservationIgnored private var announced = Set<String>()

    func start() {
        store.requestFullAccessToEvents { [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.allowed = granted
                self.why = "status \(EKEventStore.authorizationStatus(for: .event).rawValue)" + (error.map { ", \($0.localizedDescription)" } ?? "")
                guard granted else { return }
                self.calendarCount = self.store.calendars(for: .event).count
                NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: self.store, queue: .main) { [weak self] _ in
                    self?.calendarCount = self?.store.calendars(for: .event).count ?? 0
                    self?.check()
                }
                self.timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.check() }
                self.timer?.tolerance = 5
                self.check()
            }
        }
    }

    /// Today's meetings from now on, for a glance at the day.
    func today() -> [Meeting] {
        guard allowed == true else { return [] }
        let now = Date()
        let end = Calendar.current.startOfDay(for: now).addingTimeInterval(86400)
        return events(from: now.addingTimeInterval(-3600), to: end).filter { $0.end > now }
    }

    private func check() {
        let now = Date()
        // Starting within two minutes, or started less than a minute ago (the Mac was asleep).
        for meeting in events(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(125))
        where meeting.start <= now.addingTimeInterval(125) && meeting.start >= now.addingTimeInterval(-60) {
            let key = "\(meeting.id)@\(Int(meeting.start.timeIntervalSince1970))"
            guard announced.insert(key).inserted else { continue }
            NotchUI.shared.meeting(meeting)
        }
    }

    private func events(from: Date, to: Date) -> [Meeting] {
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate).compactMap { e -> Meeting? in
            guard !e.isAllDay, e.status != .canceled else { return nil }
            // Meetings the user has declined do not count.
            if let me = e.attendees?.first(where: \.isCurrentUser), me.participantStatus == .declined { return nil }
            guard let (link, service) = Self.joinLink(e) else { return nil }
            return Meeting(id: e.calendarItemIdentifier, title: e.title ?? "Meeting", start: e.startDate, end: e.endDate,
                           link: link, service: service)
        }
        .sorted { $0.start < $1.start }
    }

    /// The video link in an event: its URL, location or notes.
    static func joinLink(_ e: EKEvent) -> (URL, String)? {
        let text = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: " ")
        let services: [(String, String)] = [
            (#"https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}"#, "Google Meet"),
            (#"https://[\w.-]*zoom\.us/(j|my|w)/[^\s"<>]+"#, "Zoom"),
            (#"https://teams\.(microsoft|live)\.com/[^\s"<>]+"#, "Teams"),
            (#"https://[\w.-]*whereby\.com/[^\s"<>]+"#, "Whereby"),
            (#"https://app\.slack\.com/huddle/[^\s"<>]+"#, "Slack huddle"),
        ]
        for (pattern, name) in services {
            if let r = text.range(of: pattern, options: .regularExpression), let url = URL(string: String(text[r])) {
                return (url, name)
            }
        }
        return nil
    }

    /// Joins: the meeting link, and a Granola note that starts transcribing straight away.
    static func join(_ meeting: Meeting, granola: Bool) {
        NSWorkspace.shared.open(meeting.link)
        if granola, let notes = URL(string: "granola://new-document?auto_transcribe=true") {
            NSWorkspace.shared.open(notes)
        }
    }
}
