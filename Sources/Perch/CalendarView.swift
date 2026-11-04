import AppKit
import SwiftUI

/// Upshow's calendar tokens (the calendar-event-details design), turned to dark so the tab sits
/// with the rest of Perch. Racing green stays the brand; parchment becomes the light ink.
enum UpshowInk {
    private static func hex(_ value: UInt32) -> Color {
        Color(red: Double(value >> 16 & 0xff) / 255, green: Double(value >> 8 & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
    /// Racing green: primary buttons, the today pill, the chevron.
    static let green = hex(0x1A4D2E)
    /// Green that reads on dark: accent text, lines, the now line.
    static let green2 = hex(0x6DB98A)
    /// The canvas behind the card.
    static let cream = hex(0x0D100E)
    /// Cards: the calendar, the meeting card, the booking ticket.
    static let card = hex(0x151917)
    static let line = Color.white.opacity(0.09)
    static let text = hex(0xECE8E0)
    static let muted = hex(0xA39E93)
    static let tertiary = hex(0x7D786D)
    static let softGreen = hex(0x1F3527)
    static let red = hex(0xE08574)
    static let redBg = hex(0x3A201B)
    static let amber = hex(0xD9A35B)
    static let onGreen = hex(0xF7F4EF)
    static let onGreenDim = hex(0xBCD3C4)
    static let placeholder = hex(0x6E6A62)
    static let greenBorder = hex(0x2F5A40)
    static let fill = hex(0x1F2421)
    static let fill2 = hex(0x1A1F1C)
    static let inputBorder = hex(0x353B37)
    static let dashed = hex(0x3C433E)
    static let symbolBg = hex(0x1E2420)
    static let busyA = hex(0x171B18)
    static let busyB = hex(0x1E2320)
    static let busyBorder = hex(0x2A302C)
    static let busyText = hex(0x7D786D)
    /// A meeting on the primary calendar: the green wash, and its hover and open tones.
    static let block = hex(0x1B2A20)
    static let blockHover = hex(0x213428)
    static let blockSelected = hex(0x284030)
    static let blockBorder = hex(0x2C4434)
    /// Status inks, as on Upshow's blocks.
    static let completed = hex(0x7FB08F)
    static let noShow = hex(0xF0B04A)
    static let rescheduled = hex(0x9AA8C6)

    /// Upshow sets titles in Cormorant Garamond; the Mac's own serif stands in for it.
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight, design: .serif) }
}

/// The Calendar tab: Upshow's week, in the island. Click a meeting for its card; click empty time
/// or Add meeting to book one. The store keeps itself fresh in the background, so it never waits.
struct CalendarView: View {
    @Environment(NotchUI.self) private var ui
    private var store: CalendarStore { CalendarStore.shared }
    @State private var chosen: UpshowMeeting?
    /// The booking being made, while its panel is open on the right.
    @State private var draft: UpshowBooking?

    var body: some View {
        // Upshow's own calendar, when it has been built for Perch; otherwise Perch's version.
        if UpshowWebServer.shared.built {
            UpshowWeb()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(height: 452)
        } else {
            native
        }
    }

