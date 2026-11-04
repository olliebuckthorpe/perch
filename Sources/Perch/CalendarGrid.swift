import AppKit
import SwiftUI

// The week, ported from Upshow's calendar page (frontend/src/pages/meetings-list.tsx in the
// calendar-event-details worktree): the same geometry, the same layering, and the same ways of
// handling a meeting. Press and drag to move it (the card in hand follows the pointer unsnapped,
// the outline it will land in snaps to the quarter hour, and its old place stays greyed); grab
// an edge to change its length; hold it against a side to turn the week; drag across empty time
// to make a new one. A press that does not travel is a click and opens its card.
//
// One gesture for the whole grid rather than one per block: turning the week replaces every block,
// and a block's own gesture would end with it. The grid works out what is under the pointer from
// the same layout that draws the blocks.

enum CalendarMetrics {
    /// Height of one hour. A half hour is 28: room for a 12-point name with air around it.
    static let hour: CGFloat = 56
    /// Space left under every block, so back-to-back meetings do not touch.
    static let gap: CGFloat = 2
    /// Top and bottom padding inside the day.
    static let pad: CGFloat = 20
    /// The strip left clear to the right of every block: where a new meeting is pulled out.
    static let gutterRight: CGFloat = 12
    static let minBlock: CGFloat = hour / 2 - gap
    static let radius: CGFloat = 6
    static let timeColumn: CGFloat = 52
    /// Below this share of the column a block keeps its side padding small, for the name.
    static let narrow: CGFloat = 0.6
}

/// Where each meeting sits in its day: Upshow's lane layout (lib/calendar-lanes.ts). Items that
/// overlap form a cluster; one starting while another runs sits on top, stepped in by 14% of the
/// column (at most 70%) and running to the right edge; ones starting at the same minute share the
/// rest of the width, longest first. More than four lanes fold into a "+N".
enum CalendarLanes {
    struct Placement { let lane: Int; let lanes: Int; let offset: CGFloat; let span: CGFloat; let layer: Int }
    struct Overflow { let lane: Int; let lanes: Int; let start: Int; let end: Int; let hidden: [String] }
    struct Item { let id: String; let start: Int; let end: Int }

    static func layout(_ items: [Item], maxLanes: Int = 4, minDuration: Int = 28) -> (placed: [String: Placement], overflow: [Overflow]) {
        let sorted = items.map { ($0, max($0.end, $0.start + minDuration)) }
            .sorted { $0.0.start != $1.0.start ? $0.0.start < $1.0.start : $0.1 < $1.1 }
        var placed: [String: Placement] = [:]
        var overflow: [Overflow] = []
        var cluster: [(Item, Int)] = []
        var clusterEnd = Int.min

        func flush() {
            guard !cluster.isEmpty else { return }
            var laneEnds: [Int] = [], laneOf: [Int] = []
            for (item, end) in cluster {
                if let lane = laneEnds.firstIndex(where: { item.start >= $0 }) {
                    laneEnds[lane] = end
                    laneOf.append(lane)
                } else {
                    laneOf.append(laneEnds.count)
                    laneEnds.append(end)
                }
            }
            let capped = laneEnds.count > maxLanes
            let lanes = capped ? maxLanes : laneEnds.count
            var hidden: [(Item, Int)] = [], shown: [(Item, Int, Int)] = []
            for (index, entry) in cluster.enumerated() {
                if capped && laneOf[index] >= maxLanes - 1 { hidden.append(entry) } else { shown.append((entry.0, entry.1, laneOf[index])) }
            }
            // Layering within the cluster.
            var drawn: [(end: Int, offset: CGFloat, layer: Int)] = []
            var i = 0
            while i < shown.count {
                let start = shown[i].0.start
                let together = shown.filter { $0.0.start == start }.sorted { $0.1 > $1.1 }
                i += together.count
                let running = drawn.filter { $0.end > start }
                let base = running.isEmpty ? 0 : min(0.7, (running.map(\.offset).max() ?? 0) + 0.14)
                let firstLayer = running.isEmpty ? 0 : (running.map(\.layer).max() ?? 0) + 1
                let slot = (1 - base) / CGFloat(together.count)
                for (index, entry) in together.enumerated() {
                    let offset = base + CGFloat(index) * slot
                    placed[entry.0.id] = Placement(lane: entry.2, lanes: lanes, offset: offset, span: slot, layer: firstLayer + index)
                    drawn.append((entry.1, offset, firstLayer + index))
                }
            }
            if !hidden.isEmpty {
                overflow.append(Overflow(lane: maxLanes - 1, lanes: lanes, start: hidden.map(\.0.start).min() ?? 0,
                                         end: hidden.map(\.1).max() ?? 0, hidden: hidden.map(\.0.id)))
            }
            cluster = []
        }
        for entry in sorted {
            if !cluster.isEmpty && entry.0.start >= clusterEnd { flush(); clusterEnd = .min }
            cluster.append(entry)
            clusterEnd = max(clusterEnd, entry.1)
        }
        flush()
        return (placed, overflow)
    }
}

