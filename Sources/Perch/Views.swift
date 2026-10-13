import SwiftUI
import ServiceManagement

private let faceSize: CGFloat = 16
private let maxFaces = 7
private let island = Animation.spring(response: 0.34, dampingFraction: 0.88)

private func earWidth(_ count: Int) -> CGFloat {
    count == 0 ? 0 : CGFloat(count) * faceSize + CGFloat(count - 1) * 4 + 16
}

struct NotchContent: View {
    @Environment(AgentStore.self) private var store
    @Environment(NotchUI.self) private var ui

    var body: some View {
        let left = Array(store.grokBots.filter(ui.inPill).prefix(maxFaces))
        // Every chat that is in the sidebar sits in the notch too, idle ones included (they just
        // sit still). Only chats the user has cleared are left out.
        let right = Array(store.sessions.filter { !ui.isDismissed($0) }.prefix(maxFaces))
        let l = earWidth(left.count), r = earWidth(right.count)
        // Opened, the island is at least 340 wide; the extra is shared between both sides
        // so the gap always stays lined up with the hardware notch.
        // A chat needs more room than the roster.
        let chatting = ui.selectedID != nil || ui.composing
        let extra = ui.expanded ? max(0, (ui.cardsOnly || !ui.pendingLinks.isEmpty || ui.justOpened != nil ? 340 : 680) - (l + ui.notch.width + r)) : 0
        let radius: CGFloat = ui.expanded ? 18 : 10
        let openWidth = max(l + ui.notch.width + r, 340)
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Ear(agents: left).frame(width: l + extra / 2, alignment: .trailing)
                Color.clear.frame(width: ui.notch.width)
                Ear(agents: right).frame(width: r + extra / 2, alignment: .leading)
            }
            .frame(height: ui.notch.height)

            if ui.expanded {
                ExpandedBody()
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .frame(width: max(l + ui.notch.width + r + extra, 60))
        .background(.black)
        .clipShape(shape)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
            ui.controller?.islandFrameChanged(frame)
        }
        .shadow(color: .black.opacity(ui.expanded ? 0.35 : 0), radius: 12, y: 5)
        // Faces sit either side of the notch, so the island is only as wide as it needs to be.
        // Padding (not an offset) shifts it, so the clickable area moves with what is drawn.
        .padding(.leading, max(0, r - l))
        .padding(.trailing, max(0, l - r))
        .animation(island, value: ui.expanded)
        .animation(island, value: ui.cardsOnly)
        .animation(tabSwitch, value: ui.showingTasks)
        .animation(island, value: store.needing.count)
        .animation(island, value: l + r)
        .onChange(of: [openWidth, r - l], initial: true) {
            ui.controller?.openShapeChanged(width: openWidth, offset: (r - l) / 2)
        }
        .onChange(of: store.attention) { ui.attention(store) }
        .onChange(of: store.needing.count) { _, count in ui.pendingChanged(count) }
    }
}

private struct Ear: View {
    let agents: [Agent]
    @Environment(NotchUI.self) private var ui

    var body: some View {
        HStack(spacing: 4) {
            ForEach(agents) { agent in
                FaceView(agent: agent, size: faceSize)
                    .reach(2, 9)
                    .onTapGesture { ui.show(agent.id) }
                    .help(agent.name)
            }
        }
        .padding(.horizontal, 8)
    }
}

private struct ExpandedBody: View {
    @Environment(AgentStore.self) private var store
    @Environment(NotchUI.self) private var ui
    @State private var showQuiet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let link = ui.pendingLinks.first {
                LinkPicker(link: link, waiting: ui.pendingLinks.count - 1).id(link.id)
            } else if let opened = ui.justOpened {
                LinkOpenedNote(site: opened.site, profile: opened.profile)
            } else if ui.cardsOnly, let id = ui.noticeID, let agent = store.find(id) {
                NoticeView(agent: agent)
            } else {
                TopBar()
                if ui.showingTasks {
                    // The board gets the full width; the island stays the same size either way.
                    TasksView()
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)),
                                                removal: .opacity.combined(with: .offset(x: 24))))
                } else {
                    // Chats down the left, one conversation (or search) on the right.
                    HStack(alignment: .top, spacing: 12) {
                        Rail()
                        Rectangle().fill(.white.opacity(0.08)).frame(width: 1).frame(maxHeight: .infinity)
                        VStack(alignment: .leading, spacing: 6) { pane }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            // Going to and from search eases across; chat to chat stays instant.
                            .animation(.easeOut(duration: 0.2), value: ui.browsing)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: -24)),
                                            removal: .opacity.combined(with: .offset(x: -24))))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    @ViewBuilder private var pane: some View {
        Group {
            if ui.showingTasks {
                TasksView()
            } else if ui.showingProfiles {
                ProfilesView()
            } else if ui.composing {
                NewChatView()
            } else if let id = ui.selectedID, let agent = store.find(id) {
                ChatView(agent: agent).id(agent.id)
            } else {
                let asks = store.needing.filter { if case .followUp = $0.pending!.kind { return false } else { return true } }
                // Search is the same size as a conversation, so the island holds still while the
                // results rise into place over the chat fading out.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(asks) { PendingCard(agent: $0) }
                    roster
                }
                .frame(height: 452, alignment: .top)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)),
                                        removal: .opacity))
            }
        }
    }

    @ViewBuilder private var roster: some View {
        SearchBar()
        SearchResults()
    }

    @ViewBuilder private var sections: some View {
        let sessions = store.sessions.filter { !ui.isDismissed($0) }
        // Everything active, topped up with the most recent quiet ones.
        let shown = max(4, sessions.filter { $0.status != .idle }.count)
        Group {
            SectionHeader("Sessions")
            if sessions.isEmpty {
                Text("No Claude Code or Codex sessions right now.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(sessions.prefix(shown)) { AgentRow(agent: $0) }
                }
                if sessions.count > shown {
                    Text("and \(sessions.count - shown) quiet").font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4)).padding(.horizontal, 8)
                }
            }

            SectionHeader("Grok bots")
            if let error = store.grokError, store.grokBots.isEmpty {
                Text(error).font(.system(size: 12)).foregroundStyle(.white.opacity(0.4)).padding(.horizontal, 8)
            } else {
                // Quiet bots stay out of the way until asked for.
                let bots = store.grokBots.filter { showQuiet || ui.inPill($0) }
                let quiet = store.grokBots.count - store.grokBots.filter(ui.inPill).count
                VStack(spacing: 0) {
                    ForEach(bots) { AgentRow(agent: $0) }
                }
                if quiet > 0 {
                    Button(showQuiet ? "Hide quiet bots" : "Show \(quiet) quiet") { showQuiet.toggle() }
                        .buttonStyle(LinkButton()).padding(.horizontal, 6)
                }
            }

            Footer()
        }
    }
}

private struct SearchBar: View {
    @Environment(NotchUI.self) private var ui
    @Environment(AgentStore.self) private var store
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var ui = ui
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            TextField("Search chats and bots", text: $ui.query)
                .textFieldStyle(.plain).font(.system(size: 12.5)).focused($focused)
                .onKeyPress(.downArrow) {
                    ui.searchIndex = min(ui.searchIndex + 1, max(0, SearchItem.all(store, ui).count - 1))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    ui.searchIndex = max(ui.searchIndex - 1, 0)
                    return .handled
                }
                .onSubmit {
                    let items = SearchItem.all(store, ui)
                    if items.indices.contains(ui.searchIndex) { items[ui.searchIndex].open(ui) }
                }
            if !ui.query.isEmpty {
                Button { ui.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(Press())
            }
            Button { ui.composing = true } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(Press()).help("New Claude Code chat")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        // A click anywhere in the box starts typing, not only on the line of text.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            ui.controller?.panel.makeKey()
            focused = true
        })
        .onChange(of: focused) { _, on in if on { SessionIndex.shared.refresh() } }
        .onChange(of: ui.query) { ui.searchIndex = 0 }
        .onAppear {
            SessionIndex.shared.refresh()
            DispatchQueue.main.async { focused = true }
        }
    }
}

/// One thing search can land on.
enum SearchItem: Identifiable {
    case agent(Agent)
    case older(SessionIndex.Entry)
    case newChat(String)

    var id: String {
        switch self {
        case .agent(let a): return a.id
        case .older(let e): return "older:\(e.id)"
        case .newChat: return "new"
        }
    }

    /// Everything matching the search, in the order shown: live chats and bots, older Claude
    /// Code sessions by title, then the option to start fresh. With nothing typed, every live one.
    static func all(_ store: AgentStore, _ ui: NotchUI) -> [SearchItem] {
        let q = ui.query.trimmingCharacters(in: .whitespaces).lowercased()
        let everyone = store.sessions + store.grokBots
        guard !q.isEmpty else { return everyone.prefix(14).map { .agent($0) } }
        let live = everyone.filter { $0.name.lowercased().contains(q) || $0.detail.lowercased().contains(q) }
        let older = SessionIndex.shared.entries
            .filter { $0.title.lowercased().contains(q) && store.find("claude:\($0.id)") == nil }
        return live.prefix(8).map { .agent($0) } + older.prefix(6).map { .older($0) } + [.newChat(ui.query)]
    }