    private var native: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.live { sampleBanner }
            heading
            CalendarWeekGrid(chosen: chosen?.id, draft: $draft,
                             choose: { meeting in withAnimation(.smooth(duration: 0.18)) { chosen = meeting; draft = nil } },
                             book: startBooking)
                .overlay(alignment: .topTrailing) { sheet.padding(8) }
        }
        .padding(.horizontal, 4)
        .frame(height: 452, alignment: .top)
        .environment(\.colorScheme, .dark)
        .task { await store.refresh() }
        .onChange(of: store.handedSentence, initial: true) { _, sentence in if sentence != nil { startBooking(at: nil) } }
    }

    /// The meeting card or the booking panel, floating over the right of the week.
    @ViewBuilder private var sheet: some View {
        if draft != nil {
            CalendarNewMeeting(booking: Binding(get: { draft ?? UpshowBooking() }, set: { draft = $0 })) {
                withAnimation(.smooth(duration: 0.2)) { draft = nil }
            }
            .padding(12)
            .frame(width: 340)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(UpshowInk.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(UpshowInk.line) }
            .overlay { if store.staged != nil { CalendarBooked(undo: { b in draft = b }, done: finishBooked) } }
            .shadow(color: .black.opacity(0.5), radius: 17, y: 10)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
        } else if let chosen, let current = store.meetings.first(where: { $0.id == chosen.id }) {
            CalendarPeek(meeting: current) { withAnimation(.smooth(duration: 0.16)) { self.chosen = nil } }
                .id(current.id)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
        } else if store.staged != nil {
            CalendarBooked(undo: { b in withAnimation { draft = b } }, done: finishBooked)
                .frame(width: 340, height: 360)
        }
    }

    private var heading: some View {
        HStack(spacing: 8) {
            Text(CalendarText.monthTitle(store.days)).font(UpshowInk.serif(24)).foregroundStyle(UpshowInk.text)
            if let stale = store.stale {
                Image(systemName: "icloud.slash").font(.system(size: 11)).foregroundStyle(UpshowInk.tertiary)
                    .help("Showing the saved copy: \(stale)")
            }
            Spacer()
            Button("Today") { store.goToToday() }.buttonStyle(CalendarButton(outlined: true))
            arrow("chevron.left", "Previous") { store.move(weeks: -1) }
            arrow("chevron.right", "Next") { store.move(weeks: 1) }
            Button { startBooking(at: nil) } label: { Label("Add meeting", systemImage: "plus") }
                .buttonStyle(CalendarButton(strong: true))
                .padding(.leading, 4)
        }
        .padding(.horizontal, 2)
    }

    private func arrow(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(UpshowInk.muted)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(Press(reach: 1)).help(help)
    }

    private func startBooking(at start: Date?) {
        var booking = draft ?? CalendarView.freshBooking()
        if let start {
            booking.start = start
            booking.hasTime = true
        }
        withAnimation(.smooth(duration: 0.2)) { chosen = nil; draft = booking }
    }

    static func freshBooking() -> UpshowBooking {
        var booking = UpshowBooking()
        let types = CalendarStore.shared.types
        if let type = types.first(where: \.isDefault) ?? types.first {
            booking.sequence = .some(type.id)
            booking.minutes = type.defaultMinutes ?? 30
        }
        return booking
    }

    private func finishBooked(_ made: UpshowMeeting?) {
        store.clearStaged()
        withAnimation(.smooth(duration: 0.2)) {
            draft = nil
            if let made {
                store.reveal(made.start)
                chosen = made
            }
        }
    }

    @State private var connecting = false
    @State private var connectProblem: String?

    /// Until Upshow is connected: sample meetings, and the button that connects it.
    private var sampleBanner: some View {
        HStack(spacing: 8) {
            Label(connectProblem ?? (connecting ? "Finish signing in to Upshow in your browser…"
                                     : "Sample diary: nothing here is real and nothing is sent."),
                  systemImage: connectProblem == nil ? "info.circle" : "exclamationmark.triangle")
                .font(.system(size: 11.5)).foregroundStyle(connectProblem == nil ? UpshowInk.green2 : UpshowInk.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(connecting ? "Waiting…" : "Connect Upshow") { connect() }
                .buttonStyle(CalendarButton(strong: true)).disabled(connecting)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(UpshowInk.softGreen, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
}

// MARK: The week

private struct CalendarWeekGrid: View {
    let chosen: String?
    @Binding var draft: UpshowBooking?
    let choose: (UpshowMeeting) -> Void
    /// A click on empty time: book a meeting starting there.
    let book: (Date) -> Void
    private var store: CalendarStore { CalendarStore.shared }

    static let hourHeight: CGFloat = 48
    static let pad: CGFloat = 14
    static let gutter: CGFloat = 48

    var body: some View {
        VStack(spacing: 0) {
            dayHeads
            Rectangle().fill(UpshowInk.line).frame(height: 1)
            if case .failed(let reason) = store.phase {
                CalendarUnavailable(reason: reason).padding(16)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 0) {
                            hours
                            ForEach(store.days, id: \.self) { day in
                                CalendarDayColumn(day: day, chosen: chosen, draft: $draft, choose: choose, book: book)
                                    .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.04)).frame(width: 1) }
                            }
                        }
                        .frame(height: Self.hourHeight * 24 + Self.pad * 2)
                        .background(alignment: .top) {
                            VStack(spacing: 0) {
                                ForEach(0..<24, id: \.self) { hour in Color.clear.frame(height: Self.hourHeight).id(hour) }
                            }
                            .padding(.top, Self.pad)
                        }
                    }
                    .onAppear { anchor(proxy) }
                    .onChange(of: store.week) { anchor(proxy) }
                    .onChange(of: draft?.start) { _, start in
                        if let start { withAnimation(.smooth) { proxy.scrollTo(max(Calendar.current.component(.hour, from: start) - 2, 0), anchor: .top) } }
                    }
                }
            }
        }
        .background(UpshowInk.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(UpshowInk.line) }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Now, an hour from the top, in this week; otherwise the working day, or its first meeting.
    private func anchor(_ proxy: ScrollViewProxy) {
        let now = Date()
        let hour: Int
        if store.days.contains(where: { Calendar.current.isDate($0, inSameDayAs: now) }) {
            hour = max(Calendar.current.component(.hour, from: now) - 1, 0)
        } else {
            let first = store.meetings.map { Calendar.current.component(.hour, from: $0.start) }.min() ?? 8
            hour = min(8, first)
        }
        proxy.scrollTo(hour, anchor: .top)
    }

    private var dayHeads: some View {
        HStack(spacing: 0) {
            Text(TimeZone.current.abbreviation() ?? "").font(.system(size: 10, weight: .medium)).foregroundStyle(UpshowInk.tertiary)
                .frame(width: Self.gutter)
                .help(TimeZone.current.localizedName(for: .generic, locale: .current) ?? TimeZone.current.identifier)
            ForEach(store.days, id: \.self) { day in
                let today = Calendar.current.isDateInToday(day)
                HStack(spacing: 5) {
                    Text(CalendarText.weekday(day)).font(.system(size: 13, weight: today ? .medium : .regular))
                        .foregroundStyle(today ? UpshowInk.text : UpshowInk.muted)
                    Text(CalendarText.dayNumber(day)).font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(today ? Color.white : UpshowInk.muted)
                        .padding(.horizontal, today ? 6 : 0).padding(.vertical, 1)
                        .background(today ? UpshowInk.green : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
        }
    }

    private var hours: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(1..<24, id: \.self) { hour in
                Text(String(format: "%02d:00", hour)).font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(UpshowInk.tertiary)
                    .padding(.trailing, 6)
                    .frame(height: 12)
                    .offset(y: Self.pad + CGFloat(hour) * Self.hourHeight - 6)
            }
            if store.days.contains(where: { Calendar.current.isDateInToday($0) }) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let start = Calendar.current.startOfDay(for: context.date)
                    Text(CalendarText.time(context.date)).font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(UpshowInk.green, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(.trailing, 3)
                        .offset(y: Self.pad + CGFloat(context.date.timeIntervalSince(start) / 3600) * Self.hourHeight - 8)
                }
            }
        }
        .frame(width: Self.gutter, height: Self.hourHeight * 24 + Self.pad * 2, alignment: .topTrailing)
    }
}

