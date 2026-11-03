import AppKit
import SwiftUI

/// Upshow's own tokens (frontend/src/mobile/mobile.css), so the tab is Upshow inside Perch.
enum UpshowInk {
    private static func hex(_ value: UInt32) -> Color {
        Color(red: Double(value >> 16 & 0xff) / 255, green: Double(value >> 8 & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
    static let green = hex(0x173f2b)
    static let green2 = hex(0x245c3d)
    static let cream = hex(0xf5f1e9)
    static let card = hex(0xfffdf9)
    static let line = hex(0xe4ddd1)
    static let text = hex(0x1c211e)
    static let muted = hex(0x6c706c)
    static let softGreen = hex(0xe8f1eb)
    static let red = hex(0x9a4338)
    static let redBg = hex(0xf7e9e6)
    static let amber = hex(0xa66b22)
    static let onGreen = hex(0xf7f4ec)
    static let onGreenDim = hex(0xbcd3c4)
    static let placeholder = hex(0xb4b0a5)
    static let greenBorder = hex(0xcdddd2)
    static let fill = hex(0xf1ece2)
    static let fill2 = hex(0xf3efe6)
    static let inputBorder = hex(0xd7cfc0)
    static let dashed = hex(0xc8c1b2)
    static let symbolBg = hex(0xecefe7)
    static let busyA = hex(0xf5f0e8)
    static let busyB = hex(0xede7da)
    static let busyBorder = hex(0xddd5c4)
    static let busyText = hex(0x8a8578)
    /// A meeting block: soft green mixed into the card, edged with a hint of green.
    static let block = hex(0xedf4ee)
    static let blockBorder = hex(0xc9d6c9)

    /// Upshow sets values in Cormorant Garamond; the Mac's own serif stands in for it.
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight, design: .serif) }
}

/// The Calendar tab, laid out like Upshow's own calendar: the week ribbon and the day's meetings
/// on the left, the day itself on the right. A meeting or a new booking takes over the left.
/// The store keeps itself fresh in the background, so opening the tab never waits.
struct CalendarView: View {
    @Environment(NotchUI.self) private var ui
    private var store: CalendarStore { CalendarStore.shared }
    @State private var chosen: UpshowMeeting?
    /// The booking being made, while the panel is open on it.
    @State private var draft: UpshowBooking?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.live { sampleBanner }
            HStack(alignment: .top, spacing: 12) {
                side
                    .frame(width: 330)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .overlay {
                        if store.staged != nil {
                            CalendarBooked(undo: { booking in withAnimation(.smooth(duration: 0.25)) { draft = booking } },
                                           done: finishBooked)
                        }
                    }
                    .animation(.smooth(duration: 0.28), value: store.staged == nil)
                CalendarDayGrid(chosen: chosen?.id, draft: $draft, choose: { meeting in
                    withAnimation(.smooth(duration: 0.22)) { chosen = meeting; draft = nil }
                }, book: startBooking)
            }
        }
        .padding(12)
        .frame(height: 452, alignment: .top)
        .background(UpshowInk.cream, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .environment(\.colorScheme, .light)
        .task { await store.refresh() }
        .onChange(of: store.handedSentence, initial: true) { _, sentence in if sentence != nil { startBooking(at: nil) } }
    }