    func open(_ ui: NotchUI) {
        switch self {
        case .agent(let agent):
            ui.query = ""
            ui.dismissed[agent.id] = nil
            if agent.source != .grok { agent.kept = true }
            AgentStore.shared.save()
            ui.select(agent.id)
        case .older(let entry):
            ui.query = ""
            ui.select(CodingSessions.shared.adopt(entry).id)
        case .newChat(let prompt):
            ui.drafts["new"] = prompt
            ui.query = ""
            ui.composing = true
        }
    }
}

/// The search results. Arrow keys move the highlight, Return opens it, and clicking works too.
private struct SearchResults: View {
    @Environment(AgentStore.self) private var store
    @Environment(NotchUI.self) private var ui
    /// Rows come in one after another the first time the list appears, not on every keystroke.
    @State private var arrived = false

    var body: some View {
        let items = SearchItem.all(store, ui)
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item)
                    .background(.white.opacity(index == ui.searchIndex ? 0.12 : 0),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .opacity(arrived ? 1 : 0).offset(y: arrived ? 0 : 6)
                    .animation(.easeOut(duration: 0.22).delay(min(Double(index), 8) * 0.025), value: arrived)
            }
            if items.isEmpty {
                Text("Nothing matches.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 6).padding(.vertical, 5)
            }
            Text("↑ ↓ to move, Return to open").font(.system(size: 10)).foregroundStyle(.white.opacity(0.28))
                .padding(.horizontal, 6).padding(.top, 4)
        }
        .animation(.easeOut(duration: 0.12), value: ui.searchIndex)
        .onAppear { arrived = true }
    }

    @ViewBuilder private func row(_ item: SearchItem) -> some View {
        switch item {
        case .agent(let agent):
            HStack(spacing: 7) {
                FaceView(agent: agent, size: 18)
                Text(agent.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1).layoutPriority(1)
                Text(agent.detail.isEmpty ? agent.source.label : agent.detail)
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                Spacer(minLength: 4)
                StatusChip(agent: agent).layoutPriority(1)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .contentShape(Rectangle())
            .onTapGesture { item.open(ui) }
        case .older(let entry):
            PlainRow(icon: "clock", title: entry.title, trailing: nil) { item.open(ui) }
        case .newChat(let prompt):
            PlainRow(icon: "square.and.pencil", title: "New Claude Code chat: \(prompt)", trailing: nil) { item.open(ui) }
        }
    }
}

private struct PlainRow: View {
    let icon: String
    let title: String
    let trailing: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).frame(width: 18)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            Spacer(minLength: 4)
            if let trailing { Text(trailing).font(.system(size: 10)).foregroundStyle(.white.opacity(0.3)) }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(.white.opacity(hovered ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovered = $0 }
    }
}

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold)).kerning(0.6)
            .foregroundStyle(.white.opacity(0.32))
            .padding(.horizontal, 6).padding(.top, 3)
    }
}

// MARK: Rows

private struct AgentRow: View {
    let agent: Agent
    @Environment(NotchUI.self) private var ui
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 7) {
            FaceView(agent: agent, size: 18)
            Text(agent.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .lineLimit(1).layoutPriority(1)
            Text(agent.detail.isEmpty ? "Idle" : agent.detail)
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if ui.isDrafting(agent.id) {
                Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }
            StatusChip(agent: agent).layoutPriority(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(.white.opacity(hovered ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { ui.select(agent.id) }
        .onHover { hovered = $0 }
    }
}

/// How the island moves between Chats and To-dos.
private let tabSwitch = Animation.spring(response: 0.34, dampingFraction: 0.86)

// MARK: Top bar

/// What sits under the notch when the island is open: the two tabs on the left, and on the
/// right the Chrome profiles (one click each) and settings.
private struct TopBar: View {
    @Environment(NotchUI.self) private var ui
    @State private var profiles: [ChromeProfile] = []
    @State private var hovered: String?
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 6) {
            tab("Chats", on: !ui.showingTasks) {
                withAnimation(tabSwitch) { ui.showingTasks = false }
            }
            tab("To-dos", count: NotionTasks.shared.connected ? NotionTasks.shared.tasks.count : nil, on: ui.showingTasks) {
                ui.composing = false
                withAnimation(tabSwitch) { ui.showingTasks = true }
            }
            Spacer(minLength: 8)
            ForEach(profiles) { profile in
                ProfileAvatar(profile: profile, size: 22)
                    .scaleEffect(hovered == profile.id ? 1.14 : 1)
                    .animation(.easeOut(duration: 0.1), value: hovered)
                    .reach(3, 9)
                    .onHover { hovered = $0 ? profile.id : (hovered == profile.id ? nil : hovered) }
                    .onTapGesture {
                        profile.open()
                        ui.collapse()
                    }
            }
            Footer().frame(width: 24).padding(.leading, 2)
        }
        .onAppear { profiles = ChromeProfile.shown() }
    }

    private func tab(_ title: String, count: Int? = nil, on: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 12, weight: .semibold))
            if let count, count > 0 {
                Text("\(count)").font(.system(size: 10.5, weight: .semibold)).opacity(0.6)
            }
        }
        .foregroundStyle(on ? .black.opacity(0.85) : .white.opacity(0.6))
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background {
            ZStack {
                Capsule().fill(.white.opacity(0.08))
                // The white highlight is one shape that slides from tab to tab.
                if on { Capsule().fill(.white.opacity(0.92)).matchedGeometryEffect(id: "tab", in: pill) }
            }
        }
        .contentShape(Capsule())
        .onTapGesture(perform: action)
    }
}

// MARK: Rail

/// Every agent worth a glance, as a column of faces. Click one to switch conversation.
private struct Rail: View {
    @Environment(AgentStore.self) private var store
    @Environment(NotchUI.self) private var ui
    @State private var stripOpen = false
    @State private var overButton = false
    @State private var overStrip = false

    private var agents: [Agent] {
        var seen = Set<String>()
        let sessions = store.sessions.filter { !ui.isDismissed($0) }
        let active = sessions.filter { $0.status != .idle }
        // Chats the user added on purpose always show; other quiet ones only fill spare room.
        let kept = sessions.filter { $0.status == .idle && $0.kept }
        let quiet = kept + sessions.filter { $0.status == .idle && !$0.kept }.prefix(max(0, 5 - active.count - kept.count))
        // Pinned bots lead the rail; the rest only join when they have something.
        let pinned = store.grokBots.filter { ui.pinned.contains($0.name) }
        let bots = store.grokBots.filter(ui.inPill)
        // Whatever is open stays on the rail even if it has gone quiet.
        let open = ui.selectedID.flatMap { store.find($0) }.map { [$0] } ?? []
        let rest = (store.needing + active + quiet + bots + open)
            .filter { a in !pinned.contains { $0.id == a.id } }
        // A dragged order wins; anything not yet placed keeps its usual position after those.
        let rank = Dictionary(ui.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let arranged = rest.enumerated().sorted {
            let (l, r) = (rank[$0.element.id] ?? Int.max, rank[$1.element.id] ?? Int.max)
            return l != r ? l < r : $0.offset < $1.offset
        }.map(\.element)
        return (pinned + arranged).filter { seen.insert($0.id).inserted && !ui.isDismissed($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Search, with the new chat button on the same line.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10.5))
                Text("Search").font(.system(size: 11.5))
                Spacer(minLength: 0)
                Button {
                    ui.showingProfiles = false
                    ui.composing = true
                } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 12))
                        .foregroundStyle(.white.opacity(ui.composing ? 0.95 : 0.6))
                        .frame(width: 22, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(Press()).help("New Claude Code chat")
            }
            .foregroundStyle(.white.opacity(ui.browsing ? 0.9 : 0.5))
            .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 5)
            .background(.white.opacity(ui.browsing ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { ui.browse() }
            .padding(.bottom, 5)
            ForEach(agents) { agent in
                let star = agent.source == .grok && ui.pinned.contains(agent.name)
                RailRow(agent: agent, selected: ui.selectedID == agent.id && !ui.composing && !ui.showingProfiles && !ui.showingTasks, star: star) { dragged in
                    // Pinned bots stay at the top; everything else can be dragged into any order.
                    guard !star else { return }
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        ui.move(dragged, before: agent.id, in: agents.map(\.id))
                    }
                }
                // A cleared chat slides out to the left and fades, and the rows below close up.
                .transition(.asymmetric(insertion: .opacity,
                                        removal: .opacity.combined(with: .offset(x: -28)).combined(with: .scale(scale: 0.94, anchor: .leading))))
            }
            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: agents.map(\.id))
        .frame(width: 176)
    }

    /// Open while the pointer is on the button or the strip, with a short grace period so it
    /// survives the trip from one to the other.
    private func settleStrip() {
        if overButton || overStrip {
            withAnimation(.easeOut(duration: 0.14)) { stripOpen = true }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !overButton && !overStrip { withAnimation(.easeOut(duration: 0.14)) { stripOpen = false } }
            }
        }
    }

    private func railButton(_ icon: String, _ help: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12))
                .foregroundStyle(.white.opacity(on ? 0.95 : 0.5))
                .frame(width: 30, height: 24)
                .background(.white.opacity(on ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(Press()).help(help)
    }
}

