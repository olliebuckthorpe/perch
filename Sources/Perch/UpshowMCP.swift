import AppKit
import CryptoKit
import Foundation
import Network

// MARK: Sign-in

/// Signs in to Upshow the way any MCP app does: Perch registers itself, opens Upshow's consent
/// page in the browser, and catches the answer on a local address. The keys are kept in
/// `~/.perch/secrets`, like Slack's.
final class UpshowOAuth: UpshowSignIn {
    static let shared = UpshowOAuth()

    static let base = URL(string: "https://api.upshow.co.uk")!
    static let mcp = URL(string: "https://api.upshow.co.uk/mcp")!
    /// Upshow matches the return address exactly, so the port is fixed.
    private static let port: UInt16 = 53682
    private static let redirect = "http://127.0.0.1:53682/callback"
    private static let scopes = "meetings:read meetings:write outreach:send"
    private static let service = "upshow"

    private var access: String? { Keychain.get(Self.service, "access") }
    private var refresh: String? { Keychain.get(Self.service, "refresh") }

    var connection: UpshowConnection? {
        guard refresh != nil || access != nil else { return nil }
        return UpshowConnection(baseURL: Self.mcp, token: access ?? "")
    }

    func signOut() {
        for key in ["access", "refresh", "expires"] { Keychain.delete(Self.service, key) }
    }

    /// A token that still works, refreshed first when it is about to run out.
    ///
    /// Upshow's refresh tokens work once each. The calendar asks for several things at the same
    /// moment, so every caller waits on the one refresh in flight instead of each spending the
    /// same refresh token (the second would be refused, and used to sign Perch out).
    func token(forceRefresh: Bool = false) async throws -> String {
        let expires = Double(Keychain.get(Self.service, "expires") ?? "") ?? 0
        if !forceRefresh, let access, Date().timeIntervalSince1970 < expires - 60 { return access }
        lock.lock()
        if let running = refreshing {
            lock.unlock()
            return try await running.value
        }
        let task = Task { try await self.refreshNow() }
        refreshing = task
        lock.unlock()
        defer { lock.lock(); refreshing = nil; lock.unlock() }
        return try await task.value
    }

    private let lock = NSLock()
    private var refreshing: Task<String, Error>?