private struct CalendarDayColumn: View {
    let day: Date
    let chosen: String?
    @Binding var draft: UpshowBooking?
    let choose: (UpshowMeeting) -> Void
    let book: (Date) -> Void
    private var store: CalendarStore { CalendarStore.shared }
    private var hourHeight: CGFloat { CalendarWeekGrid.hourHeight }
    private var pad: CGFloat { CalendarWeekGrid.pad }
    @State private var dragStart: Date?

    private var start: Date { Calendar.current.startOfDay(for: day) }
    private var next: Date { start.addingTimeInterval(86400) }

    private func y(_ date: Date) -> CGFloat {
        CGFloat(min(max(date.timeIntervalSince(start) / 3600, 0), 24)) * hourHeight + pad
    }

    /// The time at a height in the day, to the quarter hour.
    private func time(at y: CGFloat) -> Date {
        let quarters = ((y - pad) / hourHeight * 4).rounded(.down)
        return start.addingTimeInterval(Double(min(max(quarters, 0), 95)) * 900)
    }

    var body: some View {
        let meetings = store.meetings.filter { $0.start < next && $0.end > start }
        let layers = CalendarLayers.make(meetings)
        GeometryReader { box in
            // The right-hand twelve points stay clear, for clicking a new meeting in beside one.
            let width = box.size.width - 2 - 12
            ZStack(alignment: .topLeading) {
                lines(width: box.size.width)
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { point in book(time(at: point.y)) }
                ForEach(Array(store.busy.filter { !$0.allDay && $0.start < next && $0.end > start }.enumerated()), id: \.offset) { _, block in
                    CalendarBusy(minutes: block.end.timeIntervalSince(block.start) / 60)
                        .frame(width: box.size.width - 4, height: max(y(block.end) - y(block.start), 4))
                        .offset(x: 2, y: y(block.start))
                        .allowsHitTesting(false)
                }
                ForEach(meetings) { meeting in
                    let layer = layers[meeting.id] ?? CalendarLayers.Place(x: 0, width: 1, depth: 0)
                    CalendarBlock(meeting: meeting, height: max(y(meeting.end) - y(meeting.start) - 2, 26),
                                  picked: meeting.id == chosen, layered: layer.depth > 0) { choose(meeting) }
                        .frame(width: max(width * layer.width - 2, 20))
                        .offset(x: 2 + width * layer.x, y: y(meeting.start))
                        .zIndex(meeting.id == chosen ? 6 : Double(1 + min(layer.depth, 2)))
                }
                if let booking = draft, let begin = booking.start, booking.hasTime,
                   Calendar.current.isDate(begin, inSameDayAs: day), let end = booking.end {
                    ghost(booking, height: max(y(end) - y(begin), 26))
                        .frame(width: width)
                        .offset(x: 2, y: y(begin))
                        .zIndex(8)
                }
                if Calendar.current.isDateInToday(day) { now }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func lines(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(1..<24, id: \.self) { hour in
                Rectangle().fill(Color.white.opacity(0.05)).frame(width: width, height: 1)
                    .offset(y: CGFloat(hour) * hourHeight + pad)
            }
        }
        .allowsHitTesting(false)
    }

    /// The meeting being booked, where it would go: solid green, rust on a clash. Drag it to move it.
    private func ghost(_ booking: UpshowBooking, height: CGFloat) -> some View {
        let clash = store.clash(for: booking) != nil
        return VStack(alignment: .leading, spacing: 1) {
            Text("New · \(booking.guests.first?.label ?? "meeting")").font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
            if let begin = booking.start, let end = booking.end, height >= 38 {
                Text("\(CalendarText.time(begin)) to \(CalendarText.time(end))").font(.system(size: 10).monospacedDigit()).opacity(0.75)
            }
        }
        .foregroundStyle(UpshowInk.onGreen)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .topLeading)
        .background(clash ? UpshowInk.red.opacity(0.85) : UpshowInk.green, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(UpshowInk.green2.opacity(0.5), lineWidth: 1) }
        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { drag in
                guard let begin = draft?.start else { return }
                if dragStart == nil { dragStart = begin }
                let moved = (dragStart ?? begin).addingTimeInterval((drag.translation.height / hourHeight * 4).rounded() * 900)
                if Calendar.current.isDate(moved, inSameDayAs: day), moved != begin { draft?.start = moved }
            }
            .onEnded { _ in dragStart = nil })
        .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
        .animation(.smooth(duration: 0.12), value: booking.start)
    }

