import Foundation
import Observation

// The calendar tab's data. Everything goes through `UpshowCalendarService`, so the screens do not
// care where it comes from. Until sign-in exists, `SampleCalendar` stands in and the tab says so.
//
// To connect the real thing, set `UpshowAccess.signIn` to something that provides a connection.
// If its token only works on Upshow's /mcp route rather than /api, write a second service that
// calls those tools and return it from `UpshowAccess.service`. Nothing else has to change.

struct UpshowMeeting: Identifiable, Equatable, Codable {
    let id: String
    var title: String
    var guest: String
    var guestEmail: String
    var company: String
    var start: Date
    var end: Date
    var link: URL?
    /// The sequence (meeting type) running on it, if any.
    var sequenceID: String?
    /// confirmed, rescheduled, completed, no_show and so on.
    var status: String?
    var remindersOff: Bool?
    var sequencePaused: Bool?
    var guestReplied: Bool?
    var wonBack: Bool?
    /// manual, cal_com, calendly, google, outlook: where the booking itself lives.
    var platform: String?
    var guestTimeZone: String?

    /// Upshow is sending this meeting's reminders: what the chevron on its block says.
    var protected: Bool {
        ["confirmed", "rescheduled"].contains(status ?? "confirmed") && remindersOff != true
            && sequencePaused != true && guestReplied != true
    }
}

/// Time taken on a connected calendar by something that is not an Upshow meeting.
struct UpshowBusy: Identifiable, Equatable, Codable {
    let id: String
    let start: Date
    let end: Date
    let allDay: Bool
}

struct UpshowCalendarSource: Identifiable, Equatable, Codable {
    let id: String
    let calendarID: String
    let name: String
    let primary: Bool
}

struct UpshowMeetingType: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    var isDefault = false
    var defaultMinutes: Int?
}

enum UpshowPlace: String, CaseIterable, Identifiable {
    case meet, teams, zoom, phone
    case inPerson = "in_person"
    case custom

    var id: String { rawValue }
    var label: String {
        switch self {
        case .meet: return "Google Meet"
        case .teams: return "Microsoft Teams"
        case .zoom: return "Zoom"
        case .phone: return "Phone"
        case .inPerson: return "In person"
        case .custom: return "Custom link"
        }
    }
}

/// Someone on a booking. A guest needs an email or a phone number to be reachable.
struct UpshowGuest: Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var email = ""
    var phone = ""
    var company = ""

    var reachable: Bool { email.contains("@") || phone.filter(\.isNumber).count >= 7 }
    var initials: String {
        let words = (name.isEmpty ? email : name).split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" })
        return words.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
    }
    var label: String { name.isEmpty ? email : name }
}

/// One new meeting, as the ticket in the booking panel fills it in. Upshow spots a repeat of
/// exactly the same booking, so sending it twice after a timeout never books anyone twice.
struct UpshowBooking: Equatable {
    var title = ""
    var guests: [UpshowGuest] = []
    /// The day, and whether a time has been chosen on it yet.
    var start: Date?
    var hasTime = false
    var minutes = 30
    /// nil until chosen; `.none` is "No reminders".
    var sequence: String??
    var place: UpshowPlace?
    var placeDetail = ""

    var end: Date? { start.map { $0.addingTimeInterval(Double(minutes) * 60) } }

    /// Why it cannot be booked yet, in the words the button shows.
    var blocker: String? {
        if guests.isEmpty { return "Add who it's with" }
        if !guests.contains(where: \.reachable) { return "Add an email or phone number" }
        guard let start, hasTime else { return "Pick a time" }
        if start <= Date() { return "That time has already passed. Pick a time from now on." }
        return nil
    }
}

/// What Upshow's language model read out of a sentence like "call Sam tomorrow 3pm".
struct UpshowParsed {
    var title: String?
    var guests: [UpshowGuest] = []
    var sequenceID: String?
    var noReminders = false
    var start: Date?
    var hasTime = false
    var minutes: Int?
    var place: UpshowPlace?
    var placeDetail: String?
}

enum CalendarProblem: LocalizedError {
    case signedOut
    case refused(String)
    case unreachable
    /// Sent to Upshow, where it waits for someone to approve it in the app.
    case awaitingApproval

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Perch is not signed in to Upshow."
        case .refused(let reason): return reason
        case .unreachable: return "Could not reach Upshow."
        case .awaitingApproval: return "Sent to Upshow. It happens once you approve it in the Upshow app."
        }
    }
}

