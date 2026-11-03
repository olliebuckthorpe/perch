import AppKit
import SwiftUI

/// The Calendar tab: the week on the right, the chosen day or meeting on the left. It only exists
/// while the tab is open, so it costs nothing the rest of the time.
struct CalendarView: View {
    @Environment(NotchUI.self) private var ui
    private var store: CalendarStore { CalendarStore.shared }
    @State private var chosen: UpshowMeeting?
    @State private var composing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !store.live { sampleBanner }
            HStack(alignment: .top, spacing: 12) {
                side.frame(width: 300)
                Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
                week
            }
        }
        .frame(height: 452, alignment: .top)
        .task {
            await store.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await store.refresh()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(CalendarText.weekTitle(store.days)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            arrow("chevron.left") { store.move(weeks: -1) }
            arrow("chevron.right") { store.move(weeks: 1) }
            Button("Today") { store.goToToday() }.buttonStyle(CalendarButton())
            Spacer()
            Button {
                chosen = nil
                composing = true
            } label: {
                Label("New meeting", systemImage: "plus")
            }
            .buttonStyle(CalendarButton(strong: true))
        }
    }

    private func arrow(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                .frame(width: 24, height: 24).background(.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(Press())
    }

    @State private var connecting = false
    @State private var connectProblem: String?

    /// Until Upshow is connected: sample meetings, and the button that connects it.
    private var sampleBanner: some View {
        HStack(spacing: 8) {
            Label(connectProblem ?? (connecting ? "Finish signing in to Upshow in your browser…"
                                     : "Sample diary: nothing here is real and nothing is sent."),
                  systemImage: connectProblem == nil ? "info.circle" : "exclamationmark.triangle")
                .font(.system(size: 11)).foregroundStyle(connectProblem == nil ? Palette.colors[4] : Palette.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(connecting ? "Waiting…" : "Connect Upshow") { connect() }
                .buttonStyle(CalendarButton(strong: true)).disabled(connecting)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Palette.colors[4].opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func connect() {
        connecting = true
        connectProblem = nil
        Task { @MainActor in
            do {
                try await UpshowAccess.signIn?.signIn()
                await CalendarStore.shared.refresh()
            } catch {
                connectProblem = error.localizedDescription
            }
            connecting = false
        }
    }

    @ViewBuilder private var side: some View {
        if composing {
            CalendarNewMeeting(day: store.selectedDay) { made in
                composing = false
                chosen = made
            } close: {
                composing = false
            }
        } else if let chosen, let current = store.meetings.first(where: { $0.id == chosen.id }) {
            CalendarMeetingCard(meeting: current) { self.chosen = nil }
        } else {
            dayList
        }
    }

    private var dayList: some View {
        let day = store.selectedDay
        let meetings = store.meetings.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
        return VStack(alignment: .leading, spacing: 6) {
            Text(CalendarText.day(day)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
            switch store.phase {
            case .loading:
                Text("Loading…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
            case .failed(let reason):
                CalendarUnavailable(reason: reason)
            case .ready:
                if meetings.isEmpty {
                    Text("No meetings").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(meetings) { row($0) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ meeting: UpshowMeeting) -> some View {
        Button { chosen = meeting } label: {
            HStack(alignment: .top, spacing: 9) {
                Text(CalendarText.time(meeting.start)).font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55)).frame(width: 42, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text([meeting.guest, meeting.company].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(Press())
    }

    @ViewBuilder private var week: some View {
        if case .failed(let reason) = store.phase {
            CalendarUnavailable(reason: reason).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            CalendarWeek { chosen = $0; composing = false }
        }
    }
}

/// A fetch that failed must not look like an empty, free week.
private struct CalendarUnavailable: View {
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Calendar unavailable", systemImage: "exclamationmark.triangle").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.red)
            Text(reason).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
            Button("Try again") { Task { await CalendarStore.shared.refresh() } }.buttonStyle(CalendarButton())
        }
    }
}

// MARK: Week grid

private struct CalendarWeek: View {
    let choose: (UpshowMeeting) -> Void
    private var store: CalendarStore { CalendarStore.shared }

    private static let firstHour = 7, lastHour = 20
    private static let hourHeight: CGFloat = 34

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                Color.clear.frame(width: 30, height: 1)
                ForEach(store.days, id: \.self) { day in
                    let today = Calendar.current.isDateInToday(day)
                    let picked = Calendar.current.isDate(day, inSameDayAs: store.selectedDay)
                    Button { store.selectedDay = day } label: {
                        Text(CalendarText.dayShort(day)).font(.system(size: 10.5, weight: today ? .bold : .medium))
                            .foregroundStyle(today ? Palette.green : .white.opacity(picked ? 0.95 : 0.55))
                            .frame(maxWidth: .infinity).padding(.vertical, 3)
                            .background(.white.opacity(picked ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(Press())
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                HStack(alignment: .top, spacing: 2) {
                    hours
                    ForEach(store.days, id: \.self) { column($0) }
                }
                .frame(height: Self.hourHeight * CGFloat(Self.lastHour - Self.firstHour))
            }
        }
    }

    private var hours: some View {
        VStack(spacing: 0) {
            ForEach(Self.firstHour..<Self.lastHour, id: \.self) { hour in
                Text(String(format: "%02d", hour)).font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.35)).frame(width: 30, height: Self.hourHeight, alignment: .topLeading)
            }
        }
    }

    private func offset(_ date: Date, on day: Date) -> CGFloat {
        let hours = date.timeIntervalSince(day) / 3600 - Double(Self.firstHour)
        return CGFloat(min(max(hours, 0), Double(Self.lastHour - Self.firstHour))) * Self.hourHeight
    }

    private func column(_ day: Date) -> some View {
        let start = Calendar.current.startOfDay(for: day)
        let next = start.addingTimeInterval(86400)
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(Self.firstHour..<Self.lastHour, id: \.self) { _ in
                    Rectangle().fill(.white.opacity(0.03)).frame(height: Self.hourHeight - 1).padding(.bottom, 1)
                }
            }
            ForEach(store.busy.filter { $0.start < next && $0.end > start }) { block in
                let top = offset(block.allDay ? start.addingTimeInterval(Double(Self.firstHour) * 3600) : block.start, on: start)
                let bottom = offset(block.allDay ? next : block.end, on: start)
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white.opacity(0.1))
                    .frame(height: max(bottom - top, 4)).offset(y: top).help("Busy")
            }
            ForEach(store.meetings.filter { $0.start < next && $0.end > start }) { meeting in
                let top = offset(meeting.start, on: start)
                let bottom = offset(meeting.end, on: start)
                Button { choose(meeting) } label: {
                    Text(meeting.title).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.black.opacity(0.85))
                        .lineLimit(2).padding(.horizontal, 3).padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .topLeading).frame(height: max(bottom - top - 1, 15), alignment: .top)
                        .background(Palette.colors[0], in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(Press()).offset(y: top)
                .help("\(CalendarText.time(meeting.start)) \(meeting.title)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: One meeting

private struct CalendarMeetingCard: View {
    let meeting: UpshowMeeting
    let close: () -> Void
    @Environment(NotchUI.self) private var ui
    private enum Mode { case view, moving, cancelling }
    @State private var mode = Mode.view
    @State private var newStart = Date()
    @State private var minutes = 30
    @State private var sendSequence = false
    @State private var working = false
    @State private var problem: String?

    private var live: Bool { CalendarStore.shared.live }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: close) { Label("Back", systemImage: "chevron.left") }.buttonStyle(CalendarButton())
                Spacer()
            }
            Text(meeting.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
            Text("\(CalendarText.day(meeting.start)), \(CalendarText.time(meeting.start)) to \(CalendarText.time(meeting.end))")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            Text([meeting.guest, meeting.guestEmail, meeting.company].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5)).textSelection(.enabled)
            switch mode {
            case .view: actions
            case .moving: moving
            case .cancelling: cancelling
            }
            if let problem { Text(problem).font(.system(size: 11)).foregroundStyle(Palette.red) }
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if let link = meeting.link, live {
                Button("Join") { NSWorkspace.shared.open(link) }.buttonStyle(CalendarButton(strong: true))
            }
            Button("Reschedule") {
                newStart = meeting.start
                minutes = max(5, Int(meeting.end.timeIntervalSince(meeting.start) / 60))
                mode = .moving
            }
            .buttonStyle(CalendarButton())
            Button("Cancel meeting") { mode = .cancelling }.buttonStyle(CalendarButton())
        }
    }

    private var moving: some View {
        VStack(alignment: .leading, spacing: 8) {
            DatePicker("New time", selection: $newStart, in: Date()...).font(.system(size: 12))
            Stepper("\(minutes) minutes", value: $minutes, in: 5...480, step: 5).font(.system(size: 12))
            Text(live ? "Upshow moves the calendar event and tells the guest." : "Sample only: nothing is sent.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            HStack(spacing: 6) {
                Button(working ? "Moving…" : "Move meeting") {
                    run { try await CalendarStore.shared.reschedule(meeting.id, to: newStart, minutes: minutes) }
                }
                .buttonStyle(CalendarButton(strong: true)).disabled(working)
                Button("Keep it") { mode = .view }.buttonStyle(CalendarButton())
            }
        }
    }

    private var cancelling: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cancel this meeting with \(meeting.guest.isEmpty ? "the guest" : meeting.guest)?")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
            Toggle("Send the cancellation sequence", isOn: $sendSequence).font(.system(size: 12))
            HStack(spacing: 6) {
                Button(working ? "Cancelling…" : "Yes, cancel it") {
                    run {
                        try await CalendarStore.shared.cancel(meeting.id, sendSequence: sendSequence)
                        close()
                    }
                }
                .buttonStyle(CalendarButton(danger: true)).disabled(working)
                Button("Keep it") { mode = .view }.buttonStyle(CalendarButton())
            }
        }
    }

    /// Not retried by itself: after a failure the calendar is reloaded first, so a move or cancel
    /// that did go through shows as done.
    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        problem = nil
        Task { @MainActor in
            do {
                try await action()
                mode = .view
            } catch {
                await CalendarStore.shared.refresh()
                problem = "\(error.localizedDescription) Check the meeting before trying again."
            }
            working = false
        }
    }
}

// MARK: New meeting

private struct CalendarNewMeeting: View {
    let day: Date
    let done: (UpshowMeeting) -> Void
    let close: () -> Void
    @Environment(NotchUI.self) private var ui
    @State private var booking = UpshowBooking()
    @State private var reviewing = false
    @State private var working = false
    @State private var problem: String?

    private var store: CalendarStore { CalendarStore.shared }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                Text(reviewing ? "Check this looks right" : "New meeting").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                if reviewing { review } else { form }
                if let problem { Text(problem).font(.system(size: 11)).foregroundStyle(Palette.red) }
            }
        }
        .onAppear {
            // The next half hour on the chosen day, or tomorrow morning if that has passed.
            var start = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: day) ?? day
            if start <= Date() {
                let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime)
                start = next ?? Date().addingTimeInterval(3600)
            }
            booking.start = start
            booking.meetingTypeID = store.types.first?.id
        }
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.plain).font(.system(size: 12))
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .simultaneousGesture(TapGesture().onEnded { ui.controller?.panel.makeKey() })
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 7) {
            field("Guest's name", $booking.guestName)
            field("Guest's email", $booking.guestEmail)
            field("Title (optional)", $booking.title)
            DatePicker("When", selection: $booking.start, in: Date()...).font(.system(size: 12))
            Stepper("\(booking.minutes) minutes", value: $booking.minutes, in: 5...480, step: 5).font(.system(size: 12))
            Picker("Where", selection: $booking.place) {
                ForEach(UpshowPlace.allCases) { Text($0.label).tag($0) }
            }
            .font(.system(size: 12))
            if [.zoom, .custom, .phone, .inPerson].contains(booking.place) {
                field(booking.place == .zoom ? "Zoom link (blank makes a room)" : booking.place == .custom ? "Link" : "Details", $booking.placeDetail)
            }
            Picker("Reminders", selection: $booking.meetingTypeID) {
                Text("None").tag(String?.none)
                ForEach(store.types) { Text($0.name).tag(String?.some($0.id)) }
            }
            .font(.system(size: 12))
            Toggle("Email the invitation", isOn: $booking.notifyGuests).font(.system(size: 12))
            HStack(spacing: 6) {
                Button("Review") { reviewing = true }.buttonStyle(CalendarButton(strong: true)).disabled(!booking.ready)
                Button("Discard", action: close).buttonStyle(CalendarButton())
            }
        }
    }

    private var review: some View {
        let type = store.types.first { $0.id == booking.meetingTypeID }?.name ?? "No reminders"
        return VStack(alignment: .leading, spacing: 6) {
            line("Guest", "\(booking.guestName), \(booking.guestEmail)")
            line("When", "\(CalendarText.day(booking.start)), \(CalendarText.time(booking.start)), \(booking.minutes) minutes")
            line("Where", booking.place.label)
            line("Reminders", type)
            line("Invitation", booking.notifyGuests ? "Emailed to the guest" : "Not emailed")
            Text(store.live ? "This creates the calendar event and starts the reminders." : "Sample only: nothing is created or sent.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            HStack(spacing: 6) {
                Button(working ? "Scheduling…" : "Schedule", action: schedule)
                    .buttonStyle(CalendarButton(strong: true)).disabled(working)
                Button("Back") { reviewing = false }.buttonStyle(CalendarButton()).disabled(working)
            }
        }
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).frame(width: 68, alignment: .leading)
            Text(value).font(.system(size: 12)).foregroundStyle(.white.opacity(0.9))
        }
    }

    /// The booking keeps its id across tries, so pressing Schedule again after a timeout finds the
    /// first attempt in Upshow instead of booking the guest twice.
    private func schedule() {
        working = true
        problem = nil
        Task { @MainActor in
            do {
                done(try await store.book(booking))
            } catch {
                problem = "\(error.localizedDescription) Pressing Schedule again is safe: it will not book twice."
            }
            working = false
        }
    }
}

// MARK: Bits

struct CalendarButton: ButtonStyle {
    var strong = false
    var danger = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(strong ? .black.opacity(0.85) : danger ? Palette.red : .white.opacity(0.85))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(strong ? .white.opacity(0.92) : danger ? Palette.red.opacity(0.14) : .white.opacity(0.08), in: Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

enum CalendarText {
    private static func format(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(pattern)
        return f
    }
    private static let timeFormat = format("HHmm")
    private static let dayFormat = format("EEEEdMMMM")
    private static let shortFormat = format("EEEd")
    private static let monthFormat = format("dMMM")

    static func time(_ date: Date) -> String { timeFormat.string(from: date) }
    static func day(_ date: Date) -> String { dayFormat.string(from: date) }
    static func dayShort(_ date: Date) -> String { shortFormat.string(from: date) }
    static func weekTitle(_ days: [Date]) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        return "\(monthFormat.string(from: first)) to \(monthFormat.string(from: last))"
    }
}