/// What the pointer is doing to the week.
private struct CalendarDrag {
    enum Mode { case move, top, bottom }
    let meeting: UpshowMeeting
    let mode: Mode
    /// Minutes between the meeting's start and where it was taken.
    let grab: Int
    /// Where on the block it was taken, and the block's size, for the card in hand.
    let grabOffset: CGSize
    let size: CGSize
    var travelled = false
}

struct CalendarGrid: View {
    let chosen: String?
    @Binding var draft: UpshowBooking?
    /// A meeting clicked: its card opens beside it.
    let open: (UpshowMeeting) -> Void
    /// A range pulled out across empty time: book a meeting there.
    let book: (Date, Int) -> Void
    /// A meeting dropped on a new time: ask before moving it.
    let move: (UpshowMeeting, Date, Date) -> Void
    /// The meeting being rescheduled: everything else steps back.
    var focus: String?
    var peek: AnyView?

    private var store: CalendarStore { CalendarStore.shared }
    @State private var drag: CalendarDrag?
    /// Where the meeting in hand would land: snapped.
    @State private var landing: (start: Date, end: Date)?
    /// The pointer, unsnapped, in the grid's own coordinates.
    @State private var pointer: CGPoint = .zero
    @State private var selecting: (day: Date, from: Int, to: Int)?
    @State private var hovered: String?
    @State private var weekTurnedAt = Date.distantPast
    @State private var slide: CGFloat = 0
    @State private var refused: String?
    @State private var width: CGFloat = 600

    private var colWidth: CGFloat { max(76, (width - CalendarMetrics.timeColumn) / 7) }
    private var contentHeight: CGFloat { CalendarMetrics.pad * 2 + 24 * CalendarMetrics.hour }