    private func refreshNow() async throws -> String {
        guard let refresh, let client = Keychain.get(Self.service, "client") else { throw CalendarProblem.signedOut }
        let reply = try await Self.form("oauth/token", ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": client,
                                                        "resource": Self.mcp.absoluteString])
        guard let fresh = reply["access_token"] as? String else {
            // Only a refusal of the grant itself means signed out. Anything else (Upshow busy, a
            // bad gateway) keeps the keys, so the next try can still work.
            if reply["error"] as? String == "invalid_grant" { signOut(); throw CalendarProblem.signedOut }
            throw CalendarProblem.unreachable
        }
        save(reply)
        return fresh
    }

    func signIn() async throws {
        let client = try await clientID()
        let verifier = Self.random(32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.random(16)
        var parts = URLComponents(url: Self.base.appendingPathComponent("oauth/authorize"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: client),
            .init(name: "redirect_uri", value: Self.redirect), .init(name: "scope", value: Self.scopes),
            .init(name: "state", value: state), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "resource", value: Self.mcp.absoluteString),
        ]
        let catcher = Callback(port: Self.port)
        try catcher.start()
        defer { catcher.stop() }
        await MainActor.run { _ = NSWorkspace.shared.open(parts.url!) }
        let answer = try await catcher.wait(timeout: 300)
        guard answer["state"] == state else { throw CalendarProblem.refused("The sign-in answer did not match. Try again.") }
        if let error = answer["error"] {
            throw CalendarProblem.refused(error == "access_denied" ? "Access was not allowed in Upshow." : "Upshow refused the sign-in (\(error)).")
        }
        guard let code = answer["code"] else { throw CalendarProblem.refused("Upshow did not send a sign-in code.") }
        let reply = try await Self.form("oauth/token", ["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect,
                                                        "client_id": client, "code_verifier": verifier, "resource": Self.mcp.absoluteString])
        guard reply["access_token"] is String else {
            throw CalendarProblem.refused((reply["error_description"] as? String) ?? "Upshow did not finish the sign-in.")
        }
        save(reply)
    }

    private func save(_ reply: [String: Any]) {
        if let access = reply["access_token"] as? String { Keychain.set(Self.service, "access", access) }
        if let refresh = reply["refresh_token"] as? String { Keychain.set(Self.service, "refresh", refresh) }
        let life = (reply["expires_in"] as? Double) ?? 3600
        Keychain.set(Self.service, "expires", String(Date().timeIntervalSince1970 + life))
    }

    /// Perch registers itself with Upshow once and keeps the id it is given.
    private func clientID() async throws -> String {
        if let known = Keychain.get(Self.service, "client") { return known }
        var req = URLRequest(url: Self.base.appendingPathComponent("oauth/register"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "Perch", "redirect_uris": [Self.redirect], "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
        ])
        let (data, _) = try await Self.fetch(req)
        guard let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["client_id"] as? String else {
            throw CalendarProblem.refused("Upshow would not register Perch.")
        }
        Keychain.set(Self.service, "client", id)
        return id
    }

    private static func form(_ path: String, _ fields: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, _) = try await fetch(req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func fetch(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw CalendarProblem.unreachable }
            return (data, http)
        } catch let problem as CalendarProblem {
            throw problem
        } catch {
            throw CalendarProblem.unreachable
        }
    }

    private static func random(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URL
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Listens on 127.0.0.1 for the one request the browser makes on the way back from Upshow.
private final class Callback {
    private let port: UInt16
    private var listener: NWListener?
    private var answer: CheckedContinuation<[String: String], Error>?
    private let lock = NSLock()

    init(port: UInt16) { self.port = port }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let listener: NWListener
        do { listener = try NWListener(using: params) } catch {
            throw CalendarProblem.refused("Perch could not listen for the sign-in (port \(port) is in use).")
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    func stop() { listener?.cancel() }

    func wait(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); answer = continuation; lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(CalendarProblem.refused("The sign-in timed out. Try again.")))
            }
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock(); let c = answer; answer = nil; lock.unlock()
        c?.resume(with: result)
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // "GET /callback?code=...&state=... HTTP/1.1"
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            guard target.hasPrefix("/callback"), let parts = URLComponents(string: "http://127.0.0.1\(target)") else {
                connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            var fields: [String: String] = [:]
            for item in parts.queryItems ?? [] { fields[item.name] = item.value ?? "" }
            let ok = fields["code"] != nil
            let page = """
            <html><body style="font-family:-apple-system;background:#111;color:#eee;display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
            <div style="text-align:center"><h2>\(ok ? "Perch is connected to Upshow" : "Perch was not connected")</h2><p>You can close this tab.</p></div></body></html>
            """
            let body = Data(page.utf8)
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            self?.finish(.success(fields))
        }
    }
}

// MARK: Calendar over MCP

/// The calendar through Upshow's MCP server: the same tools an assistant gets, with the same
/// safety. Anything that messages a guest (booking, moving, cancelling) is checked by Upshow
/// first: either it waits for approval in the Upshow app, or, when the connection was allowed to
/// send directly, it needs the confirmation Perch's own review step already gave.
struct UpshowMCP: UpshowCalendarService {
    var live: Bool { true }

    private static let parse = UpshowTime.parse

    /// The list as last fetched, so flicking between weeks does not page through it again.
    nonisolated(unsafe) private static var recent: (at: Date, rows: [[String: Any]], complete: Date)?

    func meetings(from: Date, to: Date) async throws -> [UpshowMeeting] {
        // Upshow lists newest first with no date filter, so pages are read until they reach back
        // past the week asked for. A list fetched in the last minute that already reaches that
        // far is reused.
        var rows: [[String: Any]]
        if let kept = Self.recent, Date().timeIntervalSince(kept.at) < 60, kept.complete <= from {
            rows = kept.rows
        } else {
            rows = []
            var oldest = Date.distantFuture
            for page in 0..<5 {
                let reply = try await tool("list_meetings", ["limit": 100, "offset": page * 100])
                let batch = reply["meetings"] as? [[String: Any]] ?? []
                rows += batch
                oldest = batch.compactMap { ($0["start_time"] as? String).flatMap(Self.parse) }.min() ?? oldest
                if batch.count < 100 { oldest = .distantPast; break }
                if oldest < from { break }
            }
            Self.recent = (Date(), rows, oldest)
        }
        return rows.compactMap { row in
            guard let meeting = Self.meeting(row), meeting.start < to, meeting.end > from,
                  !["cancelled", "canceled"].contains(row["status"] as? String ?? "") else { return nil }
            return meeting
        }
        .sorted { $0.start < $1.start }
    }