/// A destination at the foot of the sidebar: icon, name, and an optional count.
private struct NavRow: View {
    let icon: String
    let title: String
    let on: Bool
    var badge: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 11)).frame(width: 18)
            Text(title).font(.system(size: 11.5, weight: on ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 0)
            if let badge {
                Text(badge).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 5).padding(.vertical, 1).background(.white.opacity(0.1), in: Capsule())
            }
        }
        .foregroundStyle(.white.opacity(on ? 0.95 : 0.6))
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(.white.opacity(on ? 0.14 : hovered ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovered = $0 }
    }
}

/// One chat in the sidebar: its face, its name, and a mark if it wants something.
private struct RailRow: View {
    let agent: Agent
    let selected: Bool
    let star: Bool
    let onDrop: (String) -> Void
    @Environment(NotchUI.self) private var ui
    @State private var hovered = false
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 6) {
            FaceView(agent: agent, size: 16)
                .frame(width: 20, height: 20)
            Text(agent.name)
                .font(.system(size: 11.5, weight: selected || agent.status > .done ? .semibold : .regular))
                .foregroundStyle(.white.opacity(agent.status == .idle && !selected ? 0.6 : 0.95))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if hovered && !star {
                // Clears it from the notch. It returns by itself if it does something new.
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { ui.dismiss(agent) }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6)).frame(width: 16, height: 16)
                        .background(.white.opacity(0.12), in: Circle()).contentShape(Rectangle())
                }
                .buttonStyle(Press()).help("Remove from the notch")
            } else if ui.isDrafting(agent.id) {
                Image(systemName: "pencil").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 5).padding(.vertical, 4)
        .background(.white.opacity(selected ? 0.14 : hovered ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { ui.select(agent.id) }
        // A double click goes on to the chat in its own app. The first click has already
        // selected it here, so a single click never has to wait to see if a second is coming.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if agent.source == .grok { GrokSource.shared.open(agent) } else { CodingSessions.shared.open(agent) }
            ui.collapse()
        })
        .onHover { hovered = $0 }
        .help("\(agent.name). Double click to open in its own app.")
        // Drag a chat onto another to place it just above.
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.blue).frame(height: 2).opacity(targeted && !star ? 1 : 0).offset(y: -1)
        }
        .draggable(agent.id)
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first else { return false }
            onDrop(id)
            return true
        } isTargeted: { targeted = $0 }
    }
}

// MARK: Notification banner

/// The short version of whatever just happened. Click it for the full chat.
private struct NoticeView: View {
    let agent: Agent
    @Environment(NotchUI.self) private var ui
    @State private var hovered = false

    private var headline: String {
        guard let pending = agent.pending else {
            switch agent.status {
            case .done: return "Finished"
            case .needsYou: return "Needs you"
            case .unread: return agent.unread > 1 ? "\(agent.unread) new messages" : "New message"
            default: return "Update"
            }
        }
        switch pending.kind {
        case .permission(let tool, _): return tool == "Bash" ? "Wants to run a command" : "Wants to use \(tool)"
        case .question: return "Has a question"
        case .followUp: return "Finished"
        }
    }

    private var summary: String {
        if let pending = agent.pending {
            switch pending.kind {
            case .permission(_, let detail): return oneLine(detail, max: 110)
            case .question(let questions, _): return questions.first?.text ?? ""
            case .followUp: break
            }
        }
        return oneLine(agent.lastMessage.isEmpty ? agent.detail : agent.lastMessage, max: 130)
    }

    private var isPermission: Bool {
        if case .permission = agent.pending?.kind { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            FaceView(agent: agent, size: 20).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(headline).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 0)
                }
                if !summary.isEmpty {
                    Text(summary).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                if isPermission {
                    HStack(spacing: 6) {
                        Button("Deny") { CodingSessions.shared.deny(agent) }.buttonStyle(ChipButton())
                        Button("Allow") { CodingSessions.shared.allow(agent) }.buttonStyle(ChipButton(fill: Palette.green))
                        Spacer()
                        Text("Click for the chat").font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(8)
        .background(.white.opacity(hovered ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { ui.show(agent.id) }
        .onHover { hovered = $0 }
        .padding(.bottom, 2)
    }
}

// MARK: To-do list

/// The Notion to-do list: add one at the top, tick them off, click a name to open it in Notion.
private struct TasksView: View {
    @State private var draft = ""
    @FocusState private var focused: Bool
    private var notion: NotionTasks { NotionTasks.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !notion.connected {
                setup
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                    TextField("Add a to-do to My to-dos", text: $draft)
                        .textFieldStyle(.plain).font(.system(size: 12.5)).focused($focused)
                        .onSubmit {
                            notion.add(draft)
                            draft = ""
                        }
                    Button { notion.refresh() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(notion.loading ? 0.25 : 0.5))
                            .frame(width: 20, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(Press()).help("Refresh from Notion")
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        // A click anywhere in the box starts typing, not only on the line of text.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            NotchUI.shared.controller?.panel.makeKey()
            focused = true
        })

                if let problem = notion.problem {
                    Text(problem).font(.system(size: 11)).foregroundStyle(Palette.amber.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 6)
                }
                // The board: one column per list, cards you can tick off or drag across.
                HStack(alignment: .top, spacing: 8) {
                    // Open columns sit together on the left; folded ones line up at the right edge.
                    let arranged = NotionTasks.columns.filter { !notion.folded.contains($0) }
                        + NotionTasks.columns.filter { notion.folded.contains($0) }
                    ForEach(arranged, id: \.self) { column in
                        TaskColumn(title: column, cards: notion.cards(in: column))
                    }
                }
            }
        }
        .padding(.top, 2)
        .onAppear {
            notion.refresh()
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Not connected to Notion yet.").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            Text("Perch needs a Notion access token saved at ~/.perch/notion-token, and the tasks database shared with that integration.")
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            Button("Check again") { notion.refresh() }.buttonStyle(ChipButton())
        }
        .padding(.horizontal, 6)
    }
}

/// One column of the board. Dropping a card on it moves the card there in Notion.
private struct TaskColumn: View {
    let title: String
    let cards: [TaskItem]
    @State private var targeted = false

    /// The colour Notion gives this column on the board.
    private var tint: Color {
        // Cool, quiet colours that white text reads well on. The warm orange and yellow Notion
        // uses turn muddy and hard to read as tints on a black island.
        switch title {
        case "Upshow to-dos": return Color(red: 0.25, green: 0.72, blue: 0.62)
        case "My to-dos": return Color(red: 0.36, green: 0.58, blue: 0.98)
        case "Waiting On": return Color(red: 0.62, green: 0.52, blue: 0.96)
        default: return .white.opacity(0.4)
        }
    }

    private var folded: Bool { NotionTasks.shared.folded.contains(title) }

    private func toggle() {
        withAnimation(tabSwitch) {
            if folded { NotionTasks.shared.folded.remove(title) } else { NotionTasks.shared.folded.insert(title) }
        }
    }

    var body: some View {
        Group {
            if folded {
                // Folded: a slim strip with the name down its side. Click to open it.
                VStack(spacing: 8) {
                    Circle().fill(tint).frame(width: 7, height: 7)
                    Text("\(cards.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                        .fixedSize().rotationEffect(.degrees(90)).frame(width: 16, height: 110)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                .frame(width: 40, height: 404)
                .contentShape(Rectangle())
                .onTapGesture { toggle() }
                .help("Open \(title)")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().fill(tint).frame(width: 7, height: 7)
                        Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                        Text("\(cards.count)").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.35))
                        Spacer()
                        Button(action: toggle) {
                            Image(systemName: "chevron.compact.left").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.4)).frame(width: 18, height: 16).contentShape(Rectangle())
                        }
                        .buttonStyle(Press()).help("Fold this column away")
                    }
                    .padding(.horizontal, 4)
                    ScrollView {
                        VStack(spacing: 5) {
                            ForEach(cards) { TaskCard(task: $0, tint: tint) }
                        }
                    }
                    .frame(height: 366)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(.white.opacity(targeted ? 0.1 : 0.035), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            NotionTasks.shared.move(id, to: title)
            return true
        } isTargeted: { targeted = $0 }
    }
}

private struct TaskCard: View {
    let task: TaskItem
    /// The column's colour. Cards are tinted with it, as on a Notion board with coloured columns.
    let tint: Color
    @State private var hovered = false
    @State private var ticking = false
    @State private var targeted = false

    private var dueText: (String, Color)? {
        guard let due = task.due else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                                   to: Calendar.current.startOfDay(for: due)).day ?? 0
        if days < 0 { return ("\(-days)d late", Palette.red) }
        if days == 0 { return ("Today", .white) }
        if days == 1 { return ("Tomorrow", .white.opacity(0.6)) }
        if days < 7 { return (due.formatted(.dateTime.weekday(.abbreviated)), .white.opacity(0.5)) }
        return (due.formatted(.dateTime.day().month(.abbreviated)), .white.opacity(0.45))
    }

