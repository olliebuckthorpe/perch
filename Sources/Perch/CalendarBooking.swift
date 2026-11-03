import AppKit
import SwiftUI

// Booking a meeting from Perch, the way Upshow's own add-meeting screen does it: type a sentence
// like "Sarah demo Friday at 2pm", watch the ticket fill in, fix any slot by clicking it, then
// book. Nothing reaches Upshow until the seven-second undo window after Book meeting has passed.

struct CalendarNewMeeting: View {
    @Binding var booking: UpshowBooking
    let close: () -> Void
    @Environment(NotchUI.self) private var ui
    private var store: CalendarStore { CalendarStore.shared }

    private enum Slot { case sequence, with, when, length, place, title }
    @State private var open: Slot?
    @State private var sentence = ""
    @State private var reading = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("New meeting").font(.system(size: 20, weight: .medium)).kerning(-0.4).foregroundStyle(UpshowInk.text)
                Spacer()
                Button("Start over") {
                    withAnimation(.smooth(duration: 0.2)) { booking = CalendarView.freshBooking(); open = nil; sentence = "" }
                }
                .buttonStyle(CalendarPill())
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(UpshowInk.green2)
                        .frame(width: 22, height: 22).background(UpshowInk.fill, in: Circle())
                }
                .buttonStyle(Press(reach: 1)).help("Discard")
            }
            composer
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ticket
                    seal
                }
            }
            bookButton
        }
        .onAppear {
            ui.controller?.panel.makeKey()
            typing = booking.guests.isEmpty
        }
        .onChange(of: store.handedSentence, initial: true) { _, handed in
            guard let handed else { return }
            store.handedSentence = nil
            sentence = handed
            read()
        }
    }

    // MARK: Typing it

    private var composer: some View {
        HStack(spacing: 6) {
            TextField("e.g. Sarah demo Friday at 2pm", text: $sentence)
                .textFieldStyle(.plain).font(.system(size: 13.5)).foregroundStyle(UpshowInk.text)
                .focused($typing)
                .onSubmit(read)
                .simultaneousGesture(TapGesture().onEnded { ui.controller?.panel.makeKey() })
            if reading {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 26, height: 26)
            } else {
                Button(action: read) {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(UpshowInk.onGreen)
                        .frame(width: 30, height: 30)
                        .background(sentence.isEmpty ? Color(red: 0xc4 / 255, green: 0xca / 255, blue: 0xbf / 255) : UpshowInk.green2,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(Press(reach: 1)).disabled(sentence.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Add what you typed to the booking")
            }
        }
        .padding(.leading, 13).padding(.trailing, 5).padding(.vertical, 5)
        .background(UpshowInk.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(typing ? Color(red: 0x89 / 255, green: 0xa8 / 255, blue: 0x92 / 255) : UpshowInk.inputBorder)
        }
        .shadow(color: UpshowInk.green.opacity(typing ? 0.08 : 0), radius: 8, y: 3)
        .animation(.easeOut(duration: 0.15), value: typing)
    }

    /// What can be read on the Mac fills in at once; Upshow's reading, which knows names, follows.
    private func read() {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        withAnimation(.smooth(duration: 0.25)) { CalendarRead.apply(CalendarRead.local(text, types: store.types), to: &booking) }
        sentence = ""
        reading = true
        Task { @MainActor in
            if let parsed = await store.parse(text) {
                withAnimation(.smooth(duration: 0.25)) { CalendarRead.apply(parsed, to: &booking) }
            }
            reading = false
        }
    }

    // MARK: The ticket

    private var sequenceName: String {
        switch booking.sequence {
        case .some(.some(let id)): return store.sequenceName(id) ?? "Sequence"
        case .some(.none): return "No reminders"
        case .none: return "Choose a sequence"
        }
    }

    private var ticket: some View {
        CalendarTicket(heading: sequenceName, change: { toggle(.sequence) }) {
            if open == .sequence { sequenceEditor.transition(.opacity) }
            slot(.with, "With") {
                if booking.guests.isEmpty { empty("Who’s it with?") } else { guestChips }
            }
            if open == .with { guestEditor }
            divider
            slot(.when, "When") {
                if let start = booking.start {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        value(CalendarText.relativeDay(start))
                        if booking.hasTime { value(CalendarText.time(start)).foregroundStyle(UpshowInk.green2) } else { empty("What time?") }
                    }
                } else { empty("When?") }
            }
            if open == .when { whenEditor }
            divider
            slot(.length, "Length") {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    value("\(booking.minutes) min")
                    if let end = booking.end, booking.hasTime {
                        Text("Ends \(CalendarText.time(end))").font(.system(size: 11)).foregroundStyle(UpshowInk.muted)
                    }
                }
            }
            if open == .length { lengthEditor }
            divider
            slot(.place, "Where") {
                if let place = booking.place {
                    value(placeLabel(place))
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        empty("Where?")
                        Text("Meet, Teams, Zoom, a link, phone, or in person").font(.system(size: 10.5)).foregroundStyle(UpshowInk.muted)
                    }
                }
            }
            if open == .place { placeEditor }
            divider
            slot(.title, "Title") {
                VStack(alignment: .leading, spacing: 1) {
                    if booking.title.isEmpty { value(defaultTitle).foregroundStyle(UpshowInk.muted) } else { value(booking.title) }
                    Text(booking.title.isEmpty ? "From the sequence · change" : "What the invite is called")
                        .font(.system(size: 10.5)).foregroundStyle(UpshowInk.muted)
                }
            }
            if open == .title { titleEditor }
        }
        .animation(.smooth(duration: 0.22), value: open)
    }

    private var defaultTitle: String {
        if case .some(.some(let id)) = booking.sequence, let name = store.sequenceName(id) { return name }
        return "Meeting"
    }

    private var divider: some View { CalendarRule() }

    private func toggle(_ slot: Slot) {
        withAnimation(.smooth(duration: 0.22)) { open = open == slot ? nil : slot }
        if slot == .when, booking.start == nil {
            booking.start = Calendar.current.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime)
            booking.hasTime = true
        }
    }

    private func slot<V: View>(_ which: Slot, _ label: String, @ViewBuilder _ content: () -> V) -> some View {
        CalendarSlot(label: label, open: open == which, action: { toggle(which) }) { content() }
    }

    private func value(_ text: String) -> some View {
        Text(text).font(UpshowInk.serif(20)).foregroundStyle(UpshowInk.text).lineLimit(1)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(UpshowInk.serif(20, .medium)).italic().foregroundStyle(UpshowInk.placeholder)
    }

    private var guestChips: some View {
        FlowRow(spacing: 5) {
            ForEach(booking.guests) { guest in
                HStack(spacing: 5) {
                    Text(guest.initials).font(.system(size: 8.5, weight: .bold)).foregroundStyle(UpshowInk.onGreen)
                        .frame(width: 18, height: 18).background(UpshowInk.green, in: Circle())
                    Text(guest.label).font(UpshowInk.serif(13.5)).foregroundStyle(UpshowInk.text).lineLimit(1)
                    if !guest.reachable {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 9)).foregroundStyle(UpshowInk.amber)
                            .help("Needs an email or phone number")
                    }
                    Button { withAnimation(.smooth(duration: 0.2)) { booking.guests.removeAll { $0.id == guest.id } } } label: {
                        Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold)).foregroundStyle(UpshowInk.muted)
                    }
                    .buttonStyle(Press(reach: 2))
                }
                .padding(.leading, 3).padding(.trailing, 8).padding(.vertical, 3)
                .background(UpshowInk.fill, in: Capsule())
            }
        }
    }

    // MARK: Editors

    private var sequenceEditor: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(store.types) { type in
                choice(type.name, on: booking.sequence == .some(type.id)) {
                    booking.sequence = .some(type.id)
                    if let minutes = type.defaultMinutes { booking.minutes = minutes }
                    open = nil
                }
            }
            choice("No reminders", detail: "Booked without any messages to the guest", on: booking.sequence == .some(nil)) {
                booking.sequence = .some(nil)
                open = nil
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(UpshowInk.fill)
    }

    @State private var guest = UpshowGuest()

    private var guestEditor: some View {
        let typed = (guest.name + guest.email).lowercased()
        let suggestions = typed.count < 2 ? [] : store.knownGuests.filter { known in
            !booking.guests.contains { $0.email.lowercased() == known.email.lowercased() }
                && (known.name.lowercased().contains(guest.name.lowercased().trimmingCharacters(in: .whitespaces)) && !guest.name.isEmpty
                    || known.email.lowercased().contains(guest.email.lowercased()) && !guest.email.isEmpty)
        }.prefix(3)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(suggestions)) { known in
                Button {
                    withAnimation(.smooth(duration: 0.2)) { booking.guests.append(known); guest = UpshowGuest() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "person.crop.circle").foregroundStyle(UpshowInk.green2)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Use \(known.label)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(UpshowInk.text)
                            Text([known.email, known.company].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 10.5)).foregroundStyle(UpshowInk.muted)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(6).background(UpshowInk.softGreen, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(Press(reach: 1))
            }
            field("Their name", $guest.name)
            field("name@company.com", $guest.email)
            HStack(spacing: 6) {
                field("Phone, for SMS", $guest.phone)
                field("Company (optional)", $guest.company)
            }
            HStack {
                if !guest.name.isEmpty || !guest.email.isEmpty, !guest.reachable {
                    Text("Enter an email or phone number").font(.system(size: 10.5)).foregroundStyle(UpshowInk.amber)
                }
                Spacer()
                Button("Add to booking") {
                    var person = guest
                    person.name = person.name.trimmingCharacters(in: .whitespaces)
                    person.email = person.email.trimmingCharacters(in: .whitespaces)
                    withAnimation(.smooth(duration: 0.2)) { booking.guests.append(person) }
                    guest = UpshowGuest()
                }
                .buttonStyle(CalendarButton(strong: true))
                .disabled(!guest.reachable)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    private var whenEditor: some View {
        let start = Binding<Date>(
            get: { booking.start ?? Date() },
            set: { booking.start = $0; booking.hasTime = true })
        return VStack(alignment: .leading, spacing: 8) {
            CalendarDayChips(selection: Binding(get: { start.wrappedValue }, set: { start.wrappedValue = CalendarText.keepTime(of: start.wrappedValue, on: $0) }))
            HStack(spacing: 8) {
                DatePicker("", selection: start, displayedComponents: .hourAndMinute).labelsHidden().datePickerStyle(.stepperField)
                DatePicker("", selection: start, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.field)
            }
            Text("Or click a time on the calendar, then drag the block to move it.")
                .font(.system(size: 10.5)).foregroundStyle(UpshowInk.muted)
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    private var lengthEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            CalendarLength(minutes: $booking.minutes)
            HStack(spacing: 5) {
                ForEach([15, 25, 30, 45, 60, 90], id: \.self) { minutes in
                    Button("\(minutes)") { booking.minutes = minutes }
                        .buttonStyle(CalendarChip(on: booking.minutes == minutes))
                }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    private static let places: [(UpshowPlace, String, String)] = [
        (.meet, "video", "Comes with your Google Calendar"),
        (.teams, "person.2", "Link created from your Teams account"),
        (.zoom, "video.badge.checkmark", "Create one or paste a link. We track who joins"),
        (.phone, "phone", "You call them at the start time"),
        (.inPerson, "mappin.and.ellipse", "No link needed"),
        (.custom, "link", "Paste your own meeting link"),
    ]

    private func placeLabel(_ place: UpshowPlace) -> String {
        let detail = booking.placeDetail.trimmingCharacters(in: .whitespaces)
        switch place {
        case .phone: return "Phone call"
        case .inPerson where !detail.isEmpty: return detail
        case .zoom where !detail.isEmpty: return "Zoom · your link"
        case .custom where !detail.isEmpty: return URL(string: detail)?.host ?? detail
        default: return place.label
        }
    }

    private var placeEditor: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Self.places, id: \.0) { place, icon, detail in
                choice(place.label, detail: detail, icon: icon, on: booking.place == place) {
                    if booking.place != place { booking.placeDetail = "" }
                    booking.place = place
                    if ![.zoom, .custom, .inPerson].contains(place) { open = nil }
                }
            }
            if let place = booking.place, [.zoom, .custom, .inPerson].contains(place) {
                field(place == .inPerson ? "Where are you meeting?" : place == .zoom ? "Paste your Zoom link (blank makes a room)" : "https://…",
                      $booking.placeDetail)
                    .padding(.horizontal, 4).padding(.top, 4)
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
    }

    private var titleEditor: some View {
        HStack(spacing: 6) {
            field(defaultTitle, $booking.title).onSubmit { open = nil }
            Button("Done") { open = nil }.buttonStyle(CalendarPill())
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    private func choice(_ title: String, detail: String? = nil, icon: String? = nil, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.smooth(duration: 0.2)) { action() } }) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 11)).foregroundStyle(UpshowInk.green2).frame(width: 18)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(UpshowInk.text)
                    if let detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(UpshowInk.muted).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(UpshowInk.green2) }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(on ? UpshowInk.softGreen : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(UpshowInk.text)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(UpshowInk.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(UpshowInk.inputBorder) }
            .simultaneousGesture(TapGesture().onEnded { ui.controller?.panel.makeKey() })
    }

    // MARK: Checking and booking

    @ViewBuilder private var seal: some View {
        if let start = booking.start, booking.hasTime {
            let clash = store.clash(for: booking)
            let far = start > Date().addingTimeInterval(30 * 86400)
            Label(clash ?? (far ? "Too far ahead to check your calendar, so this slot may not be free."
                                : Calendar.current.isDateInToday(start) ? "No conflicts today" : "No conflicts on \(CalendarText.weekday(start)) \(CalendarText.dayMonth(start))"),
                  systemImage: clash != nil ? "exclamationmark.triangle.fill" : far ? "questionmark.circle" : "checkmark.seal.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(clash != nil ? UpshowInk.red : far ? UpshowInk.muted : UpshowInk.green2)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(clash != nil ? UpshowInk.redBg : UpshowInk.softGreen, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var bookButton: some View {
        let blocker = booking.blocker ?? (booking.sequence == nil ? "Choose a sequence" : nil)
        return VStack(spacing: 4) {
            Button {
                open = nil
                store.stage(booking)
            } label: {
                Text("Book meeting").font(.system(size: 15, weight: .bold)).foregroundStyle(UpshowInk.onGreen)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(UpshowInk.green, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(Press(reach: 1))
            .disabled(blocker != nil)
            .opacity(blocker == nil ? 1 : 0.4)
            if let blocker {
                Text(blocker).font(.system(size: 10.5)).foregroundStyle(UpshowInk.muted)
            }
        }
    }
}

/// A small preset pill.
struct CalendarChip: ButtonStyle {
    let on: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(on ? UpshowInk.onGreen : UpshowInk.text)
            .frame(minWidth: 30).padding(.vertical, 4)
            .background(on ? UpshowInk.green : UpshowInk.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Lays chips out in rows, wrapping when a row is full.
struct FlowRow: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let y = rows[rows.count - 1].y + rows[rows.count - 1].height + spacing
                rows.append(Row(y: y))
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

// MARK: Booked

/// The green "Booked" card over the panel. During the undo window nothing has been sent yet.
struct CalendarBooked: View {
    let undo: (UpshowBooking) -> Void
    let done: (UpshowMeeting?) -> Void
    private var store: CalendarStore { CalendarStore.shared }
    @State private var stamped = false

    var body: some View {
        if let staged = store.staged {
            let booking = staged.booking
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                stamp(staged.state)
                Text(title(staged.state)).font(UpshowInk.serif(30)).foregroundStyle(UpshowInk.onGreen)
                VStack(spacing: 3) {
                    Text(booking.guests.map(\.label).joined(separator: ", ")).font(UpshowInk.serif(16)).foregroundStyle(UpshowInk.onGreen)
                        .multilineTextAlignment(.center).lineLimit(2)
                    if let start = booking.start, let end = booking.end {
                        Text("\(CalendarText.relativeDay(start)) · \(CalendarText.time(start)) to \(CalendarText.time(end))")
                            .font(.system(size: 11.5)).foregroundStyle(UpshowInk.onGreen.opacity(0.7))
                    }
                    Text([store.sequenceName(booking.sequence ?? nil) ?? "No reminders", booking.place?.label].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(UpshowInk.onGreen.opacity(0.85))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(.white.opacity(0.12), in: Capsule())
                        .padding(.top, 4)
                }
                note(staged.state)
                Spacer(minLength: 0)
                buttons(staged)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(UpshowInk.green, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.55).delay(0.05)) { stamped = true } }
        }
    }

    private func title(_ state: CalendarStore.Staged.State) -> String {
        switch state {
        case .waiting, .booked: return "Booked"
        case .sending: return "Booking…"
        case .awaitingApproval: return "Sent to Upshow"
        case .failed: return "Not booked"
        }
    }

    private func stamp(_ state: CalendarStore.Staged.State) -> some View {
        let icon: String, tint: Color
        switch state {
        case .failed: icon = "exclamationmark"; tint = UpshowInk.red
        case .awaitingApproval: icon = "hourglass"; tint = UpshowInk.amber
        default: icon = "checkmark"; tint = UpshowInk.green2
        }
        return Image(systemName: icon).font(.system(size: 30, weight: .bold)).foregroundStyle(UpshowInk.green)
            .frame(width: 66, height: 66)
            .background(tint, in: Circle())
            .overlay { Circle().strokeBorder(tint.opacity(0.35), lineWidth: 6).padding(-8) }
            .scaleEffect(stamped ? 1 : 0.5)
            .opacity(stamped ? 1 : 0)
            .rotationEffect(.degrees(stamped ? 0 : -12))
    }

    @ViewBuilder private func note(_ state: CalendarStore.Staged.State) -> some View {
        switch state {
        case .awaitingApproval:
            Text("It’s booked once you approve it in the Upshow app.").font(.system(size: 11.5)).foregroundStyle(UpshowInk.onGreen.opacity(0.75))
                .multilineTextAlignment(.center)
        case .failed(let reason):
            Text("\(reason) Trying again is safe: it will not book twice.").font(.system(size: 11.5)).foregroundStyle(UpshowInk.onGreen.opacity(0.85))
                .multilineTextAlignment(.center)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func buttons(_ staged: CalendarStore.Staged) -> some View {
        switch staged.state {
        case .waiting:
            HStack(spacing: 8) {
                TimelineView(.animation(minimumInterval: 0.05)) { context in
                    let left = max(staged.sendAt.timeIntervalSince(context.date), 0)
                    Button {
                        if let booking = store.undoStaged() { undo(booking) }
                    } label: {
                        HStack(spacing: 7) {
                            ZStack {
                                Circle().stroke(UpshowInk.green.opacity(0.2), lineWidth: 2.5)
                                Circle().trim(from: 0, to: left / CalendarStore.undoSeconds)
                                    .stroke(UpshowInk.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
                                Text("\(Int(left.rounded(.up)))").font(.system(size: 8.5, weight: .bold).monospacedDigit()).foregroundStyle(UpshowInk.green)
                            }
                            .frame(width: 18, height: 18)
                            Text("Undo").font(.system(size: 13, weight: .bold)).foregroundStyle(UpshowInk.green)
                        }
                        .frame(maxWidth: .infinity).frame(height: 36)
                        .background(UpshowInk.onGreen, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(Press(reach: 1))
                }
                Button { Task { await store.sendStaged() } } label: {
                    Text("Send now").font(.system(size: 13, weight: .semibold)).foregroundStyle(UpshowInk.onGreen)
                        .frame(maxWidth: .infinity).frame(height: 36)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(Press(reach: 1))
            }
        case .sending:
            ProgressView().controlSize(.small).tint(UpshowInk.onGreen).frame(height: 36)
        case .booked(let made):
            wide("View in calendar") { done(made) }
        case .awaitingApproval:
            wide("Done") { done(nil) }
        case .failed:
            HStack(spacing: 8) {
                wide("Try again") { store.retryStaged() }
                Button { if let booking = store.reopenStaged() { undo(booking) } } label: {
                    Text("Edit booking").font(.system(size: 13, weight: .semibold)).foregroundStyle(UpshowInk.onGreen)
                        .frame(maxWidth: .infinity).frame(height: 36)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(Press(reach: 1))
            }
        }
    }

    private func wide(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(UpshowInk.green)
                .frame(maxWidth: .infinity).frame(height: 36)
                .background(UpshowInk.onGreen, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(Press(reach: 1))
    }
}

// MARK: Reading a sentence

enum CalendarRead {
    /// What the Mac can pick out by itself: emails, a day and time, a length, a place, a sequence.
    static func local(_ text: String, types: [UpshowMeetingType]) -> UpshowParsed {
        var out = UpshowParsed()
        let range = NSRange(text.startIndex..., in: text)
        if let emails = try? NSRegularExpression(pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", options: .caseInsensitive) {
            for match in emails.matches(in: text, range: range) {
                if let r = Range(match.range, in: text) { out.guests.append(UpshowGuest(email: String(text[r]))) }
            }
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue | NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, range: range) {
                if match.resultType == .date, out.start == nil, let date = match.date {
                    let said = (Range(match.range, in: text).map { String(text[$0]) } ?? "").lowercased()
                    out.hasTime = said.range(of: #"\d\s*(am|pm)|\d:\d\d|\bnoon\b|\bmidday\b"#, options: .regularExpression) != nil
                    out.start = out.hasTime ? date : Calendar.current.startOfDay(for: date)
                } else if match.resultType == .link, let url = match.url, url.scheme?.hasPrefix("http") == true {
                    out.place = url.host?.contains("zoom") == true ? .zoom : .custom
                    out.placeDetail = url.absoluteString
                }
            }
        }
        let lower = text.lowercased()
        if let match = lower.range(of: #"(\d+)\s*(m|min|mins|minutes|h|hr|hrs|hour|hours)\b"#, options: .regularExpression) {
            let said = String(lower[match])
            let number = Int(said.prefix { $0.isNumber }) ?? 0
            out.minutes = said.contains("h") ? number * 60 : number
        }
        if out.place == nil {
            if lower.contains("zoom") { out.place = .zoom }
            else if lower.contains("teams") { out.place = .teams }
            else if lower.contains("google meet") || lower.contains(" meet ") || lower.hasSuffix(" meet") { out.place = .meet }
            else if lower.contains("phone") { out.place = .phone }
            else if lower.contains("in person") { out.place = .inPerson }
        }
        if lower.contains("no reminders") { out.noReminders = true }
        else if let type = types.sorted(by: { $0.name.count > $1.name.count }).first(where: { lower.contains($0.name.lowercased()) }) {
            out.sequenceID = type.id
        }
        return out
    }

    /// Fills the booking from a reading. People are added, matched up by email so the same
    /// person read twice (once by the Mac, once by Upshow) stays one person.
    static func apply(_ read: UpshowParsed, to booking: inout UpshowBooking) {
        for person in read.guests {
            let email = person.email.lowercased()
            if let i = booking.guests.firstIndex(where: { !email.isEmpty && $0.email.lowercased() == email }) {
                if booking.guests[i].name.isEmpty { booking.guests[i].name = person.name }
                if booking.guests[i].phone.isEmpty { booking.guests[i].phone = person.phone }
            } else if !booking.guests.contains(where: { !person.name.isEmpty && $0.name.lowercased() == person.name.lowercased() }) {
                booking.guests.append(person)
            }
        }
        if let start = read.start {
            if read.hasTime {
                booking.start = start
                booking.hasTime = true
            } else {
                booking.start = booking.hasTime ? CalendarText.keepTime(of: booking.start ?? start, on: start) : start
            }
        }
        if let minutes = read.minutes, (5...480).contains(minutes) { booking.minutes = minutes }
        if let place = read.place {
            booking.place = place
            if let detail = read.placeDetail { booking.placeDetail = detail }
        }
        if read.noReminders { booking.sequence = .some(nil) } else if let id = read.sequenceID { booking.sequence = .some(id) }
        if let title = read.title, booking.title.isEmpty { booking.title = title }
    }
}