    private var now: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 0) {
                Circle().fill(UpshowInk.green2).frame(width: 7, height: 7)
                Rectangle().fill(UpshowInk.green2).frame(height: 1)
            }
            .offset(x: -3, y: y(context.date) - 3.5)
        }
        .allowsHitTesting(false)
        .zIndex(4)
    }
}

/// Busy time from the other calendars: hatched, marked BUSY when there is room.
private struct CalendarBusy: View {
    let minutes: Double

    var body: some View {
        ZStack(alignment: .leading) {
            UpshowInk.busyA
            Hatch().stroke(UpshowInk.busyB, lineWidth: 5)
            if minutes >= 30 {
                Text("BUSY").font(.system(size: 10, weight: .medium)).kerning(0.6).foregroundStyle(UpshowInk.busyText).padding(.horizontal, 6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(UpshowInk.busyBorder) }
    }

    private struct Hatch: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                var x = -rect.height
                while x < rect.width {
                    path.move(to: CGPoint(x: x, y: rect.height))
                    path.addLine(to: CGPoint(x: x + rect.height, y: 0))
                    x += 10
                }
            }
        }
    }
}

/// One meeting, as Upshow draws it: its title, then the time, on a green wash; the chevron when
/// Upshow is sending its reminders.
private struct CalendarBlock: View {
    let meeting: UpshowMeeting
    let height: CGFloat
    let picked: Bool
    let layered: Bool
    let action: () -> Void
    @State private var hovered = false

    private var ink: Color {
        switch meeting.status ?? "confirmed" {
        case "completed", "attended_by_colleague": return UpshowInk.completed
        case "no_show": return UpshowInk.noShow
        case "rescheduled": return UpshowInk.rescheduled
        default: return UpshowInk.text
        }
    }