    private var priorityColor: Color? {
        switch task.priority {
        case "Urgent": return Palette.red
        case "High": return .white
        default: return nil
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Button {
                ticking = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { NotionTasks.shared.complete(task) }
            } label: {
                Image(systemName: ticking ? "checkmark.circle.fill" : "circle").font(.system(size: 13.5))
                    .foregroundStyle(ticking ? Palette.green : .white.opacity(hovered ? 0.8 : 0.35))
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(Press()).help("Mark as done")
            VStack(alignment: .leading, spacing: 4) {
                Text(task.name).font(.system(size: 12)).foregroundStyle(.white.opacity(ticking ? 0.4 : 0.92))
                    .strikethrough(ticking).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if dueText != nil || priorityColor != nil {
                    HStack(spacing: 5) {
                        if let (text, color) = dueText {
                            Text(text).font(.system(size: 10.5, weight: color == .white ? .semibold : .medium)).foregroundStyle(color)
                        }
                        if let color = priorityColor {
                            Text(task.priority ?? "").font(.system(size: 10, weight: .semibold)).foregroundStyle(color.opacity(0.9))
                                .padding(.horizontal, 5).padding(.vertical, 1).background(color.opacity(0.18), in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(tint.opacity(hovered ? 0.3 : 0.2), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NotionTasks.shared.open(task) }
        .onHover { hovered = $0 }
        // Drop another card on this one to put it just above.
        .overlay(alignment: .top) {
            Capsule().fill(.white).frame(height: 2).opacity(targeted ? 0.9 : 0).offset(y: -3.5)
        }
        .draggable(task.id)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            NotionTasks.shared.place(id, before: task)
            return true
        } isTargeted: { targeted = $0 }
        .help("Drag to reorder or move column. Double click to open in Notion.")
    }
}

// MARK: Link picker

/// "Where should this open?" The profiles as big circles, best guess first. Click one or press
/// its number.
private struct LinkPicker: View {
    let link: PendingLink
    let waiting: Int
    @Environment(NotchUI.self) private var ui
    @State private var always = false
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Open \(link.site) in").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1).truncationMode(.middle)
            }
            HStack(alignment: .top, spacing: 4) {
                ForEach(Array(link.choices.enumerated()), id: \.element.id) { index, profile in
                    let likely = profile.id == link.suggested
                    VStack(spacing: 4) {
                        ProfileAvatar(profile: profile, size: 34)
                            .scaleEffect(hovered == profile.id ? 1.1 : 1)
                            .animation(.easeOut(duration: 0.1), value: hovered)
                        Text(profile.label).font(.system(size: 10.5, weight: likely ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(likely ? 0.95 : 0.65)).lineLimit(1).minimumScaleFactor(0.8)
                        Text("\(index + 1)").font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(width: 15, height: 15).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.white.opacity(hovered == profile.id ? 0.1 : likely ? 0.06 : 0),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                    .onHover { hovered = $0 ? profile.id : (hovered == profile.id ? nil : hovered) }
                    .onTapGesture { ui.resolveLink(profile, always: always) }
                }
            }
            HStack(spacing: 6) {
                if LinkRouter.shared.canSettle(link.site) {
                    Toggle(isOn: $always) {
                        Text("Always for this site").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.6))
                    }
                    .toggleStyle(.checkbox).controlSize(.small)
                } else {
                    Text("This site is always asked about").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.35))
                }
                Spacer()
                if waiting > 0 {
                    Text("\(waiting) more waiting").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                }
                Text(link.suggested == nil ? "Esc cancels" : "Return for the highlighted one").font(.system(size: 10)).foregroundStyle(.white.opacity(0.28))
            }
        }
        .padding(.horizontal, 4).padding(.top, 2)
    }

    private var detail: String {
        let path = link.url.path.count > 1 ? link.url.path : ""
        let from = link.sourceName.map { "from \($0)" } ?? ""
        return [path, from].filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }
}

/// A link Perch opened without asking, shown for a moment so a wrong guess can be corrected.
private struct LinkOpenedNote: View {
    let site: String
    let profile: ChromeProfile
    @Environment(NotchUI.self) private var ui

    var body: some View {
        HStack(spacing: 8) {
            ProfileAvatar(profile: profile, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text("Opened in \(profile.label)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                Text(site).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
            Spacer()
            Button("Wrong one") { ui.reconsider() }.buttonStyle(ChipButton())
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
    }
}

// MARK: Chrome profiles

/// A profile as a circle: a chosen icon, else its Google picture ringed in Chrome's colour for
/// it, else a plain coloured initial.
private struct ProfileAvatar: View {
    let profile: ChromeProfile
    let size: CGFloat

    private static let pictures = NSCache<NSString, NSImage>()

    private var tint: Color {
        guard let argb = profile.argb else { return Palette.blue }
        let v = UInt32(truncatingIfNeeded: argb)
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    private static var solid: [ObjectIdentifier: Bool] = [:]

    /// True when the image is painted right into its corners, i.e. a solid square, not a
    /// shape on a transparent background.
    private static func fillsItsSquare(_ image: NSImage) -> Bool {
        let key = ObjectIdentifier(image)
        if let known = solid[key] { return known }
        var result = false
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            let (w, h) = (rep.pixelsWide, rep.pixelsHigh)
            let corners = [(1, 1), (w - 2, 1), (1, h - 2), (w - 2, h - 2)]
            result = w > 4 && h > 4 && corners.allSatisfy { (rep.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 0) > 0.95 }
        }
        solid[key] = result
        return result
    }

    private var icon: NSImage? {
        guard let path = profile.iconPath else { return nil }
        if let cached = Self.pictures.object(forKey: path as NSString) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        Self.pictures.setObject(image, forKey: path as NSString)
        return image
    }

    private var picture: NSImage? {
        guard let path = profile.picturePath else { return nil }
        if let cached = Self.pictures.object(forKey: path as NSString) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        Self.pictures.setObject(image, forKey: path as NSString)
        return image
    }

    var body: some View {
        let initial = String(profile.label.prefix(1)).uppercased()
        ZStack {
            if let icon, Self.fillsItsSquare(icon) {
                // A solid square icon (a block of brand colour) fills the whole circle.
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size).clipShape(Circle())
            } else if let icon {
                // A logo with transparent edges sits whole on a white disc instead.
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                    .padding(size * 0.14)
                    .frame(width: size, height: size).background(.white, in: Circle()).clipShape(Circle())
            } else if let picture {
                Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size).clipShape(Circle())
            } else {
                Text(initial).font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.black.opacity(0.8))
                    .frame(width: size, height: size).background(tint, in: Circle())
            }
        }
        .frame(width: size, height: size)
    }
}

/// The quick way in: hover the profiles button and the profiles fan out as circles. One click
/// takes you to that profile's window.
private struct ProfileStrip: View {
    @Environment(NotchUI.self) private var ui
    @State private var profiles: [ChromeProfile] = []
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(profiles.first { $0.id == hovered }?.label ?? "Go to a Chrome profile")
                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(hovered == nil ? 0.4 : 0.8))
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 5) {
                ForEach(profiles) { profile in
                    ProfileAvatar(profile: profile, size: 20)
                        .scaleEffect(hovered == profile.id ? 1.18 : 1)
                        .animation(.easeOut(duration: 0.12), value: hovered)
                        .reach(2, 8)
                        .onHover { hovered = $0 ? profile.id : (hovered == profile.id ? nil : hovered) }
                        .onTapGesture {
                            profile.open()
                            ui.collapse()
                        }
                }
            }
        }
        .padding(.horizontal, 5).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onAppear { profiles = ChromeProfile.shown() }
    }
}

/// Jump to a Chrome profile, or open the link you just copied in the right one.
private struct ProfilesView: View {
    @Environment(NotchUI.self) private var ui
    @State private var profiles: [ChromeProfile] = []
    @State private var link: URL?
    @State private var canJump = ChromeProfile.canJump

    private static let tints: [Color] = [Palette.blue, Palette.green, Palette.amber, Palette.red] + Palette.colors

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chrome profiles").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 6)
            if let link {
                HStack(spacing: 5) {
                    Image(systemName: "link").font(.system(size: 10))
                    Text("Copied link: \(link.host ?? "")").font(.system(size: 11)).lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.5)).padding(.horizontal, 6)
            }
            VStack(spacing: 1) {
                ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                    ProfileRow(profile: profile, tint: Self.tints[index % Self.tints.count], link: link) { url in
                        profile.open(url)
                        ui.collapse()
                    }
                }
            }
            if !canJump {
                // Without this a click opens a fresh window instead of the one already open.
                VStack(alignment: .leading, spacing: 5) {
                    Text("To go to the window a profile already has open, Perch needs the Accessibility permission. Until then a click opens a new window.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                    Button("Allow in System Settings") { ChromeProfile.askToJump() }.buttonStyle(ChipButton())
                }
                .padding(.horizontal, 6).padding(.top, 4)
            }
            if profiles.isEmpty {
                Text("No Chrome profiles found.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 6)
            }
        }
        .padding(.top, 2)
        .onAppear {
            profiles = ChromeProfile.shown()
            link = ChromeProfile.copiedLink
            canJump = ChromeProfile.canJump
        }
    }
}