    var body: some View {
        // The width the island gives it, read from outside so the grid can never widen itself.
        GeometryReader { box in
            content.onAppear { width = box.size.width }.onChange(of: box.size.width) { _, w in width = w }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            dayHeads
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            if case .failed(let reason) = store.phase {
                Text(reason).font(.system(size: 12)).foregroundStyle(UpshowInk.red).padding(16)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        canvas
                            .frame(height: contentHeight)
                            .background(alignment: .top) {
                                VStack(spacing: 0) {
                                    ForEach(0..<24, id: \.self) { h in Color.clear.frame(height: CalendarMetrics.hour).id(h) }
                                }
                                .padding(.top, CalendarMetrics.pad)
                            }
                    }
                    .onAppear { anchor(proxy) }
                    .onChange(of: store.week) { if drag == nil { anchor(proxy) } }
                }
            }
        }
        .background(UpshowInk.card)
        .overlay(alignment: .bottom) { refusal }
    }

    // MARK: Heads and hours

    private var dayHeads: some View {
        HStack(spacing: 0) {
            Text(TimeZone.current.abbreviation() ?? "").font(.system(size: 10, weight: .medium)).foregroundStyle(UpshowInk.tertiary)
                .frame(width: CalendarMetrics.timeColumn)
                .help(TimeZone.current.localizedName(for: .generic, locale: .current) ?? TimeZone.current.identifier)
            ForEach(store.days, id: \.self) { day in
                let today = Calendar.current.isDateInToday(day)
                HStack(spacing: 5) {
                    Text(CalendarText.weekday(day)).font(.system(size: 14, weight: today ? .medium : .regular))
                        .foregroundStyle(today ? UpshowInk.text : UpshowInk.muted)
                    Text(CalendarText.dayNumber(day)).font(.system(size: 14, weight: .medium).monospacedDigit())
                        .foregroundStyle(today ? Color.white : UpshowInk.muted)
                        .padding(.horizontal, today ? 6 : 0).padding(.vertical, 1)
                        .background(today ? UpshowInk.green : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .frame(width: colWidth).padding(.vertical, 9)
            }
        }
        .offset(x: slide)
    }

    /// Opens an hour above now on this week, otherwise at eight or the week's first meeting.
    private func anchor(_ proxy: ScrollViewProxy) {
        let now = Date()
        let hour: Int
        if store.days.contains(where: { Calendar.current.isDate($0, inSameDayAs: now) }) {
            hour = max(Calendar.current.component(.hour, from: now) - 1, 0)
        } else {
            hour = min(8, store.meetings.map { Calendar.current.component(.hour, from: $0.start) }.min() ?? 8)
        }
        proxy.scrollTo(hour, anchor: .top)
    }

    // MARK: Geometry

    private func y(_ minutes: Double) -> CGFloat { CalendarMetrics.pad + CGFloat(minutes / 60) * CalendarMetrics.hour }

    private func minutes(_ date: Date, on day: Date) -> Double { date.timeIntervalSince(Calendar.current.startOfDay(for: day)) / 60 }

    private func dayIndex(_ date: Date) -> Int? { store.days.firstIndex { Calendar.current.isDate($0, inSameDayAs: date) } }

    private func columnX(_ index: Int) -> CGFloat { CalendarMetrics.timeColumn + CGFloat(index) * colWidth }

    /// The day and quarter hour under a point in the grid.
    private func slot(_ point: CGPoint) -> (day: Date, minutes: Int)? {
        guard !store.days.isEmpty else { return nil }
        let index = min(max(Int((point.x - CalendarMetrics.timeColumn) / colWidth), 0), store.days.count - 1)
        let raw = Double((point.y - CalendarMetrics.pad) / CalendarMetrics.hour) * 60
        let quarter = Int((raw / 15).rounded()) * 15
        return (store.days[index], min(max(quarter, 0), 24 * 60))
    }

    private struct Placed: Identifiable {
        let meeting: UpshowMeeting
        let rect: CGRect
        let layer: Int
        let narrow: Bool
        var id: String { meeting.id }
    }

    /// Every meeting of the week where it is drawn, the same rectangles the pointer is tested against.
    private var placed: (blocks: [Placed], more: [(rect: CGRect, count: Int, first: UpshowMeeting?)]) {
        var blocks: [Placed] = [], more: [(CGRect, Int, UpshowMeeting?)] = []
        for (index, day) in store.days.enumerated() {
            let next = Calendar.current.startOfDay(for: day).addingTimeInterval(86400)
            let meetings = store.meetings.filter { $0.start >= Calendar.current.startOfDay(for: day) && $0.start < next }
            let items = meetings.map { m in
                CalendarLanes.Item(id: m.id, start: Int(minutes(m.start, on: day)), end: max(Int(minutes(m.start, on: day)) + 1, Int(minutes(m.end, on: day))))
            }
            let layout = CalendarLanes.layout(items)
            let room = colWidth - 2 - CalendarMetrics.gutterRight
            for m in meetings {
                guard let p = layout.placed[m.id] else { continue }
                let gap: CGFloat = p.offset + p.span < 0.999 ? 2 : 0
                let start = minutes(m.start, on: day), end = minutes(m.end, on: day)
                let height = max(CalendarMetrics.minBlock, CGFloat((end - start) / 60) * CalendarMetrics.hour - CalendarMetrics.gap)
                let rect = CGRect(x: columnX(index) + 2 + room * p.offset, y: y(start), width: room * p.span - gap, height: height)
                blocks.append(Placed(meeting: m, rect: rect, layer: p.layer, narrow: p.span < CalendarMetrics.narrow))
            }
            for o in layout.overflow {
                let x = columnX(index) + 2 + room * CGFloat(o.lane) / CGFloat(o.lanes)
                let rect = CGRect(x: x, y: y(Double(o.start)), width: room / CGFloat(o.lanes) - 2,
                                  height: max(CalendarMetrics.minBlock, CGFloat(Double(o.end - o.start) / 60) * CalendarMetrics.hour))
                more.append((rect, o.hidden.count, meetings.first { o.hidden.contains($0.id) }))
            }
        }
        return (blocks, more)
    }

    // MARK: The grid

    private var canvas: some View {
        let layout = placed
        return ZStack(alignment: .topLeading) {
            hours
            lines
            ForEach(Array(store.days.enumerated()), id: \.offset) { index, day in busy(day, index) }
            ForEach(layout.blocks) { block in
                if drag?.meeting.id == block.id, drag?.travelled == true {
                    // Its old place, greyed, while it is in hand.
                    ghost(block)
                } else {
                    CalendarBlockView(meeting: block.meeting, size: block.rect.size, narrow: block.narrow,
                                      picked: chosen == block.id, hovered: hovered == block.id, layered: block.layer > 0)
                        .offset(x: block.rect.minX, y: block.rect.minY)
                        .zIndex(chosen == block.id ? 6 : hovered == block.id ? 5 : Double(1 + min(block.layer, 2)))
                        .opacity(focus == nil || focus == block.id ? 1 : 0.32)
                        .saturation(focus == nil || focus == block.id ? 1 : 0.3)
                        .shadow(color: focus == block.id ? UpshowInk.green.opacity(0.5) : .clear, radius: focus == block.id ? 14 : 0, y: 6)
                        .animation(.easeInOut(duration: 0.36), value: focus)
                }
            }
            ForEach(Array(layout.more.enumerated()), id: \.offset) { _, item in
                Text("+\(item.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(UpshowInk.text)
                    .frame(width: item.rect.width, height: item.rect.height)
                    .background(UpshowInk.card, in: RoundedRectangle(cornerRadius: CalendarMetrics.radius, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: CalendarMetrics.radius, style: .continuous).strokeBorder(Color.white.opacity(0.1)) }
                    .offset(x: item.rect.minX, y: item.rect.minY).zIndex(3)
                    .allowsHitTesting(false)
            }
            landingOutline
            selectionRange
            draftPreview
            nowLine
            if let peek, let id = chosen, let block = layout.blocks.first(where: { $0.id == id }) {
                peekPlaced(peek, beside: block.rect)
            }
            cardInHand
        }
        .frame(width: width, height: contentHeight, alignment: .topLeading)
        .offset(x: slide)
        .coordinateSpace(name: "grid")
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .named("grid")) { phase in
            if case .active(let point) = phase {
                let hit = layout.blocks.filter { $0.rect.contains(point) }.max { $0.layer < $1.layer }
                if hovered != hit?.id { withAnimation(.easeOut(duration: 0.14)) { hovered = hit?.id } }
                cursor(point, layout.blocks)
            } else if hovered != nil {
                withAnimation(.easeOut(duration: 0.14)) { hovered = nil }
            }
        }
        .gesture(press(layout.blocks))
        .onTapGesture(coordinateSpace: .named("grid")) { point in
            if let hit = layout.blocks.filter({ $0.rect.contains(point) }).max(by: { $0.layer < $1.layer }) {
                open(hit.meeting)
            } else if let item = layout.more.first(where: { $0.rect.contains(point) }), let first = item.first {
                open(first)
            }
        }
    }

    private func cursor(_ point: CGPoint, _ blocks: [Placed]) {
        guard drag == nil, let hit = blocks.filter({ $0.rect.contains(point) }).max(by: { $0.layer < $1.layer }), movable(hit.meeting) else {
            if drag == nil { NSCursor.arrow.set() }
            return
        }
        let grip = min(10, max(4, hit.rect.height * 0.28))
        if point.y - hit.rect.minY < grip || hit.rect.maxY - point.y < grip { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
    }

    /// Only a meeting added in Upshow can be moved from here; the rest say where they are moved.
    private func movable(_ m: UpshowMeeting) -> Bool {
        (m.platform ?? "manual") == "manual" && !["cancelled", "prospect_cancelled"].contains(m.status ?? "")
    }

    // MARK: Press, drag and drop

    private func press(_ blocks: [Placed]) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("grid"))
            .onChanged { value in
                pointer = value.location
                if drag == nil && selecting == nil {
                    begin(at: value.startLocation, blocks)
                    if drag == nil && selecting == nil { return }
                }
                if selecting != nil, let at = slot(value.location) {
                    selecting?.to = at.minutes
                    return
                }
                guard var state = drag else { return }
                if !state.travelled {
                    state.travelled = true
                    drag = state
                    NSCursor.closedHand.set()
                }
                turnWeekIfAtEdge(value.location)
                track(value.location, state)
            }
            .onEnded { _ in finish(commit: true) }
    }

    private func begin(at point: CGPoint, _ blocks: [Placed]) {
        if let hit = blocks.filter({ $0.rect.contains(point) }).max(by: { $0.layer < $1.layer }) {
            guard movable(hit.meeting) else {
                refuse(hit.meeting)
                return
            }
            let grip = min(10, max(4, hit.rect.height * 0.28))
            let mode: CalendarDrag.Mode = point.y - hit.rect.minY < grip ? .top : hit.rect.maxY - point.y < grip ? .bottom : .move
            let at = slot(point)
            let startMinutes = Int(minutes(hit.meeting.start, on: hit.meeting.start))
            drag = CalendarDrag(meeting: hit.meeting, mode: mode, grab: (at?.minutes ?? startMinutes) - startMinutes,
                                grabOffset: CGSize(width: point.x - hit.rect.minX, height: point.y - hit.rect.minY), size: hit.rect.size)
        } else if point.x > CalendarMetrics.timeColumn, let at = slot(point) {
            selecting = (at.day, at.minutes, at.minutes)
        }
    }

    private func track(_ point: CGPoint, _ state: CalendarDrag) {
        guard let at = slot(point) else { return }
        let m = state.meeting
        let length = Int(m.end.timeIntervalSince(m.start) / 60)
        let day = Calendar.current.startOfDay(for: at.day)
        switch state.mode {
        case .move:
            let start = max(0, min(24 * 60 - length, at.minutes - state.grab))
            let next = day.addingTimeInterval(Double(start) * 60)
            landing = (next, next.addingTimeInterval(Double(length) * 60))
        case .top:
            let base = Calendar.current.startOfDay(for: m.start)
            let end = Int(m.end.timeIntervalSince(base) / 60)
            let top = max(0, min(end - 15, at.minutes))
            landing = (base.addingTimeInterval(Double(top) * 60), m.end)
        case .bottom:
            let base = Calendar.current.startOfDay(for: m.start)
            let start = Int(m.start.timeIntervalSince(base) / 60)
            let bottom = max(start + 15, min(24 * 60, at.minutes))
            landing = (m.start, base.addingTimeInterval(Double(bottom) * 60))
        }
    }

    /// Held against the left or right side, the week turns, once every 900ms so each one lands
    /// and can be read before the next; it slides in from the side it came from.
    private func turnWeekIfAtEdge(_ point: CGPoint) {
        guard drag?.mode == .move, Date().timeIntervalSince(weekTurnedAt) > 0.9 else { return }
        let left = point.x < CalendarMetrics.timeColumn + 28, right = point.x > width - 28
        guard left || right else { return }
        weekTurnedAt = Date()
        store.move(weeks: left ? -1 : 1)
        slide = left ? -34 : 34
        withAnimation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.32)) { slide = 0 }
    }

    private func finish(commit: Bool) {
        defer {
            drag = nil
            landing = nil
            selecting = nil
            NSCursor.arrow.set()
        }
        if let range = selecting {
            let from = min(range.from, range.to), to = max(range.from, range.to)
            book(Calendar.current.startOfDay(for: range.day).addingTimeInterval(Double(from) * 60), max(15, to - from))
            return
        }
        guard commit, let state = drag, state.travelled, let landing else { return }
        if landing.start != state.meeting.start || landing.end != state.meeting.end {
            move(state.meeting, landing.start, landing.end)
        }
    }

    private func refuse(_ m: UpshowMeeting) {
        let tool: String
        switch m.platform ?? "" {
        case "cal_com": tool = "Cal.com"
        case "calendly": tool = "Calendly"
        case "google": tool = "Google Calendar"
        case "outlook": tool = "Outlook"
        default: tool = "the tool it was booked in"
        }
        withAnimation(.smooth(duration: 0.2)) { refused = "Move this in \(tool)" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation(.smooth(duration: 0.2)) { refused = nil } }
    }

    @ViewBuilder private var refusal: some View {
        if let refused {
            Text(refused).font(.system(size: 12.5, weight: .medium)).foregroundStyle(UpshowInk.text)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(UpshowInk.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.1)) }
                .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .offset(y: 8)))
        }
    }

    // MARK: Pieces

    private var hours: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(1..<24, id: \.self) { h in
                Text(CalendarText.hourLabel(h)).font(.system(size: 10, weight: .medium)).foregroundStyle(UpshowInk.tertiary)
                    .padding(.trailing, 6).frame(height: 12)
                    .offset(y: y(Double(h) * 60) - 6)
            }
            if store.days.contains(where: { Calendar.current.isDateInToday($0) }) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(CalendarText.clock12(context.date)).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(UpshowInk.green, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(.trailing, 3)
                        .offset(y: y(minutes(context.date, on: context.date)) - 7)
                }
            }
        }
        .frame(width: CalendarMetrics.timeColumn, height: contentHeight, alignment: .topTrailing)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1) }
        .allowsHitTesting(false)
    }

    private var lines: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0...24, id: \.self) { h in
                Rectangle().fill(Color.white.opacity(0.045)).frame(width: width - CalendarMetrics.timeColumn, height: 1)
                    .offset(x: CalendarMetrics.timeColumn, y: y(Double(h) * 60))
            }
            ForEach(1..<7, id: \.self) { i in
                Rectangle().fill(Color.white.opacity(0.045)).frame(width: 1, height: contentHeight).offset(x: columnX(i))
            }
        }
        .allowsHitTesting(false)
    }

    private func busy(_ day: Date, _ index: Int) -> some View {
        let start = Calendar.current.startOfDay(for: day), next = start.addingTimeInterval(86400)
        let blocks = store.busy.filter { !$0.allDay && $0.start < next && $0.end > start }
        return ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
            let from = max(0, minutes(block.start, on: day)), to = min(24 * 60, minutes(block.end, on: day))
            CalendarBusyView(minutes: to - from)
                .frame(width: colWidth - 4, height: max(CalendarMetrics.minBlock, CGFloat(max(15, to - from) / 60) * CalendarMetrics.hour - CalendarMetrics.gap))
                .offset(x: columnX(index) + 2, y: y(from))
                .opacity(focus == nil ? 1 : 0.32)
                .allowsHitTesting(false)
        }
    }

    /// Where it is leaving from, while it is in flight: the meeting greyed, not an empty outline.
    private func ghost(_ block: Placed) -> some View {
        Text(block.meeting.title.isEmpty ? "Meeting" : block.meeting.title)
            .font(.system(size: 10, weight: .medium)).foregroundStyle(UpshowInk.tertiary).lineLimit(1)
            .padding(.horizontal, 7)
            .frame(width: colWidth - 2 - CalendarMetrics.gutterRight, height: block.rect.height, alignment: .leading)
            .background(UpshowInk.fill, in: RoundedRectangle(cornerRadius: CalendarMetrics.radius, style: .continuous))
            .offset(x: columnX(dayIndex(block.meeting.start) ?? 0) + 2, y: block.rect.minY)
            .zIndex(2)
            .allowsHitTesting(false)
    }

    /// The outline it will snap into, while the card is in hand or an edge is being pulled.
    @ViewBuilder private var landingOutline: some View {
        if let state = drag, state.travelled, let landing, let index = dayIndex(landing.start) {
            let top = y(minutes(landing.start, on: landing.start))
            let height = max(CalendarMetrics.minBlock, CGFloat(landing.end.timeIntervalSince(landing.start) / 3600) * CalendarMetrics.hour)
            if state.mode == .move {
                RoundedRectangle(cornerRadius: CalendarMetrics.radius, style: .continuous)
                    .fill(UpshowInk.green.opacity(0.12))
                    .overlay { RoundedRectangle(cornerRadius: CalendarMetrics.radius, style: .continuous).strokeBorder(UpshowInk.green2, lineWidth: 2) }
                    .frame(width: colWidth - 2 - CalendarMetrics.gutterRight, height: height)
                    .offset(x: columnX(index) + 2, y: top)
                    .zIndex(4).allowsHitTesting(false)
            } else {
                // An edge being pulled: the block itself stretches, saying its new time.
                CalendarBlockView(meeting: state.meeting, size: CGSize(width: colWidth - 2 - CalendarMetrics.gutterRight, height: height),
                                  narrow: false, picked: false, hovered: false, layered: false,
                                  live: "\(CalendarText.time(landing.start)) · \(Int(landing.end.timeIntervalSince(landing.start) / 60))m", dragging: true)
                    .offset(x: columnX(index) + 2, y: top)
                    .zIndex(30).allowsHitTesting(false)
            }
        }
    }

    /// The card in hand, following the pointer unsnapped, tipped a fraction, the colour it has in
    /// the grid. A short card carries the time alone, since the time is what is being chosen.
    @ViewBuilder private var cardInHand: some View {
        if let state = drag, state.travelled, state.mode == .move, let landing {
            VStack(alignment: .leading, spacing: 0) {
                if state.size.height >= 30 {
                    Text(state.meeting.title.isEmpty ? state.meeting.guest : state.meeting.title)
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(UpshowInk.text).lineLimit(1)
                }
                Text("\(CalendarText.time(landing.start)) · \(Int(landing.end.timeIntervalSince(landing.start) / 60))m")
                    .font(.system(size: state.size.height >= 30 ? 9.5 : 10, weight: .semibold)).foregroundStyle(UpshowInk.green2).lineLimit(1)
            }
            .padding(.horizontal, 7).padding(.vertical, 2)
            .frame(width: state.size.width, height: state.size.height, alignment: .topLeading)
            .background(UpshowInk.block, in: RoundedRectangle(cornerRadius: CalendarMetrics.radius, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 11, y: 8)
            .rotationEffect(.degrees(-0.4))
            .offset(x: pointer.x - state.grabOffset.width, y: pointer.y - state.grabOffset.height)
            .zIndex(80)
            .allowsHitTesting(false)
        }
    }

    /// A range being pulled out across empty time.
    @ViewBuilder private var selectionRange: some View {
        if let range = selecting, let index = dayIndex(range.day) {
            let from = min(range.from, range.to), to = max(range.from, range.to)
            let length = max(15, to - from)
            Text("\(CalendarText.clockLabel(from)) to \(CalendarText.clockLabel(from + length))")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(UpshowInk.green2)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .frame(width: colWidth - 2 - CalendarMetrics.gutterRight,
                       height: max(CalendarMetrics.minBlock, CGFloat(Double(length) / 60) * CalendarMetrics.hour), alignment: .topLeading)
                .background(UpshowInk.softGreen, in: RoundedRectangle(cornerRadius: CalendarMetrics.radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: CalendarMetrics.radius, style: .continuous)
                        .strokeBorder(UpshowInk.green2, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
                .offset(x: columnX(index) + 2, y: y(Double(from)))
                .zIndex(5).allowsHitTesting(false)
        }
    }

    /// The meeting Add meeting is building, drawn where it will land: solid green with a light
    /// ring, "New · name".
    @ViewBuilder private var draftPreview: some View {
        if let booking = draft, let start = booking.start, booking.hasTime, let index = dayIndex(start) {
            let clash = store.clash(for: booking) != nil
            (Text("New · ").fontWeight(.medium).foregroundColor(UpshowInk.onGreen.opacity(0.75))
                + Text(booking.guests.first?.label ?? "").foregroundColor(UpshowInk.onGreen))
                .font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .frame(width: colWidth - 2 - CalendarMetrics.gutterRight,
                       height: max(CalendarMetrics.minBlock, CGFloat(Double(booking.minutes) / 60) * CalendarMetrics.hour), alignment: .topLeading)
                .background(clash ? UpshowInk.red.opacity(0.85) : UpshowInk.green, in: RoundedRectangle(cornerRadius: CalendarMetrics.radius, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: CalendarMetrics.radius + 3, style: .continuous).strokeBorder(UpshowInk.softGreen, lineWidth: 3).padding(-3) }
                .offset(x: columnX(index) + 2, y: y(minutes(start, on: start)))
                .zIndex(5)
                .animation(.smooth(duration: 0.18), value: start)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var nowLine: some View {
        if let index = store.days.firstIndex(where: { Calendar.current.isDateInToday($0) }) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: 0) {
                    Circle().fill(UpshowInk.green2).frame(width: 7, height: 7)
                    Rectangle().fill(UpshowInk.green2).frame(height: 1)
                }
                .frame(width: colWidth + 3)
                .offset(x: columnX(index) - 3, y: y(minutes(context.date, on: context.date)) - 3.5)
            }
            .zIndex(4).allowsHitTesting(false)
        }
    }

    /// The meeting's card, 10 points to the right of its block, or to its left if there is no room.
    private func peekPlaced(_ card: AnyView, beside rect: CGRect) -> some View {
        let right = rect.maxX + 10 + 340 <= width
        let x = right ? rect.maxX + 10 : max(8, rect.minX - 10 - 340)
        return card
            .offset(x: x, y: max(8, rect.minY - 6))
            .zIndex(61)
            .transition(.asymmetric(insertion: .scale(scale: 0.96, anchor: right ? .leading : .trailing).combined(with: .opacity),
                                    removal: .opacity))
    }
}

/// One meeting, drawn as Upshow draws it: no border, no stripe; its title then its time, wrapping
/// as far as its height allows; the chevron when Upshow is sending its reminders. Hover and the
/// open card change how deep the colour sits, never the shape.
struct CalendarBlockView: View {
    let meeting: UpshowMeeting
    let size: CGSize
    let narrow: Bool
    let picked: Bool
    let hovered: Bool
    let layered: Bool
    var live: String?
    var dragging = false

    private var ink: Color {
        switch meeting.status ?? "confirmed" {
        case "completed", "attended_by_colleague": return UpshowInk.completed
        case "no_show": return UpshowInk.noShow
        case "rescheduled": return UpshowInk.rescheduled
        case "cancelled", "prospect_cancelled": return UpshowInk.red
        default: return UpshowInk.text
        }
    }

    var body: some View {
        let minutes = meeting.end.timeIntervalSince(meeting.start) / 60
        let name = meeting.title.isEmpty ? "Meeting" : meeting.title
        let past = meeting.end < Date() && !dragging
        let marked = meeting.protected
        VStack(alignment: .leading, spacing: 0) {
            if minutes < 45 {
                // "Lunch 13:00": the start after the name, which keeps the room it needs.
                // Where the name needs the room, the time goes out of sight whole, never cut.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) {
                        Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(ink).lineLimit(1).fixedSize()
                        if size.width >= 52 {
                            Text(CalendarText.time(meeting.start)).font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(ink == UpshowInk.text ? UpshowInk.muted : ink).fixedSize()
                        }
                    }
                    Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(ink).lineLimit(1)
                }
            } else {
                Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(ink)
                    .lineLimit(minutes >= 120 ? 4 : minutes >= 90 ? 3 : 2)
                if size.width >= 52 {
                    Text("\(CalendarText.time(meeting.start))–\(CalendarText.time(meeting.end))").font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(ink == UpshowInk.text ? UpshowInk.muted : ink).lineLimit(1)
                }
            }
            if let live {
                Text(live).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(UpshowInk.green2).lineLimit(1).padding(.top, 1)
            }
        }
        .padding(.top, 3).padding(.bottom, 3)
        .padding(.leading, narrow ? 5 : 7).padding(.trailing, marked ? (narrow ? 16 : 20) : (narrow ? 5 : 7))
        .frame(width: max(size.width, 8), height: size.height, alignment: .topLeading)
        .background(picked ? UpshowInk.blockSelected : hovered && !dragging ? UpshowInk.blockHover : UpshowInk.block,
                    in: RoundedRectangle(cornerRadius: CalendarMetrics.radius, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if marked { UpshowChevron().frame(width: 14, height: 14).padding(4) }
        }
        .overlay {
            RoundedRectangle(cornerRadius: CalendarMetrics.radius, style: .continuous)
                .strokeBorder(picked ? UpshowInk.blockBorder : layered ? UpshowInk.card : .clear, lineWidth: 1)
        }
        .overlay {
            if hovered && !picked && !dragging {
                RoundedRectangle(cornerRadius: CalendarMetrics.radius + 1, style: .continuous)
                    .strokeBorder(UpshowInk.green2.opacity(0.45), lineWidth: 1).padding(-1)
            }
        }
        .shadow(color: dragging ? UpshowInk.green.opacity(0.35) : .clear, radius: dragging ? 10 : 0, y: dragging ? 6 : 0)
        .opacity(past ? (marked ? 0.75 : 0.6) : 1)
        .animation(.easeOut(duration: 0.14), value: hovered)
        .animation(.easeOut(duration: 0.14), value: picked)
        .help(marked ? "Protected by Upshow\nUpshow is sending this meeting's reminders, so the people booked in turn up." : "")
    }
}

