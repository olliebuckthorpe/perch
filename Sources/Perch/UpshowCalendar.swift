import Foundation
import Observation

// The calendar tab's data. Everything goes through `UpshowCalendarService`, so the screens do not
// care where it comes from. Until sign-in exists, `SampleCalendar` stands in and the tab says so.
//
// To connect the real thing, set `UpshowAccess.signIn` to something that provides a connection.
// If its token only works on Upshow's /mcp route rather than /api, write a second service that
// calls those tools and return it from `UpshowAccess.service`. Nothing else has to change.

struct UpshowMeeting: Identifiable, Equatable {
    let id: String
    var title: String
    var guest: String
    var guestEmail: String
    var company: String
    var start: Date
    var end: Date
    var link: URL?
}

/// Time taken on a connected calendar by something that is not an Upshow meeting.
struct UpshowBusy: Identifiable, Equatable {
    let id: String
    let start: Date
    let end: Date
    let allDay: Bool
}

struct UpshowCalendarSource: Identifiable, Equatable {
    let id: String
    let calendarID: String
    let name: String
    let primary: Bool
}

struct UpshowMeetingType: Identifiable, Equatable {
    let id: String
    let name: String
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

/// One new meeting. `clientID` is what Upshow uses to spot a repeat, so the same booking sent
/// twice after a timeout can never book anyone twice. It stays the same until the form is reset.
struct UpshowBooking: Equatable {
    var clientID = UUID()
    var title = ""
    var guestName = ""
    var guestEmail = ""
    var start = Date()
    var minutes = 30
    var meetingTypeID: String?
    var place = UpshowPlace.meet
    var placeDetail = ""
    var note = ""
    var notifyGuests = true
    var timeZone = TimeZone.current.identifier

    var ready: Bool {
        !guestName.trimmingCharacters(in: .whitespaces).isEmpty
            && guestEmail.contains("@") && start > Date()
    }
}

enum CalendarProblem: LocalizedError {
    case signedOut
    case refused(String)
    case unreachable

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Perch is not signed in to Upshow."
        case .refused(let reason): return reason
        case .unreachable: return "Could not reach Upshow."
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
    nonisolated(unsafe) static var signIn: UpshowSignIn?

    static var service: UpshowCalendarService {
        if let connection = signIn?.connection { return UpshowAPI(connection: connection) }
        return SampleCalendar.shared
    }
}

// MARK: Upshow's API

/// The routes Upshow's own app uses, as they stand on main.
struct UpshowAPI: UpshowCalendarService {
    let connection: UpshowConnection
    var live: Bool { true }

    private static let parse: (String) -> Date? = { text in
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        let fine = ISO8601DateFormatter()
        fine.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fine.date(from: text) ?? whole.date(from: text)
    }

    static func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private func call(_ method: String, _ path: String, query: [String: String] = [:],
                      body: [String: Any]? = nil) async throws -> Any {
        var parts = URLComponents(url: connection.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: parts.url!)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch { throw CalendarProblem.unreachable }
        let reply = try? JSONSerialization.jsonObject(with: data)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw CalendarProblem.signedOut }
        guard (200..<300).contains(code) else {
            throw CalendarProblem.refused((reply as? [String: Any])?["error"] as? String ?? "Upshow refused that (\(code)).")
        }
        return reply ?? NSNull()
    }

    private static func rows(_ reply: Any) -> [[String: Any]] {
        (reply as? [String: Any])?["data"] as? [[String: Any]] ?? reply as? [[String: Any]] ?? []
    }

    static func meeting(_ row: [String: Any]) -> UpshowMeeting? {
        guard let id = row["id"] as? String, let start = (row["start_time"] as? String).flatMap(parse) else { return nil }
        let guest = row["prospect_name"] as? String ?? ""
        return UpshowMeeting(id: id, title: row["meeting_title"] as? String ?? guest, guest: guest,
                             guestEmail: row["prospect_email"] as? String ?? "",
                             company: row["prospect_company"] as? String ?? "", start: start,
                             end: (row["end_time"] as? String).flatMap(parse) ?? start.addingTimeInterval(1800),
                             link: (row["meeting_link"] as? String).flatMap(URL.init(string:)))
    }

    func meetings(from: Date, to: Date) async throws -> [UpshowMeeting] {
        let reply = try await call("GET", "api/meetings", query: [
            "from": Self.stamp(from), "to": Self.stamp(to), "status": "confirmed", "limit": "200",
        ])
        return Self.rows(reply).compactMap(Self.meeting).sorted { $0.start < $1.start }
    }