    var body: some View {
        let past = meeting.end < Date()
        let minutes = meeting.end.timeIntervalSince(meeting.start) / 60
        let name = meeting.title.isEmpty ? "Meeting" : meeting.title
        Button(action: action) {
            Group {
                if minutes < 45 {
                    HStack(spacing: 5) {
                        Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(ink).lineLimit(1)
                        Text(CalendarText.time(meeting.start)).font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(ink == UpshowInk.text ? UpshowInk.muted : ink).opacity(0.75)
                            .layoutPriority(-1)
                        Spacer(minLength: 0)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(ink)
                            .lineLimit(minutes >= 120 ? 4 : minutes >= 90 ? 3 : 2)
                        Text("\(CalendarText.time(meeting.start))–\(CalendarText.time(meeting.end))")
                            .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(ink == UpshowInk.text ? UpshowInk.muted : ink).opacity(0.75)
                    }
                }
            }
            .padding(.leading, 7).padding(.trailing, meeting.protected ? 20 : 7).padding(.vertical, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(height: height)
            .background(picked ? UpshowInk.blockSelected : hovered ? UpshowInk.blockHover : UpshowInk.block,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if meeting.protected { UpshowChevron().frame(width: 14, height: 14).padding(3).help("Protected by Upshow: it is sending this meeting's reminders, so the people booked in turn up.") }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(picked ? UpshowInk.blockBorder : layered ? UpshowInk.card : .clear, lineWidth: 1)
            }
            .overlay {
                if hovered && !picked {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(UpshowInk.green2.opacity(0.45), lineWidth: 1).padding(-1)
                }
            }
            .opacity(past ? (meeting.protected ? 0.75 : 0.6) : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.14), value: hovered)
    }
}

/// Upshow's mark: two chevrons, the lower one faint.
struct UpshowChevron: View {
    var color = UpshowInk.green2

    var body: some View {
        Canvas { context, size in
            let s = size.width / 32
            func chevron(_ top: CGFloat) -> Path {
                Path { p in
                    p.move(to: CGPoint(x: 16 * s, y: top * s))
                    p.addLine(to: CGPoint(x: 7 * s, y: (top + 11) * s))
                    p.addLine(to: CGPoint(x: 25 * s, y: (top + 11) * s))
                    p.closeSubpath()
                }
            }
            context.fill(chevron(6.5), with: .color(color))
            context.fill(chevron(13.5), with: .color(color.opacity(0.4)))
        }
    }
}

/// Overlapping meetings, layered as Upshow does: one that starts while another is running sits on
/// top of it, stepped in, and runs to the right edge.
enum CalendarLayers {
    struct Place { let x: CGFloat; let width: CGFloat; let depth: Int }

    static func make(_ meetings: [UpshowMeeting]) -> [String: Place] {
        var out: [String: Place] = [:]
        var running: [(end: Date, depth: Int)] = []
        for meeting in meetings.sorted(by: { ($0.start, $1.end) < ($1.start, $0.end) }) {
            running.removeAll { $0.end <= meeting.start }
            let depth = min((running.map(\.depth).max() ?? -1) + 1, 4)
            let x = running.isEmpty ? 0 : min(CGFloat(depth) * 0.14, 0.7)
            out[meeting.id] = Place(x: x, width: 1 - x, depth: running.isEmpty ? 0 : depth)
            running.append((meeting.end, running.isEmpty ? 0 : depth))
        }
        return out
    }
}

/// A fetch that failed must not look like an empty, free week.
private struct CalendarUnavailable: View {
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Calendar unavailable", systemImage: "exclamationmark.triangle").font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(UpshowInk.red)
            Text(reason).font(.system(size: 11.5)).foregroundStyle(UpshowInk.muted)
            Button("Try again") { Task { await CalendarStore.shared.refresh() } }.buttonStyle(CalendarButton(outlined: true))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UpshowInk.redBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: One meeting

/// The meeting's card: when, who, where (with Join), and moving or cancelling it.
private struct CalendarPeek: View {
    let meeting: UpshowMeeting
    let close: () -> Void
    private enum Mode { case view, moving, cancelling }
    @State private var mode = Mode.view
    @State private var newStart = Date()
    @State private var minutes = 30
    @State private var sendSequence = false
    @State private var working = false
    @State private var problem: String?
    @State private var copied = false
    private var store: CalendarStore { CalendarStore.shared }

    private var join: (URL, String)? {
        meeting.link.map { ($0, "Video call") } ?? MeetingWatch.shared.joinLink(start: meeting.start, guestEmail: meeting.guestEmail)
    }

    private var label: (String, Color) {
        switch meeting.status ?? "confirmed" {
        case "no_show": return ("No-show", UpshowInk.red)
        case "prospect_cancelled": return ("Cancelled by them", UpshowInk.red)
        case "cancelled": return ("Cancelled", UpshowInk.red)
        case "rescheduled": return ("Rescheduled", UpshowInk.red)
        case "attended_by_colleague": return ("Attended (colleague)", UpshowInk.red)
        case "completed": return ("Completed", UpshowInk.red)
        default: return ("Meeting", UpshowInk.muted)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label.0).font(.system(size: 12.5, weight: .medium)).foregroundStyle(label.1)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(UpshowInk.tertiary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(Press(reach: 1)).help("Close")
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.top, 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title.isEmpty ? meeting.guest : meeting.title).font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(UpshowInk.text).lineLimit(2)
                if !meeting.company.isEmpty { Text(meeting.company).font(.system(size: 12.5)).foregroundStyle(UpshowInk.muted) }
            }
            .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 10)
            switch mode {
            case .view: details
            case .moving: section { moving }
            case .cancelling: section { cancelling }
            }
            if let problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(UpshowInk.red).padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .frame(width: 340, alignment: .leading)
        .background(UpshowInk.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(UpshowInk.line) }
        .shadow(color: .black.opacity(0.5), radius: 17, y: 10)
    }