    private func startBooking(at start: Date?) {
        var booking = draft ?? CalendarView.freshBooking()
        if let start {
            booking.start = start
            booking.hasTime = true
        } else if booking.start == nil {
            booking.start = store.selectedDay
        }
        withAnimation(.smooth(duration: 0.25)) { chosen = nil; draft = booking }
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
        withAnimation(.smooth(duration: 0.25)) {
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
        .background(UpshowInk.softGreen, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        if draft != nil {
            CalendarNewMeeting(booking: Binding(get: { draft ?? UpshowBooking() }, set: { draft = $0 })) {
                withAnimation(.smooth(duration: 0.25)) { draft = nil }
            }
            .transition(.opacity.combined(with: .offset(x: -12)))
        } else if let chosen, let current = store.meetings.first(where: { $0.id == chosen.id }) {
            CalendarMeetingCard(meeting: current) { withAnimation(.smooth(duration: 0.22)) { self.chosen = nil } }
                .transition(.opacity.combined(with: .offset(x: -12)))
        } else {
            VStack(spacing: 10) {
                CalendarRibbon()
                CalendarAgenda(choose: { meeting in withAnimation(.smooth(duration: 0.22)) { chosen = meeting } })
            }
            .transition(.opacity)
        }
    }
}

// MARK: Week ribbon

/// The week as seven chips: the selected day on a green thumb that slides, today on soft green,
/// and a dot per meeting (up to four) or "free".
private struct CalendarRibbon: View {
    private var store: CalendarStore { CalendarStore.shared }
    @Namespace private var thumb

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                arrow("chevron.left") { store.move(weeks: -1) }
                Button("Today") { store.goToToday() }
                    .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(UpshowInk.green2)
                    .padding(.horizontal, 6)
                Spacer(minLength: 0)
                if let stale = store.stale {
                    Image(systemName: "icloud.slash").font(.system(size: 10)).foregroundStyle(UpshowInk.muted).help("Showing the saved copy: \(stale)")
                }
                Text(CalendarText.weekTitle(store.days)).font(.system(size: 12.5)).foregroundStyle(UpshowInk.muted)
                arrow("chevron.right") { store.move(weeks: 1) }
            }
            .frame(height: 34)
            .padding(.horizontal, 2)
            HStack(spacing: 3) {
                ForEach(store.days, id: \.self) { day in chip(day) }
            }
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .background(UpshowInk.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(UpshowInk.line) }
    }

    private func arrow(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(UpshowInk.green2)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(Press(reach: 1))
    }