private struct ProfileRow: View {
    let profile: ChromeProfile
    let tint: Color
    let link: URL?
    let open: (URL?) -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            ProfileAvatar(profile: profile, size: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(profile.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if !profile.email.isEmpty {
                    Text(profile.email).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let link {
                Button("Open link here") { open(link) }.buttonStyle(ChipButton())
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(.white.opacity(hovered ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { open(nil) }
        .onHover { hovered = $0 }
    }
}

// MARK: New chat

/// Write the first message of a new Claude Code session and it starts right here.
private struct NewChatView: View {
    @Environment(AgentStore.self) private var store
    @Environment(NotchUI.self) private var ui
    @State private var folder = UserDefaults.standard.string(forKey: "newChatFolder") ?? ""
    @FocusState private var focused: Bool

    /// Folders to offer: the one used last time, ones picked by hand, then wherever recent
    /// sessions were working. Throwaway and hidden locations are left out.
    private var folders: [String] {
        var seen = Set<String>()
        let fm = FileManager.default
        let picked = UserDefaults.standard.stringArray(forKey: "pickedFolders") ?? []
        let live = store.sessions.filter { $0.source == .claude }.compactMap(\.cwd)
        let older = SessionIndex.shared.entries.compactMap(\.cwd)
        let all = [folder] + picked + live + older + ["\(Shell.home)/Dev"]
        return all.filter { path in
            !path.isEmpty && !path.contains("/.") && !path.hasPrefix("/tmp") && !path.hasPrefix("/private")
                && fm.fileExists(atPath: path) && seen.insert(path).inserted
        }.prefix(10).map { $0 }
    }

    private func choose(_ path: String) {
        folder = path
        UserDefaults.standard.set(path, forKey: "newChatFolder")
        focused = true
    }

    /// Any other folder, through the normal macOS chooser. The island tucks away while it is
    /// up and comes back on the new chat afterwards.
    private func browse(from current: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use this folder"
        panel.message = "Where should the new chat work?"
        panel.directoryURL = URL(fileURLWithPath: current)
        panel.level = .popUpMenu
        NSApp.activate(ignoringOtherApps: true)
        let ui = ui
        panel.begin { response in
            if response == .OK, let path = panel.url?.path {
                var picked = UserDefaults.standard.stringArray(forKey: "pickedFolders") ?? []
                picked.removeAll { $0 == path }
                picked.insert(path, at: 0)
                UserDefaults.standard.set(Array(picked.prefix(6)), forKey: "pickedFolders")
                UserDefaults.standard.set(path, forKey: "newChatFolder")
            }
            ui.composing = true
            ui.expand()
            ui.controller?.panel.makeKey()
        }
    }

    private func chip(_ path: String, selected: Bool) -> some View {
        Button { choose(path) } label: {
            HStack(spacing: 5) {
                Image(systemName: selected ? "folder.fill" : "folder").font(.system(size: 10))
                Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.black : .white.opacity(0.75))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(selected ? Color.white.opacity(0.92) : .white.opacity(0.09), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(Press())
    }

    var body: some View {
        let draft = Binding(get: { ui.drafts["new"] ?? "" }, set: { ui.drafts["new"] = $0 })
        let options = folders
        let chosen = options.contains(folder) ? folder : (options.first ?? Shell.home)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Button { ui.composing = false } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6)).frame(width: 18, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(Press())
                Text("New Claude Code chat").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Work in").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(options, id: \.self) { path in chip(path, selected: path == chosen) }
                        Button { browse(from: chosen) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "plus").font(.system(size: 9.5, weight: .semibold))
                                Text("Other folder").font(.system(size: 11.5))
                            }
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .overlay(Capsule().strokeBorder(.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(Press())
                    }
                }
                Text(chosen.replacingOccurrences(of: Shell.home, with: "~"))
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1).truncationMode(.head)
            }
            .padding(.top, 4)
            // The same size as a conversation, with the message box at the bottom where it is
            // in every other chat, so starting one does not make the island shrink.
            Spacer(minLength: 0)
            Text("Starts in the background in auto mode and shows up in the Claude app once it has replied.")
                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.3))
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .bottom, spacing: 6) {
                TextField("What do you want to work on?", text: draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 12.5)).lineLimit(3...12)
                    .focused($focused)
                    .onSubmit { start(chosen) }
                Button { Dictation.shared.toggle(for: "new") } label: {
                    let listening = Dictation.shared.activeAgentID == "new"
                    Image(systemName: listening ? "mic.fill" : "mic").font(.system(size: 13))
                        .foregroundStyle(listening ? Palette.red : .white.opacity(0.45))
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(Press())
                Button { start(chosen) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 16))
                        .foregroundStyle(draft.wrappedValue.isEmpty ? .white.opacity(0.2) : Palette.blue)
                }
                .buttonStyle(Press()).disabled(draft.wrappedValue.isEmpty)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        // A click anywhere in the box starts typing, not only on the line of text.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            ui.controller?.panel.makeKey()
            focused = true
        })
        }
        .frame(height: 452, alignment: .top)
        .padding(.top, 2)
        .onAppear {
            SessionIndex.shared.refresh()
            ui.controller?.panel.makeKey()
            DispatchQueue.main.async { focused = true }
        }
    }

    private func start(_ folder: String) {
        let prompt = ui.drafts["new"] ?? ""
        guard let agent = CodingSessions.shared.startChat(prompt: prompt, folder: folder) else { return }
        Dictation.shared.stop()
        ui.drafts["new"] = nil
        ui.select(agent.id)
    }
}

// MARK: Chat

/// One agent's conversation: recent messages in full, and a reply box.
private struct ChatView: View {
    let agent: Agent
    @Environment(NotchUI.self) private var ui
    /// How many of the most recent messages are drawn.
    @State private var shown = 10
    /// Rests the view on the newest message, by its top edge: a long reply is read from its
    /// first line, and anything shorter simply sits at the bottom of the chat.
    private func settle(_ proxy: ScrollViewProxy) {
        if let target = Self.restingID(messages) { proxy.scrollTo(target, anchor: .top) }
    }