    private func section<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(UpshowInk.line).frame(height: 1)
            content().padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private func row<V: View>(_ icon: String?, @ViewBuilder _ content: () -> V) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Group { if let icon { Image(systemName: icon) } else { Color.clear } }
                .font(.system(size: 13)).foregroundStyle(UpshowInk.tertiary).frame(width: 16)
            content().font(.system(size: 13.5)).foregroundStyle(UpshowInk.text)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
    }

    @ViewBuilder private var details: some View {
        section {
            row("clock") {
                HStack(spacing: 7) {
                    Text(CalendarText.time(meeting.start)).monospacedDigit()
                    Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(UpshowInk.tertiary)
                    Text(CalendarText.time(meeting.end)).monospacedDigit()
                    Text("\(Int(meeting.end.timeIntervalSince(meeting.start) / 60))m").font(.system(size: 12.5)).foregroundStyle(UpshowInk.tertiary)
                }
            }
            row(nil) { Text(CalendarText.day(meeting.start)) }
            if let zone = meeting.guestTimeZone.flatMap(TimeZone.init(identifier:)), zone.secondsFromGMT(for: meeting.start) != TimeZone.current.secondsFromGMT(for: meeting.start) {
                row("globe") {
                    Text("\(CalendarText.time(meeting.start, in: zone)) for them, \(zone.localizedName(for: .shortGeneric, locale: .current) ?? zone.identifier)")
                }
            }
        }
        section {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(meeting.guest.isEmpty ? "No guest" : meeting.guest).font(.system(size: 13.5)).foregroundStyle(UpshowInk.text).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(meeting.remindersOff == true ? "No reminders" : store.sequenceName(meeting.sequenceID) ?? "Sequence")
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .foregroundStyle(meeting.remindersOff == true ? UpshowInk.muted : UpshowInk.green2)
                        .padding(.horizontal, 9).padding(.vertical, 2)
                        .background(UpshowInk.card, in: Capsule())
                        .overlay { Capsule().strokeBorder(UpshowInk.line) }
                        .frame(maxWidth: 150, alignment: .trailing)
                }
                if !meeting.guestEmail.isEmpty, meeting.guestEmail != meeting.guest {
                    Text(meeting.guestEmail).font(.system(size: 12)).foregroundStyle(UpshowInk.muted).textSelection(.enabled)
                }
                status
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(UpshowInk.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.bottom, 2)
        }
        section {
            if let (link, service) = join {
                row("video") {
                    HStack(spacing: 8) {
                        Text(service)
                        Spacer(minLength: 0)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link.absoluteString, forType: .string)
                            copied = true
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11)).foregroundStyle(UpshowInk.muted)
                                .frame(width: 24, height: 24)
                                .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(UpshowInk.line) }
                        }
                        .buttonStyle(Press(reach: 1)).help("Copy the link")
                        Button("Join") { NSWorkspace.shared.open(link) }
                            .buttonStyle(CalendarButton(strong: true, compact: true))
                    }
                }
            } else {
                row("video") { Text("No conferencing link").foregroundStyle(UpshowInk.tertiary) }
            }
        }
        if meeting.end > Date(), ["confirmed", "rescheduled"].contains(meeting.status ?? "confirmed") {
            section {
                HStack(spacing: 6) {
                    Button("Reschedule") {
                        newStart = max(meeting.start, Date().addingTimeInterval(900))
                        minutes = max(5, Int(meeting.end.timeIntervalSince(meeting.start) / 60))
                        withAnimation(.smooth(duration: 0.18)) { mode = .moving }
                    }
                    .buttonStyle(CalendarButton(outlined: true))
                    Button("Cancel meeting") { withAnimation(.smooth(duration: 0.18)) { mode = .cancelling } }
                        .buttonStyle(CalendarButton(danger: true))
                }
            }
        }
        Text(footer).font(.system(size: 12)).foregroundStyle(UpshowInk.tertiary)
            .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 10)
    }

    /// What Upshow is doing for this guest, worded as Upshow does.
    @ViewBuilder private var status: some View {
        let (text, tint): (String, Color) = {
            if meeting.guestReplied == true { return (meeting.sequencePaused == true ? "Replied · reminders paused" : "Replied", UpshowInk.green2) }
            if meeting.sequencePaused == true { return ("Reminders paused", UpshowInk.amber) }
            if meeting.remindersOff == true { return ("No reminders scheduled", UpshowInk.muted) }
            if meeting.end < Date() { return ("All sent, no reply", UpshowInk.muted) }
            return ("No reply yet", UpshowInk.muted)
        }()
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(tint)
    }

    private var footer: String {
        let source: String
        switch meeting.platform ?? "manual" {
        case "cal_com": source = "Cal.com"
        case "calendly": source = "Calendly"
        case "google": source = "Google Calendar"
        case "outlook": source = "Outlook"
        default: source = "Added by hand"
        }
        return meeting.wonBack == true ? "\(source) · rebooked after a follow-up" : source
    }

    private var moving: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("MOVE IT TO").font(.system(size: 10.5, weight: .medium)).kerning(0.5).foregroundStyle(UpshowInk.tertiary)
            CalendarDayChips(selection: Binding(get: { newStart }, set: { newStart = CalendarText.keepTime(of: newStart, on: $0) }))
            HStack(spacing: 10) {
                DatePicker("", selection: $newStart, displayedComponents: .hourAndMinute).labelsHidden().datePickerStyle(.stepperField)
                CalendarLength(minutes: $minutes)
            }
            Label("Reminders are replanned around the new time.", systemImage: "bell.and.waves.left.and.right")
                .font(.system(size: 12)).foregroundStyle(UpshowInk.muted)
            if newStart <= Date() {
                Text("That time has already gone. Pick one ahead.").font(.system(size: 12)).foregroundStyle(UpshowInk.amber)
            }
            HStack(spacing: 6) {
                Button(working ? "Moving…" : "Move to \(CalendarText.weekday(newStart)) \(CalendarText.dayMonth(newStart)), \(CalendarText.time(newStart))") {
                    run { try await CalendarStore.shared.reschedule(meeting.id, to: newStart, minutes: minutes) }
                }
                .buttonStyle(CalendarButton(strong: true)).disabled(working || newStart <= Date())
                Button("Keep the old time") { mode = .view }.buttonStyle(CalendarButton())
            }
        }
    }

    private var cancelling: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cancel this meeting with \(meeting.guest.isEmpty ? "the guest" : meeting.guest)?")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(UpshowInk.text)
            Toggle("Send the cancellation sequence", isOn: $sendSequence).font(.system(size: 12)).foregroundStyle(UpshowInk.text)
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
            } catch CalendarProblem.awaitingApproval {
                problem = CalendarProblem.awaitingApproval.localizedDescription
                mode = .view
            } catch {
                await CalendarStore.shared.refresh()
                problem = "\(error.localizedDescription) Check the meeting before trying again."
            }
            working = false
        }
    }
}