    private func chip(_ day: Date) -> some View {
        let selected = Calendar.current.isDate(day, inSameDayAs: store.selectedDay)
        let today = Calendar.current.isDateInToday(day)
        let count = store.meetings.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }.count
        return Button {
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.18)) { store.selectedDay = Calendar.current.startOfDay(for: day) }
        } label: {
            VStack(spacing: 3) {
                Text(CalendarText.weekdayLetter(day)).font(.system(size: 11)).foregroundStyle(selected ? UpshowInk.softGreen : UpshowInk.muted)
                Text(CalendarText.dayNumber(day)).font(.system(size: 16, weight: .medium)).foregroundStyle(selected ? UpshowInk.card : UpshowInk.text)
                if count == 0 {
                    Text("free").font(.system(size: 10.5)).foregroundStyle(selected ? UpshowInk.onGreenDim : UpshowInk.line)
                } else {
                    HStack(spacing: 2) {
                        ForEach(0..<min(4, count), id: \.self) { _ in
                            Circle().fill(selected ? UpshowInk.card : UpshowInk.green2).frame(width: 4, height: 4)
                        }
                    }
                    .frame(height: 12)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background {
                ZStack {
                    if today { RoundedRectangle(cornerRadius: 11, style: .continuous).fill(UpshowInk.softGreen) }
                    if selected {
                        RoundedRectangle(cornerRadius: 11, style: .continuous).fill(UpshowInk.green)
                            .matchedGeometryEffect(id: "thumb", in: thumb)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(CalendarText.day(day)), \(count == 1 ? "1 meeting" : "\(count) meetings")")
    }
}

// MARK: The day's meetings

private struct CalendarAgenda: View {
    let choose: (UpshowMeeting) -> Void
    private var store: CalendarStore { CalendarStore.shared }

    var body: some View {
        let day = store.selectedDay
        let meetings = store.meetings.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
        VStack(alignment: .leading, spacing: 6) {
            switch store.phase {
            case .loading:
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(UpshowInk.fill).frame(height: 54)
                }
            case .failed(let reason):
                CalendarUnavailable(reason: reason)
            case .ready:
                if meetings.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Nothing booked").font(UpshowInk.serif(19, .medium)).italic().foregroundStyle(UpshowInk.placeholder)
                        Text("Click a time on the day to book a meeting there.")
                            .font(.system(size: 11.5)).foregroundStyle(UpshowInk.muted)
                    }
                    .padding(.horizontal, 4).padding(.top, 6)
                }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(meetings) { row($0) }
                    }
                    .padding(.vertical, 1)
                }
                .defaultScrollAnchor(.top)
                .clipped()
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ meeting: UpshowMeeting) -> some View {
        let past = meeting.end < Date()
        return Button { choose(meeting) } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(CalendarText.time(meeting.start)).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(UpshowInk.text)
                    Text(CalendarText.time(meeting.end)).font(.system(size: 11).monospacedDigit()).foregroundStyle(UpshowInk.muted)
                }
                .frame(width: 42, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.guest.isEmpty ? meeting.title : meeting.guest).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(UpshowInk.text).lineLimit(1)
                    Text([meeting.title, store.sequenceName(meeting.sequenceID)].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11.5)).foregroundStyle(UpshowInk.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Circle().fill(past ? UpshowInk.placeholder : UpshowInk.green2).frame(width: 7, height: 7)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(UpshowInk.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(UpshowInk.line) }
            .opacity(past ? 0.72 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(Press(reach: 1))
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
            Button("Try again") { Task { await CalendarStore.shared.refresh() } }.buttonStyle(CalendarButton())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UpshowInk.redBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: The day

private struct CalendarDayGrid: View {
    let chosen: String?
    @Binding var draft: UpshowBooking?
    let choose: (UpshowMeeting) -> Void
    /// A click on empty time: book a meeting starting there.
    let book: (Date) -> Void
    private var store: CalendarStore { CalendarStore.shared }

    static let hourHeight: CGFloat = 46
    static let inset: CGFloat = 13
    static let gutter: CGFloat = 46

    /// The booking's day while one is being made, so its block is always in view.
    private var day: Date {
        if let start = draft?.start { return Calendar.current.startOfDay(for: start) }
        return store.selectedDay
    }

    var body: some View {
        let meetings = store.meetings.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(CalendarText.dayName(day)).font(.system(size: 24, weight: .medium)).kerning(-0.6).foregroundStyle(UpshowInk.text)
                    Text("\(CalendarText.dayMonth(day)) · \(meetings.count == 1 ? "1 meeting" : "\(meetings.count) meetings")")
                        .font(.system(size: 12)).foregroundStyle(UpshowInk.muted)
                }
                Spacer()
                Button { book(nextFreeStart) } label: {
                    Label("Add meeting", systemImage: "plus")
                }
                .buttonStyle(CalendarButton(strong: true, large: true))
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            if store.busy.contains(where: { $0.allDay && $0.start < next && $0.end > day }) {
                Text("Busy all day").font(.system(size: 11, weight: .bold)).foregroundStyle(UpshowInk.busyText)
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
                    .background(UpshowInk.busyA, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(UpshowInk.busyBorder) }
                    .padding(.horizontal, 16).padding(.bottom, 6)
            }
            Rectangle().fill(UpshowInk.line).frame(height: 1)
            if case .failed(let reason) = store.phase {
                CalendarUnavailable(reason: reason).padding(16)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        CalendarDayCanvas(day: day, meetings: meetings, chosen: chosen, draft: $draft, choose: choose, book: book)
                            .frame(height: Self.hourHeight * 24 + Self.inset * 2)
                            .background(alignment: .top) {
                                // Scroll targets: offset views keep their place at the top for
                                // scrolling, so each hour gets a real row of its own.
                                VStack(spacing: 0) {
                                    ForEach(0..<24, id: \.self) { hour in Color.clear.frame(height: Self.hourHeight).id(hour) }
                                }
                                .padding(.top, Self.inset)
                            }
                    }
                    .onAppear { anchor(proxy, animated: false) }
                    .onChange(of: day) { anchor(proxy, animated: true) }
                    .onChange(of: draft?.start) { _, start in
                        if let start { withAnimation(.smooth) { proxy.scrollTo(max(Calendar.current.component(.hour, from: start) - 2, 0), anchor: .top) } }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(UpshowInk.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(UpshowInk.line) }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var next: Date { day.addingTimeInterval(86400) }

    /// Near now on today, otherwise the working day or the day's first meeting if it is earlier.
    private func anchor(_ proxy: ScrollViewProxy, animated: Bool) {
        let hour: Int
        if Calendar.current.isDateInToday(day) {
            hour = max(Calendar.current.component(.hour, from: Date()) - 2, 0)
        } else {
            let first = store.meetings.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
                .map { Calendar.current.component(.hour, from: $0.start) }.min() ?? 8
            hour = max(min(first, 8) - 1, 0)
        }
        if animated { withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(hour, anchor: .top) } } else { proxy.scrollTo(hour, anchor: .top) }
    }

    /// The next free half hour on the day on screen, for Add meeting.
    private var nextFreeStart: Date {
        var start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        let soon = Calendar.current.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? Date()
        if start < soon { start = Calendar.current.isDate(soon, inSameDayAs: day) ? soon : start }
        let taken = store.meetings.map { ($0.start, $0.end) } + store.busy.filter { !$0.allDay }.map { ($0.start, $0.end) }
        for _ in 0..<24 where taken.contains(where: { $0.0 < start.addingTimeInterval(1800) && $0.1 > start }) {
            start = start.addingTimeInterval(1800)
        }
        return start
    }
}

private struct CalendarDayCanvas: View {
    let day: Date
    let meetings: [UpshowMeeting]
    let chosen: String?
    @Binding var draft: UpshowBooking?
    let choose: (UpshowMeeting) -> Void
    let book: (Date) -> Void
    private var store: CalendarStore { CalendarStore.shared }
    private var hourHeight: CGFloat { CalendarDayGrid.hourHeight }
    private var inset: CGFloat { CalendarDayGrid.inset }
    private var gutter: CGFloat { CalendarDayGrid.gutter }
    @State private var dragStart: Date?

    private var start: Date { Calendar.current.startOfDay(for: day) }
    private var next: Date { start.addingTimeInterval(86400) }

    private func y(_ date: Date) -> CGFloat {
        CGFloat(min(max(date.timeIntervalSince(start) / 3600, 0), 24)) * hourHeight + inset
    }

    /// The time at a height on the day, to the quarter hour.
    private func time(at y: CGFloat) -> Date {
        let quarters = ((y - inset) / hourHeight * 4).rounded(.down)
        return start.addingTimeInterval(Double(min(max(quarters, 0), 95)) * 900)
    }

    var body: some View {
        let lanes = CalendarLanes.make(meetings)
        GeometryReader { box in
            let width = box.size.width - gutter - 12
            ZStack(alignment: .topLeading) {
                hours(width: box.size.width)
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { point in if point.x > gutter { book(time(at: point.y)) } }
                ForEach(Array(store.busy.filter { !$0.allDay && $0.start < next && $0.end > start }.enumerated()), id: \.offset) { _, block in
                    busy(minutes: block.end.timeIntervalSince(block.start) / 60, height: max(y(block.end) - y(block.start), 4))
                        .frame(width: width - 4)
                        .offset(x: gutter + 2, y: y(block.start))
                        .allowsHitTesting(false)
                }
                ForEach(meetings) { meeting in
                    let lane = lanes[meeting.id] ?? (0, 1)
                    let laneWidth = width / CGFloat(lane.of)
                    CalendarBlock(meeting: meeting, height: max(y(meeting.end) - y(meeting.start), 22), picked: meeting.id == chosen) { choose(meeting) }
                        .frame(width: laneWidth - 3)
                        .offset(x: gutter + CGFloat(lane.at) * laneWidth + 1.5, y: y(meeting.start))
                }
                if let booking = draft, let begin = booking.start, booking.hasTime,
                   Calendar.current.isDate(begin, inSameDayAs: day), let end = booking.end {
                    ghost(booking, height: max(y(end) - y(begin), 22))
                        .frame(width: width - 3)
                        .offset(x: gutter + 1.5, y: y(begin))
                }
                if Calendar.current.isDateInToday(day) { now(width: box.size.width) }
            }
        }
    }

    private func hours(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(spacing: 0) {
                    Text(String(format: "%02d:00", hour)).font(.system(size: 10).monospacedDigit()).foregroundStyle(UpshowInk.muted)
                        .frame(width: gutter - 8, alignment: .leading).padding(.leading, 8)
                    Rectangle().fill(UpshowInk.line).frame(height: 1)
                }
                .frame(width: width, height: 12)
                .offset(y: CGFloat(hour) * hourHeight + inset - 6)
            }
        }
        .allowsHitTesting(false)
    }

    private func busy(minutes: Double, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            UpshowInk.busyA
            Stripes().stroke(UpshowInk.busyB, lineWidth: 5)
            if minutes >= 30 {
                Text("Busy").font(.system(size: 10, weight: .semibold)).foregroundStyle(UpshowInk.busyText).padding(.leading, 8).padding(.top, 4)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(UpshowInk.busyBorder) }
    }

    /// The meeting being booked, where it would go: green, or rust on a clash. Drag to move it.
    private func ghost(_ booking: UpshowBooking, height: CGFloat) -> some View {
        let clash = store.clash(for: booking) != nil
        return HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(booking.guests.first?.label ?? "New meeting").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if let begin = booking.start, let end = booking.end, height >= 38 {
                    Text("\(CalendarText.time(begin)) to \(CalendarText.time(end))").font(.system(size: 10).monospacedDigit()).opacity(0.75)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.and.down").font(.system(size: 9, weight: .bold)).opacity(0.7)
        }
        .foregroundStyle(UpshowInk.onGreen)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(height: height, alignment: .topLeading)
        .background(clash ? UpshowInk.red : UpshowInk.green2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: (clash ? UpshowInk.red : UpshowInk.green).opacity(0.28), radius: 10, y: 4)
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { drag in
                guard let begin = draft?.start else { return }
                if dragStart == nil { dragStart = begin }
                let base = dragStart ?? begin
                let moved = base.addingTimeInterval((drag.translation.height / hourHeight * 4).rounded() * 900)
                if Calendar.current.isDate(moved, inSameDayAs: day), moved != begin { draft?.start = moved }
            }
            .onEnded { _ in dragStart = nil })
        .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
        .animation(.smooth(duration: 0.12), value: booking.start)
    }

    private func now(width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text("Now").font(.system(size: 9, weight: .semibold)).foregroundStyle(UpshowInk.green2)
            Rectangle().fill(UpshowInk.green2).frame(height: 1)
        }
        .frame(width: width - gutter - 4)
        .offset(x: gutter + 2, y: y(Date()) - 6)
        .frame(height: 12)
        .allowsHitTesting(false)
    }
}