    func busy(from: Date, to: Date) async throws -> [UpshowBusy] {
        let reply = try await call("GET", "api/calendar/busy", query: ["from": Self.stamp(from), "to": Self.stamp(to)])
        return Self.rows(reply).compactMap { row in
            guard let start = (row["start_time"] as? String).flatMap(Self.parse),
                  let end = (row["end_time"] as? String).flatMap(Self.parse) else { return nil }
            return UpshowBusy(id: "\(row["provider_event_id"] ?? UUID().uuidString)", start: start, end: end,
                              allDay: row["is_all_day"] as? Bool ?? false)
        }
    }

    func calendars() async throws -> [UpshowCalendarSource] {
        Self.rows(try await call("GET", "api/calendar/sources")).compactMap { row in
            guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
            return UpshowCalendarSource(id: id, calendarID: row["calendarId"] as? String ?? "", name: name,
                                        primary: row["isPrimary"] as? Bool ?? false)
        }
    }

    func meetingTypes() async throws -> [UpshowMeetingType] {
        Self.rows(try await call("GET", "api/meeting-types")).compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return UpshowMeetingType(id: id, name: row["name"] as? String ?? "Untitled")
        }
    }

    func book(_ booking: UpshowBooking) async throws -> UpshowMeeting {
        var place: [String: Any] = ["kind": booking.place.rawValue]
        let detail = booking.placeDetail.trimmingCharacters(in: .whitespaces)
        if !detail.isEmpty { place[booking.place == .zoom || booking.place == .custom ? "url" : "label"] = detail }
        var body: [String: Any] = [
            "client_booking_id": booking.clientID.uuidString.lowercased(),
            "attendees": [["name": booking.guestName, "email": booking.guestEmail]],
            "meeting_type_id": booking.meetingTypeID ?? NSNull(),
            "start_time": Self.stamp(booking.start),
            "duration_minutes": booking.minutes,
            "timezone": booking.timeZone,
            "where": place,
            "notify_guests": booking.notifyGuests,
        ]
        if !booking.title.isEmpty { body["meeting_title"] = booking.title }
        if !booking.note.isEmpty { body["note"] = booking.note }
        let reply = try await call("POST", "api/meetings/manual", body: body)
        guard let row = (reply as? [String: Any])?["data"] as? [String: Any], let made = Self.meeting(row) else {
            throw CalendarProblem.refused("Upshow did not confirm the booking. Check the calendar before trying again.")
        }
        return made
    }

    func reschedule(_ id: String, to start: Date, minutes: Int) async throws {
        _ = try await call("POST", "api/meetings/\(id)/reschedule",
                           body: ["start_time": Self.stamp(start), "duration_minutes": minutes])
    }

    func cancel(_ id: String, sendSequence: Bool) async throws {
        _ = try await call("POST", "api/meetings/\(id)/cancel", body: ["send_cancellation_sequence": sendSequence])
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
        [UpshowMeetingType(id: "sample-type", name: "Sample sequence")]
    }

    func book(_ booking: UpshowBooking) async throws -> UpshowMeeting {
        let meeting = UpshowMeeting(id: booking.clientID.uuidString, title: booking.title.isEmpty ? "Meeting" : booking.title,
                                    guest: booking.guestName, guestEmail: booking.guestEmail, company: "", start: booking.start,
                                    end: booking.start.addingTimeInterval(Double(booking.minutes) * 60), link: nil)
        if !made.contains(where: { $0.id == meeting.id }) { made.append(meeting) }
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

    func move(weeks: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: weeks * 7, to: week) else { return }
        week = next
        selectedDay = next
        Task { await refresh() }
    }

    func goToToday() {
        week = Self.monday(of: Date())
        selectedDay = Calendar.current.startOfDay(for: Date())
        Task { await refresh() }
    }

    @MainActor
    func refresh() async {
        let service = UpshowAccess.service
        live = service.live
        let from = week
        let to = Calendar.current.date(byAdding: .day, value: 7, to: from) ?? from
        // What is on screen stays while it updates. On failure the tab says so, and never shows
        // an empty week that would read as free time.
        if meetings.isEmpty { phase = .loading }
        do {
            async let meetingRows = service.meetings(from: from, to: to)
            async let busyRows = service.busy(from: from, to: to)
            let (loaded, blocks) = try await (meetingRows, busyRows)
            guard from == week else { return }
            meetings = loaded
            busy = blocks
            phase = .ready
        } catch {
            guard from == week else { return }
            meetings = []
            busy = []
            phase = .failed(error.localizedDescription)
        }
        if types.isEmpty { types = (try? await service.meetingTypes()) ?? [] }
        if calendars.isEmpty { calendars = (try? await service.calendars()) ?? [] }
    }

    @MainActor
    func book(_ booking: UpshowBooking) async throws -> UpshowMeeting {
        let made = try await UpshowAccess.service.book(booking)
        await refresh()
        return made
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