// MARK: Ticket pieces (the booking panel)

/// Upshow's booking ticket: the sequence across the top, a dashed tear line, then the slots.
struct CalendarTicket<Content: View>: View {
    let heading: String
    var change: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                UpshowChevron().frame(width: 13, height: 13)
                Text(heading.uppercased()).font(.system(size: 11.5, weight: .semibold)).kerning(1).foregroundStyle(UpshowInk.green2).lineLimit(1)
                Spacer(minLength: 4)
                if let change {
                    Button("Change", action: change).buttonStyle(CalendarPill())
                }
            }
            .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 10)
            Dash().stroke(UpshowInk.dashed, style: StrokeStyle(lineWidth: 1, dash: [5, 4])).frame(height: 1)
            content
        }
        .background(UpshowInk.fill2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(UpshowInk.line) }
    }

    private struct Dash: Shape {
        func path(in rect: CGRect) -> Path { Path { $0.move(to: CGPoint(x: 0, y: 0.5)); $0.addLine(to: CGPoint(x: rect.width, y: 0.5)) } }
    }
}

/// The hairline between slots.
struct CalendarRule: View {
    var body: some View { Rectangle().fill(UpshowInk.line).frame(height: 1).padding(.horizontal, 14) }
}

/// One slot on the ticket: a small label over its value.
struct CalendarSlot<Content: View>: View {
    let label: String
    var open = false
    var action: (() -> Void)?
    @ViewBuilder let content: Content
    @State private var hovered = false