    /// The id of the last thing drawn: the last message, or the first of a trailing run of
    /// bot-to-bot messages (which are drawn as one line under that id).
    private static func restingID(_ messages: [ChatMessage]) -> String? {
        guard let last = messages.last else { return nil }
        guard last.peerName != nil else { return last.id }
        var id = last.id
        for message in messages.reversed() {
            if message.peerName == nil { break }
            id = message.id
        }
        return id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    // Not lazy: every message has to exist for the view to be able to come to
                    // rest on the newest one, and a chat is only a few dozen messages.
                    VStack(alignment: .leading, spacing: 10) {
                        if messages.count > shown {
                            Button("Show earlier messages") { shown += 20 }
                                .buttonStyle(LinkButton()).frame(maxWidth: .infinity)
                        }
                        ForEach(items) { item in
                            Group {
                                if item.peers.isEmpty, let message = item.message {
                                    bubble(message)
                                } else {
                                    PeerGroup(owner: agent.name, messages: item.peers)
                                }
                            }
                            .id(item.id)
                        }
                        if agent.status == .working {
                            Text(agent.source == .grok ? "\(agent.name) is working…" : "Working…")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .padding(.horizontal, 6)
                }
                // A fixed height keeps the island the same size every time it opens, so the
                // opening animation has one target instead of jumping as the history loads.
                .frame(height: 380)
                .onChange(of: messages.last?.id) {
                    withAnimation(.easeOut(duration: 0.22)) { settle(proxy) }
                }
                .onAppear {
                    // Go to the newest message as the chat appears, and again once it has been
                    // laid out, since the first attempt can land before the content has a size.
                    settle(proxy)
                    DispatchQueue.main.async { settle(proxy) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { settle(proxy) }
                    // Opened before its history arrived: fetch it now, and once more shortly after
                    // in case the first try was too early.
                    if agent.thread.isEmpty {
                        // Keep asking for a few seconds: just after launch the first tries can
                        // land before Perch has finished connecting.
                        for delay in [0.0, 1.0, 2.5, 5.0, 9.0] {
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { if agent.thread.isEmpty { Threads.load(agent) } }
                        }
                    }
                }
            }
            if agent.status == .needsYou, agent.pending == nil {
                // It asked for something, but the request itself is not open here (answered or
                // timed out elsewhere, or Perch restarted while it was waiting).
                VStack(alignment: .leading, spacing: 5) {
                    Text(agent.askElsewhere.map { "Waiting for your answer in its own app. It wants to use \($0)" }
                         ?? "It asked for something, but that request is not open here. Check it in its own app, or tell it to carry on.")
                        .font(.system(size: 11)).foregroundStyle(Palette.amber.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open it there") { open() }.buttonStyle(ChipButton())
                }
                .padding(.horizontal, 6)
            }
            if !agent.queued.isEmpty {
                Text("Sent. It will read this at its next step.").font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4)).padding(.horizontal, 6)
            }
            if let pending = agent.pending {
                if case .followUp = pending.kind {
                    // Just finished: it is simply a chat, so only the reply box.
                    ReplyField(agent: agent, autofocus: ui.focusReply)
                } else {
                    PendingCard(agent: agent)
                }
            } else {
                ReplyField(agent: agent, autofocus: ui.focusReply)
            }
        }
        .padding(.top, 2)
        // Reload when the agent says something new or changes state.
        .task(id: "\(agent.id)|\(agent.status.rawValue)|\(agent.lastMessage.count)|\(agent.tick)") { Threads.load(agent) }
        // Having the chat open in front of you is reading it, however it came to be open and
        // whenever the message arrived.
        .onAppear { ui.markSeen(agent.id) }
        .onChange(of: agent.unread) { ui.markSeen(agent.id) }
        .onChange(of: agent.status) { ui.markSeen(agent.id) }
    }

    /// What is drawn, top to bottom: ordinary messages one by one, and each run of bot-to-bot
    /// messages gathered into a single line, the way Grok Bot shows them.
    private struct Item: Identifiable {
        let id: String
        var message: ChatMessage?
        var peers: [ChatMessage] = []
    }

    private var items: [Item] {
        var out: [Item] = []
        // Drawing a whole long conversation is what made the island slow to open, so only the
        // recent part is laid out until earlier messages are asked for.
        for message in messages.suffix(shown) {
            if message.peerName != nil {
                if let last = out.indices.last, !out[last].peers.isEmpty {
                    out[last].peers.append(message)
                } else {
                    out.append(Item(id: message.id, peers: [message]))
                }
            } else {
                out.append(Item(id: message.id, message: message))
            }
        }
        return out
    }

    /// Until the history has loaded, at least show the latest thing the agent said.
    private var messages: [ChatMessage] {
        if !agent.thread.isEmpty { return agent.thread }
        let latest = agent.lastMessage.isEmpty ? agent.detail : agent.lastMessage
        return latest.isEmpty ? [] : [ChatMessage(id: "latest", fromUser: false, text: latest)]
    }

    private var header: some View {
        HStack(spacing: 7) {
            FaceView(agent: agent, size: 18)
            Text(agent.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            if agent.source != .grok {
                Text(agent.source.label).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
            }
            Spacer(minLength: 4)
            StatusChip(agent: agent)
            Button(action: open) {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6)).frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(Press()).help("Open in its own app")
        }
        .padding(.horizontal, 2)
    }

    private static let imageNote = try! NSRegularExpression(pattern: #"\[Image attached, saved at ([^\]]+)\]"#)
    private static let thumbnails = NSCache<NSString, NSImage>()

    /// Pulls the "image attached" notes out of a message, so the pictures can be shown instead.
    private static var split: [String: (text: String, paths: [String])] = [:]

    private static func splitImages(_ text: String) -> (text: String, paths: [String]) {
        if let done = split[text] { return done }
        let result = findImages(text)
        if split.count > 400 { split.removeAll() }
        split[text] = result
        return result
    }

    private static func findImages(_ text: String) -> (text: String, paths: [String]) {
        guard text.contains("[Image attached") else { return (text, []) }
        let range = NSRange(text.startIndex..., in: text)
        let paths = imageNote.matches(in: text, range: range).compactMap { m in
            Range(m.range(at: 1), in: text).map { String(text[$0]) }
        }
        guard !paths.isEmpty else { return (text, []) }
        let cleaned = imageNote.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return (cleaned.trimmingCharacters(in: .whitespacesAndNewlines), paths)
    }

    /// A small copy of a picture, made off the main thread. Screenshots are several thousand
    /// pixels across, and decoding them at full size in the middle of drawing a chat is what
    /// made opening one hang.
    fileprivate static func thumbnail(_ path: String, done: @escaping (NSImage?) -> Void) {
        if let cached = thumbnails.object(forKey: path as NSString) { return done(cached) }
        DispatchQueue.global(qos: .userInitiated).async {
            var image: NSImage?
            let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                           kCGImageSourceThumbnailMaxPixelSize: 520] as CFDictionary
            if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
               let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options) {
                image = NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height))
            }
            DispatchQueue.main.async {
                if let image { thumbnails.setObject(image, forKey: path as NSString) }
                done(image)
            }
        }
    }

    private struct Picture: View {
        let path: String
        @State private var image: NSImage?

        var body: some View {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Color.white.opacity(0.06).frame(width: 170, height: 110)
                }
            }
            .frame(maxWidth: 230, maxHeight: 170)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            .help("Open the image")
            .task(id: path) { ChatView.thumbnail(path) { image = $0 } }
        }
    }

    @ViewBuilder private func pictures(_ paths: [String]) -> some View {
        ForEach(paths, id: \.self) { Picture(path: $0) }
    }

    /// The fill for the user's own bubbles in this chat.
    private var mine: Color {
        switch agent.source {
        case .claude: return Color(red: 0.80, green: 0.42, blue: 0.29)
        case .codex: return Color(red: 0.40, green: 0.36, blue: 0.93)
        case .grok: return Color(white: 0.96)
        }
    }

    @ViewBuilder private func bubble(_ message: ChatMessage) -> some View {
        let parts = Self.splitImages(message.text)
        VStack(alignment: message.fromUser ? .trailing : .leading, spacing: 3) {
            if let peer = message.peerName {
                PeerNote(owner: agent.name, peer: peer, outbound: message.peerOutbound, text: parts.text)
            } else if message.fromUser {
                pictures(parts.paths)
                if !parts.text.isEmpty {
                    HStack {
                        Spacer(minLength: 50)
                        // Your side takes the colour of whoever you are talking to: Claude's orange,
                        // Codex's blue-violet, and plain white (with dark text) for Grok bots.
                        Text(Self.markdown(parts.text)).font(.system(size: 12.5)).lineSpacing(2)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(agent.source == .grok ? Color.black.opacity(0.88) : .white)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(mine, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                }
            } else if let name = message.fileName, let path = message.filePath {
                FileCard(name: name, path: path, agent: agent)
            } else if let email = message.email {
                EmailCard(draft: email, agent: agent)
            } else {
                // The agent's side: a quieter bubble on the left, yours brighter on the right.
                AgentBubble(text: parts.text, react: agent.source == .grok && !message.id.hasPrefix("local-") ? { emoji in
                    GrokSource.shared.react(emoji, to: message.id, in: agent)
                } : nil)
            }
            if !message.reactions.isEmpty {
                // Reactions the agent (or you) left on this message in Grok Bot.
                HStack(spacing: 3) {
                    ForEach(Array(message.reactions.enumerated()), id: \.offset) { _, emoji in
                        Text(emoji).font(.system(size: 11))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(.white.opacity(0.1), in: Capsule())
                    }
                }
            }
        }
    }

    /// Bold, code and links render; line breaks and lists stay as written.
    private static func markdown(_ s: String) -> AttributedString {
        if let done = styled[s] { return done }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let result = (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
        if styled.count > 400 { styled.removeAll() }
        styled[s] = result
        return result
    }

    private static var styled: [String: AttributedString] = [:]

    private func open() {
        if agent.source == .grok { GrokSource.shared.open(agent) } else { CodingSessions.shared.open(agent) }
        ui.collapse()
    }
}

private struct StatusChip: View {
    let agent: Agent

    var body: some View {
        switch agent.status {
        case .needsYou: chip("Needs you", Palette.amber)
        case .working: chip("Working", Palette.blue)
        case .done: chip("Done", Palette.green)
        case .unread: chip("\(agent.unread)", Palette.red)
        case .idle:
            Text(ago(agent.lastActivity)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(color.opacity(0.16), in: Capsule())
    }

    private func ago(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

private struct ReplyField: View {
    let agent: Agent
    var autofocus = false
    @Environment(NotchUI.self) private var ui
    @FocusState private var focused: Bool

    /// Nothing blocks a reply any more: mid-turn messages are delivered at the next step.
    private var busy: Bool { false }

    private var placeholder: String {
        if let problem = Dictation.shared.problem { return problem }
        if Dictation.shared.activeAgentID == agent.id { return "Listening…" }
        if agent.source == .grok { return "Message \(agent.name), paste images too" }
        if agent.source != .grok, agent.status == .working, agent.pending == nil { return "Message now, it reads it at its next step" }
        if agent.pending != nil { return "Tell it what to do next" }
        return agent.waiter != nil ? "Reply to this session" : "Reply in the background"
    }

    var body: some View {
        let draft = Binding(get: { ui.drafts[agent.id] ?? "" }, set: { ui.drafts[agent.id] = $0 })
        let files = ui.attachments[agent.id] ?? []
        let empty = draft.wrappedValue.isEmpty && files.isEmpty
        let listening = Dictation.shared.activeAgentID == agent.id
        // Typing "/" offers your skills; click one, or press Tab for the first.
        let typed = draft.wrappedValue
        let offers = agent.source != .grok && typed.hasPrefix("/") && !typed.contains(" ")
            ? Array(SkillIndex.shared.matching(typed).prefix(6)) : []
        VStack(alignment: .leading, spacing: 6) {
            if !offers.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(offers) { skill in
                        HStack(spacing: 6) {
                            Text("/\(skill.id)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
                                .lineLimit(1).layoutPriority(1)
                            Text(skill.summary).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(.white.opacity(skill.id == offers.first?.id ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { ui.drafts[agent.id] = "/\(skill.id) " }
                    }
                }
            }
            if !files.isEmpty {
                HStack(spacing: 6) {
                    ForEach(files) { file in
                        Image(nsImage: file.thumbnail).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                Button { ui.attachments[agent.id]?.removeAll { $0.id == file.id } } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                                        .foregroundStyle(.white, .black.opacity(0.7))
                                }
                                .buttonStyle(Press()).offset(x: 4, y: -4)
                            }
                    }
                }
                .padding(.top, 3)
            }
        HStack(alignment: .bottom, spacing: 6) {
            TextField(placeholder, text: draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...4)
                .focused($focused)
                .onSubmit { send() }
                .onKeyPress(.tab) {
                    guard let first = offers.first else { return .ignored }
                    ui.drafts[agent.id] = "/\(first.id) "
                    return .handled
                }
                .disabled(busy)
            Button { Dictation.shared.toggle(for: agent.id) } label: {
                Image(systemName: listening ? "mic.fill" : "mic").font(.system(size: 13))
                    .foregroundStyle(listening ? Palette.red : .white.opacity(0.45))
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(Press()).disabled(busy)
            .help(listening ? "Stop dictating" : "Dictate a reply")
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 15))
                    .foregroundStyle(empty || busy ? .white.opacity(0.2) : agent.color)
            }
            .buttonStyle(Press())
            .disabled(empty || busy)
        }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .stroke(.white.opacity(focused ? 0.38 : 0.2), lineWidth: 1))
        // The text line itself is thin. A click anywhere in the box starts typing.
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .simultaneousGesture(TapGesture().onEnded {
            guard !busy else { return }
            ui.controller?.panel.makeKey()
            focused = true
        })
        .onChange(of: focused) { _, on in
            if on {
                ui.focusedAgentID = agent.id
                SkillIndex.shared.refresh()
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                    guard let data, let image = NSImage(data: data) else { return }
                    DispatchQueue.main.async {
                        if let file = Attachment.from(image) { ui.attachments[agent.id, default: []].append(file) }
                    }
                }
            }
            return true
        }
        .onAppear {
            guard autofocus, !busy else { return }
            DispatchQueue.main.async { focused = true }
        }
    }

    private func send() {
        let text = (ui.drafts[agent.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let files = ui.attachments[agent.id] ?? []
        guard !(text.isEmpty && files.isEmpty), !busy else { return }
        Dictation.shared.stop()
        ui.drafts[agent.id] = nil
        ui.attachments[agent.id] = nil
        if agent.source == .grok {
            GrokSource.shared.send(agent, text: text, files: files)
        } else {
            // Claude Code and Codex run on this Mac, so they can open the saved image themselves.
            let notes = files.map { "[Image attached, saved at \($0.path)]" }
            CodingSessions.shared.reply(agent, text: ([text] + notes).filter { !$0.isEmpty }.joined(separator: "\n\n"))
        }
    }
}

/// The agent's bubble. In a Grok bot's chat, hovering it shows a small face beside it; that
/// opens a menu of reactions. Picking one leaves it on the message in Grok Bot (picking it
/// again takes it back).
private struct AgentBubble: View {
    let text: String
    let react: ((String) -> Void)?
    @State private var hovered = false

    private static let quick = ["👍", "❤️", "😂", "🙏", "👀", "✅"]

    var body: some View {
        HStack(spacing: 0) {
            MessageBody(text: text)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            // Only while the pointer is on the message: one small, dim face. Clicking it opens
            // a menu of reactions.
            if let react {
                Menu {
                    ForEach(Self.quick, id: \.self) { emoji in
                        Button(emoji) { react(emoji) }
                    }
                } label: {
                    Image(systemName: "face.smiling").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                        .frame(width: 26, height: 24).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .padding(.leading, 2)
                .opacity(hovered ? 1 : 0)
            }
            Spacer(minLength: 28)
        }
        // The whole row counts as "on the message", including the gap between the bubble and
        // the face, so the face does not vanish on the way over to it.
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

/// An agent's message, with the parts plain text cannot carry drawn properly: tables as real
/// tables and headings as headings. Everything else keeps its line breaks and inline styling.
private struct MessageBody: View {
    let text: String

    private enum Block: Identifiable {
        case prose(Int, String)
        case table(Int, [String], [[String]])

        var id: Int {
            switch self {
            case .prose(let i, _), .table(let i, _, _): return i
            }
        }
    }

    private static func cells(_ line: Substring) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isDivider(_ line: Substring) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.contains("-") && t.allSatisfy { "|-: ".contains($0) }
    }

    private static var parsed: [String: [Block]] = [:]

    /// Splitting a message into prose and tables is done once per message and kept, so going
    /// back to a chat costs nothing.
    private var blocks: [Block] {
        if let done = Self.parsed[text] { return done }
        let result = parse()
        if Self.parsed.count > 400 { Self.parsed.removeAll() }
        Self.parsed[text] = result
        return result
    }

    private func parse() -> [Block] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [Block] = []
        var prose: [String] = []
        var i = 0
        func flush() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { out.append(.prose(out.count, joined)) }
            prose = []
        }
        while i < lines.count {
            let line = lines[i]
            // A table is a row of cells followed by a divider row.
            if line.contains("|"), i + 1 < lines.count, Self.isDivider(lines[i + 1]) {
                flush()
                let header = Self.cells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(Self.cells(lines[i]))
                    i += 1
                }
                out.append(.table(out.count, header, rows))
                continue
            }
            // Headings become bold lines; there is no room for big type up here.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                prose.append(title.isEmpty ? "" : "**\(title.replacingOccurrences(of: "**", with: ""))**")
            } else {
                prose.append(String(line))
            }
            i += 1
        }
        flush()
        return out
    }

    private static var formatted: [String: AttributedString] = [:]

    /// Formatting is worked out once per piece of text and kept, so reopening a chat is cheap.
    private static func inline(_ s: String) -> AttributedString {
        if let done = formatted[s] { return done }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let result = (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
        if formatted.count > 600 { formatted.removeAll() }
        formatted[s] = result
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block {
                case .prose(_, let s):
                    Text(Self.inline(s)).font(.system(size: 12.5)).lineSpacing(2)
                        .foregroundStyle(.white.opacity(0.88)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .table(_, let header, let rows):
                    table(header, rows)
                }
            }
        }
    }

    private func table(_ header: [String], _ rows: [[String]]) -> some View {
        let columns = header.count
        return Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<columns, id: \.self) { c in
                    Text(Self.inline(header[c])).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Rectangle().fill(.white.opacity(0.1)).frame(height: 1).gridCellColumns(columns)
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        Text(Self.inline(c < row.count ? row[c] : "")).font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.88)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                    }
                }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 1))
    }
}