/// Busy time from other calendars: hatched parchment turned dark, BUSY when it is half an hour or more.
struct CalendarBusyView: View {
    let minutes: Double

    var body: some View {
        ZStack(alignment: .leading) {
            UpshowInk.busyA
            Hatch().stroke(UpshowInk.busyB, lineWidth: 5)
            if minutes >= 30 {
                Text("BUSY").font(.system(size: 10, weight: .medium)).kerning(0.6).foregroundStyle(UpshowInk.busyText).padding(.horizontal, 6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: CalendarMetrics.radius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: CalendarMetrics.radius, style: .continuous).strokeBorder(UpshowInk.busyBorder) }
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

/// "Move this meeting?", after a meeting is dropped on a new time: what it was, what it will be,
/// and what moving it does.
struct CalendarMoveDialog: View {
    let meeting: UpshowMeeting
    let start: Date
    let end: Date
    let keep: () -> Void
    let confirm: () -> Void
    var working = false

    var body: some View {
        let who = meeting.guest.isEmpty ? "the guest" : meeting.guest
        let sameDay = Calendar.current.isDate(meeting.start, inSameDayAs: start)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Move this meeting?").font(.system(size: 12.5, weight: .medium)).foregroundStyle(UpshowInk.muted)
                Spacer()
                Button(action: keep) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(UpshowInk.tertiary).frame(width: 24, height: 24)
                }
                .buttonStyle(Press(reach: 1))
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.top, 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title.isEmpty ? meeting.guest : meeting.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(UpshowInk.text)
                if !meeting.company.isEmpty { Text(meeting.company).font(.system(size: 12.5)).foregroundStyle(UpshowInk.muted) }
            }
            .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 12)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("WAS").font(.system(size: 11, weight: .medium)).kerning(0.4).foregroundStyle(UpshowInk.tertiary)
                    Text(sameDay ? CalendarText.time(meeting.start) : "\(CalendarText.weekday(meeting.start)) \(CalendarText.dayMonth(meeting.start)), \(CalendarText.time(meeting.start))")
                        .font(.system(size: 13.5).monospacedDigit()).foregroundStyle(UpshowInk.tertiary)
                }
                Image(systemName: "arrow.right").font(.system(size: 13)).foregroundStyle(UpshowInk.tertiary).padding(.top, 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NOW").font(.system(size: 11, weight: .medium)).kerning(0.4).foregroundStyle(UpshowInk.green2)
                    (Text("\(CalendarText.weekday(start)) \(CalendarText.dayMonth(start)), \(CalendarText.time(start))").fontWeight(.semibold).foregroundColor(UpshowInk.text)
                        + Text(" · \(Int(end.timeIntervalSince(start) / 60)) min").foregroundColor(UpshowInk.muted))
                        .font(.system(size: 13.5).monospacedDigit())
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(UpshowInk.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 16).padding(.bottom, 14)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            VStack(alignment: .leading, spacing: 9) {
                consequence(meeting.platform == "cal_com" ? "envelope" : "envelope.badge.shield.half.filled",
                            meeting.platform == "cal_com" ? "Cal.com emails \(who) about the new time."
                                : "There is no calendar invitation for this meeting, so \(who) is not told automatically.",
                            warn: meeting.platform != "cal_com")
                consequence("bell.and.waves.left.and.right", "Reminders are replanned around the new time.")
                if ["no_show", "cancelled", "prospect_cancelled"].contains(meeting.status ?? "") {
                    consequence("checkmark.circle", "The meeting is marked confirmed again.")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            HStack(spacing: 8) {
                Spacer()
                Button("Keep the old time", action: keep).buttonStyle(.plain).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(UpshowInk.muted).padding(.horizontal, 10)
                    .disabled(working)
                Button(working ? "Moving…" : "Move meeting", action: confirm).buttonStyle(CalendarButton(strong: true))
                    .keyboardShortcut(.defaultAction).disabled(working)
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
        }
        .frame(width: 380)
        .background(UpshowInk.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.08)) }
        .shadow(color: .black.opacity(0.55), radius: 30, y: 24)
    }

    private func consequence(_ icon: String, _ text: String, warn: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(warn ? UpshowInk.amber : UpshowInk.tertiary).frame(width: 16).padding(.top, 1)
            Text(text).font(.system(size: 13)).foregroundStyle(warn ? UpshowInk.amber : UpshowInk.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Upshow's mark: two chevrons, the lower one faint. On a meeting it says Upshow is protecting it.
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