    var body: some View {
        let inner = VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.system(size: 10, weight: .medium)).kerning(0.6).foregroundStyle(UpshowInk.tertiary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(open || (hovered && action != nil) ? UpshowInk.fill : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        if let action {
            Button(action: action) { inner }.buttonStyle(.plain)
        } else {
            inner
        }
    }
}

/// Today, tomorrow and the twelve days after, as chips.
struct CalendarDayChips: View {
    @Binding var selection: Date

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(0..<14, id: \.self) { offset in
                    let day = Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date()))!
                    let on = Calendar.current.isDate(day, inSameDayAs: selection)
                    Button { selection = day } label: {
                        VStack(spacing: 0) {
                            Text(offset == 0 ? "Today" : offset == 1 ? "Tmrw" : CalendarText.weekday(day))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(on ? UpshowInk.onGreenDim : UpshowInk.tertiary)
                            Text(CalendarText.dayNumber(day)).font(.system(size: 15, weight: .medium))
                                .foregroundStyle(on ? UpshowInk.onGreen : UpshowInk.text)
                        }
                        .frame(width: 44, height: 42)
                        .background(on ? UpshowInk.green : UpshowInk.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(Press(reach: 1))
                }
            }
        }
    }
}

/// Five-minute steps.
struct CalendarLength: View {
    @Binding var minutes: Int

    var body: some View {
        HStack(spacing: 6) {
            step("minus") { minutes = max(5, minutes - 5) }
            Text("\(minutes) min").font(.system(size: 14, weight: .medium)).monospacedDigit().foregroundStyle(UpshowInk.text).frame(minWidth: 60)
            step("plus") { minutes = min(480, minutes + 5) }
        }
    }

    private func step(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(UpshowInk.green2)
                .frame(width: 26, height: 26).background(UpshowInk.fill, in: Circle())
        }
        .buttonStyle(Press(reach: 1))
    }
}

// MARK: Bits

struct CalendarButton: ButtonStyle {
    var strong = false
    var danger = false
    var outlined = false
    var compact = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12.5 : 13, weight: strong ? .semibold : .medium))
            .foregroundStyle(strong ? UpshowInk.onGreen : danger ? UpshowInk.red : UpshowInk.text)
            .padding(.horizontal, compact ? 12 : 14).frame(height: compact ? 26 : 30)
            .background(strong ? UpshowInk.green : danger ? UpshowInk.redBg : outlined ? .clear : UpshowInk.fill,
                        in: RoundedRectangle(cornerRadius: compact ? 8 : 9, style: .continuous))
            .overlay {
                if outlined { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.14)) }
            }
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// The small "Change" pill on the ticket.
struct CalendarPill: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(UpshowInk.green2)
            .padding(.horizontal, 10).frame(height: 24)
            .overlay { Capsule().strokeBorder(UpshowInk.greenBorder) }
            .opacity(configuration.isPressed ? 0.7 : 1)
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
    private static let longMonthFormat = format("dMMMM")
    private static let weekdayFormat = format("EEE")
    private static let numberFormat = format("d")
    private static let monthYear = format("MMMMyyyy")
    private static let monthOnly = format("MMMM")
    private static let yearOnly = format("yyyy")

    static func time(_ date: Date) -> String { timeFormat.string(from: date) }
    static func time(_ date: Date, in zone: TimeZone) -> String {
        let f = format("HHmm")
        f.timeZone = zone
        return f.string(from: date)
    }
    static func day(_ date: Date) -> String { dayFormat.string(from: date) }
    static func dayShort(_ date: Date) -> String { shortFormat.string(from: date) }
    static func weekday(_ date: Date) -> String { weekdayFormat.string(from: date) }
    static func dayNumber(_ date: Date) -> String { numberFormat.string(from: date) }
    static func dayMonth(_ date: Date) -> String { monthFormat.string(from: date) }

    /// "November 2026", or "October to November 2026" when the week spans two months.
    static func monthTitle(_ days: [Date]) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        if Calendar.current.isDate(first, equalTo: last, toGranularity: .month) { return monthYear.string(from: first) }
        if Calendar.current.isDate(first, equalTo: last, toGranularity: .year) {
            return "\(monthOnly.string(from: first)) to \(monthYear.string(from: last))"
        }
        return "\(monthYear.string(from: first)) to \(monthYear.string(from: last))"
    }

    /// "Today · 3 Nov", "Tomorrow · 4 Nov" or "Thu 5 Nov", for the ticket.
    static func relativeDay(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today · \(monthFormat.string(from: date))" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow · \(monthFormat.string(from: date))" }
        return "\(weekday(date)) \(monthFormat.string(from: date))"
    }

    /// The same clock time on another day.
    static func keepTime(of time: Date, on day: Date) -> Date {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return Calendar.current.date(bySettingHour: parts.hour ?? 9, minute: parts.minute ?? 0, second: 0, of: day) ?? day
    }
}