/// One meeting on the day, as Upshow draws it: "Name · title · 09:00", a status dot, and the
/// time range along the bottom when there is room.
private struct CalendarBlock: View {
    let meeting: UpshowMeeting
    let height: CGFloat
    let picked: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let past = meeting.end < Date()
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    (Text(meeting.guest.isEmpty ? meeting.title : meeting.guest).font(.system(size: 12, weight: .medium)).foregroundColor(UpshowInk.text)
                        + Text(" · \(meeting.title) · \(CalendarText.time(meeting.start))").font(.system(size: 11)).foregroundColor(UpshowInk.muted))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Circle().fill(past ? UpshowInk.placeholder : UpshowInk.green2).frame(width: 7, height: 7)
                }
                if height >= 40 {
                    Spacer(minLength: 0)
                    Text("\(CalendarText.time(meeting.start)) to \(CalendarText.time(meeting.end))")
                        .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(UpshowInk.muted)
                }
            }
            .padding(.horizontal, 9).padding(.top, height >= 40 ? 5 : 3).padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height, alignment: height >= 40 ? .top : .center)
            .background(hovered ? UpshowInk.softGreen : UpshowInk.block, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(picked ? UpshowInk.green2 : UpshowInk.blockBorder, lineWidth: picked ? 1.5 : 1)
            }
            .opacity(past ? 0.72 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.1), value: hovered)
        .help("\(meeting.guest), \(meeting.title), \(CalendarText.time(meeting.start)) to \(CalendarText.time(meeting.end))")
    }
}