protocol UpshowCalendarService {
    /// False for the stand-in. The tab shows a banner, and nothing leaves the Mac.
    var live: Bool { get }
    func meetings(from: Date, to: Date) async throws -> [UpshowMeeting]
    func busy(from: Date, to: Date) async throws -> [UpshowBusy]
    func calendars() async throws -> [UpshowCalendarSource]
    func meetingTypes() async throws -> [UpshowMeetingType]
    /// Writes nothing. Names in the text go to Upshow's language model.
    func parse(_ text: String) async throws -> UpshowParsed?
    func book(_ booking: UpshowBooking) async throws -> UpshowMeeting
    func reschedule(_ id: String, to start: Date, minutes: Int) async throws
    func cancel(_ id: String, sendSequence: Bool) async throws
}

/// Where Upshow lives for this user, and the credential for it.
struct UpshowConnection {
    let baseURL: URL
    let token: String
}

/// Provided by Upshow's sign-in once it exists. Keep the token in the Keychain.
protocol UpshowSignIn: AnyObject {
    var connection: UpshowConnection? { get }
    func signIn() async throws
    func signOut()
}

enum UpshowAccess {
    /// The one place sign-in plugs in.
    nonisolated(unsafe) static var signIn: UpshowSignIn? = UpshowOAuth.shared

    static var service: UpshowCalendarService {
        if signIn?.connection != nil { return UpshowMCP() }
        return SampleCalendar.shared
    }
}

// MARK: Times

enum UpshowTime {
    /// UTC with milliseconds: the only form every Upshow tool accepts.
    static func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    static func parse(_ text: String) -> Date? {
        let fine = ISO8601DateFormatter()
        fine.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return fine.date(from: text) ?? whole.date(from: text)
    }
}

// MARK: Sample data

/// Made-up meetings, held in memory, so the tab can be used before sign-in. Nothing here reaches
/// a calendar or a person.
final class SampleCalendar: UpshowCalendarService {
    static let shared = SampleCalendar()
    var live: Bool { false }

    private var made: [UpshowMeeting]

    private init() {
        let day = Calendar.current.startOfDay(for: Date())
        func at(_ days: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            Calendar.current.date(byAdding: .minute, value: days * 1440 + hour * 60 + minute, to: day)!
        }
        func sample(_ n: Int, _ title: String, _ guest: String, _ company: String, _ start: Date, _ minutes: Int) -> UpshowMeeting {
            UpshowMeeting(id: "sample-\(n)", title: title, guest: guest, guestEmail: "sample@example.com", company: company,
                          start: start, end: start.addingTimeInterval(Double(minutes) * 60), link: URL(string: "https://meet.google.com/sample"))
        }
        made = [
            sample(1, "Discovery call", "Sample Guest", "Example Ltd", at(0, 10), 30),
            sample(2, "Pricing walkthrough", "Alex Example", "Sample Co", at(0, 14, 30), 45),
            sample(3, "Onboarding", "Sam Placeholder", "Demo Agency", at(1, 11), 60),
            sample(4, "Follow-up", "Sample Guest", "Example Ltd", at(2, 9, 30), 30),
            sample(5, "Quarterly review", "Jo Placeholder", "Sample Co", at(3, 15), 60),
        ]
    }

    func meetings(from: Date, to: Date) async throws -> [UpshowMeeting] {
        made.filter { $0.start < to && $0.end > from }.sorted { $0.start < $1.start }
    }

    func busy(from: Date, to: Date) async throws -> [UpshowBusy] {
        let day = Calendar.current.startOfDay(for: Date())
        let start = day.addingTimeInterval(12 * 3600)
        return [UpshowBusy(id: "sample-lunch", start: start, end: start.addingTimeInterval(3600), allDay: false)]
            .filter { $0.start < to && $0.end > from }
    }

    func calendars() async throws -> [UpshowCalendarSource] {
        [UpshowCalendarSource(id: "sample", calendarID: "primary", name: "Sample calendar", primary: true)]
    }

    func meetingTypes() async throws -> [UpshowMeetingType] {
        [UpshowMeetingType(id: "sample-type", name: "Sample sequence", isDefault: true)]
    }

    func parse(_ text: String) async throws -> UpshowParsed? { nil }

    func book(_ booking: UpshowBooking) async throws -> UpshowMeeting {
        let start = booking.start ?? Date()
        let meeting = UpshowMeeting(id: UUID().uuidString, title: booking.title.isEmpty ? "Meeting" : booking.title,
                                    guest: booking.guests.first?.label ?? "", guestEmail: booking.guests.first?.email ?? "",
                                    company: "", start: start, end: start.addingTimeInterval(Double(booking.minutes) * 60), link: nil)
        made.append(meeting)
        return meeting
    }

    func reschedule(_ id: String, to start: Date, minutes: Int) async throws {
        guard let i = made.firstIndex(where: { $0.id == id }) else { throw CalendarProblem.refused("Meeting not found.") }
        made[i].start = start
        made[i].end = start.addingTimeInterval(Double(minutes) * 60)
    }

    func cancel(_ id: String, sendSequence: Bool) async throws {
        made.removeAll { $0.id == id }
    }
}