/// A file an agent attached. Text files open right here, formatted; anything else points to
/// the agent's own app.
private struct FileCard: View {
    let name: String
    let path: String
    let agent: Agent
    @Environment(NotchUI.self) private var ui
    @State private var expanded = false
    @State private var text: String?
    @State private var failed = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Spacer()
                Text(expanded ? "Hide" : "Read").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle() }

            if expanded {
                Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                if let text {
                    MessageBody(text: text)
                    HStack(spacing: 6) {
                        Button(copied ? "Copied" : "Copy all") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            copied = true
                        }
                        .buttonStyle(ChipButton())
                        Spacer()
                    }
                } else if failed {
                    Text("This one can only be opened in Grok Bot.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
                    Button("Open Grok Bot") {
                        GrokSource.shared.open(agent)
                        ui.collapse()
                    }
                    .buttonStyle(ChipButton())
                } else {
                    Text("Loading…").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private func toggle() {
        expanded.toggle()
        guard expanded, text == nil, !failed else { return }
        GrokSource.shared.readAttachment(path) { loaded in
            if let loaded { text = loaded } else { failed = true }
        }
    }
}

/// A run of messages between bots, as one quiet centred line: "4 messages with Tweetie and
/// Link", or "Message from Tweetie". Click it to read them.
private struct PeerGroup: View {
    let owner: String
    let messages: [ChatMessage]
    @Environment(AgentStore.self) private var store
    @State private var expanded = false

    private var names: [String] {
        var seen = Set<String>()
        return messages.compactMap(\.peerName).filter { seen.insert($0).inserted }
    }

    private var lead: String {
        if messages.count > 1 { return "\(messages.count) messages with" }
        return messages[0].peerOutbound ? "Message to" : "Message from"
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Text(lead)
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                    if index > 0 { Text(index == names.count - 1 ? "and" : ",") }
                    if let bot = store.grokBots.first(where: { $0.name == name }) { FaceView(agent: bot, size: 13) }
                    Text(name).foregroundStyle(.white.opacity(0.7))
                }
            }
            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.42))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }

            if expanded {
                ForEach(messages) { m in
                    PeerNote(owner: owner, peer: m.peerName ?? "", outbound: m.peerOutbound, text: m.text)
                }
            }
        }
    }
}

/// One bot briefing another. Shown folded and set apart, so the conversation with the user
/// stays readable; click to read the whole exchange.
private struct PeerNote: View {
    let owner: String
    let peer: String
    let outbound: Bool
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: outbound ? "arrow.turn.up.right" : "arrow.turn.down.left").font(.system(size: 9, weight: .semibold))
                Text(outbound ? "\(owner) to \(peer)" : "\(peer) to \(owner)").font(.system(size: 10.5, weight: .semibold))
                Spacer()
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.45))
            Text(text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                .lineLimit(expanded ? nil : 2).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
    }
}