/// The diagonal hatch on busy time.
private struct Stripes: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            var x = -rect.height
            while x < rect.width {
                path.move(to: CGPoint(x: x, y: rect.height))
                path.addLine(to: CGPoint(x: x + rect.height, y: 0))
                x += 14
            }
        }
    }
}

/// Meetings that overlap sit side by side instead of on top of each other.
enum CalendarLanes {
    static func make(_ meetings: [UpshowMeeting]) -> [String: (at: Int, of: Int)] {
        var out: [String: (at: Int, of: Int)] = [:]
        var group: [(UpshowMeeting, Int)] = [], laneEnds: [Date] = [], groupEnd = Date.distantPast
        func close() {
            for (meeting, lane) in group { out[meeting.id] = (lane, laneEnds.count) }
            group = []; laneEnds = []
        }
        for meeting in meetings.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if meeting.start >= groupEnd { close() }
            let lane = laneEnds.firstIndex { $0 <= meeting.start } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(meeting.end) } else { laneEnds[lane] = meeting.end }
            group.append((meeting, lane))
            groupEnd = max(groupEnd, meeting.end)
        }
        close()
        return out
    }
}

// MARK: One meeting

private struct CalendarMeetingCard: View {
    let meeting: UpshowMeeting
    let close: () -> Void
    private enum Mode { case view, moving, cancelling }
    @State private var mode = Mode.view
    @State private var newStart = Date()
    @State private var minutes = 30
    @State private var sendSequence = false
    @State private var working = false
    @State private var problem: String?
    private var store: CalendarStore { CalendarStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: close) {
                    Label("Day", systemImage: "chevron.left").font(.system(size: 13, weight: .medium)).foregroundStyle(UpshowInk.green2)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    CalendarTicket(heading: store.sequenceName(meeting.sequenceID) ?? "No reminders") {
                        CalendarSlot(label: "With") {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(meeting.guest.isEmpty ? "No guest" : meeting.guest).font(UpshowInk.serif(21)).foregroundStyle(UpshowInk.text)
                                if !meeting.guestEmail.isEmpty, meeting.guestEmail != meeting.guest {
                                    Text(meeting.guestEmail).font(.system(size: 11.5)).foregroundStyle(UpshowInk.muted).textSelection(.enabled)
                                }
                                if !meeting.company.isEmpty { Text(meeting.company).font(.system(size: 11.5)).foregroundStyle(UpshowInk.muted) }
                            }
                        }
                        CalendarRule()
                        CalendarSlot(label: "When") {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(CalendarText.relativeDay(meeting.start)).font(UpshowInk.serif(21)).foregroundStyle(UpshowInk.text)
                                Text("\(CalendarText.time(meeting.start)) to \(CalendarText.time(meeting.end))")
                                    .font(.system(size: 11.5)).foregroundStyle(UpshowInk.muted)
                            }
                        }
                        CalendarRule()
                        CalendarSlot(label: "Title") {
                            Text(meeting.title).font(UpshowInk.serif(18)).foregroundStyle(UpshowInk.text).lineLimit(2)
                        }
                    }
                    switch mode {
                    case .view: actions
                    case .moving: moving
                    case .cancelling: cancelling
                    }
                    if let problem {
                        Text(problem).font(.system(size: 11.5)).foregroundStyle(UpshowInk.red)
                    }
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if let link = meeting.link, store.live {
                Button("Join") { NSWorkspace.shared.open(link) }.buttonStyle(CalendarButton(strong: true))
            }
            Button("Reschedule") {
                newStart = max(meeting.start, Date().addingTimeInterval(900))
                minutes = max(5, Int(meeting.end.timeIntervalSince(meeting.start) / 60))
                withAnimation(.smooth(duration: 0.2)) { mode = .moving }
            }
            .buttonStyle(CalendarButton())
            Button("Cancel meeting") { withAnimation(.smooth(duration: 0.2)) { mode = .cancelling } }.buttonStyle(CalendarButton(danger: true))
        }
        .disabled(meeting.end < Date())
    }

    private var moving: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("MOVE IT TO").font(.system(size: 11, weight: .semibold)).kerning(0.6).foregroundStyle(UpshowInk.muted)
            CalendarDayChips(selection: Binding(get: { newStart }, set: { newStart = CalendarText.keepTime(of: newStart, on: $0) }))
            HStack(spacing: 10) {
                DatePicker("", selection: $newStart, displayedComponents: .hourAndMinute).labelsHidden().datePickerStyle(.stepperField)
                CalendarLength(minutes: $minutes)
            }
            Text(store.live ? "Upshow moves the calendar event and tells the guest." : "Sample only: nothing is sent.")
                .font(.system(size: 11.5)).foregroundStyle(UpshowInk.muted)
            HStack(spacing: 6) {
                Button(working ? "Moving…" : "Move meeting") {
                    run { try await CalendarStore.shared.reschedule(meeting.id, to: newStart, minutes: minutes) }
                }
                .buttonStyle(CalendarButton(strong: true)).disabled(working || newStart <= Date())
                Button("Keep it") { mode = .view }.buttonStyle(CalendarButton())
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

// MARK: Ticket pieces

/// Upshow's booking ticket: the sequence across the top, a dashed tear line, then the slots.
struct CalendarTicket<Content: View>: View {
    let heading: String
    var change: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                HStack(spacing: -3) {
                    Image(systemName: "triangle.fill").rotationEffect(.degrees(90))
                    Image(systemName: "triangle.fill").rotationEffect(.degrees(90)).opacity(0.5)
                }
                .font(.system(size: 7)).foregroundStyle(UpshowInk.green2)
                Text(heading.uppercased()).font(.system(size: 12, weight: .semibold)).kerning(1).foregroundStyle(UpshowInk.green2).lineLimit(1)
                Spacer(minLength: 4)
                if let change {
                    Button("Change", action: change).buttonStyle(CalendarPill())
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 11)
            Dash().stroke(UpshowInk.dashed, style: StrokeStyle(lineWidth: 1, dash: [5, 4])).frame(height: 1)
            content
        }
        .background(UpshowInk.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(UpshowInk.line) }
        .shadow(color: Color(red: 0.11, green: 0.16, blue: 0.13).opacity(0.07), radius: 14, y: 8)
    }

    private struct Dash: Shape {
        func path(in rect: CGRect) -> Path { Path { $0.move(to: CGPoint(x: 0, y: 0.5)); $0.addLine(to: CGPoint(x: rect.width, y: 0.5)) } }
    }
}