// MARK: The tab's state

@Observable
final class CalendarStore {
    static let shared = CalendarStore()

    enum Phase: Equatable {
        case loading, ready
        case failed(String)
    }

    private(set) var phase = Phase.loading
    private(set) var meetings: [UpshowMeeting] = []
    private(set) var busy: [UpshowBusy] = []
    private(set) var calendars: [UpshowCalendarSource] = []
    private(set) var types: [UpshowMeetingType] = []
    private(set) var live = false
    /// Monday of the week on screen.
    private(set) var week = CalendarStore.monday(of: Date())
    var selectedDay = Calendar.current.startOfDay(for: Date())

    static func monday(of date: Date) -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)) ?? date
    }

    var days: [Date] { (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: week) } }

    @MainActor
    func move(weeks: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: weeks * 7, to: week) else { return }
        jump(to: next, day: next)
    }

    @MainActor
    func goToToday() {
        jump(to: Self.monday(of: Date()), day: Calendar.current.startOfDay(for: Date()))
    }

    /// Opens the week holding a day, for a meeting just booked on another week.
    @MainActor
    func reveal(_ day: Date) {
        let monday = Self.monday(of: day)
        if monday == week { selectedDay = Calendar.current.startOfDay(for: day) } else { jump(to: monday, day: Calendar.current.startOfDay(for: day)) }
    }

    /// What each week looked like when it was last loaded, kept on disk, so the tab opens on the
    /// real diary at once and only refreshes it behind the scenes.
    private struct Saved: Codable {
        var weeks: [Date: Week] = [:]
        var types: [UpshowMeetingType] = []
        var calendars: [UpshowCalendarSource] = []
    }
    private struct Week: Codable {
        var meetings: [UpshowMeeting]
        var busy: [UpshowBusy]
    }
    private var saved = Saved()
    private static let file = URL(fileURLWithPath: "\(Shell.home)/.perch/calendar.json")
    private var timer: Timer?

    /// Called once at launch: puts last time's diary on screen and keeps it fresh every few
    /// minutes, whether or not the tab is open.
    @MainActor
    func start() {
        if UpshowAccess.service.live, let data = try? Data(contentsOf: Self.file),
           let old = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = old
            live = true
            types = old.types
            calendars = old.calendars
            show(week)
        }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in await CalendarStore.shared.refresh() }
        }
        timer?.tolerance = 30
    }

    /// The saved copy of a week, if there is one.
    @MainActor
    private func show(_ monday: Date) {
        guard let kept = saved.weeks[monday] else { return }
        meetings = kept.meetings
        busy = kept.busy
        phase = .ready
    }

    private func store() {
        // Only the weeks around now are worth keeping.
        let near = Date().addingTimeInterval(-60 * 86400)...Date().addingTimeInterval(120 * 86400)
        saved.weeks = saved.weeks.filter { near.contains($0.key) }
        saved.types = types
        saved.calendars = calendars
        let copy = saved
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(copy).write(to: Self.file, options: .atomic)
        }
    }

    @MainActor
    func refresh() async {
        let service = UpshowAccess.service
        // Just connected (or signed out): the sample's meetings, types and calendars go.
        if live != service.live {
            meetings = []; busy = []; types = []; calendars = []
            saved = Saved()
            if !service.live { try? FileManager.default.removeItem(at: Self.file) }
        }
        live = service.live
        let from = week
        let to = Calendar.current.date(byAdding: .day, value: 7, to: from) ?? from
        // What is on screen stays while it updates. On failure the tab says so, and never shows
        // an empty week that would read as free time.
        if saved.weeks[from] != nil { show(from) } else { phase = .loading }
        do {
            async let meetingRows = service.meetings(from: from, to: to)
            async let busyRows = service.busy(from: from, to: to)
            async let typeRows = try? service.meetingTypes()
            async let calendarRows = try? service.calendars()
            let (loaded, blocks) = try await (meetingRows, busyRows)
            if let fresh = await typeRows, !fresh.isEmpty { types = fresh }
            if let fresh = await calendarRows, !fresh.isEmpty { calendars = fresh }
            if service.live { saved.weeks[from] = Week(meetings: loaded, busy: blocks); store() }
            guard from == week else { return }
            meetings = loaded
            busy = blocks
            phase = .ready
        } catch {
            guard from == week else { return }
            // A saved copy is still better than nothing, as long as the tab says it may be stale.
            if saved.weeks[from] != nil { stale = error.localizedDescription; return }
            meetings = []
            busy = []
            phase = .failed(error.localizedDescription)
            return
        }
        stale = nil
    }

    /// Set when the last refresh failed but a saved copy is on screen.
    private(set) var stale: String?

    /// Meetings in a week other than the one on screen show from the saved copy straight away.
    @MainActor
    private func jump(to monday: Date, day: Date) {
        week = monday
        selectedDay = day
        if saved.weeks[monday] != nil { show(monday) } else { meetings = []; busy = []; phase = .loading }
        Task { await refresh() }
    }

    /// A booking waiting out its undo window. Nothing reaches Upshow until it ends, so Undo
    /// costs nothing; closing the tab does not stop it.
    struct Staged: Equatable {
        let booking: UpshowBooking
        let sendAt: Date
        var state = State.waiting
        enum State: Equatable { case waiting, sending, booked(UpshowMeeting), awaitingApproval, failed(String) }
    }
    private(set) var staged: Staged?
    /// A sentence to book from, handed in from elsewhere in Perch: the tab opens a booking and
    /// reads it as if it had been typed.
    var handedSentence: String?
    private var sendTask: Task<Void, Never>?
    static let undoSeconds = 7.0

    @MainActor
    func stage(_ booking: UpshowBooking) {
        staged = Staged(booking: booking, sendAt: Date().addingTimeInterval(Self.undoSeconds))
        sendTask?.cancel()
        sendTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.undoSeconds))
            guard !Task.isCancelled else { return }
            await self.sendStaged()
        }
    }

    /// Undo inside the window: the booking never left the Mac.
    @MainActor
    func undoStaged() -> UpshowBooking? {
        guard let staged, staged.state == .waiting else { return nil }
        sendTask?.cancel()
        self.staged = nil
        return staged.booking
    }

    /// "Send now", or the window ran out.
    @MainActor
    func sendStaged() async {
        guard var current = staged, current.state == .waiting else { return }
        sendTask?.cancel()
        current.state = .sending
        staged = current
        do {
            let made = try await UpshowAccess.service.book(current.booking)
            staged?.state = .booked(made)
        } catch CalendarProblem.awaitingApproval {
            staged?.state = .awaitingApproval
        } catch {
            staged?.state = .failed(error.localizedDescription)
        }
        await refresh()
    }

    /// After a failure: send exactly the same booking again. Upshow books a repeat only once.
    @MainActor
    func retryStaged() {
        guard let staged, case .failed = staged.state else { return }
        self.staged?.state = .waiting
        Task { await sendStaged() }
    }

    /// After a failure: back to the ticket to change something.
    @MainActor
    func reopenStaged() -> UpshowBooking? {
        guard let staged, case .failed = staged.state else { return nil }
        self.staged = nil
        return staged.booking
    }

    func sequenceName(_ id: String?) -> String? {
        guard let id else { return nil }
        return types.first { $0.id == id }?.name
    }

    /// What a booking would overlap, in the words the ticket shows, or nil when the slot is free.
    func clash(for booking: UpshowBooking) -> String? {
        guard booking.hasTime, let start = booking.start, let end = booking.end else { return nil }
        var seen = Set<String>()
        let all = (meetings + saved.weeks.values.flatMap(\.meetings)).filter { seen.insert($0.id).inserted }
        if let hit = all.first(where: { $0.start < end && $0.end > start }) {
            let who = hit.guest.isEmpty ? "" : " with \(hit.guest)"
            return "Overlaps \(hit.title)\(who) at \(CalendarText.time(hit.start))"
        }
        let blocks = busy + saved.weeks.values.flatMap(\.busy)
        if let hit = blocks.first(where: { !$0.allDay && $0.start < end && $0.end > start }) {
            return "Overlaps something on your calendar at \(CalendarText.time(hit.start))"
        }
        return nil
    }

    @MainActor
    func clearStaged() {
        if staged?.state == .waiting { return }
        staged = nil
    }

    /// Asks Upshow's parser about a sentence. Never throws: a failure just leaves the local read.
    @MainActor
    func parse(_ text: String) async -> UpshowParsed? {
        try? await UpshowAccess.service.parse(text)
    }

    /// Guests from meetings Perch has seen, for suggestions while typing a name.
    var knownGuests: [UpshowGuest] {
        var seen = Set<String>(), out: [UpshowGuest] = []
        let all = saved.weeks.values.flatMap(\.meetings) + meetings
        for m in all.sorted(by: { $0.start > $1.start }) where !m.guestEmail.isEmpty && seen.insert(m.guestEmail.lowercased()).inserted {
            out.append(UpshowGuest(name: m.guest == m.guestEmail ? "" : m.guest, email: m.guestEmail, company: m.company))
        }
        return out
    }

    @MainActor
    func reschedule(_ id: String, to start: Date, minutes: Int) async throws {
        try await UpshowAccess.service.reschedule(id, to: start, minutes: minutes)
        await refresh()
    }

    @MainActor
    func cancel(_ id: String, sendSequence: Bool) async throws {
        try await UpshowAccess.service.cancel(id, sendSequence: sendSequence)
        await refresh()
    }
}