    private static func meeting(_ row: [String: Any]) -> UpshowMeeting? {
        guard let id = row["id"] as? String, let start = (row["start_time"] as? String).flatMap(parse) else { return nil }
        let end = (row["end_time"] as? String).flatMap(parse) ?? start.addingTimeInterval(1800)
        let email = row["prospect_email"] as? String ?? ""
        return UpshowMeeting(id: id, title: row["meeting_title"] as? String ?? "Meeting",
                             guest: (row["prospect_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? email,
                             guestEmail: email, company: row["prospect_company"] as? String ?? "",
                             start: start, end: end, link: nil, sequenceID: row["meeting_type_id"] as? String,
                             status: row["status"] as? String, remindersOff: row["reminders_disabled"] as? Bool,
                             sequencePaused: !(row["sequence_paused_at"] is NSNull || row["sequence_paused_at"] == nil),
                             guestReplied: !(row["prospect_responded_at"] is NSNull || row["prospect_responded_at"] == nil),
                             wonBack: !(row["recovered_at"] is NSNull || row["recovered_at"] == nil),
                             platform: row["booking_platform"] as? String, guestTimeZone: row["prospect_timezone"] as? String)
    }

    func busy(from: Date, to: Date) async throws -> [UpshowBusy] {
        let reply = try await tool("get_calendar_info", ["action": "busy_times", "from": UpshowTime.stamp(from), "to": UpshowTime.stamp(to)])
        return (reply["busy"] as? [[String: Any]] ?? []).enumerated().compactMap { i, row in
            guard let start = (row["start_time"] as? String).flatMap(Self.parse),
                  let end = (row["end_time"] as? String).flatMap(Self.parse) else { return nil }
            return UpshowBusy(id: "busy-\(i)", start: start, end: end, allDay: row["is_all_day"] as? Bool ?? false)
        }
    }

    func calendars() async throws -> [UpshowCalendarSource] {
        let reply = try await tool("get_calendar_info", ["action": "sources"])
        return (reply["calendars"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return UpshowCalendarSource(id: id, calendarID: id, name: row["name"] as? String ?? "Calendar",
                                        primary: row["isPrimary"] as? Bool ?? false)
        }
    }

    func meetingTypes() async throws -> [UpshowMeetingType] {
        let reply = try await tool("get_meeting_types", ["action": "list"])
        return (reply["meetingTypes"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return UpshowMeetingType(id: id, name: row["name"] as? String ?? "Sequence", isDefault: row["is_default"] as? Bool ?? false,
                                     defaultMinutes: (row["default_duration_minutes"] as? NSNumber)?.intValue)
        }
    }

    func parse(_ text: String) async throws -> UpshowParsed? {
        let now = Date()
        let day = DateFormatter(), time = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        time.dateFormat = "HH:mm"
        for f in [day, time] { f.locale = Locale(identifier: "en_US_POSIX") }
        let reply = try await tool("parse_meeting_text", [
            "text": text, "today": day.string(from: now), "now": time.string(from: now),
            "host_timezone": TimeZone.current.identifier,
        ])
        var out = UpshowParsed()
        out.title = (reply["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        for person in reply["people"] as? [[String: Any]] ?? [] {
            out.guests.append(UpshowGuest(name: person["name"] as? String ?? "", email: person["email"] as? String ?? "",
                                          phone: person["phone"] as? String ?? ""))
            if out.sequenceID == nil { out.sequenceID = person["sequence_id"] as? String }
            if person["no_reminders"] as? Bool == true { out.noReminders = true }
        }
        if let date = reply["date"] as? String {
            let zone = (reply["time_zone"] as? String).flatMap(TimeZone.init(identifier:)) ?? .current
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = zone
            if let clock = reply["time"] as? String {
                f.dateFormat = "yyyy-MM-dd HH:mm"
                out.start = f.date(from: "\(date) \(clock)")
                out.hasTime = out.start != nil
            } else {
                f.dateFormat = "yyyy-MM-dd"
                out.start = f.date(from: date)
            }
        }
        out.minutes = (reply["duration_minutes"] as? NSNumber)?.intValue
        if let place = reply["where"] as? [String: Any], let kind = (place["kind"] as? String).flatMap(UpshowPlace.init(rawValue:)) {
            out.place = kind
            out.placeDetail = place["place"] as? String ?? place["url"] as? String
        }
        return out
    }

    func book(_ booking: UpshowBooking) async throws -> UpshowMeeting {
        guard let start = booking.start else { throw CalendarProblem.refused("Pick a time first.") }
        let attendees: [[String: Any]] = booking.guests.map { guest in
            var row: [String: Any] = ["name": guest.name.isEmpty ? guest.email : guest.name]
            if !guest.email.isEmpty { row["email"] = guest.email }
            if !guest.phone.isEmpty { row["phone"] = guest.phone }
            return row
        }
        var args: [String: Any] = [
            "attendees": attendees, "meeting_type_id": (booking.sequence ?? nil) ?? NSNull(),
            "start_time": UpshowTime.stamp(start), "duration_minutes": booking.minutes,
        ]
        // As Upshow's own app sends it: Meet and Teams make their own link.
        if let place = booking.place {
            let detail = booking.placeDetail.trimmingCharacters(in: .whitespaces)
            var row: [String: Any] = ["kind": place.rawValue]
            switch place {
            case .zoom, .custom: if !detail.isEmpty { row["url"] = detail }
            case .phone: row["label"] = "Phone call"
            case .inPerson: row["label"] = detail.isEmpty ? "In person" : detail
            case .meet, .teams: break
            }
            args["where"] = row
        }
        let title = booking.title.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty { args["meeting_title"] = title }
        let reply = try await outbound("create_manual_meeting", args)
        let row = (reply["data"] as? [String: Any]) ?? (reply["meeting"] as? [String: Any]) ?? reply
        return Self.meeting(row) ?? UpshowMeeting(
            id: row["id"] as? String ?? UUID().uuidString, title: title.isEmpty ? "Meeting" : title,
            guest: booking.guests.first?.label ?? "", guestEmail: booking.guests.first?.email ?? "", company: "",
            start: start, end: start.addingTimeInterval(Double(booking.minutes) * 60), link: nil,
            sequenceID: booking.sequence ?? nil)
    }

    func reschedule(_ id: String, to start: Date, minutes: Int) async throws {
        _ = try await outbound("reschedule_meeting", ["meetingId": id, "start_time": UpshowTime.stamp(start), "duration_minutes": minutes])
    }

    func cancel(_ id: String, sendSequence: Bool) async throws {
        _ = try await outbound("cancel_meeting", ["meetingId": id, "send_cancellation_sequence": sendSequence])
    }

    /// A call that messages a guest. The user has already reviewed it in Perch, so a confirmation
    /// Upshow asks for is given straight away; an approval in the Upshow app is said plainly.
    private func outbound(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
        Self.recent = nil
        defer { Self.recent = nil }
        let first = try await tool(name, args)
        switch first["status"] as? String {
        case "confirmation_required":
            guard let token = first["confirmToken"] as? String else { throw CalendarProblem.refused("Upshow did not give a confirmation.") }
            var again = args
            again["confirmToken"] = token
            return try await tool(name, again)
        case "waiting_for_approval":
            throw CalendarProblem.awaitingApproval
        default:
            return first
        }
    }

    /// One MCP tool call, its JSON answer unwrapped.
    private func tool(_ name: String, _ args: [String: Any], retried: Bool = false) async throws -> [String: Any] {
        let token = try await UpshowOAuth.shared.token(forceRefresh: retried)
        var req = URLRequest(url: UpshowOAuth.mcp)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": Int.random(in: 1...999_999), "method": "tools/call",
            "params": ["name": name, "arguments": args],
        ])
        let (data, http) = try await UpshowOAuth.fetch(req)
        if http.statusCode == 401 {
            if retried { UpshowOAuth.shared.signOut(); throw CalendarProblem.signedOut }
            return try await tool(name, args, retried: true)
        }
        guard http.statusCode < 400 else { throw CalendarProblem.refused("Upshow answered \(http.statusCode).") }
        // A plain JSON answer, or the same carried as a server-sent event.
        var text = String(data: data, encoding: .utf8) ?? ""
        if let line = text.split(separator: "\n").last(where: { $0.hasPrefix("data:") }) { text = String(line.dropFirst(5)) }
        guard let message = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw CalendarProblem.refused("Upshow sent an answer Perch could not read.")
        }
        if let error = message["error"] as? [String: Any] {
            throw CalendarProblem.refused(error["message"] as? String ?? "Upshow refused that.")
        }
        let result = message["result"] as? [String: Any] ?? [:]
        let body = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "{}"
        let reply = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]) ?? [:]
        if result["isError"] as? Bool == true {
            throw CalendarProblem.refused(reply["message"] as? String ?? reply["error"] as? String ?? "Upshow refused that.")
        }
        return reply
    }
}