/// A drafted email, laid out like the card Grok Bot shows. Sending stays in Grok Bot,
/// which owns the mail connection; from here it can be read, copied, or sent back for changes.
private struct EmailCard: View {
    let draft: EmailDraft
    let agent: Agent
    @Environment(NotchUI.self) private var ui
    @State private var copied = false

    @State private var expanded = false

    private var sent: Bool { draft.sendState == "sent" }
    /// Sent and replaced drafts fold away; only a live draft needs reading in full.
    private var settled: Bool { sent || draft.superseded || draft.sendState != nil }

    private var label: String {
        if sent { return "Email sent" }
        if draft.superseded { return "Earlier draft, replaced" }
        if let state = draft.sendState { return "Email \(state)" }
        return "Draft email"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: sent ? "checkmark.circle.fill" : "envelope.fill").font(.system(size: 10))
                    .foregroundStyle(sent ? Palette.green : .white.opacity(0.55))
                Text(label).font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(sent ? Palette.green : .white.opacity(0.55))
                Spacer()
                if settled {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                field("To", draft.to.joined(separator: ", "))
                if !settled || expanded {
                    if !draft.cc.isEmpty { field("Cc", draft.cc.joined(separator: ", ")) }
                    if !draft.from.isEmpty { field("From", draft.from) }
                }
            }
            Text(draft.subject).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(settled ? 0.7 : 1))
                .fixedSize(horizontal: false, vertical: true)
            if !settled || expanded {
                Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                Text(draft.body).font(.system(size: 12.5)).lineSpacing(2).foregroundStyle(.white.opacity(0.9))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draft.body, forType: .string)
                        copied = true
                    }
                    .buttonStyle(ChipButton())
                    if !settled {
                        Button("Send in Grok Bot") {
                            GrokSource.shared.open(agent)
                            ui.collapse()
                        }
                        .buttonStyle(ChipButton())
                    }
                    Spacer()
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(settled ? 0.04 : 0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { if settled { expanded.toggle() } }
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4)).frame(width: 30, alignment: .leading)
            Text(value).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
        }
    }
}

// MARK: Things waiting on the user

private struct PendingCard: View {
    let agent: Agent
    @State private var picks: [UUID: Set<String>] = [:]

    var body: some View {
        let tint = agent.color
        if let pending = agent.pending {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    FaceView(agent: agent, size: 18)
                    Text(title(pending.kind)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    Text(agent.name).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    Spacer()
                }
                switch pending.kind {
                case .permission(_, let detail): permission(detail)
                case .question(let questions, _): questionList(questions)
                case .followUp: followUp(pending)
                }
            }
            .padding(9)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(tint.opacity(0.45), lineWidth: 1))
        }
    }

    private func title(_ kind: PendingKind) -> String {
        switch kind {
        case .permission(let tool, _):
            switch tool {
            case "Bash": return "Run this command?"
            case "WebSearch": return "Search the web for this?"
            case "WebFetch": return "Open this page?"
            case "Edit", "Write", "MultiEdit", "NotebookEdit": return "Change this file?"
            case "Read": return "Read this file?"
            default: return "Use \(tool)?"
            }
        case .question: return "Quick question"
        case .followUp: return "Anything else?"
        }
    }

    private func permission(_ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.9))
                .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 8) {
                Button("Deny") { CodingSessions.shared.deny(agent) }.buttonStyle(ChipButton())
                Button("Allow") { CodingSessions.shared.allow(agent) }.buttonStyle(ChipButton(fill: Palette.green))
                // Never offered for shell commands, where each one deserves a look.
                if let tool = agent.pending?.toolName, !["Bash", "shell", "exec_command"].contains(tool) {
                    Button("Always in this chat") { CodingSessions.shared.allowAlways(agent) }.buttonStyle(ChipButton())
                }
                Spacer()
                Button("In the app") { CodingSessions.shared.dismiss(agent) }.buttonStyle(LinkButton())
            }
        }
    }

    private func questionList(_ questions: [Question]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(questions) { q in
                VStack(alignment: .leading, spacing: 4) {
                    Text(q.text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(q.options, id: \.self) { option in
                        let on = picks[q.id]?.contains(option) ?? false
                        Button(option) { pick(option, for: q, in: questions) }
                            .buttonStyle(ChipButton(fill: on ? agent.color : nil, wide: true))
                    }
                }
            }
            HStack {
                if questions.count > 1 || questions.contains(where: \.multiSelect) {
                    Button("Send") { submit(questions) }
                        .buttonStyle(ChipButton(fill: Palette.green))
                        .disabled(!questions.allSatisfy { !(picks[$0.id] ?? []).isEmpty })
                }
                Spacer()
                Button("In the app") { CodingSessions.shared.dismiss(agent) }.buttonStyle(LinkButton())
            }
        }
    }

    private func pick(_ option: String, for q: Question, in questions: [Question]) {
        if q.multiSelect {
            var set = picks[q.id] ?? []
            if set.contains(option) { set.remove(option) } else { set.insert(option) }
            picks[q.id] = set
        } else {
            picks[q.id] = [option]
            if questions.count == 1 { submit(questions) }
        }
    }

    private func submit(_ questions: [Question]) {
        var answers: [String: String] = [:]
        for q in questions {
            // Keep the order the options were offered in.
            answers[q.text] = q.options.filter { picks[q.id]?.contains($0) ?? false }.joined(separator: ", ")
        }
        CodingSessions.shared.answer(agent, answers: answers)
    }

    private func followUp(_ pending: PendingRequest) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if !agent.lastMessage.isEmpty {
                Text(agent.lastMessage.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.8))
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Dismiss") { CodingSessions.shared.dismiss(agent) }.buttonStyle(LinkButton())
            }
            ReplyField(agent: agent)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let total = max(1, pending.deadline.timeIntervalSince(pending.createdAt))
                let left = max(0, pending.deadline.timeIntervalSince(context.date))
                GeometryReader { geo in
                    Capsule().fill(.white.opacity(0.25))
                        .frame(width: geo.size.width * left / total)
                        .animation(.linear(duration: 1), value: left)
                }
                .frame(height: 2)
            }
        }
    }
}

// MARK: Chrome

private struct Footer: View {
    @Environment(AgentStore.self) private var store
    @Environment(NotchUI.self) private var ui
    @State private var sounds = Settings.sounds
    @State private var soundName = Settings.soundName
    @State private var edgeGuard = EdgeGuard.wanted
    @State private var replyWindow = Settings.replyWindow
    @State private var loginItem = SMAppService.mainApp.status == .enabled

    var body: some View {
        HStack {
            Menu {
                Menu("Always in the notch") {
                    ForEach(store.grokBots) { bot in
                        Toggle(bot.name, isOn: Binding(
                            get: { ui.pinned.contains(bot.name) },
                            set: { on in if on { ui.pinned.insert(bot.name) } else { ui.pinned.remove(bot.name) } }))
                    }
                }
                Toggle("Launch at login", isOn: $loginItem)
                Divider()
                Button(LinkRouter.isDefault ? "Perch is choosing where links open" : "Let Perch choose where links open…") {
                    LinkRouter.makeDefault()
                }
                .disabled(LinkRouter.isDefault)
                Button("Forget learned link choices (\(LinkRouter.shared.settledCount))") { LinkRouter.shared.forgetEverything() }
                Divider()
                Toggle("Sounds", isOn: $sounds)
                Picker("Notification sound", selection: $soundName) {
                    ForEach(Settings.soundChoices, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Keep the menu bar hidden in full screen", isOn: $edgeGuard)
                Picker("Wait for a reply when a session finishes", selection: $replyWindow) {
                    Text("Off").tag(0)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                }
                Divider()
                Button("Quit Perch") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .onChange(of: sounds) { _, on in Settings.sounds = on }
        .onChange(of: soundName) { _, name in
            Settings.soundName = name
            // Hear it as you pick it.
            Settings.playSound()
        }
        .onChange(of: edgeGuard) { _, on in
            EdgeGuard.wanted = on
            if on { EdgeGuard.shared.start(prompt: true) } else { EdgeGuard.shared.stop() }
        }
        .onChange(of: replyWindow) { _, seconds in Settings.replyWindow = seconds }
        .onChange(of: loginItem) { _, on in
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Perch: login item change failed: \(error)")
                loginItem = SMAppService.mainApp.status == .enabled
            }
        }
    }
}

private struct ChipButton: ButtonStyle {
    var fill: Color?
    var wide = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(fill == nil ? .white : .black)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .frame(maxWidth: wide ? .infinity : nil, alignment: .leading)
            .background(fill ?? .white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
            .reach(3, 5)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct LinkButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11)).foregroundStyle(.white.opacity(configuration.isPressed ? 0.3 : 0.5))
            .reach(8, 7)
    }
}

/// The look of a plain button, with two things added: it can be hit a little outside what is
/// drawn (small icons are hard to land on otherwise), and it dips slightly while pressed so a
/// click is felt.
struct Press: ButtonStyle {
    var reach: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .reach(reach, reach)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension View {
    /// Makes the view clickable this far beyond its edges without moving anything around it.
    func reach(_ x: CGFloat, _ y: CGFloat) -> some View {
        padding(.horizontal, x).padding(.vertical, y).contentShape(Rectangle())
            .padding(.horizontal, -x).padding(.vertical, -y)
    }
}