/// The hairline between slots.
struct CalendarRule: View {
    var body: some View { Rectangle().fill(UpshowInk.line.opacity(0.7)).frame(height: 1).padding(.horizontal, 16) }
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
            Text(label.uppercased()).font(.system(size: 10.5, weight: .semibold)).kerning(0.7).foregroundStyle(UpshowInk.muted)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(open || (hovered && action != nil) ? UpshowInk.fill2 : .clear)
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
                                .foregroundStyle(on ? UpshowInk.softGreen : UpshowInk.muted)
                            Text(CalendarText.dayNumber(day)).font(.system(size: 15, weight: .medium))
                                .foregroundStyle(on ? UpshowInk.card : UpshowInk.text)
                        }
                        .frame(width: 44, height: 42)
                        .background(on ? UpshowInk.green : UpshowInk.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            Text("\(minutes) min").font(UpshowInk.serif(18)).monospacedDigit().foregroundStyle(UpshowInk.text).frame(minWidth: 64)
            step("plus") { minutes = min(480, minutes + 5) }
        }
    }

    private func step(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(UpshowInk.green2)
                .frame(width: 30, height: 30).background(UpshowInk.fill, in: Circle())
        }
        .buttonStyle(Press(reach: 1))
    }
}

// MARK: Bits

struct CalendarButton: ButtonStyle {
    var strong = false
    var danger = false
    var large = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 13.5 : 12, weight: .medium))
            .foregroundStyle(strong ? UpshowInk.card : danger ? UpshowInk.red : UpshowInk.green2)
            .padding(.horizontal, large ? 16 : 12).frame(height: large ? 34 : 28)
            .background(strong ? UpshowInk.green : danger ? UpshowInk.redBg : UpshowInk.fill,
                        in: RoundedRectangle(cornerRadius: large ? 12 : 10, style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
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
            .background(UpshowInk.card, in: Capsule())
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
    private static let weekdayNameFormat = format("EEEE")
    private static let letterFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEEEE"; return f }()
    private static let numberFormat = format("d")

    static func time(_ date: Date) -> String { timeFormat.string(from: date) }
    static func day(_ date: Date) -> String { dayFormat.string(from: date) }
    static func dayShort(_ date: Date) -> String { shortFormat.string(from: date) }
    static func weekday(_ date: Date) -> String { weekdayFormat.string(from: date) }
    static func weekdayLetter(_ date: Date) -> String { letterFormat.string(from: date) }
    static func dayNumber(_ date: Date) -> String { numberFormat.string(from: date) }
    static func dayMonth(_ date: Date) -> String { longMonthFormat.string(from: date) }

    /// "Today", "Tomorrow" or the weekday, as the day grid heads itself.
    static func dayName(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return weekdayNameFormat.string(from: date)
    }

    /// "Today · 3 Nov", "Tomorrow · 4 Nov" or "Thu 5 Nov", for the ticket.
    static func relativeDay(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today · \(monthFormat.string(from: date))" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow · \(monthFormat.string(from: date))" }
        return "\(weekday(date)) \(monthFormat.string(from: date))"
    }

    static func weekTitle(_ days: [Date]) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        if Calendar.current.isDate(first, equalTo: last, toGranularity: .month) {
            return "\(numberFormat.string(from: first)) to \(longMonthFormat.string(from: last))"
        }
        return "\(monthFormat.string(from: first)) to \(monthFormat.string(from: last))"
    }

    /// The same clock time on another day.
    static func keepTime(of time: Date, on day: Date) -> Date {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return Calendar.current.date(bySettingHour: parts.hour ?? 9, minute: parts.minute ?? 0, second: 0, of: day) ?? day
    }
}
