import SwiftUI
import UniformTypeIdentifiers
import ServiceManagement

private let faceSize: CGFloat = 16
private let maxFaces = 7
private let island = Animation.spring(response: 0.34, dampingFraction: 0.88)

private let dialWidth: CGFloat = 24

private func earWidth(_ count: Int) -> CGFloat {
    count == 0 ? 0 : CGFloat(count) * faceSize + CGFloat(count - 1) * 4 + 16
}

struct NotchContent: View {
    @Environment(AgentStore.self) private var store
    @Environment(NotchUI.self) private var ui

    var body: some View {
        let left = Array(store.grokBots.filter { ui.inPill($0) && !ui.isDismissed($0) }.prefix(maxFaces))
        // Every chat that is in the sidebar sits in the notch too, idle ones included (they just
        // sit still). Only chats the user has cleared are left out.
        let right = Array(store.sessions.filter { !ui.isDismissed($0) }.prefix(maxFaces))
        // A small usage dial sits at the outer end of each side: Grok Bot's by the bots, Claude's
        // by the chats.
        let usage = Usage.shared
        // Only while the island is open in full; closed, and for a notification banner, the notch
        // stays as small as it can be.
        let dials = ui.expanded && !ui.cardsOnly && ui.pendingLinks.isEmpty && ui.justOpened == nil && !(ui.showingClips && !ui.clipsInline) && !ui.showingShelf
        let grokDial = dials && usage.grok.week != nil, claudeDial = dials && (usage.claude.short != nil || usage.claude.week != nil)
        let l = earWidth(left.count) + (grokDial ? dialWidth : 0), r = earWidth(right.count) + (claudeDial ? dialWidth : 0)
        // Opened, the island is at least 340 wide; the extra is shared between both sides
        // so the gap always stays lined up with the hardware notch.
        // A chat needs more room than the roster.
        let chatting = ui.selectedID != nil || ui.composing
        // A Slack thread opens beside its conversation, as in Slack, so the island widens for it.
        let threadBeside = ui.slackTarget.map { t in t.workspace != WhatsAppSource.workspace && ui.openThreads["\(t.workspace):\(t.id)"] != nil } == true
            && !ui.browsing && !ui.showingTasks && !ui.showingCalendar
        let extra = ui.expanded ? max(0, (ui.cardsOnly || !ui.pendingLinks.isEmpty || ui.justOpened != nil ? 340 : (ui.showingClips && !ui.clipsInline) || ui.showingShelf ? 380 : threadBeside ? 1180 : 768) - (l + ui.notch.width + r)) : 0
        let side = max(l, r, extra > 0 ? (l + r + extra) / 2 : 0)
        let leftWidth = ui.expanded ? side : l, rightWidth = ui.expanded ? side : r
        let radius: CGFloat = ui.expanded ? 18 : 10
        let openWidth = max(l + ui.notch.width + r, 340)
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    if grokDial { UsageDial(plan: usage.grok, name: "Grok Bot", color: .white, labelOnLeft: true).padding(.leading, 10) }
                    Ear(agents: left)
                }
                .frame(width: leftWidth, alignment: .trailing)
                Color.clear.frame(width: ui.notch.width)
                HStack(spacing: 0) {
                    Ear(agents: right)
                    if claudeDial {
                        UsageDial(plan: usage.claude, name: "Claude", color: Color(red: 0.85, green: 0.47, blue: 0.34)).padding(.trailing, 10)
                    }
                }
                .frame(width: rightWidth, alignment: .leading)
            }
            .frame(height: ui.notch.height)
            // Above a banner, the strip is the way into everything else.
            .contentShape(Rectangle())
            .onHover { ui.overStrip($0) }
            .onTapGesture { ui.showEverything() }

            if ui.expanded {
                // Laid out once at its final width. The island's edges animate over it, so the
                // chat is not measured again on every frame of the opening.
                ExpandedBody()
                    .frame(width: max(side * 2 + ui.notch.width, 60))
                    .transition(.opacity)
            }
        }
        .frame(width: max(leftWidth + ui.notch.width + rightWidth, 60))
        .background(.black)
        .clipShape(shape)
        // A faint rim down the sides and along the bottom, so the open island stands apart from
        // a dark screen behind it. It fades out towards the top, where it meets the menu bar.
        .overlay {
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.11), .white.opacity(0.17)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
                .opacity(ui.expanded ? 1 : 0)
                .allowsHitTesting(false)
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
            ui.controller?.islandFrameChanged(frame)
        }
        .shadow(color: .black.opacity(ui.expanded ? 0.35 : 0), radius: 12, y: 5)
        // Faces sit either side of the notch, so the island is only as wide as it needs to be.
        // Padding (not an offset) shifts it, so the clickable area moves with what is drawn.
        // Open, both sides are the same width, so the island is centred on the notch and does
        // not slide sideways when a chat is added or cleared.
        .padding(.leading, ui.expanded ? 0 : max(0, r - l))
        .padding(.trailing, ui.expanded ? 0 : max(0, l - r))
        .animation(island, value: ui.expanded)
        .animation(island, value: ui.cardsOnly)
        .animation(tabSwitch, value: ui.showingTasks)
        .animation(tabSwitch, value: ui.showingCalendar)
        .animation(island, value: ui.showingClips)
        .animation(island, value: ui.showingShelf)
        .animation(island, value: store.needing.count)
        .animation(island, value: l + r)
        .animation(island, value: threadBeside)
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
    @State private var paneReady = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if KeyboardLock.shared.locked {
                KeyboardLockCard()
            } else if let link = ui.pendingLinks.first {
                LinkPicker(link: link, waiting: ui.pendingLinks.count - 1).id(link.id)
            } else if let opened = ui.justOpened {
                LinkOpenedNote(site: opened.site, profile: opened.profile)
            } else if ui.showingWhatsAppLink {
                WhatsAppLinkView()
            } else if ui.cardsOnly, let meeting = ui.meetingAlert {
                MeetingBanner(meeting: meeting)
            } else if ui.cardsOnly, let alert = ui.slackAlert {
                // One per chat: nothing typed or sent for one person carries onto the next.
                SlackBanner(alert: alert).id(NotchUI.bannerKey(alert))
                    .transition(.opacity)
            } else if ui.cardsOnly, let id = ui.noticeID, let agent = store.find(id) {
                NoticeView(agent: agent)
            } else if ui.showingShelf {
                // A small panel, not the whole island: for holding a file, or taking one back.
                ShelfPanel()
            } else if ui.showingClips && !ui.clipsInline {
                ClipboardPanel()
            } else {
                TopBar()
                    .overlay(alignment: .top) {
                        // A meeting about to start, over whatever is open, until joined or dismissed.
                        if let meeting = ui.meetingAlert {
                            MeetingBanner(meeting: meeting).frame(maxWidth: 520)
                                .background(.black, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                        } else {
                            ToastBanner()
                        }
                    }
                    .zIndex(5)
                if ui.showingCalendar {
                    CalendarView().transition(.opacity)
                } else if ui.showingTasks {
                    // The board gets the full width; the island stays the same size either way.
                    TasksView()
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)),
                                                removal: .opacity.combined(with: .offset(x: 24))))
                } else {
                    // Chats down the left, one conversation (or search) on the right.
                    HStack(alignment: .top, spacing: 12) {
                        Rail()
                        Rectangle().fill(.white.opacity(0.08)).frame(width: 1).frame(maxHeight: .infinity)
                        VStack(alignment: .leading, spacing: 6) {
                            // The chat is the costly part to build, so it waits for the opening
                            // to finish rather than competing with it for frames.
                            if paneReady { pane } else { Color.clear.frame(height: 452) }
                        }
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
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
                withAnimation(.easeOut(duration: 0.12)) { paneReady = true }
            }
        }
    }

    @ViewBuilder private var pane: some View {
        Group {
            if ui.showingClips && ui.clipsInline {
                ClipboardPanel().frame(height: 452, alignment: .top)
            } else if ui.showingTasks {
                TasksView()
            } else if ui.showingProfiles {
                ProfilesView()
            } else if let target = ui.slackTarget {
                SlackComposer(target: target).id(target.id).transition(.opacity)
            } else if ui.composing {
                NewChatView()
            } else if let id = ui.selectedID, let agent = store.find(id) {
                ChatView(agent: agent).id(agent.id).transition(.opacity)
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
        // One chat to the next: a quick crossfade, not a hard cut.
        .animation(.easeOut(duration: 0.16), value: ui.slackTarget.map { "\($0.workspace):\($0.id)" } ?? ui.selectedID ?? "")
    }

    @ViewBuilder private var roster: some View {
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
                let bots = store.grokBots.filter { (showQuiet && !GrokSource.hidden.contains($0.sessionID)) || ui.inPill($0) }
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
            TextField("Search", text: $ui.query)
                .textFieldStyle(.plain).font(.system(size: 11.5)).focused($focused)
                .help("Find someone or a chat. Start with a space to search what was said.")
                .onKeyPress(.escape) {
                    // Esc clears the search, then a second Esc leaves it.
                    if !ui.query.isEmpty { ui.query = ""; return .handled }
                    return .ignored
                }
                .onKeyPress(.downArrow) {
                    ui.searchIndex = min(ui.searchIndex + 1, max(0, SearchItem.all(store, ui).count - 1))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    ui.searchIndex = max(ui.searchIndex - 1, 0)
                    return .handled
                }
                .onSubmit {
                    // Return straight after typing acts on what is typed now, not the last pause.
                    ui.searchResults = SearchItem.compute(store, ui)
                    let items = SearchItem.all(store, ui)
                    if items.indices.contains(ui.searchIndex) { items[ui.searchIndex].open(ui) }
                }
            if !ui.query.isEmpty {
                Button { ui.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(Press())
            }
            Button {
                ui.showingProfiles = false
                ui.composing = true
            } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 12))
                    .foregroundStyle(.white.opacity(ui.composing ? 0.95 : 0.6))
                    .frame(width: 22, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(Press()).help("New chat")
        }
        .foregroundStyle(.white.opacity(focused || ui.browsing ? 0.9 : 0.5))
        .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 5)
        .background(.white.opacity(focused || ui.browsing ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        // A click anywhere in the box starts typing, not only on the line of text.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            ui.controller?.panel.makeKey()
            focused = true
        })
        .onChange(of: focused) { _, on in
            guard on else { return }
            // Only now, not whenever the island opens: reading every chat's history and warming the
            // search is real work, and it was making each open stutter.
            SessionIndex.shared.refresh()
            ThreadSearch.shared.refresh()
            ThreadSearch.shared.prepare(live: store.sessions + store.grokBots)
            // Typing here shows the results on the right.
            if !ui.browsing { ui.browse() }
        }
        .onChange(of: ui.query) {
            ui.searchIndex = 0
            if !ui.browsing && !ui.query.isEmpty { ui.browse() }
            ui.searchSoon()
        }
        // New chats read, or a Slack conversation understood: refresh what is shown, quietly.
        .onChange(of: ThreadSearch.shared.version) { if !ui.query.isEmpty { ui.searchSoon() } }
        .onChange(of: ui.searchFocus) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
    }
}

/// One thing search can land on.
enum SearchItem: Identifiable {
    case agent(Agent)
    case older(SessionIndex.Entry)
    case newChat(String)
    case slack(SlackTarget)

    var id: String {
        switch self {
        case .agent(let a): return a.id
        case .older(let e): return "older:\(e.id)"
        case .newChat: return "new"
        case .slack(let t): return "slack:\(t.workspace):\(t.id)"
        }
    }

    /// A line of each result's conversation around what matched, by result id.
    static var snippets: [String: String] = [:]
    /// Results found by meaning alone.
    static var related = Set<String>()
    /// The words to highlight in each result's snippet, and when it was last active.
    static var matches: [String: [String]] = [:]
    static var times: [String: Date] = [:]
    /// People and channels on Slack offered to message, rather than conversations found.
    static var people = Set<String>()
    /// A quiet note of where a result lives, like the Slack workspace.
    static var places: [String: String] = [:]

    /// Everything matching the search, best first: chats from every app (live or older), bots and
    /// Slack conversations, matched on what was said as well as titles, then people on Slack to
    /// message, then the option to start fresh. With nothing typed, every live one.
    static func all(_ store: AgentStore, _ ui: NotchUI) -> [SearchItem] {
        let q = ui.query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return recent(store, ui) }
        return ui.searchResults
    }

    /// Before anything is typed: whoever and whatever was talked to most recently, people and
    /// chats together, newest first.
    static func recent(_ store: AgentStore, _ ui: NotchUI) -> [SearchItem] {
        var found: [(SearchItem, Double)] = []
        for chat in WhatsAppSource.shared.chats where !chat.crowd {
            found.append((.slack(chat.target), chat.ts.timeIntervalSince1970))
        }
        for t in ui.slackRecent where t.workspace != WhatsAppSource.workspace {
            found.append((.slack(t), ui.slackLastAt["\(t.workspace):\(t.id)"] ?? 0))
        }
        for a in store.sessions + store.grokBots.filter({ !GrokSource.hidden.contains($0.sessionID) }) {
            found.append((.agent(a), (a.lastTurnAt ?? a.lastActivity).timeIntervalSince1970))
        }
        var seen = Set<String>()
        return found.sorted { $0.1 > $1.1 }.map(\.0).filter { seen.insert($0.id).inserted }.prefix(14).map { $0 }
    }

    /// Searching inside chats: the query starts with a space. Otherwise search finds people,
    /// bots and chats by name.
    static func inMessages(_ ui: NotchUI) -> Bool { ui.query.hasPrefix(" ") }

    static func compute(_ store: AgentStore, _ ui: NotchUI) -> [SearchItem] {
        let q = ui.query.trimmingCharacters(in: .whitespaces).lowercased()
        let everyone = store.sessions + store.grokBots
        guard !q.isEmpty else { return [] }
        if !inMessages(ui) { return byName(q, store, ui) }
        let search = ThreadSearch.shared
        // Slack conversations Perch has loaded, so what was said there can be found too.
        let conversations = SlackConversations.shared
        let directory = SlackDirectory.shared.targets
        var slackChats: [(SlackTarget, [SlackLine])] = []
        for (key, lines) in conversations.lines where !lines.isEmpty {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let (workspace, channel) = (parts[0], parts[1])
            if workspace == WhatsAppSource.workspace {
                if let chat = WhatsAppSource.shared.chats.first(where: { $0.id == channel }) { slackChats.append((chat.target, lines)) }
                continue
            }
            let person = conversations.dmChannel.first { $0.value == channel && $0.key.hasPrefix("\(workspace):") }
                .map { String($0.key.dropFirst(workspace.count + 1)) }
            if let target = directory.first(where: { $0.workspace == workspace && $0.id == (person ?? channel) }) {
                slackChats.append((target, lines))
            }
        }
        let hits = search.search(q, live: everyone, slack: slackChats)
        var items: [SearchItem] = []
        var seen = Set<String>()
        snippets = [:]
        related = []
        matches = [:]
        times = [:]
        people = []
        places = [:]
        for hit in hits.prefix(10) {
            let item: SearchItem
            switch hit.target {
            case .agent(let id):
                guard let agent = store.find(id) else { continue }
                item = .agent(agent)
            case .older(let entry):
                if let agent = store.find("\(entry.source.rawValue):\(entry.id)") { item = .agent(agent) } else { item = .older(entry) }
            case .slack(let target):
                item = .slack(target)
            }
            guard seen.insert(item.id).inserted else { continue }
            if let snippet = hit.snippet { snippets[item.id] = snippet }
            if hit.related { related.insert(item.id) }
            matches[item.id] = hit.matches
            times[item.id] = hit.modified
            items.append(item)
        }
        // People and channels on Slack, to message directly.
        // WhatsApp chats called what was typed, to open or message.
        let whatsapp = WhatsAppSource.shared.matching(q).prefix(6).map { SearchItem.slack($0) }
        let found = (whatsapp + SlackDirectory.shared.matching(q).prefix(4).map { SearchItem.slack($0) }).filter { !seen.contains($0.id) }
        // Typing a name means that person, bot or chat: those come first, ahead of chats that
        // only mention it.
        let terms = ThreadSearch.terms(q)
        func named(_ item: SearchItem) -> Bool {
            let title: String
            switch item {
            case .agent(let a): title = a.name
            case .older(let e): title = e.title
            case .slack(let t): title = t.label
            case .newChat: return false
            }
            let words = ThreadSearch.terms(title)
            return !terms.isEmpty && terms.allSatisfy { t in words.contains { $0.hasPrefix(t) } }
        }
        for case .slack(let t) in items + found {
            places["slack:\(t.workspace):\(t.id)"] = t.workspace == WhatsAppSource.workspace ? "WhatsApp" : "Slack · \(t.workspace.capitalized)"
        }
        let byName = (items.filter(named) + found)
        people = Set(byName.map(\.id))
        let rest = items.filter { !people.contains($0.id) }
        return byName + rest + [.newChat(ui.query.trimmingCharacters(in: .whitespaces))]
    }

    /// How well a name answers what was typed: 2 when every word typed starts a word of the
    /// name, 1 when it does allowing one slip ("olie" for Ollie), nil when it does not.
    static func nameScore(_ query: String, _ name: String) -> Int? {
        let terms = ThreadSearch.terms(query), words = ThreadSearch.terms(name)
        guard !terms.isEmpty, !words.isEmpty else { return nil }
        var exact = true
        for t in terms {
            if words.contains(where: { $0.hasPrefix(t) }) { continue }
            // A slip is allowed once a few letters are in, and never in the first one.
            guard t.count >= 4, words.contains(where: { w in w.first == t.first &&
                    [t.count - 1, t.count, t.count + 1].contains { n in n > 0 && n <= w.count && slips(t, String(w.prefix(n))) <= 1 }
            }) else { return nil }
            exact = false
        }
        return exact ? 2 : 1
    }

    private static func slips(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var prev = row[0]; row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let keep = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = keep
            }
        }
        return row[b.count]
    }

    /// Search by name: people first (WhatsApp and Slack), most recently messaged first, then
    /// bots and chats, then Slack channels. Return opens the top one.
    private static func byName(_ q: String, _ store: AgentStore, _ ui: NotchUI) -> [SearchItem] {
        snippets = [:]; related = []; matches = [:]; times = [:]; people = []; places = [:]
        struct Found { let item: SearchItem; let score: Int; let at: Double; let tier: Int }
        var found: [Found] = []
        var seen = Set<String>()
        func add(_ item: SearchItem, _ name: String, tier: Int, at: Double, place: String? = nil) {
            guard let score = nameScore(q, name), seen.insert(item.id).inserted else { return }
            found.append(Found(item: item, score: score, at: at, tier: tier))
            if let place { places[item.id] = place }
            if at > 0 { times[item.id] = Date(timeIntervalSince1970: at) }
        }
        let wa = WhatsAppSource.shared
        for t in wa.matching(where: { nameScore(q, $0) != nil }) {
            let at = wa.chats.first { $0.id == t.id }?.ts.timeIntervalSince1970 ?? 0
            add(.slack(t), liveName(t), tier: t.id.hasSuffix("@g.us") ? 2 : 0, at: at, place: "WhatsApp")
        }
        for t in SlackDirectory.shared.targets {
            add(.slack(t), t.name, tier: t.channel ? 3 : 0, at: ui.slackLastAt["\(t.workspace):\(t.id)"] ?? 0,
                place: "Slack · \(t.workspace.capitalized)")
        }
        for a in store.grokBots + store.sessions {
            add(.agent(a), a.name, tier: 1, at: (a.lastTurnAt ?? a.lastActivity).timeIntervalSince1970)
        }
        let ranked = found.sorted {
            if $0.tier != $1.tier { return $0.tier < $1.tier }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.at > $1.at
        }.prefix(12).map(\.item)
        people = Set(ranked.map(\.id))
        return ranked + [.newChat(ui.query.trimmingCharacters(in: .whitespaces))]
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
        case .slack(let target):
            ui.query = ""
            ui.browsing = false
            ui.openSlack(target)
        }
    }
}

/// The search results. Arrow keys move the highlight, Return opens it, and clicking works too.
/// Grouped: chats that contain the words, chats about the same thing, people to message.
private struct SearchResults: View {
    @Environment(AgentStore.self) private var store
    @Environment(NotchUI.self) private var ui
    /// Rows come in one after another the first time the list appears, not on every keystroke.
    @State private var arrived = false

    /// Top matches (things called what was typed), then everything else, split by a thin line.
    private func group(_ item: SearchItem) -> Int {
        if case .newChat = item { return 2 }
        return SearchItem.people.contains(item.id) ? 0 : 1
    }

    var body: some View {
        let items = SearchItem.all(store, ui)
        let typed = !ui.query.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if typed, index > 0, group(items[index - 1]) != group(item) {
                    Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
                        .padding(.vertical, 4).padding(.horizontal, 8)
                }
                row(item)
                    .background(.white.opacity(index == ui.searchIndex ? 0.1 : 0),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .opacity(arrived ? 1 : 0)
                    .animation(.easeOut(duration: 0.18).delay(min(Double(index), 6) * 0.02), value: arrived)
            }
            if items.isEmpty && typed {
                Text("Nothing matches.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 8).padding(.vertical, 6)
            }
            if typed && !SearchItem.inMessages(ui) {
                Text("Looking for something said in a chat? Start with a space.")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.3))
                    .padding(.horizontal, 8).padding(.top, 6)
            }
        }
        .onAppear { arrived = true }
    }

    @ViewBuilder private func row(_ item: SearchItem) -> some View {
        switch item {
        case .agent(let agent):
            if ui.query.trimmingCharacters(in: .whitespaces).isEmpty {
                // Nothing typed: the plain list of live chats.
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
            } else {
                result(item, title: agent.name) { FaceView(agent: agent, size: 20) }
            }
        case .older(let entry):
            result(item, title: entry.title) { AppMark(source: entry.source) }
        case .newChat(let prompt):
            PlainRow(icon: "square.and.pencil", title: "New Claude Code chat: \(prompt)", trailing: nil) { item.open(ui) }
        case .slack(let target):
            result(item, title: target.label) {
                SlackAvatar(url: livePicture(target), channel: target.channel, size: 18, whatsapp: target.workspace == WhatsAppSource.workspace)
            }
        }
    }

    /// A found thread: what it is and when, with the line of it that matched underneath.
    private func result<Icon: View>(_ item: SearchItem, title: String, @ViewBuilder icon: () -> Icon) -> some View {
        let snippet = SearchItem.snippets[item.id]
        return HStack(alignment: snippet == nil ? .center : .top, spacing: 9) {
            icon().frame(width: 18, height: 18).padding(.top, snippet == nil ? 0 : 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.95)).lineLimit(1)
                    if let place = SearchItem.places[item.id] {
                        Text(place).font(.system(size: 11)).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if let time = SearchItem.times[item.id] {
                        Text(Self.when(time)).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.3)).lineLimit(1)
                    }
                }
                if let snippet {
                    Text(Self.highlighted(snippet, SearchItem.matches[item.id] ?? []))
                        .font(.system(size: 11)).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { item.open(ui) }
    }

    private static func when(_ date: Date) -> String {
        let age = Date().timeIntervalSince(date)
        if age < 60 { return "now" }
        if age < 3600 { return "\(Int(age / 60))m" }
        if age < 86400 { return "\(Int(age / 3600))h" }
        if age < 7 * 86400 { return "\(Int(age / 86400))d" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// The snippet in grey with the matching words picked out in white (whole words, and the
    /// longer words they begin).
    private static func highlighted(_ text: String, _ words: [String]) -> AttributedString {
        var out = AttributedString(text)
        out.foregroundColor = .white.opacity(0.4)
        let ns = text as NSString
        for word in words where word.count >= 2 {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\w*"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let r = Range(m.range, in: text),
                      let lo = AttributedString.Index(r.lowerBound, within: out),
                      let hi = AttributedString.Index(r.upperBound, within: out) else { continue }
                out[lo..<hi].foregroundColor = .white.opacity(0.85)
            }
        }
        return out
    }
}

/// The app an older chat belongs to, as a small mark.
private struct AppMark: View {
    let source: AgentSource

    var body: some View {
        let bundle = source == .codex ? "com.openai.codex" : "com.anthropic.claudefordesktop"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
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

// MARK: Usage

/// A small dial for one subscription. The outer ring is the short window when there is one
/// (Claude's five hours), with the week inside it; a plan with only a weekly allowance gets
/// the one ring. Hover for the numbers and when each resets.
private struct UsageDial: View {
    let plan: Usage.Plan
    let name: String
    let color: Color

    var body: some View {
        let outer = plan.short ?? plan.week, inner = plan.short == nil ? nil : plan.week
        ZStack {
            ring((outer?.current ?? 0) / 100, width: 2.2).frame(width: 13, height: 13)
            if let inner { ring(inner.current / 100, width: 2).frame(width: 6, height: 6) }
        }
        .frame(width: 14, height: 14)
        .reach(4, 9)
        .onHover { hovered = $0 }
        // The figure appears beside the dial, on the outer side where there is room.
        .overlay(alignment: labelOnLeft ? .trailing : .leading) {
            if hovered {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(lines, id: \.self) { Text($0) }
                }
                    .font(.system(size: lines.count > 1 ? 9.5 : 10.5, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.9)).fixedSize()
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .offset(x: labelOnLeft ? -20 : 20)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    @State private var hovered = false
    var labelOnLeft = false

    /// One line per window, each with its figure and when it resets.
    private var lines: [String] {
        func when(_ w: Usage.Window) -> String {
            guard let resets = w.resets, resets > Date() else { return "" }
            let f = DateFormatter()
            f.dateFormat = resets.timeIntervalSinceNow < 20 * 3600 ? "HH:mm" : "EEE HH:mm"
            return ", resets \(f.string(from: resets))"
        }
        if let s = plan.short, let w = plan.week {
            return ["5h  \(Int(s.current.rounded()))%\(when(s))", "7d  \(Int(w.current.rounded()))%\(when(w))"]
        }
        if let w = plan.week ?? plan.short { return ["\(Int(w.current.rounded()))% used\(when(w))"] }
        return []
    }

    private func ring(_ part: Double, width: CGFloat) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.16), lineWidth: width)
            Circle().trim(from: 0, to: max(0.001, min(1, part)))
                .stroke(part > 0.9 ? Palette.red : color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: part)
        }
    }

    private var describe: String {
        func line(_ label: String, _ w: Usage.Window?) -> String? {
            guard let w else { return nil }
            var s = "\(label): \(Int(w.current.rounded()))% used"
            if let resets = w.resets, resets > Date() {
                let f = DateFormatter()
                f.dateFormat = resets.timeIntervalSinceNow < 20 * 3600 ? "HH:mm" : "EEE HH:mm"
                s += ", resets \(f.string(from: resets))"
            }
            return s
        }
        return ([name] + [line("5 hours", plan.short), line("Week", plan.week)].compactMap { $0 }).joined(separator: "\n")
    }
}

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
            tab("Chats", on: !ui.showingTasks && !ui.showingCalendar) {
                withAnimation(tabSwitch) { ui.showingTasks = false; ui.showingCalendar = false }
            }
            tab("Calendar", on: ui.showingCalendar) {
                ui.composing = false
                withAnimation(tabSwitch) { ui.showingTasks = false; ui.showingCalendar = true }
            }
            tab("To-dos", count: NotionTasks.shared.connected ? NotionTasks.shared.tasks.count : nil, on: ui.showingTasks) {
                ui.composing = false
                withAnimation(tabSwitch) { ui.showingCalendar = false; ui.showingTasks = true }
            }
            // Only when something is being held: a small tray with how many. Click for the shelf.
            if !Clips.shared.shelf.isEmpty {
                Button { ui.openShelf() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "tray.full.fill").font(.system(size: 11))
                        Text("\(Clips.shared.shelf.count)").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(Press()).help("Files you are holding")
                .transition(.scale(scale: 0.7).combined(with: .opacity))
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
        // Anything dragged up to the bar is held on the shelf.
        .overlay {
            if dropping {
                HStack(spacing: 7) {
                    Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 11))
                    Text("Drop to hold on the shelf").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.16), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeOut(duration: 0.14), value: dropping)
        .onDrop(of: [.fileURL, .image, .movie, .data], isTargeted: $dropping) { providers in
            shelve(providers)
            return true
        }
    }

    @State private var dropping = false

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

    /// While the pointer is over the list its order holds still, so a row never moves out from
    /// under a click. Everywhere else the list is newest first, live.
    @State private var frozen: [String]?
    /// Ticks over every so often, so a conversation's five minutes running out is noticed.
    @State private var now = Date()

    private var displayedAgents: [Agent] {
        agents.filter { agent in
            !ui.isDismissed(agent) && !(agent.source == .grok && GrokSource.hidden.contains(agent.sessionID) && ui.selectedID != agent.id)
        }
    }

    /// Slack and WhatsApp conversations stay while they have something unread, while open, or
    /// when pinned. Once read and left, they go.
    private var displayedConversations: [SlackTarget] {
        ui.slackRecent.filter { t in
            let key = "\(t.workspace):\(t.id)"
            let open = ui.slackTarget?.workspace == t.workspace && ui.slackTarget?.id == t.id
            let whatsappUnread = t.workspace == WhatsAppSource.workspace
                && WhatsAppSource.shared.chats.contains { $0.id == t.id && $0.unread > 0 && !$0.crowd }
            // Opened or written in within the last five minutes: still here for a follow-up.
            let recent = (ui.conversationTouched[key].map { now.timeIntervalSince($0) < 300 } ?? false)
                || now.timeIntervalSince1970 - lastAt(t) < 300
            let floating = SidePanel.shared.showing(t.workspace, t.id)
            return open || floating || recent || (ui.slackUnread[key] ?? 0) > 0 || whatsappUnread || ui.pinnedConversations.contains(key)
        }
    }

    /// When something last really happened in a chat: a message or a turn, not housekeeping.
    private func lastActive(_ chat: SidebarChat) -> Double {
        switch chat {
        // When it last finished a turn, so a chat working away on its own holds its place.
        case .agent(let a): return (a.finishedAt ?? a.createdAt).timeIntervalSince1970
        case .conversation(let t): return lastAt(t)
        }
    }

    private var agents: [Agent] {
        var seen = Set<String>()
        let sessions = store.sessions.filter { !ui.isDismissed($0) }
        let active = sessions.filter { $0.status != .idle }
        // Chats the user added on purpose always show, and quiet ones that did something in the
        // last few hours. Nothing older is pulled in to fill the space, so a chat swiped away
        // is not replaced by another.
        let kept = sessions.filter { $0.status == .idle && $0.kept }
        let lately = sessions.filter { $0.status == .idle && !$0.kept
            && Date().timeIntervalSince($0.lastTurnAt ?? $0.lastActivity) < 6 * 3600 }
        let quiet = kept + lately
        // Remmi leads, then any other bot with something to say, then pinned chats, then the rest.
        let lead = store.grokBots.filter { ui.pinned.contains($0.name) }
        let bots = store.grokBots.filter { ui.inPill($0) && !ui.pinned.contains($0.name) }
        let pinnedChats = store.sessions.filter { ui.pinnedChats.contains($0.id) }
        let pinned = lead + bots + pinnedChats
        // Whatever is open stays on the rail even if it has gone quiet.
        let open = ui.selectedID.flatMap { store.find($0) }.map { [$0] } ?? []
        let rest = (store.needing + active + quiet + open)
            .filter { a in !pinned.contains { $0.id == a.id } }
        // A dragged order wins; anything not yet placed keeps its usual position after those.
        let rank = Dictionary(ui.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let arranged = rest.enumerated().sorted {
            let (l, r) = (rank[$0.element.id] ?? Int.max, rank[$1.element.id] ?? Int.max)
            return l != r ? l < r : $0.offset < $1.offset
        }.map(\.element)
        // Bots hidden from Perch only appear while opened from search.
        return (pinned + arranged).filter {
            seen.insert($0.id).inserted && !ui.isDismissed($0)
                && !($0.source == .grok && GrokSource.hidden.contains($0.sessionID) && ui.selectedID != $0.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Search, typed right here, with the new chat button on the same line.
            SearchBar().padding(.bottom, 5)
            let entries = sidebarEntries
            let pinned = entries.filter(ui.sidebarPinned)
            // Messages from people (Slack, WhatsApp) apart from the AI chats.
            // Bots are people-like too: they sit with Slack and WhatsApp. AI chats are the coding ones.
            let messages = entries.filter { e in
                guard !ui.sidebarPinned(e) else { return false }
                if case .agent(let a) = e { return a.source == .grok }
                return true
            }
            let chats = entries.filter { e in
                guard !ui.sidebarPinned(e), case .agent(let a) = e else { return false }
                return a.source != .grok
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    if !pinned.isEmpty {
                        sidebarHeading("Pinned")
                        ForEach(pinned) { sidebarRow($0) }
                    }
                    if !messages.isEmpty {
                        sidebarHeading("Messages")
                        ForEach(messages) { sidebarRow($0) }
                    }
                    if !chats.isEmpty {
                        sidebarHeading("AI chats")
                        ForEach(chats) { sidebarRow($0) }
                    }
                }.frame(maxWidth: .infinity, alignment: .topLeading)
                .animation(.spring(response: 0.36, dampingFraction: 0.86), value: entries.map(\.id))
            }
            .frame(maxHeight: .infinity)
            .onHover { inside in frozen = inside ? sidebarEntries.map(\.id) : nil }
            if let name = ui.sidebarUndoName {
                HStack(spacing: 6) {
                    Text("\(name) removed").lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Undo") { ui.undoSidebarRemoval() }.buttonStyle(LinkButton())
                }
                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 7).padding(.top, 5)
            }
        }
        .frame(width: 264, height: 452, alignment: .top)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) { now = Date() }
            }
        }
    }

    private var sidebarEntries: [SidebarChat] {
        let remmi = displayedAgents.filter { $0.source == .grok && $0.name == "Remmi" }
        let rest = (displayedConversations.map(SidebarChat.conversation)
            + displayedAgents.filter { agent in !remmi.contains(where: { $0.id == agent.id }) }.map(SidebarChat.agent))
            .sorted { lastActive($0) == lastActive($1) ? $0.id < $1.id : lastActive($0) > lastActive($1) }
        let live = remmi.map(SidebarChat.agent) + rest
        guard let frozen else { return live }
        // Held still under the pointer; anything new waits at the bottom until it leaves.
        let rank = Dictionary(frozen.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return live.enumerated().sorted {
            let (l, r) = (rank[$0.element.id] ?? Int.max, rank[$1.element.id] ?? Int.max)
            return l != r ? l < r : $0.offset < $1.offset
        }.map(\.element)
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.4))
            .padding(.horizontal, 7).padding(.top, 6).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func sidebarRow(_ chat: SidebarChat) -> some View {
        switch chat {
        case .agent(let agent):
            RailRow(agent: agent, selected: ui.selectedID == agent.id && !ui.composing && !ui.showingProfiles && !ui.showingTasks,
                    star: ui.sidebarPinned(chat)) { dragged in
                ui.move(dragged, before: agent.id, in: displayedAgents.map(\.id))
            }
        case .conversation(let target):
            SlackRailRow(target: target, selected: ui.slackTarget?.workspace == target.workspace && ui.slackTarget?.id == target.id)
        }
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

/// Shared geometry keeps every chat on the same simple sidebar grid.
private enum SidebarStyle {
    static let avatar: CGFloat = 22
    static let rowHeight: CGFloat = 30
    static let spacing: CGFloat = 7
    static let inset: CGFloat = 5
    static let nameSize: CGFloat = 11.5
}

private struct SidebarActionButtons: View {
    let chat: SidebarChat
    @Environment(NotchUI.self) private var ui
    var body: some View {
        Button { ui.toggleSidebarPin(chat) } label: {
            Label(ui.sidebarPinned(chat) ? "Unpin" : "Pin to top", systemImage: ui.sidebarPinned(chat) ? "pin.slash" : "pin")
        }
        Button { ui.removeSidebarChat(chat) } label: { Label("Remove from Perch", systemImage: "xmark") }
    }
}

/// Whether a chat is waiting on the user: orange when it needs an answer, blue when there is
/// something new to read (a reply that came in, a turn that finished).
private struct WaitingDot: View {
    let agent: Agent
    var body: some View {
        let needs = agent.status == .needsYou
        let fresh = agent.unread > 0 || agent.status == .unread || agent.status == .done
        if needs || fresh {
            Circle().fill(needs ? Palette.amber : Palette.blue).frame(width: 8, height: 8)
                .transition(.scale.combined(with: .opacity))
                .help(needs ? "Waiting for your answer" : "New since you last looked")
        }
    }
}

private struct SidebarActions: View {
    let chat: SidebarChat
    var body: some View {
        Menu { SidebarActionButtons(chat: chat) } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5)).frame(width: 24, height: 28).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Actions for \(chat.name)")
        .accessibilityLabel("Actions for \(chat.name)")
    }
}

private struct SidebarSwipeRow: ViewModifier {
    let chat: SidebarChat
    @Environment(NotchUI.self) private var ui
    func body(content: Content) -> some View {
        let current = ui.sidebarSwipe?.id == chat.id ? ui.sidebarSwipe : nil
        let exiting = ui.sidebarExitingID == chat.id
        let collapsing = ui.sidebarCollapsingID == chat.id
        content
            .offset(x: current?.x ?? 0)
            .opacity(exiting && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 1)
            .background(alignment: .trailing) {
                if let current {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark")
                        Text("Remove")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(current.ready ? 1 : 0.55))
                    .scaleEffect(current.ready ? 1.08 : 0.88)
                    .animation(.spring(response: 0.24, dampingFraction: 0.6), value: current.ready)
                    .padding(.horizontal, 12).frame(maxHeight: .infinity)
                    .background(Color(red: 0.52, green: 0.18, blue: 0.2))
                    .opacity(min(1, abs(current.x) / 30))
                }
            }
            .frame(height: collapsing ? 0 : SidebarStyle.rowHeight)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onHover { over in
                if over { ui.hoveredSidebarChat = chat }
                else if ui.hoveredSidebarChat?.id == chat.id { ui.hoveredSidebarChat = nil }
            }
            .onDisappear { if ui.hoveredSidebarChat?.id == chat.id { ui.hoveredSidebarChat = nil } }
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
        HStack(spacing: SidebarStyle.spacing) {
            FaceView(agent: agent, size: 16)
                .frame(width: SidebarStyle.avatar, height: SidebarStyle.avatar)
            Text(agent.name)
                .font(.system(size: SidebarStyle.nameSize, weight: selected || agent.status > .done ? .semibold : .regular))
                .foregroundStyle(.white.opacity(agent.status == .idle && !selected ? 0.6 : 0.95))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            WaitingDot(agent: agent)
            SidebarActions(chat: .agent(agent))
        }
        .frame(height: SidebarStyle.rowHeight)
        .padding(.horizontal, SidebarStyle.inset)
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
        .contextMenu { SidebarActionButtons(chat: .agent(agent)) }
        .modifier(SidebarSwipeRow(chat: .agent(agent)))
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
                    Text(bannerText(summary)).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.75))
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

/// A card being dragged around the board. The board draws the card floating under the pointer,
/// a stable insertion line where it would land. Existing cards keep their geometry until
/// release; nothing is sent to Notion while the pointer moves.
@Observable
private final class BoardDrag {
    static weak var current: BoardDrag?
    @ObservationIgnored var scrollViews: [String: NSScrollView] = [:]
    var card: TaskItem?
    /// Pointer position in the board's space, and where on the card it was picked up. Only the
    /// floating card watches this; everything else watches the few things below that change
    /// rarely, so moving the pointer does not redraw the whole board.
    var point = CGPoint.zero
    /// A column whose top or bottom edge the pointer is resting on: -1 top, 1 bottom.
    var edge: (column: String, dir: Int)?
    var grab = CGSize.zero
    var size = CGSize.zero
    /// Where it would land: a column and a position in it.
    var target: (column: String, index: Int)?
    /// Frames of the cards and columns, kept without redrawing anything when they change.
    @ObservationIgnored var cards: [String: CGRect] = [:]
    @ObservationIgnored var columns: [String: CGRect] = [:]
    @ObservationIgnored var lists: [String: CGRect] = [:]

    @ObservationIgnored private var orderedIDs: [String: [String]] = [:]

    func begin(_ task: TaskItem, at start: CGPoint) {
        guard card == nil, let frame = cards[task.id], frame.width > 0, frame.height > 0 else { return }
        orderedIDs = Dictionary(uniqueKeysWithValues: NotionTasks.columns.map { ($0, NotionTasks.shared.cards(in: $0).map(\.id)) })
        size = frame.size
        grab = CGSize(width: start.x - frame.minX, height: start.y - frame.minY)
        point = start
        NotionTasks.shared.beginArrangement()
        card = task
    }

    func move(to point: CGPoint) {
        self.point = point
        guard let card else { return }
        let next = BoardDropGeometry.target(at: point, columns: columns, frames: cards, orderedIDs: orderedIDs, dragging: card.id)
        if target?.column != next?.column || target?.index != next?.index {
            target = next
        }
        var now: (column: String, dir: Int)?
        if let column = next?.column, let frame = lists[column], frame.contains(point) {
            if point.y < frame.minY + 28 { now = (column, -1) }
            else if point.y > frame.maxY - 28 { now = (column, 1) }
        }
        if now?.column != edge?.column || now?.dir != edge?.dir { edge = now }
    }

    func finish() {
        guard let card else { return }
        let destination = target
        // End first: both the gesture and mouse-up fallback may arrive, but only one commits.
        end()
        if let destination {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                NotionTasks.shared.place(card.id, in: destination.column)
            }
        }
    }

    func end() {
        card = nil
        target = nil
        edge = nil
        orderedIDs = [:]
        NotionTasks.shared.endArrangement()
    }
}

/// The board: My to-dos open, the other lists folded to slim strips until wanted. Ticking a
/// card off, adding one and moving one all happen on screen at once; Notion is told after.
private struct TasksView: View {
    @State private var draft = ""
    @State private var drag = BoardDrag()
    @State private var mouseUp: Any?
    @FocusState private var focused: Bool
    private var notion: NotionTasks { NotionTasks.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !notion.connected {
                setup
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 13))
                        .foregroundStyle(.white.opacity(draft.isEmpty ? 0.3 : 0.9))
                    TextField("Add a to-do", text: $draft)
                        .textFieldStyle(.plain).font(.system(size: 12.5)).focused($focused)
                        .onSubmit {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.75)) { notion.add(draft) }
                            draft = ""
                        }
                    if notion.loading {
                        ProgressView().controlSize(.mini).transition(.opacity)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.white.opacity(focused ? 0.1 : 0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded {
                    NotchUI.shared.controller?.panel.makeKey()
                    focused = true
                })
                .animation(.easeOut(duration: 0.15), value: focused)

                if let problem = notion.problem {
                    Text(problem).font(.system(size: 11)).foregroundStyle(Palette.red.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 6)
                }
                HStack(alignment: .top, spacing: 8) {
                    let arranged = NotionTasks.columns.filter { !notion.folded.contains($0) }
                        + NotionTasks.columns.filter { notion.folded.contains($0) }
                    ForEach(arranged, id: \.self) { column in
                        TaskColumn(title: column, cards: notion.cards(in: column))
                    }
                }
                .coordinateSpace(.named("board"))
                .overlay(alignment: .topLeading) { FloatingCard() }
            }
        }
        .environment(drag)
        .padding(.top, 2)
        .onAppear {
            notion.refresh()
            BoardDrag.current = drag
            // Belt and braces: letting go of the mouse always ends a drag, even if the card's own
            // gesture missed it.
            mouseUp = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [drag] event in
                DispatchQueue.main.async {
                    drag.finish()
                }
                return event
            }
        }
        .onDisappear {
            if let mouseUp { NSEvent.removeMonitor(mouseUp) }
            mouseUp = nil
            if BoardDrag.current === drag { BoardDrag.current = nil }
            drag.end()
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

/// The card being dragged, floating under the pointer. The only view that follows every move.
private struct FloatingCard: View {
    @Environment(BoardDrag.self) private var drag

    var body: some View {
        if let card = drag.card {
            TaskCard(task: card, tint: TaskColumn.tint(drag.target?.column ?? card.column), floating: true)
                .frame(width: drag.size.width)
                .position(x: drag.point.x - drag.grab.width + drag.size.width / 2,
                          y: drag.point.y - drag.grab.height + drag.size.height / 2)
                .allowsHitTesting(false)
                .transaction { $0.animation = nil }
        }
    }
}

/// Resolves the actual clip view so edge scrolling is smooth, in pixels, without
/// repeatedly replacing SwiftUI's scroll anchor during an active card gesture.
private struct BoardScrollProbe: NSViewRepresentable {
    let found: (NSScrollView) -> Void
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.found = found
        DispatchQueue.main.async { view.resolve() }
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.found = nil }
    final class Probe: NSView {
        var found: ((NSScrollView) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); DispatchQueue.main.async { self.resolve() } }
        func resolve() { if let scroll = enclosingScrollView { found?(scroll) } }
    }
}

private struct TaskColumn: View {
    let title: String
    let cards: [TaskItem]
    @Environment(BoardDrag.self) private var drag
    /// Native scrolling stays continuous while a dragged card is held near an edge.
    @State private var nativeScroll: NSScrollView?
    @State private var scroller: Timer?
    @State private var hoveredID: String?

    static func tint(_ column: String) -> Color {
        // Cool, quiet colours that white text reads well on.
        switch column {
        case "Upshow to-dos": return Color(red: 0.25, green: 0.72, blue: 0.62)
        case "My to-dos": return Color(red: 0.36, green: 0.58, blue: 0.98)
        case "Waiting On": return Color(red: 0.62, green: 0.52, blue: 0.96)
        default: return .white.opacity(0.4)
        }
    }

    private var tint: Color { Self.tint(title) }
    private var folded: Bool { NotionTasks.shared.folded.contains(title) }

    private func toggle() {
        withAnimation(tabSwitch) {
            if folded { NotionTasks.shared.folded.remove(title) } else { NotionTasks.shared.folded.insert(title) }
        }
    }

    /// Holding a dragged card at the top or bottom of the list scrolls it that way.
    private func autoscroll(_ direction: Int) {
        scroller?.invalidate(); scroller = nil
        guard direction != 0 else { return }
        scroller = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            guard drag.card != nil, let scroll = nativeScroll, let document = scroll.documentView else { return }
            let clip = scroll.contentView
            let origin = clip.bounds.origin
            let next = max(0, min(max(0, document.bounds.height - clip.bounds.height), origin.y + CGFloat(direction) * 4))
            guard abs(next - origin.y) > 0.1 else { return }
            clip.scroll(to: CGPoint(x: origin.x, y: next))
            scroll.reflectScrolledClipView(clip)
            DispatchQueue.main.async { drag.move(to: drag.point) }
        }
        // Keep ticking during AppKit's mouse tracking loop as well as ordinary events.
        if let scroller { RunLoop.main.add(scroller, forMode: .common) }
    }

    private var insertionID: String? {
        guard let target = drag.target, target.column == title else { return nil }
        let others = cards.filter { $0.id != drag.card?.id }
        return target.index < others.count ? others[target.index].id : nil
    }

    var body: some View {
        let landing = drag.card != nil && drag.target?.column == title
        Group {
            if folded {
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
                            .contentTransition(.numericText())
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
                            ForEach(cards) { card in
                                TaskCard(task: card, tint: tint, hovered: hoveredID == card.id && drag.card == nil)
                                    .id(card.id)
                                    .opacity(drag.card?.id == card.id ? 0.18 : 1)
                                    .overlay(alignment: .top) {
                                        if drag.card != nil, insertionID == card.id {
                                            Capsule().fill(tint).frame(height: 3).offset(y: -4)
                                                .allowsHitTesting(false)
                                        }
                                    }
                            }
                            Color.clear.frame(height: 3)
                                .overlay { if landing, insertionID == nil { Capsule().fill(tint) } }
                                .allowsHitTesting(false)
                            if cards.isEmpty && !landing {
                                Text("Nothing here").font(.system(size: 11)).foregroundStyle(.white.opacity(0.3))
                                    .frame(maxWidth: .infinity).padding(.top, 20)
                            }
                        }
                        .padding(.bottom, 30)
                        .background(BoardScrollProbe { scroll in
                            if nativeScroll !== scroll { nativeScroll = scroll }
                            drag.scrollViews[title] = scroll
                        }.frame(width: 0, height: 0))
                    }
                    .frame(height: 366)
                    // Which card is under the pointer is worked out here, from where the pointer is,
                    // so a highlight can never be left behind on a card the pointer has already left.
                    .onContinuousHover(coordinateSpace: .named("board")) { phase in
                        switch phase {
                        case .active(let point):
                            let id = cards.first { drag.cards[$0.id]?.contains(point) == true }?.id
                            if id != hoveredID { hoveredID = id }
                        case .ended:
                            hoveredID = nil
                        }
                    }
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("board")) }) { drag.lists[title] = $0 }
                    .onChange(of: drag.edge?.column == title ? drag.edge?.dir ?? 0 : 0) { _, direction in autoscroll(direction) }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(landing ? tint.opacity(folded ? 0.25 : 0.07) : .white.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: landing)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("board")) }) { drag.columns[title] = $0 }
        .onDisappear {
            scroller?.invalidate()
            nativeScroll = nil
            drag.columns[title] = nil; drag.lists[title] = nil; drag.scrollViews[title] = nil
        }
    }
}

/// Read-only native drag regression: lift a real visible card, check geometry, cancel.
/// No completion or place call is made, so this never writes a task to Notion.
func checkBoardDrag(to path: String) {
    guard let drag = BoardDrag.current,
          let task = NotionTasks.shared.tasks.first(where: { task in
              guard let frame = drag.cards[task.id], let list = drag.lists[task.column] else { return false }
              return frame.height > 0 && list.contains(CGPoint(x: frame.midX, y: frame.midY))
          }), let frame = drag.cards[task.id] else {
        try? Data("{\"Board is ready\":false}".utf8).write(to: URL(fileURLWithPath: path))
        return
    }
    let original = drag.cards
    let point = CGPoint(x: frame.midX, y: frame.midY)
    drag.begin(task, at: point)
    drag.move(to: point)
    let slot = drag.target
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
        var results: [String: Bool] = [:]
        results["Native scroll view resolved"] = drag.scrollViews[task.column] != nil
        results["Source card keeps its full frame"] = drag.cards[task.id] == frame
        results["Other cards do not shift during pickup"] = original.allSatisfy { drag.cards[$0.key] == $0.value }
        drag.move(to: point)
        results["Stationary pointer keeps the insertion slot"] = drag.target?.column == slot?.column && drag.target?.index == slot?.index
        drag.move(to: CGPoint(x: -100, y: -100))
        results["Outside-board release has no destination"] = drag.target == nil
        drag.end()
        results["Cancel clears floating card and target"] = drag.card == nil && drag.target == nil
        try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
    }
}

private struct TaskCard: View {
    let task: TaskItem
    let tint: Color
    /// The copy that follows the pointer while dragging.
    var floating = false
    /// Set by the column, which knows where the pointer is.
    var hovered = false
    @Environment(BoardDrag.self) private var drag
    /// Handing this to-do to the pinned bot: the note being written, and whether it went.
    @State private var pushing = false
    @State private var note = ""
    @State private var pushed = false
    @FocusState private var noteFocused: Bool

    private var bot: Agent? {
        let ui = NotchUI.shared
        return AgentStore.shared.grokBots.first { ui.pinned.contains($0.name) } ?? AgentStore.shared.grokBots.first
    }

    /// Sends the to-do and the note to the bot as one message, with the Notion link so it can
    /// find the card.
    private func push() {
        guard let bot else { return }
        var lines = ["To-do from my list: \"\(task.name)\""]
        var facts: [String] = [task.column]
        if let (due, _) = dueText { facts.append("due \(due.lowercased())") }
        if let p = task.priority { facts.append("\(p) priority") }
        lines[0] += " (\(facts.joined(separator: ", ")))"
        if let url = task.url { lines.append(url) }
        let ask = note.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(ask.isEmpty ? "Can you take this on?" : ask)
        GrokSource.shared.send(bot, text: lines.joined(separator: "\n\n"))
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            pushing = false
            pushed = true
        }
        note = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { withAnimation { pushed = false } }
    }

    @ViewBuilder private var pushBox: some View {
        if pushing, let bot {
            HStack(spacing: 6) {
                TextField("What should \(bot.name) do with it?", text: $note, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 11.5)).lineLimit(1...4)
                    .focused($noteFocused)
                    .onSubmit(push)
                    .onKeyPress(.escape) {
                        withAnimation { pushing = false }
                        return .handled
                    }
                Button(action: push) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 15)).foregroundStyle(.white)
                }
                .buttonStyle(Press())
                .help("Send to \(bot.name)")
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .transition(.opacity.combined(with: .move(edge: .top)))
            .onAppear {
                NotchUI.shared.controller?.panel.makeKey()
                DispatchQueue.main.async { noteFocused = true }
            }
        } else if pushed, let bot {
            Label("Sent to \(bot.name)", systemImage: "checkmark").font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.green).transition(.opacity)
        }
    }
    @State private var ticking = false

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
        HStack(alignment: .top, spacing: 8) {
            Button(action: tick) {
                ZStack {
                    Circle().strokeBorder(.white.opacity(ticking ? 0 : hovered ? 0.75 : 0.35), lineWidth: 1.4)
                    Circle().fill(Palette.green).scaleEffect(ticking ? 1 : 0.01).opacity(ticking ? 1 : 0)
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.black)
                        .scaleEffect(ticking ? 1 : 0.3).opacity(ticking ? 1 : 0)
                }
                .frame(width: 15, height: 15).padding(.top, 1)
            }
            .buttonStyle(Press(reach: 6)).help("Mark as done")
            VStack(alignment: .leading, spacing: 4) {
                Text(task.name).font(.system(size: 12)).foregroundStyle(.white.opacity(ticking ? 0.4 : 0.93))
                    .strikethrough(ticking, color: .white.opacity(0.5))
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
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
                if !floating { pushBox }
            }
            // Hand it to Remmi: shown while the pointer is on the card. Its space is always kept,
            // so the text never re-wraps and the card never changes size as the pointer passes.
            if bot != nil {
                let showing = hovered || pushing
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { pushing.toggle() } } label: {
                    Image(systemName: "paperplane.fill").font(.system(size: 10))
                        .foregroundStyle(.white.opacity(pushing ? 0.95 : 0.6))
                        .frame(width: 22, height: 22)
                        .background(.white.opacity(pushing ? 0.2 : 0.1), in: Circle())
                }
                .buttonStyle(Press(reach: 3))
                .help("Push to \(bot?.name ?? "Remmi") with a note")
                .opacity(!floating && showing ? 1 : 0)
                .allowsHitTesting(!floating && showing)
                .animation(.easeOut(duration: 0.1), value: showing)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .background(tint.opacity(floating ? 0.42 : hovered ? 0.3 : 0.2), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .background(floating ? Color.black.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(floating ? 0.25 : 0), lineWidth: 1))
        .scaleEffect(floating ? 1.04 : 1)
        .rotationEffect(.degrees(floating ? -1.5 : 0))
        .shadow(color: .black.opacity(floating ? 0.6 : 0), radius: 14, y: 8)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("board")) }) { frame in
            if !floating { drag.cards[task.id] = frame }
        }
        .onTapGesture(count: 2) { NotionTasks.shared.open(task) }
        // Keep this gesture's source mounted at its original size throughout the drag.
        // The floating copy follows the pointer; release commits the insertion line once.
        .gesture(floating || pushing ? nil : DragGesture(minimumDistance: 6, coordinateSpace: .named("board"))
            .onChanged { value in
                if drag.card == nil { drag.begin(task, at: value.startLocation) }
                if drag.card?.id == task.id { drag.move(to: value.location) }
            }
            .onEnded { value in
                guard drag.card?.id == task.id else { return }
                drag.move(to: value.location)
                drag.finish()
            })
        .help("Drag to move. Double click to open in Notion.")
    }

    private func tick() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { ticking = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { NotionTasks.shared.complete(task) }
        }
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

/// One option in a question: a round (or square, for several) marker, the option, what it
/// means underneath, and "Recommended" picked out instead of left in the label.
private struct QuestionOption: View {
    let label: String
    let detail: String
    let multi: Bool
    let on: Bool
    let tint: Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let recommended = label.localizedCaseInsensitiveContains("(recommended)")
        let shown = recommended ? label.replacingOccurrences(of: #"\s*\((?i:recommended)\)"#, with: "", options: .regularExpression) : label
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    if multi {
                        RoundedRectangle(cornerRadius: 3).stroke(on ? tint : .white.opacity(0.35), lineWidth: 1.5)
                        if on { Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(tint) }
                    } else {
                        Circle().stroke(on ? tint : .white.opacity(0.35), lineWidth: 1.5)
                        if on { Circle().fill(tint).padding(3) }
                    }
                }
                .frame(width: 13, height: 13).padding(.top, 1.5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(shown).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        if recommended {
                            Text("Recommended").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.green)
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(Palette.green.opacity(0.15), in: Capsule())
                        }
                    }
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(on ? tint.opacity(0.18) : .white.opacity(hovered ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(on ? tint.opacity(0.75) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(Press(reach: 0))
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: on)
    }
}

// MARK: Chrome profiles

/// A profile as a circle: a chosen icon, else its Google picture ringed in Chrome's colour for
/// it, else a plain coloured initial.
private struct ProfileAvatar: View {
    let profile: ChromeProfile
    let size: CGFloat

    private static let pictures: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 32
        return cache
    }()

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
                // A logo with transparent edges sits whole on a disc instead: white, or black for
                // the profiles whose logo reads better on dark. A black disc gets a thin edge
                // so it still shows against the island.
                let dark = (UserDefaults.standard.stringArray(forKey: "darkIconProfiles") ?? ["Profile 3"]).contains(profile.id)
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                    .padding(size * 0.14)
                    .frame(width: size, height: size).background(dark ? Color.black : .white, in: Circle()).clipShape(Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(dark ? 0.28 : 0), lineWidth: 1))
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
    /// Which app the new chat runs in, remembered for next time.
    @State private var engine = UserDefaults.standard.string(forKey: "newChatEngine") ?? "claude"
    @FocusState private var focused: Bool

    @Namespace private var engineSpace

    /// The chosen app's own colour, for the accents on this screen.
    private var tint: Color {
        engine == "codex" ? Color(red: 0.40, green: 0.36, blue: 0.93) : Color(red: 0.80, green: 0.42, blue: 0.29)
    }

    /// One app to start the chat in, shown by its logo. The highlight slides between them.
    private func engineChip(_ id: String, _ source: AgentSource, _ title: String) -> some View {
        let on = engine == id
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { engine = id }
            UserDefaults.standard.set(id, forKey: "newChatEngine")
        } label: {
            AppMark(source: source)
                .saturation(on ? 1 : 0).opacity(on ? 1 : 0.55)
                .scaleEffect(on ? 1 : 0.9)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background {
                    if on {
                        Capsule().fill(tint.opacity(0.35))
                            .overlay(Capsule().strokeBorder(tint.opacity(0.7), lineWidth: 1))
                            .matchedGeometryEffect(id: "engine", in: engineSpace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(Press()).help(title)
    }

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
        ui.heldOpen = true
        NSApp.activate(ignoringOtherApps: true)
        let ui = ui
        panel.begin { response in
            ui.heldOpen = false
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
                Text("New chat").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                HStack(spacing: 2) {
                    engineChip("claude", .claude, "Claude Code")
                    engineChip("codex", .codex, "Codex")
                }
                .padding(2)
                .background(.white.opacity(0.08), in: Capsule())
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
            Text(engine == "codex"
                 ? "Starts in Codex in the background, able to edit files in this folder, and shows up in the Codex app."
                 : "Starts in Claude Code in the background, in auto mode, and shows up in the Claude app once it has replied.")
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: engine)
                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.3))
                .fixedSize(horizontal: false, vertical: true)
            // Pictures and files pasted (Cmd+V) or dropped in go with the first message.
            if let files = ui.attachments["new"], !files.isEmpty {
                HStack(spacing: 6) {
                    ForEach(files) { file in
                        Image(nsImage: file.thumbnail).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                Button { ui.attachments["new"]?.removeAll { $0.id == file.id } } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                                        .foregroundStyle(.white, .black.opacity(0.7))
                                }
                                .buttonStyle(Press()).offset(x: 4, y: -4)
                            }
                    }
                }
            }
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
                        .foregroundStyle(!ui.drafts.hasText("new") && (ui.attachments["new"] ?? []).isEmpty ? .white.opacity(0.2) : tint)
                }
                .buttonStyle(Press()).disabled(!ui.drafts.hasText("new") && (ui.attachments["new"] ?? []).isEmpty)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            // Edged in the chosen app's colour, fading across when it changes.
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.opacity(0.45), lineWidth: 1))
            .animation(.easeInOut(duration: 0.3), value: engine)
        // A click anywhere in the box starts typing, not only on the line of text.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            ui.controller?.panel.makeKey()
            focused = true
        })
        }
        .frame(height: 452, alignment: .top)
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        DispatchQueue.main.async { if let f = Attachment.from(file: url) { ui.attachments["new", default: []].append(f) } }
                    }
                } else {
                    _ = provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                        guard let data, let image = NSImage(data: data) else { return }
                        DispatchQueue.main.async { if let f = Attachment.from(image) { ui.attachments["new", default: []].append(f) } }
                    }
                }
            }
            return true
        }
        .padding(.top, 2)
        .onAppear {
            SessionIndex.shared.refresh()
            ui.controller?.panel.makeKey()
            DispatchQueue.main.async { focused = true }
        }
    }

    private func start(_ folder: String) {
        let files = ui.attachments["new"] ?? []
        let prompt = ([ui.drafts["new"] ?? ""] + files.map(\.note)).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let started = engine == "codex" ? CodingSessions.shared.startCodexChat(prompt: prompt, folder: folder)
                                        : CodingSessions.shared.startChat(prompt: prompt, folder: folder)
        guard !prompt.isEmpty, let agent = started else { return }
        Dictation.shared.stop()
        ui.drafts["new"] = nil
        ui.attachments["new"] = nil
        ui.select(agent.id)
    }
}

// MARK: Chat

/// Pending follow-ups remain visibly separate from messages already accepted by Codex.
private struct CodexQueueCard: View {
    let agent: Agent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                Text("Queued in Codex" + (agent.codexQueue.isEmpty ? "" : " · \(agent.codexQueue.count)"))
                Spacer(minLength: 0)
                Button("Manage in Codex") { CodingSessions.shared.open(agent) }
                    .buttonStyle(LinkButton())
                    .help("Steer, edit, reorder or remove queued messages in Codex")
            }
            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.65))
            if let error = agent.codexQueueError {
                Text(error).font(.system(size: 10.5)).foregroundStyle(.orange)
            }
            if !agent.codexQueue.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(agent.codexQueue) { message in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "arrow.turn.down.right").foregroundStyle(.white.opacity(0.4))
                                VStack(alignment: .leading, spacing: 2) {
                                    if !message.text.isEmpty {
                                        Text(message.text).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                            .help(message.text)
                                    }
                                    if !message.attachments.isEmpty {
                                        Label(message.attachments.joined(separator: ", "), systemImage: "paperclip")
                                            .foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                                    }
                                }
                            }
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One agent's conversation: recent messages in full, and a reply box.
struct ChatView: View {
    /// Whether the newest message is in view (the user is following along), and whether
    /// something arrived while they were reading further up.
    @State private var following = true
    @State private var newBelow = false
    @State private var newCount = 0
    @State private var viewHeight: CGFloat = 0
    /// Hidden until it has come to rest on the right message, so opening never shows it jumping.
    @State private var ready = false
    let agent: Agent
    @Environment(NotchUI.self) private var ui
    @Environment(\.sideWindow) private var sideWindow
    /// How many of the most recent messages are drawn.
    @State private var shown = 10
    /// Rests the view on the newest message, by its top edge: a long reply is read from its
    /// first line, and anything shorter simply sits at the bottom of the chat.
    private func settle(_ proxy: ScrollViewProxy) {
        if let first = firstUnread { return proxy.scrollTo(first, anchor: .top) }
        if let target = Self.restingID(messages) { proxy.scrollTo(target, anchor: .top) }
    }

    /// Opened with several of its messages unread: the first of them, so reading starts there.
    /// Once the user writes, the chat follows the newest again.
    private var firstUnread: String? {
        let count = ui.openedUnread[agent.id] ?? 0
        guard count > 1, messages.last?.fromUser != true else { return nil }
        var left = count
        for message in messages.reversed() where !message.fromUser {
            left -= 1
            if left == 0 { return message.id }
        }
        return nil
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

    private var queueHeight: CGFloat {
        guard agent.source == .codex else { return 0 }
        if !agent.codexQueue.isEmpty { return min(148, 36 + CGFloat(agent.codexQueue.count) * 36) }
        return agent.codexQueueError == nil ? 0 : 52
    }

    /// Coding chats give up a little height to their status line; bot chats have none.
    private var historyHeight: CGFloat {
        let status: CGFloat = agent.source == .grok ? 0 : 32
        return max(100, (agent.codexQuestion == nil ? 380 : 160) - status - queueHeight)
    }

    var body: some View {
        let visibleItems = items
        let lastItemID = visibleItems.last?.id
        VStack(alignment: .leading, spacing: 8) {
            header
            // Where a coding chat's work has got to. Bots are conversations; they need none.
            if agent.source != .grok { StatusLine(agent: agent, messages: messages) }
            ScrollViewReader { proxy in
                ScrollView {
                    // Not lazy: every message has to exist for the view to be able to come to
                    // rest on the newest one, and a chat is only a few dozen messages.
                    VStack(alignment: .leading, spacing: 10) {
                        if messages.count > shown {
                            Button("Show earlier messages") { shown += 20 }
                                .buttonStyle(LinkButton()).frame(maxWidth: .infinity)
                        }
                        ForEach(visibleItems) { item in
                            Group {
                                if item.peers.isEmpty, let message = item.message {
                                    if agent.source == .grok, !message.id.hasPrefix("local-"), message.id != "latest" {
                                        bubble(message).modifier(SwipeToReply(agent: agent, message: message))
                                    } else {
                                        bubble(message)
                                    }
                                } else {
                                    PeerGroup(owner: agent.name, messages: item.peers)
                                }
                            }
                            .id(item.id)
                            .transition(item.message?.fromUser == true ? .sent : .opacity)
                            .reportsTop(item.id == lastItemID)
                        }
                        if agent.status == .working {
                            // Its face, busy at work, as in Grok Bot's own chat.
                            HStack(spacing: 7) {
                                FaceView(agent: agent, size: 18)
                                Text(agent.activity ?? (agent.source == .grok ? "\(agent.name) is working…" : "Working…"))
                                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                                    .contentTransition(.opacity)
                                    .animation(.easeOut(duration: 0.25), value: agent.activity)
                            }
                            .padding(.top, 2)
                            // Comes in once the message just sent has landed, not on top of it.
                            .transition(.opacity.animation(.easeOut(duration: 0.25).delay(0.3)))
                        }
                    }
                    .padding(.horizontal, 6)
                }
                // A fixed height keeps the island the same size every time it opens, so the
                // opening animation has one target instead of jumping as the history loads.
                .coordinateSpace(name: "chat")
                .opacity(ready || messages.isEmpty ? 1 : 0)
                .background(GeometryReader { g in Color.clear.onAppear { viewHeight = g.size.height }
                    .onChange(of: g.size.height) { _, h in viewHeight = h } })
                .onPreferenceChange(LastTopKey.self) { top in
                    // At the bottom: the newest message rests at the top (where the chat settles it), or
                    // its end is in view. Scrolled up any further is reading, not following.
                    following = top.minY < 30 || top.maxY < viewHeight + 30
                    if following, newBelow { withAnimation(.easeOut(duration: 0.2)) { newBelow = false; newCount = 0 } }
                }
                .overlay(alignment: .bottom) {
                    if newBelow {
                        NewBelowButton(count: newCount) {
                            withAnimation(.sendSpring) { settle(proxy) }
                            newBelow = false
                            newCount = 0
                        }
                    }
                }
                .frame(height: sideWindow == nil ? historyHeight : nil)
                .frame(maxHeight: sideWindow == nil ? historyHeight : .infinity)
                .onChange(of: messages.last?.id) { before, _ in
                    // A new message glides into view. A whole history arriving at once (opening
                    // a chat, or after a relaunch) jumps straight to the end instead of racing past.
                    if let before, messages.contains(where: { $0.id == before }) {
                        // Reading further up: say something came, do not pull the view down.
                        // Your own message always goes to the bottom.
                        if messages.last?.fromUser != true && !following {
                            withAnimation(.easeOut(duration: 0.2)) { newBelow = true; newCount += 1 }
                            return
                        }
                        withAnimation(.sendSpring) { settle(proxy) }
                        DispatchQueue.main.async { withAnimation(.sendSpring) { settle(proxy) } }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { withAnimation(.sendSpring) { settle(proxy) } }
                    } else {
                        settle(proxy)
                        DispatchQueue.main.async { settle(proxy) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            settle(proxy)
                            withAnimation(.easeOut(duration: 0.14)) { ready = true }
                        }
                    }
                }
                // Something in the chat was opened up (a file to read): bring it to the top.
                .onChange(of: ui.scrollTarget?.n) {
                    guard let id = ui.scrollTarget?.id else { return }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) }
                }
                .onAppear {
                    // Go to the newest message as the chat appears, and again once it has been
                    // laid out, since the first attempt can land before the content has a size.
                    settle(proxy)
                    DispatchQueue.main.async { settle(proxy) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        settle(proxy)
                        withAnimation(.easeOut(duration: 0.14)) { ready = true }
                    }
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
            if agent.status == .needsYou, agent.pending == nil, agent.source != .grok {
                // It asked for something, but the request itself is not open here (answered or
                // timed out elsewhere, or Perch restarted while it was waiting).
                VStack(alignment: .leading, spacing: 5) {
                    Text(agent.askElsewhere.map { "Waiting for your answer in its own app. It wants to use \($0)" }
                         ?? "It asked for something, but that request is not open here. Check it in its own app, or tell it to carry on.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open it there") { open() }.buttonStyle(ChipButton())
                }
                .padding(.horizontal, 6)
            }
            if queueHeight > 0 {
                CodexQueueCard(agent: agent).frame(height: queueHeight)
            }
            if !agent.queued.isEmpty {
                Text(agent.queued.count == 1 ? "1 message waiting for this turn to finish." : "\(agent.queued.count) messages waiting for this turn to finish.").font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4)).padding(.horizontal, 6)
            }
            if let pending = agent.pending {
                if case .followUp = pending.kind {
                    // Just finished: it is simply a chat, so only the reply box.
                    ReplyField(agent: agent, autofocus: ui.focusReply)
                } else if agent.codexQuestion != nil {
                    ScrollView {
                        PendingCard(agent: agent)
                    }.frame(height: 250, alignment: .top)
                } else {
                    PendingCard(agent: agent)
                }
            } else {
                ReplyField(agent: agent, autofocus: ui.focusReply)
            }
        }
        .padding(.top, 2)
        .task(id: agent.id) {
            guard agent.source == .codex else { return }
            while !Task.isCancelled {
                CodexQueue.shared.refresh(agent)
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
        // A picture clicked in this chat, enlarged over it.
        .overlay { Lightbox(side: sideWindow != nil) }
        // Reload when the agent says something new or changes state.
        .task(id: "\(agent.id)|\(agent.status.rawValue)|\(agent.lastMessage.count)|\(agent.tick)") { Threads.load(agent) }
        // Having the chat open in front of you is reading it, however it came to be open and
        // whenever the message arrived.
        .onAppear { ui.markSeen(agent.id) }
        .onChange(of: agent.unread) { ui.markSeen(agent.id) }
        .onChange(of: agent.status) { ui.markSeen(agent.id) }
        .onChange(of: agent.seen) { ui.markSeen(agent.id) }
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
            Spacer(minLength: 4)
            if agent.source != .grok, let used = agent.contextUsed { ContextMeter(used: used, model: agent.contextModel) }
            StatusChip(agent: agent)
            if CodingSessions.shared.canStop(agent) {
                // Stop it, from here, whichever app it is running in.
                Button { CodingSessions.shared.stop(agent) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill").font(.system(size: 8.5, weight: .bold))
                        Text("Stop").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Palette.red.opacity(0.85), in: Capsule())
                }
                .buttonStyle(Press()).help("Stop what it is doing")
                .transition(.scale.combined(with: .opacity))
            }
            if let sideWindow {
                // Back into the notch, on this same chat.
                Button {
                    SidePanel.shared.returnToNotch(agent)
                } label: {
                    Image(systemName: "rectangle.topthird.inset.filled").font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(Press()).help("Back to the notch")
                .id(ObjectIdentifier(sideWindow))
            } else {
                // Keep this chat open in a slim panel at the side of the screen, for following
                // instructions while working in another app.
                Button { SidePanel.shared.show(agent) } label: {
                    Image(systemName: "sidebar.right").font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(Press()).help("Keep open at the side")
            }
            if sideWindow != nil {
                // The side panel closes here; double-clicking the header still opens the real chat.
                Button { SidePanel.shared.close() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(Press()).help("Close")
            } else {
                Button(action: open) {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(Press()).help("Open in its own app")
            }
        }
        .padding(.horizontal, 2)
        // Double-clicking the header jumps to the real chat in its own app. Caught natively behind
        // the header, so its buttons still react on the first click with no wait.
        .background(DoubleClick(action: open))
    }

    private static let imageNote = try! NSRegularExpression(pattern: #"\[(?:Image|File) attached, saved at ([^\]]+)\]"#)
    private static let thumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 24 << 20
        return cache
    }()

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
        guard text.contains(" attached, saved at ") else { return (text, []) }
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
                if let image {
                    thumbnails.setObject(image, forKey: path as NSString,
                                         cost: Int(image.size.width * image.size.height) * 4)
                }
                done(image)
            }
        }
    }

    private struct Picture: View {
        let path: String
        @Environment(NotchUI.self) private var ui
        @Environment(\.sideWindow) private var sideWindow
        @State private var image: NSImage?
        @State private var hovered = false

        private var isImage: Bool { UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)?.conforms(to: .image) == true }

        var body: some View {
            if isImage { picture } else { file }
        }

        /// A file that is not a picture: its icon and name. Click to open it; on hover, save a
        /// copy to Downloads or show where it is.
        private var file: some View {
            HStack(spacing: 7) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 22, height: 22)
                Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9)).lineLimit(1).truncationMode(.middle)
                if hovered {
                    Button { saveToDownloads(path: path) } label: {
                        Image(systemName: "arrow.down.to.line").font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.white.opacity(0.75)).frame(width: 20, height: 20)
                            .background(.white.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(Press()).help("Save a copy to Downloads")
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                        Image(systemName: "folder").font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75)).frame(width: 20, height: 20)
                            .background(.white.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(Press()).help("Show in Finder")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.white.opacity(hovered ? 0.14 : 0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(maxWidth: 300, alignment: .trailing)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            .help("Open \(URL(fileURLWithPath: path).lastPathComponent)")
        }

        private var picture: some View {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Color.white.opacity(0.06).frame(width: 170, height: 110)
                }
            }
            .frame(width: 300)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            // Framed like a photo, so a screenshot never reads as part of the chat around it.
            .padding(4)
            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(hovered ? 0.3 : 0.18), lineWidth: 1))
            .overlay(alignment: .topTrailing) { if hovered { SaveButton { saveToDownloads(path: path) } } }
            .onHover { hovered = $0 }
            .onTapGesture {
                guard let full = NSImage(contentsOfFile: path) ?? image else { return }
                ui.enlarge(full, name: URL(fileURLWithPath: path).lastPathComponent, side: sideWindow != nil)
            }
            .help("Enlarge")
            .task(id: path) { ChatView.thumbnail(path) { image = $0 } }
        }
    }

    @ViewBuilder private func pictures(_ paths: [String]) -> some View {
        ForEach(paths, id: \.self) { Picture(path: $0) }
    }

    /// The fill for the user's own bubbles in this chat.
    private var mine: Color { agent.theme }

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
                            // As in Grok Bot: reactions sit in a round badge on the bubble's corner.
                            .overlay(alignment: .topLeading) { ReactionBadge(emojis: message.reactions).offset(x: -16, y: -14) }
                    }
                    .padding(.top, message.reactions.isEmpty ? 0 : 12)
                }
                if message.fromUser, message.id.hasPrefix("local-"), agent.queued.contains(where: { Threads.said($0) == Threads.said(message.text) }) {
                    // Not in yet: it goes in when the current turn finishes.
                    HStack(spacing: 6) {
                        Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                        Text("Waiting to send").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                        if CodingSessions.shared.canInterrupt(agent) {
                            Button("Interrupt with it") { CodingSessions.shared.interrupt(agent) }.buttonStyle(LinkButton())
                                .help("Stop the current turn and send this now")
                        } else if CodingSessions.shared.canSendNow(agent) {
                            Button("Send now") { CodingSessions.shared.sendNow(agent) }.buttonStyle(LinkButton())
                                .help("Interrupt the current turn with it. It arrives as a relayed message, so the chat may ask you to confirm spending or sending")
                        }
                    }
                }
                if let retry = agent.unsent[message.id] {
                    // It did not get through: say so on the message, never silently.
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(Palette.red)
                        Text("Not delivered").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.red)
                        Button("Try again", action: retry).buttonStyle(LinkButton())
                    }
                }
            } else if let name = message.fileName, let path = message.filePath {
                FileCard(name: name, path: path, agent: agent, messageID: message.id)
            } else if let email = message.email {
                EmailCard(draft: email, agent: agent)
            } else if let handoff = message.handoff {
                HandoffCard(instruction: handoff.instruction, resolution: handoff.resolution, agent: agent,
                            picture: messages.prefix { $0.id != message.id }.last { !$0.boxImages.isEmpty }?.boxImages.first)
            } else if let form = message.form {
                FormCard(form: form, entry: message.id, agent: agent)
            } else if let listener = message.listener {
                ListenerCard(platform: listener.platform, reason: listener.reason)
            } else if let connector = message.connector {
                ConnectorCard(name: connector.name, serverID: connector.serverID, entry: message.id, agent: agent)
            } else if let secret = message.secret {
                SecretCard(label: secret.label, detail: secret.detail, entry: message.id, agent: agent, provided: secret.provided)
            } else if let approval = message.approval {
                ApprovalCard(approval: approval, entry: message.id, agent: agent)
            } else if let choice = message.choice {
                // Answered once you have said anything after it, by picking or by typing.
                let asked = messages.firstIndex { $0.id == message.id } ?? 0
                ChoiceCard(choice: choice, agent: agent, answered: messages.dropFirst(asked + 1).contains { $0.fromUser })
            } else {
                // The agent's side: a quieter bubble on the left, yours brighter on the right.
                ForEach(message.boxImages, id: \.self) { BoxPicture(path: $0) }
                // Pictures the agent made or attached, drawn as pictures.
                pictures(parts.paths)
                if !parts.text.isEmpty {
                AgentBubble(text: parts.text, reactions: message.reactions,
                            react: agent.source == .grok && !message.id.hasPrefix("local-") ? { emoji in
                    GrokSource.shared.react(emoji, to: message.id, in: agent)
                } : nil)
                .padding(.top, message.reactions.isEmpty ? 0 : 12)
                }
            }
        }
    }

    /// Bold, code and links render; line breaks and lists stay as written.
    static func markdown(_ s: String) -> AttributedString {
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
        if sideWindow != nil { SidePanel.shared.close() } else { ui.collapse() }
    }
}

/// How full the session's context window is: a small ring and the percentage. It fills
/// towards red as the session nears the point where Claude Code will compact it.
private struct ContextMeter: View {
    let used: Int
    let model: String?

    private var limit: Int {
        // Long-context sessions run to a million tokens; anything already past 200k must be one.
        (model ?? "").lowercased().contains("1m") || used > 200_000 ? 1_000_000 : 200_000
    }

    var body: some View {
        let part = min(1, Double(used) / Double(limit))
        let color: Color = part > 0.85 ? Palette.red : part > 0.65 ? .white : .white.opacity(0.55)
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 2)
                Circle().trim(from: 0, to: max(0.01, part)).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 11, height: 11)
            Text("\(Int((part * 100).rounded()))%").font(.system(size: 10, weight: .medium)).monospacedDigit()
                .foregroundStyle(color)
        }
        .help("Context: \(used / 1000)k of \(limit / 1000)k tokens")
        .animation(.easeOut(duration: 0.3), value: part)
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
    @Environment(\.sideWindow) private var sideWindow
    @State private var focused = false
    /// Bumped to put the cursor in the box.
    @State private var focusAsk = 0
    /// Bumped on each send, for the button's little bounce.
    @State private var sent = 0

    private func focus() {
        focused = true
        focusAsk += 1
    }

    /// Nothing blocks a reply any more: mid-turn messages are delivered at the next step.
    private var busy: Bool { false }

    private var placeholder: String {
        if let problem = Dictation.shared.problem { return problem }
        if Dictation.shared.activeAgentID == agent.id { return "Listening…" }
        if agent.source == .grok { return "Message \(agent.name)" }
        if agent.source == .codex { return "Message Codex" }
        if agent.source != .grok, agent.status == .working, agent.pending == nil { return "Message now, it reads it at its next step" }
        if agent.pending != nil { return "Tell it what to do next" }
        return agent.waiter != nil ? "Reply to this session" : "Reply in the background"
    }

    var body: some View {
        let files = ui.attachments[agent.id] ?? []
        let empty = !ui.drafts.hasText(agent.id) && files.isEmpty
        let listening = Dictation.shared.activeAgentID == agent.id
        // Typing "/" offers your skills; click one, or press Tab for the first.
        let typed = ui.drafts.command(agent.id) ?? ""
        let offers = agent.source != .grok && typed.hasPrefix("/") && !typed.contains(" ")
            ? Array(SkillIndex.shared.matching(typed).prefix(6)) : []
        VStack(alignment: .leading, spacing: 6) {
            if let problem = ui.attachmentSaveError {
                Text(problem).font(.system(size: 11)).foregroundStyle(Palette.red)
            }
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
        if let target = ui.replyTo[agent.id] {
            // The message this reply is aimed at, with a way to drop it.
            HStack(spacing: 6) {
                Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.5))
                Text(oneLine(target.text, max: 90)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                Spacer(minLength: 0)
                Button { ui.replyTo[agent.id] = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                        .frame(width: 15, height: 15).background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(Press())
            }
            .padding(.bottom, 5)
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.1)).frame(height: 1) }
            .transition(.opacity.combined(with: .offset(y: 4)))
        }
        HStack(alignment: .bottom, spacing: 6) {
            // A real text view: it grows with what is written, up to about eight lines, then
            // scrolls smoothly. Return sends; Shift+Return starts a new line.
            DraftText(store: ui.drafts, id: agent.id, placeholder: placeholder, focusAsk: focusAsk,
                        onFocus: { focused = $0 }, onSubmit: send, onTab: {
                            guard let first = offers.first else { return false }
                            ui.drafts[agent.id] = "/\(first.id) "
                            return true
                        })
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .topLeading) {
                    if !ui.drafts.hasText(agent.id) {
                        Text(placeholder).font(.system(size: 13)).foregroundStyle(.white.opacity(0.35))
                            .lineLimit(1).allowsHitTesting(false)
                    }
                }
            EmojiButton { ui.drafts[agent.id, default: ""] += $0 }
            Button(action: chooseFiles) {
                Image(systemName: "paperclip").font(.system(size: 13)).foregroundStyle(.white.opacity(0.45))
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(Press()).help("Attach files")
            Button { Dictation.shared.toggle(for: agent.id) } label: {
                Image(systemName: listening ? "mic.fill" : "mic").font(.system(size: 13))
                    .foregroundStyle(listening ? Palette.red : .white.opacity(0.45))
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(Press()).disabled(busy)
            .help(listening ? "Stop dictating" : "Dictate a reply")
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 15)).symbolEffect(.bounce, value: sent)
                    .foregroundStyle(empty || busy ? .white.opacity(0.2) : agent.theme)
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
            (sideWindow ?? ui.controller?.panel)?.makeKey()
            focus()
        })
        .onChange(of: focused) { _, on in
            if on {
                ui.focusedAgentID = agent.id
                SkillIndex.shared.refresh()
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        DispatchQueue.main.async {
                            if let file = Attachment.from(file: url) { ui.attachments[agent.id, default: []].append(file) }
                        }
                    }
                    continue
                }
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
            DispatchQueue.main.async { focus() }
        }
        // Aiming a reply at a message puts the cursor in the box.
        .onChange(of: ui.replyTo[agent.id]?.id) { _, id in if id != nil { focus() } }
        .animation(.easeOut(duration: 0.15), value: ui.replyTo[agent.id]?.id)
    }

    /// The Mac's file chooser. The island tucks away while it is up and reopens on this chat.
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        panel.level = .popUpMenu
        // The notch stays open behind the chooser, on this chat. From a floating window, the
        // notch is left alone and the window gets the keyboard back.
        let side = sideWindow
        if side == nil { ui.heldOpen = true }
        NSApp.activate(ignoringOtherApps: true)
        let ui = ui, id = agent.id
        panel.begin { response in
            if side == nil { ui.heldOpen = false }
            if response == .OK {
                ui.attachments[id, default: []].append(contentsOf: panel.urls.compactMap { Attachment.from(file: $0) })
            }
            if let side { side.makeKey() } else { ui.show(id) }
        }
    }

    private func send() {
        let text = (ui.drafts[agent.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let files = ui.attachments[agent.id] ?? []
        guard !(text.isEmpty && files.isEmpty), !busy else { return }
        Dictation.shared.stop()
        Settings.sentFeel()
        ui.openedUnread[agent.id] = nil
        sent += 1
        ui.drafts[agent.id] = nil
        ui.attachments[agent.id] = nil
        if agent.source == .grok {
            let target = ui.replyTo[agent.id]?.id
            ui.replyTo[agent.id] = nil
            GrokSource.shared.send(agent, text: text, files: files, replyTo: target)
        } else {
            // Claude Code and Codex run on this Mac, so they can open the saved image themselves.
            let notes = files.map(\.note)
            CodingSessions.shared.reply(agent, text: ([text] + notes).filter { !$0.isEmpty }.joined(separator: "\n\n"))
        }
    }
}

/// The agent's bubble. In a Grok bot's chat, hovering it shows a small face beside it; that
/// opens a menu of reactions. Picking one leaves it on the message in Grok Bot (picking it
/// again takes it back).
private struct AgentBubble: View {
    let text: String
    var reactions: [String] = []
    let react: ((String) -> Void)?
    @State private var hovered = false
    @State private var picking = false
    @State private var over: String?
    @State private var chosen: String?
    @State private var copied = false
    @State private var overCopy = false
    @State private var overFace = false

    private static let quick = ["👍", "❤️", "😂", "🙏", "👀", "🔥", "✅"]
    private static let pop = Animation.spring(response: 0.3, dampingFraction: 0.6)

    var body: some View {
        HStack(spacing: 0) {
            MessageBody(text: text)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(alignment: .topTrailing) { ReactionBadge(emojis: reactions).offset(x: 16, y: -14) }
            // Only while the pointer is on the message: one small, dim face. Clicking it springs
            // open a tray of reactions just above.
            // Copy the whole message: a prompt to hand on, an address, a draft.
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 13, weight: copied ? .bold : .regular))
                    .foregroundStyle(copied ? Palette.green : .white.opacity(overCopy ? 0.95 : 0.6))
                    .frame(width: 30, height: 28)
                    .background(.white.opacity(overCopy || copied ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(Press(reach: 2))
            .onHover { overCopy = $0 }
            .padding(.leading, 6)
            .opacity(hovered || picking || copied ? 1 : 0)
            .help("Copy this message")
            if let react {
                ReactFace(hovered: hovered, open: $picking, react: react).padding(.leading, 4)
            }
            Spacer(minLength: 28)
        }
        // The whole row counts as "on the message", including the gap between the bubble and
        // the face, so the face does not vanish on the way over to it.
        .contentShape(Rectangle())
        .onHover { inside in
            hovered = inside
            // Wandering off closes the tray after a moment, unless the pointer comes back.
            if !inside, picking {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if !hovered, over == nil { withAnimation(.easeOut(duration: 0.15)) { picking = false } }
                }
            }
        }
        .zIndex(picking ? 5 : 0)
    }


}

/// An agent's message shortened for a banner, with its **bold**, _italic_ and `code` shown as
/// such. A marker cut in half by the shortening is dropped rather than shown as asterisks.
func bannerText(_ text: String) -> AttributedString {
    var t = text
    for marker in ["**", "__", "`"] where t.components(separatedBy: marker).count % 2 == 0 {
        if let r = t.range(of: marker, options: .backwards) { t.removeSubrange(r) }
    }
    return ChatView.markdown(t)
}

/// The way to react to any message, in every chat: a small face beside it while the pointer is
/// on the message. Clicking it springs open a few quick reactions and a "+" for all of them.
struct ReactFace: View {
    let hovered: Bool
    @Binding var open: Bool
    /// Kept for callers; the pop-up places itself.
    var opensRight = false
    let react: (String) -> Void
    @State private var over: String?
    @State private var overFace = false
    @State private var more = false

    static let quick = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: open ? "face.smiling.inverse" : "face.smiling").font(.system(size: 13))
                .foregroundStyle(.white.opacity(open || overFace ? 0.95 : 0.55))
                .frame(width: 26, height: 26)
                .background(.white.opacity(overFace || open ? 0.12 : 0.06), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(Press(reach: 2))
        .onHover { overFace = $0 }
        .opacity(hovered || open ? 1 : 0)
        .help("React")
        // A pop-up of its own, so it is never cut off at the chat's edge and every reaction in it
        // takes the click. A click anywhere else closes it.
        .popover(isPresented: $open, arrowEdge: .top) {
            VStack(spacing: 6) {
                HStack(spacing: 2) {
                    ForEach(Self.quick, id: \.self) { emoji in
                        Button { pick(emoji) } label: {
                            Text(emoji).font(.system(size: 20))
                                .scaleEffect(chosen == emoji ? 1.6 : over == emoji ? 1.25 : 1)
                                .offset(y: chosen == emoji ? -4 : 0)
                                .frame(width: 34, height: 34).contentShape(Rectangle())
                        }
                        .buttonStyle(Press())
                        .onHover { inside in withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) { over = inside ? emoji : (over == emoji ? nil : over) } }
                    }
                    Button { withAnimation(.easeOut(duration: 0.15)) { more.toggle() } } label: {
                        Image(systemName: more ? "minus" : "plus").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.primary.opacity(0.75)).frame(width: 28, height: 28)
                            .background(.primary.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(Press()).help("More reactions")
                }
                if more {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 2), count: 8), spacing: 2) {
                        ForEach(EmojiButton.common, id: \.self) { e in
                            Button { pick(e) } label: {
                                Text(e).font(.system(size: 19)).frame(width: 30, height: 30).contentShape(Rectangle())
                            }
                            .buttonStyle(Press())
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    @State private var chosen: String?

    /// The chosen emoji swells for a moment, then the pop-up closes and the reaction lands.
    private func pick(_ emoji: String) {
        Settings.sentFeel()
        withAnimation(.spring(response: 0.18, dampingFraction: 0.45)) { chosen = emoji }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            open = false
            more = false
            over = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                react(emoji)
                chosen = nil
            }
        }
    }
}

/// Slack's names for the emoji Perch offers as reactions.
enum SlackEmojiName {
    static let byEmoji: [String: String] = [
        "😀": "grinning", "😂": "joy", "🙂": "slightly_smiling_face", "😉": "wink", "😍": "heart_eyes",
        "🥲": "smiling_face_with_tear", "😅": "sweat_smile", "🤔": "thinking_face", "😎": "sunglasses",
        "🙃": "upside_down_face", "😬": "grimacing", "😴": "sleeping", "👍": "+1", "👎": "-1", "👏": "clap",
        "🙌": "raised_hands", "🙏": "pray", "💪": "muscle", "👀": "eyes", "🤝": "handshake", "👋": "wave",
        "✌️": "v", "🤞": "crossed_fingers", "🫡": "saluting_face", "❤️": "heart", "🔥": "fire", "🎉": "tada",
        "✅": "white_check_mark", "❌": "x", "⚠️": "warning", "💯": "100", "🚀": "rocket", "⭐️": "star",
        "💡": "bulb", "📌": "pushpin", "⏰": "alarm_clock", "😢": "cry", "😮": "open_mouth", "😡": "rage",
        "🤯": "exploding_head", "🥳": "partying_face", "🤣": "rolling_on_the_floor_laughing", "😇": "innocent",
        "🤷": "shrug", "🤦": "face_palm", "💀": "skull", "☕️": "coffee", "🍻": "beers",
    ]
}

/// Reactions on a message, the way Grok Bot draws them: each in a dark round badge with a
/// black ring, overlapping the corner of the bubble. Several sit in a slightly overlapping row.
private struct ReactionBadge: View {
    let emojis: [String]

    var body: some View {
        HStack(spacing: -7) {
            ForEach(Array(emojis.enumerated()), id: \.offset) { _, emoji in
                Text(emoji).font(.system(size: 14))
                    .frame(width: 28, height: 28)
                    .background(Color(white: 0.13), in: Circle())
                    .overlay(Circle().strokeBorder(.black, lineWidth: 2.5))
                    .modifier(PopIn(delay: 0))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Springs a view up from nothing a moment after it appears.
private struct PopIn: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : 0.2).opacity(shown ? 1 : 0)
            .onAppear { withAnimation(.spring(response: 0.3, dampingFraction: 0.55).delay(delay)) { shown = true } }
    }
}

/// An agent's message, with the parts plain text cannot carry drawn properly: tables as real
/// tables and headings as headings. Everything else keeps its line breaks and inline styling.
private struct MessageBody: View {
    let text: String

    private enum Block: Identifiable {
        case prose(Int, String)
        case table(Int, [String], [[String]])
        /// Quoted text (lines starting "> "), such as a tweet being discussed.
        case quote(Int, String)
        /// A fenced block (```). `writing` when it is prose (a draft post, a message to send),
        /// shown in the normal font; otherwise code, in a code font. Line breaks kept either way.
        case fenced(Int, String, writing: Bool)

        var id: Int {
            switch self {
            case .prose(let i, _), .table(let i, _, _), .quote(let i, _), .fenced(let i, _, _): return i
            }
        }
    }

    /// Whether a fenced block is writing rather than code: no language (or a text one) and few of
    /// the characters code is full of.
    private static func isWriting(_ body: String, language: String) -> Bool {
        let lang = language.lowercased()
        guard ["", "text", "txt", "plain", "plaintext", "markdown", "md", "email", "post"].contains(lang) else { return false }
        let codeChars = body.filter { "{}();=<>[]$`\\|".contains($0) }.count
        return Double(codeChars) / Double(max(1, body.count)) < 0.02
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
            // A fenced block runs to its closing fence (or the end), keeping every line as it is.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                let language = line.trimmingCharacters(in: .whitespaces).dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(String(lines[i]))
                    i += 1
                }
                i += 1
                // Code inside a list item comes indented: take off what every line shares.
                let indent = body.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .map { $0.prefix { $0 == " " }.count }.min() ?? 0
                body = body.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }
                let joined = body.joined(separator: "\n").trimmingCharacters(in: .newlines)
                if !joined.isEmpty { out.append(.fenced(out.count, joined, writing: Self.isWriting(joined, language: language))) }
                continue
            }
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
            // A run of quoted lines becomes one quote, its blank ">" lines kept as paragraph breaks.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var q = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
                    if q.hasPrefix(" ") { q = q.dropFirst() }
                    quoted.append(String(q))
                    i += 1
                }
                let joined = quoted.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { out.append(.quote(out.count, joined)) }
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
        var result = (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
        References.link(&result)
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
                case .fenced(_, let body, let writing):
                    FencedBlock(text: body, writing: writing)
                case .quote(_, let s):
                    Text(Self.inline(s)).font(.system(size: 12.5)).lineSpacing(2)
                        .foregroundStyle(.white.opacity(0.72)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 11).padding(.vertical, 2)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1.5).fill(.white.opacity(0.28)).frame(width: 3)
                        }
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

/// A fenced block in a message. Writing (a draft post, an email) reads in the normal font with
/// its paragraphs; code keeps a code font and scrolls sideways rather than wrapping. Both copy
/// exactly as written.
private struct FencedBlock: View {
    let text: String
    let writing: Bool
    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        Group {
            if writing {
                Text(text).font(.system(size: 12.5)).lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.9)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text).font(.system(size: 11, design: .monospaced)).lineSpacing(2)
                        .foregroundStyle(.white.opacity(0.85)).textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if hovered || copied {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8)).frame(width: 24, height: 22)
                        .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(Press()).help("Copy").padding(5)
            }
        }
        .onHover { hovered = $0 }
    }
}

/// Lets a message be pulled sideways with two fingers to reply to it, the way Grok Bot does.
/// A reply arrow fades in as it is pulled, and turns solid once letting go will count.
private struct SwipeToReply: ViewModifier {
    let agent: Agent
    let message: ChatMessage
    @Environment(NotchUI.self) private var ui

    func body(content: Content) -> some View {
        let x = ui.swipe?.id == message.id ? ui.swipe!.x : 0
        content
            .offset(x: x)
            .background(alignment: x >= 0 ? .leading : .trailing) {
                Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 12))
                    .foregroundStyle(.white.opacity(abs(x) > 40 ? 0.95 : 0.4))
                    .opacity(min(1, abs(x) / 30))
                    .scaleEffect(abs(x) > 40 ? 1.15 : 0.9)
                    .animation(.easeOut(duration: 0.12), value: abs(x) > 40)
                    .padding(.horizontal, 8)
            }
            .contentShape(Rectangle())
            .onHover { over in
                if over {
                    ui.hoveredMessage = (agent.id, message)
                } else if ui.hoveredMessage?.message.id == message.id {
                    ui.hoveredMessage = nil
                }
            }
    }
}

/// A picture from a bot's own computer, fetched through Grok Bot. Click to see it full size.
private struct BoxPicture: View {
    let path: String
    var maxWidth: CGFloat = 300
    @Environment(NotchUI.self) private var ui
    @Environment(\.sideWindow) private var sideWindow
    @State private var image: NSImage?
    @State private var hovered = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.white.opacity(0.06).frame(width: 220, height: 130)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .frame(maxWidth: maxWidth, maxHeight: 260, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if hovered, let image { SaveButton { saveToDownloads(image: image, name: URL(fileURLWithPath: path).lastPathComponent) } }
        }
        .onHover { hovered = $0 }
        .onTapGesture {
            guard let image else { return }
            ui.enlarge(image, name: URL(fileURLWithPath: path).lastPathComponent, side: sideWindow != nil)
        }
        .help("Enlarge")
        .task(id: path) { GrokSource.shared.boxImage(path) { image = $0 } }
    }
}

/// A bot handing its computer over for a step only the user can do, like scanning a QR code
/// to sign in. Taking over happens in Grok Bot, which shows the live screen.
private struct HandoffCard: View {
    let instruction: String
    let resolution: String?
    let agent: Agent
    let picture: String?
    @Environment(NotchUI.self) private var ui

    private var status: String? {
        switch resolution {
        case nil, "": return nil
        case "handed_back", "done", "completed": return "Done"
        case "skipped": return "Skipped"
        default: return resolution!.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "desktopcomputer").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    Text("Computer").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    if let status {
                        Text(status).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.green)
                            .padding(.horizontal, 7).padding(.vertical, 2.5).background(Palette.green.opacity(0.15), in: Capsule())
                    }
                }
                Text(instruction).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                if status == nil {
                    if let picture { BoxPicture(path: picture, maxWidth: .infinity) }
                    HStack(spacing: 8) {
                        Button("Take over in Grok Bot") {
                            GrokSource.shared.open(agent)
                            ui.collapse()
                        }
                        .buttonStyle(ChipButton(fill: .white))
                        Text("Signing in happens on \(agent.name)'s computer").font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            .padding(11)
            .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .opacity(status == nil ? 1 : 0.7)
            Spacer(minLength: 28)
        }
    }
}

/// A bot asking for a key or password. It is typed into a hidden field and handed straight
/// to the host with the same call Grok Bot's own field uses; the bot never sees it and Perch
/// keeps no copy. Grok Bot is still there as a fallback.
/// A secure form from a bot: what it is for, which website it goes into, and the fields.
/// Sending hands the answers to Grok Bot, which types them into the page itself; they never
/// pass through the chat, and Perch keeps nothing once they are sent.
private struct FormCard: View {
    let form: GrokForm
    let entry: String
    let agent: Agent
    @Environment(NotchUI.self) private var ui
    @Environment(\.sideWindow) private var sideWindow
    @State private var values: [String: String] = [:]
    @State private var state: String?
    @FocusState private var focus: String?

    private var finished: String? {
        if let r = form.resolution {
            switch r {
            case "dismissed", "escalated": return "Not sent"
            case "fill_failed":
                return form.missed.isEmpty ? "Sent, but some of it did not go in" : "Sent. Did not go in: " + form.missed.joined(separator: ", ")
            default: return "Sent securely"
            }
        }
        switch state {
        case "sent": return "Sent securely"
        case "dismissed": return "Not sent"
        default: return nil
        }
    }

    private var ready: Bool {
        form.fields.allSatisfy { f in !f.required || f.type == "checkbox" || !(value(f).trimmingCharacters(in: .whitespaces).isEmpty) }
    }

    private func value(_ f: GrokForm.Field) -> String { values[f.id] ?? f.defaultValue }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: finished == nil ? "lock.fill" : "checkmark.seal.fill").font(.system(size: 11))
                        .foregroundStyle(finished == nil ? .white.opacity(0.65) : Palette.green)
                    Text(form.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let finished {
                    Text(finished).font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(form.resolution == "fill_failed" ? .white.opacity(0.7) : Palette.green)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if !form.instruction.isEmpty {
                        Text(form.instruction).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(form.fields, id: \.id) { field in fieldView(field) }
                    HStack(spacing: 8) {
                        Button(state == "sending" ? "Sending…" : "Send securely", action: send)
                            .buttonStyle(ChipButton(fill: ready ? .white : nil)).disabled(!ready || state == "sending")
                        Button("Not now", action: dismiss).buttonStyle(LinkButton())
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 5) {
                        Image(systemName: "lock.shield").font(.system(size: 10))
                        Text(state == "failed" ? "Grok Bot did not take it from here." :
                                (form.domain.isEmpty ? "Goes straight into the page, not the chat" : "Goes straight into \(form.domain), not the chat"))
                        if state == "failed" {
                            Button("Use Grok Bot") { GrokSource.shared.open(agent); ui.collapse() }.buttonStyle(LinkButton())
                        }
                    }
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(11)
            .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .opacity(finished != nil ? 0.75 : 1)
            Spacer(minLength: 28)
        }
        .animation(.easeOut(duration: 0.2), value: finished)
    }

    @ViewBuilder private func fieldView(_ f: GrokForm.Field) -> some View {
        let binding = Binding(get: { value(f) }, set: { values[f.id] = $0 })
        VStack(alignment: .leading, spacing: 3) {
            if f.type != "checkbox" {
                Text(f.label + (f.required ? "" : " (optional)")).font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            switch f.type {
            case "checkbox":
                Toggle(f.label, isOn: Binding(get: { value(f) == "true" }, set: { values[f.id] = $0 ? "true" : "false" }))
                    .toggleStyle(.checkbox).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.85))
            case "select":
                Picker("", selection: binding) {
                    ForEach(f.options, id: \.value) { o in Text(o.label).tag(o.value) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            default:
                Group {
                    if f.secret {
                        SecureField("", text: binding)
                    } else {
                        TextField("", text: binding)
                    }
                }
                .textFieldStyle(.plain).font(.system(size: 12.5)).focused($focus, equals: f.id)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white.opacity(focus == f.id ? 0.35 : 0.15), lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture {
                    (sideWindow ?? ui.controller?.panel)?.makeKey()
                    focus = f.id
                }
                .onSubmit { if ready { send() } }
            }
        }
    }

    private func send() {
        guard ready, state != "sending" else { return }
        var answers: [String: String] = [:]
        for f in form.fields { answers[f.id] = value(f) }
        state = "sending"
        GrokSource.shared.submitForm(answers, entry: entry, in: agent) { ok in
            withAnimation { state = ok ? "sent" : "failed" }
            // Nothing typed is kept once it has gone.
            if ok { values = [:] }
        }
    }

    private func dismiss() {
        GrokSource.shared.dismissForm(entry: entry, in: agent) { ok in
            withAnimation { state = ok ? "dismissed" : "failed" }
        }
    }
}

/// A bot asking for an app (Slack, say) to be linked so its trigger can fire. Connecting opens
/// that app's own approval page in the browser; the card turns green once it is linked.
private struct ListenerCard: View {
    let platform: String
    let reason: String
    @State private var connected: Bool?
    @State private var opening = false
    @State private var watching = false

    private var name: String {
        switch platform {
        case "github": return "GitHub"
        case "gitlab": return "GitLab"
        case "azure-devops": return "Azure DevOps"
        default: return platform.prefix(1).uppercased() + platform.dropFirst()
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: connected == true ? "checkmark.circle.fill" : "bolt.horizontal.circle")
                        .font(.system(size: 13)).foregroundStyle(connected == true ? Palette.green : .white.opacity(0.7))
                    Text(connected == true ? "\(name) connected" : "Connect \(name)")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                }
                if connected != true {
                    Text(reason.isEmpty ? "So this routine can fire." : reason.prefix(1).uppercased() + reason.dropFirst() + ".")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(opening ? "Opening…" : "Connect \(name)", action: connect)
                            .buttonStyle(ChipButton(fill: .white)).disabled(opening)
                        if watching {
                            Text("Approve it in your browser, this updates by itself")
                                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
            }
            .padding(11)
            .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .opacity(connected == true ? 0.75 : 1)
            Spacer(minLength: 28)
        }
        .animation(.easeOut(duration: 0.2), value: connected)
        .task(id: platform) { check() }
    }

    private func check() {
        GrokSource.shared.listenerConnected(platform) { connected = $0 }
    }

    private func connect() {
        opening = true
        GrokSource.shared.connectListener(platform) { ok in
            opening = false
            guard ok else { return NSSound.beep() }
            watching = true
            // Look again every few seconds for a few minutes while they approve it.
            for i in 1...60 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 3) {
                    if connected != true { check() }
                }
            }
        }
    }
}

/// A bot asking for one of Grok Bot's connectors (DigitalOcean, say) to be signed in to. Connect
/// opens that service's own sign-in page; the card turns green once Grok Bot reports it linked.
private struct ConnectorCard: View {
    let name: String
    let serverID: String
    let entry: String
    let agent: Agent
    @State private var connected: Bool?
    @State private var opening = false
    @State private var note: String?
    @State private var watching = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: connected == true ? "checkmark.circle.fill" : "powerplug")
                        .font(.system(size: 13)).foregroundStyle(connected == true ? Palette.green : .white.opacity(0.7))
                    Text(connected == true ? "\(name) connected" : "Connect \(name)")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                }
                if connected != true {
                    Text("\(agent.name) needs \(name) signed in to carry on.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(opening ? "Opening…" : "Connect \(name)", action: connect)
                            .buttonStyle(ChipButton(fill: .white)).disabled(opening)
                        if let note {
                            Text(note).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(11)
            .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .opacity(connected == true ? 0.75 : 1)
            Spacer(minLength: 28)
        }
        .animation(.easeOut(duration: 0.2), value: connected)
        .task(id: serverID) { check() }
    }

    private func check() {
        GrokSource.shared.connectorReady(serverID) { connected = $0 }
    }

    private func connect() {
        opening = true
        note = nil
        GrokSource.shared.connectConnector(serverID, card: entry, in: agent) { result in
            opening = false
            switch result {
            case .opened:
                note = "Approve it in your browser, this updates by itself"
                guard !watching else { return }
                watching = true
                for i in 1...60 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 3) { if connected != true { check() } }
                }
            case .already:
                connected = true
            case .busy(let minutes):
                note = "\(name) is turning sign-ins away for now. Try again in \(minutes == 1 ? "a minute" : "\(minutes) minutes")."
            case .refused(let reason):
                note = reason
                NSSound.beep()
            }
        }
    }
}

private struct SecretCard: View {
    let label: String
    let detail: String
    let entry: String
    let agent: Agent
    /// Grok Bot's own record says it has been given, from here or from the app.
    var provided = false
    @Environment(NotchUI.self) private var ui
    @Environment(\.sideWindow) private var sideWindow
    @State private var value = ""
    @State private var saved: String?
    private var state: String? { provided ? "saved" : saved }
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: state == "saved" ? "checkmark.seal.fill" : "key.fill").font(.system(size: 11))
                        .foregroundStyle(state == "saved" ? Palette.green : .white.opacity(0.6))
                    Text(label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                }
                if state == "saved" {
                    Text("Saved securely").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.green)
                } else {
                    HStack(spacing: 7) {
                        SecureField("Paste it here", text: $value)
                            .textFieldStyle(.plain).font(.system(size: 12.5)).focused($focused)
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white.opacity(focused ? 0.35 : 0.15), lineWidth: 1))
                            .onSubmit(save)
                        Button(state == "saving" ? "Saving…" : "Save securely", action: save)
                            .buttonStyle(ChipButton(fill: value.isEmpty ? nil : .white))
                            .disabled(value.isEmpty || state == "saving")
                    }
                    HStack(spacing: 5) {
                        Image(systemName: "lock.shield").font(.system(size: 10))
                        Text(state == "failed" ? "Grok Bot did not take it from here." : "Goes straight to Grok Bot's secure store")
                        if state == "failed" {
                            Button("Use Grok Bot") { GrokSource.shared.open(agent); ui.collapse() }.buttonStyle(LinkButton())
                        }
                    }
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(11)
            .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .opacity(state == "saved" ? 0.7 : 1)
            Spacer(minLength: 28)
        }
        .animation(.easeOut(duration: 0.2), value: state)
        .onTapGesture {
            guard state != "saved" else { return }
            (sideWindow ?? ui.controller?.panel)?.makeKey()
            focused = true
        }
    }

    private func save() {
        let secret = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty, state != "saving" else { return }
        saved = "saving"
        GrokSource.shared.submitSecret(secret, entry: entry, in: agent) { ok in
            withAnimation(.easeOut(duration: 0.2)) { saved = ok ? "saved" : "failed" }
            if ok {
                value = ""
                GrokSource.shared.loadThread(agent)
            }
        }
    }
}

/// A Grok bot asking before it acts. Allow once, always allow, or deny, right here; once
/// answered it folds down to a line saying what was decided.
private struct ApprovalCard: View {
    let approval: GrokApproval
    let entry: String
    let agent: Agent
    @State private var showCommand = false
    @State private var sending: String?
    @State private var failed = false

    private var settled: String? { approval.status ?? sending }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Allow \(agent.name) to use \(approval.tool)?").font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    badge
                }
                if !approval.summary.isEmpty {
                    Text(approval.summary).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !approval.command.isEmpty {
                    Button { withAnimation(.easeOut(duration: 0.18)) { showCommand.toggle() } } label: {
                        HStack(spacing: 4) {
                            Text(showCommand ? "Hide the full request" : "View the full request")
                            Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .semibold))
                                .rotationEffect(.degrees(showCommand ? 90 : 0))
                        }
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(Press(reach: 4))
                    if showCommand {
                        Text(approval.command).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.65))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
                if settled == nil {
                    HStack(spacing: 6) {
                        Button("Allow once") { answer("approved") }.buttonStyle(ChipButton(fill: .white))
                        Button("Always") { answer("always") }.buttonStyle(ChipButton())
                        Spacer()
                        Button("Deny") { answer("denied") }.buttonStyle(ChipButton())
                    }
                }
                if failed {
                    HStack(spacing: 6) {
                        Text("Grok Bot did not take that from here.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                        Button("Answer in Grok Bot") { GrokSource.shared.open(agent) }.buttonStyle(LinkButton())
                    }
                }
            }
            .padding(11)
            .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .opacity(settled == nil ? 1 : 0.75)
            Spacer(minLength: 28)
        }
    }

    @ViewBuilder private var badge: some View {
        let (text, color): (String, Color) = switch settled {
        case "approved": ("Allowed", Palette.green)
        case "always": ("Always allowed", Palette.green)
        case "denied": ("Denied", .white.opacity(0.5))
        default: ("Needs approval", .white)
        }
        Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func answer(_ resolution: String) {
        failed = false
        withAnimation(.easeOut(duration: 0.18)) { sending = resolution }
        GrokSource.shared.resolve(approval, entry: entry, in: agent, as: resolution) { ok in
            if !ok { withAnimation { sending = nil; failed = true } }
        }
    }
}

/// A question from an agent with options to pick from. Picking one sends it as your reply;
/// the reply box underneath is there for an answer of your own.
private struct ChoiceCard: View {
    let choice: ChoiceWidget
    let agent: Agent
    let answered: Bool
    @State private var hovered: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(choice.prompt).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    ForEach(Array(choice.options.enumerated()), id: \.offset) { index, option in
                        if index > 0 { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
                        Button { GrokSource.shared.send(agent, text: option.value) } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Text(String(UnicodeScalar(UInt8(65 + min(index, 25)))))
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .frame(width: 18, height: 18)
                                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
                                    if !option.detail.isEmpty {
                                        Text(option.detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(.white.opacity(hovered == option.label && !answered ? 0.07 : 0))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(Press(reach: 0))
                        .onHover { hovered = $0 ? option.label : (hovered == option.label ? nil : hovered) }
                    }
                }
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .disabled(answered)
                Text(answered ? "Answered" : "Pick one, or type your own answer below.")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.35))
            }
            .padding(11)
            .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .opacity(answered ? 0.6 : 1)
            Spacer(minLength: 28)
        }
    }
}

/// A file an agent attached. Text files open right here, formatted; anything else (a Word
/// document, a spreadsheet) is saved to Downloads and opened in its own app.
private struct FileCard: View {
    let name: String
    let path: String
    let agent: Agent
    var messageID = ""
    @Environment(NotchUI.self) private var ui
    @State private var expanded = false
    @State private var text: String?
    @State private var failed = false
    @State private var copied = false
    @State private var fetching = false
    @State private var saved: URL?

    /// Files that are not text, so reading them here would only fail.
    private static let documents: Set<String> = ["docx", "doc", "xlsx", "xls", "pptx", "ppt", "pdf", "pages", "numbers",
                                                 "key", "zip", "odt", "ods", "rtf", "mp3", "mp4", "mov", "wav"]
    private var isDocument: Bool { Self.documents.contains((name as NSString).pathExtension.lowercased()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Spacer()
                if isDocument {
                    Text(fetching ? "Downloading…" : failed ? "Could not download" : "Open")
                        .font(.system(size: 11)).foregroundStyle(failed ? Palette.red : .white.opacity(0.5))
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                } else {
                    Text(expanded ? "Hide" : "Read").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { isDocument ? openFile() : toggle() }

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
                    Text("This one is not text, so it opens in its own app.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
                    HStack(spacing: 6) {
                        Button(fetching ? "Downloading…" : "Open") { openFile() }
                            .buttonStyle(ChipButton()).disabled(fetching)
                        Button("Open Grok Bot") {
                            GrokSource.shared.open(agent)
                            ui.collapse()
                        }
                        .buttonStyle(ChipButton())
                    }
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

    /// Downloads the file (once) and opens it in whatever app opens that kind of file.
    private func openFile() {
        if let saved, FileManager.default.fileExists(atPath: saved.path) { NSWorkspace.shared.open(saved); return }
        guard !fetching else { return }
        fetching = true
        fetch(tries: 3)
    }

    /// A box that was asleep, or the bridge restarting with Perch, fails the first try; the
    /// file is fine a few seconds later, so it is asked for again before saying it failed.
    private func fetch(tries: Int) {
        GrokSource.shared.download(path, name: name) { url in
            if url == nil, tries > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { fetch(tries: tries - 1) }
                return
            }
            fetching = false
            guard let url else { failed = true; return }
            failed = false
            saved = url
            NSWorkspace.shared.open(url)
        }
    }

    private func toggle() {
        expanded.toggle()
        guard expanded else { return }
        // Start reading from the top of the file: the card moves up to the top of the chat,
        // now and again once the text has arrived and the card has its full height.
        ui.bringToTop(messageID)
        guard text == nil, !failed else { return }
        GrokSource.shared.readAttachment(path) { loaded in
            if let loaded { text = loaded } else { failed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { ui.bringToTop(messageID) }
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
    @State private var sending: String?
    @State private var expanded = false

    private var sent: Bool { draft.sendState == "sent" }
    /// Sent and replaced drafts fold away; only a live draft needs reading in full.
    private var settled: Bool { sent || draft.superseded || draft.sendState != nil }

    private var label: String {
        let noun = draft.noun.prefix(1).uppercased() + draft.noun.dropFirst()
        if sent { return "\(noun) sent" }
        if draft.superseded { return "Earlier draft, replaced" }
        if let state = draft.sendState { return "\(noun) \(state)" }
        return "Draft \(draft.noun), not sent"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // What the bot said about it, as an ordinary message above the email.
            if !draft.intro.isEmpty {
                Text(ChatView.markdown(draft.intro)).font(.system(size: 12.5)).lineSpacing(2)
                    .foregroundStyle(.white.opacity(0.9)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: the state, then who it goes to and the subject, as an email client shows them.
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Image(systemName: sent ? "checkmark.circle.fill" : draft.noun == "email" ? "envelope.fill" : "bubble.left.fill")
                        .font(.system(size: 10))
                    Text(label).font(.system(size: 10.5, weight: .semibold))
                    Spacer()
                    if settled {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .foregroundStyle(sent ? Palette.green : .white.opacity(0.5))
                if !draft.to.isEmpty { recipients("To", draft.to) }
                if !draft.cc.isEmpty && (!settled || expanded) { recipients("Cc", draft.cc) }
                if !draft.subject.isEmpty {
                    Text(draft.subject).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white.opacity(settled ? 0.7 : 1))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            if !settled || expanded {
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                VStack(alignment: .leading, spacing: 10) {
                    Text(draft.body).font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(.white.opacity(0.88))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if !draft.attachments.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(draft.attachments, id: \.self) { name in
                                HStack(spacing: 5) {
                                    Image(systemName: "paperclip").font(.system(size: 10, weight: .semibold))
                                    Text(name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                                }
                                .foregroundStyle(.white.opacity(0.75))
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(.white.opacity(0.08), in: Capsule())
                            }
                        }
                    }
                }
                .padding(12)
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                HStack(spacing: 6) {
                    if let link = draft.link, !settled {
                        Button {
                            NSWorkspace.shared.open(link)
                            ui.collapse()
                        } label: {
                            Label(draft.linkTitle.isEmpty ? "Open the draft" : draft.linkTitle, systemImage: "arrow.up.forward")
                                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.black)
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(.white, in: Capsule())
                        }
                        .buttonStyle(Press())
                    } else if !settled && !draft.grokPayload.isEmpty {
                        // Sends it from here, as Grok Bot's own Send button does.
                        Button {
                            guard sending == nil else { return }
                            sending = "sending"
                            Settings.sentFeel()
                            GrokSource.shared.sendDraft(draft, in: agent) { ok in sending = ok ? "sent" : "failed" }
                        } label: {
                            Label(sending == "sent" ? "Sent" : sending == "sending" ? "Sending…" : sending == "failed" ? "Try again" : "Send",
                                  systemImage: sending == "sent" ? "checkmark" : "paperplane.fill")
                                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.black)
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(sending == "failed" ? Palette.red : .white, in: Capsule())
                        }
                        .buttonStyle(Press()).disabled(sending == "sending" || sending == "sent")
                        Button("Open in Grok Bot") {
                            GrokSource.shared.open(agent)
                            ui.collapse()
                        }
                        .buttonStyle(ChipButton())
                    } else if !settled {
                        Button("Send in Grok Bot") {
                            GrokSource.shared.open(agent)
                            ui.collapse()
                        }
                        .buttonStyle(ChipButton())
                    }
                    Button(copied ? "Copied" : "Copy text") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draft.body, forType: .string)
                        copied = true
                    }
                    .buttonStyle(ChipButton())
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: settled ? 0.1 : 0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { if settled { expanded.toggle() } }
    }

    private func recipients(_ label: String, _ people: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).frame(width: 22, alignment: .leading)
            Text(people.joined(separator: ", ")).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
        }
    }
}

// MARK: Things waiting on the user

private struct PendingCard: View {
    let agent: Agent
    @State private var picks: [UUID: Set<String>] = [:]
    @State private var written: [UUID: String] = [:]
    /// The question on screen, when there are several.
    @State private var step = 0

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
        let at = min(step, max(0, questions.count - 1))
        return VStack(alignment: .leading, spacing: 9) {
            if questions.count > 1 {
                // Where you are: a tab per question, ticked once answered.
                HStack(spacing: 4) {
                    ForEach(Array(questions.enumerated()), id: \.element.id) { i, q in
                        let done = answered(q)
                        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) { step = i } } label: {
                            HStack(spacing: 4) {
                                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 9.5)).foregroundStyle(done ? agent.color : .white.opacity(0.35))
                                Text(q.header.isEmpty ? "Question \(i + 1)" : q.header).lineLimit(1)
                            }
                            .font(.system(size: 10.5, weight: i == at ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(i == at ? 0.95 : 0.55))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.white.opacity(i == at ? 0.12 : 0), in: Capsule())
                        }
                        .buttonStyle(Press())
                    }
                    Spacer(minLength: 0)
                    Text("\(at + 1) of \(questions.count)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }
            }
            if questions.indices.contains(at) {
                question(questions[at], in: questions)
                    .id(questions[at].id)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 18)), removal: .opacity))
            }
            if let error = agent.codexQuestionError {
                Text(error).font(.system(size: 11)).foregroundStyle(Palette.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if at > 0 {
                    Button("Back") { withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) { step = at - 1 } }
                        .buttonStyle(LinkButton())
                }
                Button("Answer in the app") { CodingSessions.shared.dismiss(agent) }.buttonStyle(LinkButton())
                Spacer()
                if at < questions.count - 1 {
                    Button("Next") { withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) { step = at + 1 } }
                        .buttonStyle(ChipButton(fill: answered(questions[at]) ? agent.color : nil))
                        .disabled(!answered(questions[at]))
                } else if questions.count > 1 || questions.contains(where: \.multiSelect) || !(written[questions[at].id] ?? "").isEmpty {
                    Button(agent.sending ? "Sending…" : "Send answers") { submit(questions) }
                        .buttonStyle(ChipButton(fill: ready(questions) ? Palette.green : nil))
                        .disabled(!ready(questions) || agent.sending)
                }
            }
        }
        .onChange(of: questions.map(\.id)) { step = 0 }
    }

    /// One question: what it asks, its options (with what each means), and room for your own.
    private func question(_ q: Question, in questions: [Question]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(q.text).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 2)
            if q.multiSelect {
                Text("Pick any that apply").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
            }
            ForEach(Array(q.options.enumerated()), id: \.offset) { i, option in
                QuestionOption(label: option, detail: q.descriptions.indices.contains(i) ? q.descriptions[i] : "",
                               multi: q.multiSelect, on: picks[q.id]?.contains(option) ?? false, tint: agent.color) {
                    pick(option, for: q, in: questions)
                }
            }
            // Your own answer, as "Other" in the app.
            HStack(spacing: 7) {
                Image(systemName: "pencil").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4)).frame(width: 14)
                TextField(q.options.isEmpty ? "Your answer" : "Something else…", text: Binding(
                    get: { written[q.id] ?? "" },
                    set: { written[q.id] = $0; if !$0.isEmpty { picks[q.id] = nil } }
                ))
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(.white)
                .onSubmit { advance(from: q, in: questions) }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke((written[q.id] ?? "").isEmpty ? .white.opacity(0.08) : agent.color.opacity(0.7), lineWidth: 1))
        }
    }

    private func answered(_ q: Question) -> Bool {
        !(written[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(picks[q.id] ?? []).isEmpty
    }

    /// On to the next unanswered question, or send once they are all answered.
    private func advance(from q: Question, in questions: [Question]) {
        guard answered(q) else { return }
        if let i = questions.firstIndex(where: { $0.id == q.id }), i < questions.count - 1 {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) { step = i + 1 }
        } else if ready(questions) {
            submit(questions)
        }
    }

    private func pick(_ option: String, for q: Question, in questions: [Question]) {
        guard !agent.sending else { return }
        written[q.id] = nil
        if q.multiSelect {
            var set = picks[q.id] ?? []
            if set.contains(option) { set.remove(option) } else { set.insert(option) }
            picks[q.id] = set
        } else {
            picks[q.id] = [option]
            // One question: that's the answer. Several: on to the next, a beat later so the
            // choice is seen landing.
            if questions.count == 1 { return submit(questions) }
            if let i = questions.firstIndex(where: { $0.id == q.id }), i < questions.count - 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) { step = i + 1 }
                }
            }
        }
    }

    private func ready(_ questions: [Question]) -> Bool {
        questions.allSatisfy { !(written[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(picks[$0.id] ?? []).isEmpty }
    }

    private func submit(_ questions: [Question]) {
        guard ready(questions), !agent.sending else { return }
        var answers: [String: String] = [:]
        for q in questions {
            let text = (written[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            answers[q.text] = text.isEmpty ? q.options.filter { picks[q.id]?.contains($0) ?? false }.joined(separator: ", ") : text
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
            // No countdown bar: a chat now waits up to a day, and the bar's smooth shrinking kept
            // SwiftUI laying out the whole open notch many times a second to move it a pixel.
            ReplyField(agent: agent)
        }
    }
}

// MARK: Chrome

private final class FooterPreferences: ObservableObject {
    @Published var sounds = Settings.sounds
    @Published var soundName = Settings.soundName
    @Published var replyWindow = Settings.replyWindow
    @Published var loginItem = false
    @Published var routesLinks = false

    private var checkedAt = Date.distantPast

    /// Off the main thread: both ask macOS and wait for its answer, and this runs as the island
    /// opens, where waiting froze the first frames of the animation.
    func refreshSystemStatus() {
        // Neither changes often, so a burst of opens asks once.
        guard Date().timeIntervalSince(checkedAt) > 300 else { return }
        checkedAt = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let login = SMAppService.mainApp.status == .enabled, links = LinkRouter.isDefault
            DispatchQueue.main.async {
                guard let self else { return }
                if self.loginItem != login { self.loginItem = login }
                if self.routesLinks != links { self.routesLinks = links }
            }
        }
    }
}

private struct Footer: View {
    @Environment(AgentStore.self) private var store
    @Environment(NotchUI.self) private var ui
    @StateObject private var preferences = FooterPreferences()

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
                // Bots hidden here never notify or sit in the notch, but stay findable in search.
                Menu("Hidden from Perch") {
                    ForEach(store.grokBots) { bot in
                        Toggle(bot.name, isOn: Binding(
                            get: { GrokSource.hidden.contains(bot.sessionID) },
                            set: { on in
                                if on { GrokSource.shared.hide(bot) } else { GrokSource.hidden.remove(bot.sessionID) }
                            }))
                    }
                }
                Toggle("Launch at login", isOn: Binding(get: { preferences.loginItem }, set: setLoginItem))
                Toggle("Keyboard cleaning mode", isOn: Binding(get: { KeyboardLock.shared.locked },
                                                               set: { _ in KeyboardLock.shared.toggle() }))
                Divider()
                switch WhatsAppSource.shared.state {
                case .ready:
                    Button("Disconnect WhatsApp") { WhatsAppSource.shared.disconnect() }
                default:
                    Button("Connect WhatsApp…") {
                        WhatsAppSource.shared.connect()
                        ui.showingWhatsAppLink = true
                    }
                }
                Divider()
                Button(preferences.routesLinks ? "Perch is choosing where links open" : "Let Perch choose where links open…") {
                    LinkRouter.makeDefault()
                }
                .disabled(preferences.routesLinks)
                Button("Forget learned link choices (\(LinkRouter.shared.settledCount))") { LinkRouter.shared.forgetEverything() }
                Divider()
                Toggle("Sounds", isOn: $preferences.sounds)
                Picker("Notification sound", selection: $preferences.soundName) {
                    ForEach(Settings.soundChoices, id: \.self) { Text($0).tag($0) }
                }
                Picker("Wait for a reply when a session finishes", selection: $preferences.replyWindow) {
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
        .onChange(of: preferences.sounds) { _, on in Settings.sounds = on }
        .onChange(of: preferences.soundName) { _, name in
            Settings.soundName = name
            // Hear it as you pick it.
            Settings.playSound()
        }
        .onChange(of: preferences.replyWindow) { _, seconds in Settings.replyWindow = seconds }
        // ServiceManagement is a synchronous cross-process query. Read it when this
        // view appears, not each time SwiftUI recreates Footer during an update.
        .onAppear { preferences.refreshSystemStatus() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in
            // Settings changed elsewhere become visible on the next visit to Perch.
            if NSApp.isActive { preferences.refreshSystemStatus() }
        }
    }

    private func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            preferences.loginItem = on
        } catch {
            NSLog("Perch: login item change failed: \(error)")
            preferences.loginItem = SMAppService.mainApp.status == .enabled
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
        PressBody(configuration: configuration, reach: reach)
    }
}

/// Reacts the instant the pointer arrives and the moment it presses: a brighter hover, a quick
/// dip on press, and a snappy spring back.
private struct PressBody: View {
    let configuration: ButtonStyleConfiguration
    let reach: CGFloat
    @State private var hovered = false

    var body: some View {
        configuration.label
            .brightness(configuration.isPressed ? 0.25 : hovered ? 0.15 : 0)
            .reach(reach, reach)
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.05) : .spring(response: 0.18, dampingFraction: 0.6),
                       value: configuration.isPressed)
            .animation(.easeOut(duration: 0.08), value: hovered)
            .onHover { hovered = $0 }
    }
}

/// Catches a double-click on empty space behind other views, without slowing their own clicks.
struct DoubleClick: NSViewRepresentable {
    let action: () -> Void

    final class Catcher: NSView {
        var action: (() -> Void)?
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { action?() } else { super.mouseDown(with: event) }
        }
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.action = action
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) { view.action = action }
}

extension View {
    /// Makes the view clickable this far beyond its edges without moving anything around it.
    func reach(_ x: CGFloat, _ y: CGFloat) -> some View {
        padding(.horizontal, x).padding(.vertical, y).contentShape(Rectangle())
            .padding(.horizontal, -x).padding(.vertical, -y)
    }
}

extension Agent {
    /// The colour of a chat with this agent: Claude's orange, Codex's blue-violet, white for
    /// Grok bots. Your bubbles and the send button both take it.
    var theme: Color {
        switch source {
        case .claude: return Color(red: 0.80, green: 0.42, blue: 0.29)
        case .codex: return Color(red: 0.40, green: 0.36, blue: 0.93)
        case .grok: return Color(white: 0.96)
        }
    }
}

// MARK: Clips

/// Takes whatever was dropped onto the shelf: files, pictures with no file of their own, and
/// files that are only promised (a screen recording's preview, a photo from Photos). Anything
/// that lives in a temporary place is copied onto the shelf at once, before its source deletes it.
private func shelve(_ providers: [NSItemProvider]) {
    for provider in providers {
        if provider.hasItemConformingToTypeIdentifier("public.file-url") {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                let temporary = url.path.hasPrefix("/private/var/folders") || url.path.hasPrefix("/var/folders")
                    || url.path.hasPrefix("/tmp") || url.path.hasPrefix("/private/tmp") || url.path.contains("/TemporaryItems/")
                if temporary {
                    // Copied right here, while the file still exists.
                    let staged = FileManager.default.temporaryDirectory.appendingPathComponent("perch-shelf-\(UUID().uuidString)")
                    try? FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
                    let copy = staged.appendingPathComponent(url.lastPathComponent)
                    guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { return }
                    DispatchQueue.main.async { Clips.shared.keep(copyOf: copy); try? FileManager.default.removeItem(at: staged) }
                } else {
                    DispatchQueue.main.async { Clips.shared.hold([url]) }
                }
            }
            continue
        }
        // A promised file: ask for it as a real file and keep a copy before it is cleaned up.
        let type = provider.registeredTypeIdentifiers.first { id in
            UTType(id).map { $0.conforms(to: .data) || $0.conforms(to: .movie) || $0.conforms(to: .image) } ?? false
        }
        if let type {
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { return }
                let staged = FileManager.default.temporaryDirectory.appendingPathComponent("perch-shelf-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
                let name = provider.suggestedName.map { n -> String in
                    (n as NSString).pathExtension.isEmpty ? n + "." + url.pathExtension : n
                } ?? url.lastPathComponent
                let copy = staged.appendingPathComponent(name)
                guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { return }
                DispatchQueue.main.async { Clips.shared.keep(copyOf: copy, named: name); try? FileManager.default.removeItem(at: staged) }
            }
        } else if provider.hasItemConformingToTypeIdentifier("public.image") {
            _ = provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                guard let data, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async { Clips.shared.hold(image) }
            }
        }
    }
}

/// The clipboard, on its shortcut only: a small panel of what was copied recently, newest
/// first. Type to filter, arrows to move, Return (or a click) pastes into the app in use.
private struct ClipboardPanel: View {
    @Environment(NotchUI.self) private var ui
    @State private var filter = ""
    @FocusState private var focused: Bool

    private var clips: [Clip] {
        let all = Clips.shared.history
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? all : all.filter { ($0.text ?? "picture image").lowercased().contains(q) }
    }

    var body: some View {
        let clips = clips
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if ui.clipsInline {
                    Button { ui.closeClips() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6)).frame(width: 18, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(Press()).help("Back to the chat (Esc)")
                }
                Text("Clipboard").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                Text(ui.clipsInline && ui.selectedID != nil ? "goes into your reply" : "pastes where you were")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.35))
                Spacer()
                if !ui.clipsInline {
                    // The rest of Perch, one click away.
                    Button { ui.clipsToFull() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 10))
                            Text("Chats").font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(Press())
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                TextField("Filter", text: $filter)
                    .textFieldStyle(.plain).font(.system(size: 12.5)).focused($focused)
                    .onKeyPress(.downArrow) {
                        ui.clipIndex = min(ui.clipIndex + 1, max(0, clips.count - 1))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        ui.clipIndex = max(ui.clipIndex - 1, 0)
                        return .handled
                    }
                    .onSubmit { if clips.indices.contains(ui.clipIndex) { Clips.shared.paste(clips[ui.clipIndex]) } }
                Text("↑ ↓  Return  Esc").font(.system(size: 10)).foregroundStyle(.white.opacity(0.28))
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                            ClipRow(clip: clip, selected: index == ui.clipIndex).id(clip.id)
                                .onHover { if $0 { ui.clipIndex = index } }
                        }
                        if clips.isEmpty {
                            Text(filter.isEmpty ? "Things you copy will collect here." : "Nothing matches.")
                                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 6)
                        }
                    }
                }
                // Room for several, with the selected one opened out; the rest scroll.
                .frame(height: ui.clipsInline ? 360 : min(CGFloat(max(clips.count, 1)) * 35 + 60, 300))
                .onChange(of: ui.clipIndex) { _, i in
                    if clips.indices.contains(i) { proxy.scrollTo(clips[i].id) }
                }
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: ui.clipIndex)
        .onChange(of: filter) { ui.clipIndex = 0 }
        .onAppear {
            ui.controller?.panel.makeKey()
            DispatchQueue.main.async { focused = true }
        }
    }
}

/// The shelf. It drops down by itself while a file is being dragged, as somewhere to put it,
/// and shows what is being held. Drag a file back out to use it.
private struct ShelfPanel: View {
    @Environment(NotchUI.self) private var ui
    @State private var dropping = false
    @State private var attaching = false

    /// The chat a dragged picture would go to: the one open last, else the pinned bot.
    private var chat: Agent? {
        let store = AgentStore.shared
        let last = (ui.selectedID ?? UserDefaults.standard.string(forKey: "lastChat")).flatMap { store.find($0) }
        return last ?? store.grokBots.first { ui.pinned.contains($0.name) }
    }

    private func zone(icon: String, text: String, lit: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: lit ? icon + (icon == "paperclip" ? "" : ".fill") : icon).font(.system(size: 14))
                .scaleEffect(lit ? 1.15 : 1)
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
        }
        .foregroundStyle(.white.opacity(lit ? 1 : 0.6))
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(lit ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(.white.opacity(lit ? 0.7 : 0.2), style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])))
        .contentShape(Rectangle())
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: lit)
    }

    /// Pictures become attachments on that chat's reply and the chat opens, ready to send.
    /// Anything that is not a picture cannot be attached, so it is held on the shelf instead.
    private func attach(_ providers: [NSItemProvider], to chat: Agent) {
        var opened = false
        for provider in providers {
            _ = provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                DispatchQueue.main.async {
                    guard let data, let image = NSImage(data: data), let file = Attachment.from(image) else {
                        shelve([provider])
                        return
                    }
                    ui.attachments[chat.id, default: []].append(file)
                    if !opened {
                        opened = true
                        ui.show(chat.id)
                    }
                }
            }
        }
    }

    var body: some View {
        let items = Clips.shared.shelf
        VStack(spacing: 8) {
            if !items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(items) { ShelfTile(item: $0) }
                    }
                    .padding(.horizontal, 4).padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if items.isEmpty || ui.fileInHand {
                HStack(spacing: 8) {
                    zone(icon: "tray.and.arrow.down", text: ui.fileInHand ? "Hold it here" : "Nothing held. Drag a file here to keep it handy.", lit: dropping)
                    // With a file in hand there is a second place to drop it: straight into the
                    // chat you were last in, as an attachment.
                    if ui.fileInHand, let chat {
                        zone(icon: "paperclip", text: "Send to \(chat.name)", lit: attaching)
                            .onDrop(of: [.fileURL, .image], isTargeted: $attaching) { providers in
                                attach(providers, to: chat)
                                return true
                            }
                    }
                }
                .frame(height: items.isEmpty ? 76 : 50)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .image, .movie, .data], isTargeted: $dropping) { providers in
            shelve(providers)
            ui.fileLanded()
            return true
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: items.map(\.id))
    }
}

/// A held file: its picture or icon with the name under it. Drag it out to use it, double
/// click to open it, and the small cross lets it go.
private struct ShelfTile: View {
    let item: ShelfItem
    @State private var hovered = false
    @State private var picture: NSImage?

    var body: some View {
        VStack(spacing: 3) {
            Group {
                if let picture {
                    Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 40, height: 40)
                        .frame(width: 44, height: 44)
                }
            }
            .overlay(alignment: .topTrailing) {
                if hovered {
                    Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { Clips.shared.drop(item) } } label: {
                        Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 15, height: 15).background(Color(white: 0.25), in: Circle())
                    }
                    .buttonStyle(Press()).offset(x: 5, y: -5)
                }
            }
            Text(item.name).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.65))
                .lineLimit(1).truncationMode(.middle).frame(width: 58)
        }
        .scaleEffect(hovered ? 1.05 : 1)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onHover { hovered = $0 }
        .onDrag { NSItemProvider(contentsOf: URL(fileURLWithPath: item.path)) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: item.path)) }
        .help(item.name)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
        .task(id: item.path) {
            let ext = URL(fileURLWithPath: item.path).pathExtension.lowercased()
            guard ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"].contains(ext) else { return }
            ChatView.thumbnail(item.path) { picture = $0 }
        }
    }
}

private struct ClipRow: View {
    let clip: Clip
    let selected: Bool
    @State private var hovered = false
    @State private var picture: NSImage?
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Group {
                if let picture {
                    Image(nsImage: picture).resizable().aspectRatio(contentMode: selected ? .fit : .fill)
                        .frame(width: selected ? 120 : 30, height: selected ? 80 : 22)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Image(systemName: clip.imagePath != nil ? "photo" : clip.isLink ? "link" : "text.alignleft")
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4)).frame(width: 30, height: 22)
                }
            }
            // The selected clip opens out to show more of itself.
            Text(clip.text.map { selected ? String($0.prefix(600)) : oneLine($0, max: 140) } ?? "Picture")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(selected || hovered ? 0.95 : 0.8))
                .lineLimit(selected ? 6 : 1).fixedSize(horizontal: false, vertical: selected)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 6)
            if hovered {
                Button {
                    Clips.shared.copy(clip)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10.5))
                        .foregroundStyle(copied ? Palette.green : .white.opacity(0.55)).frame(width: 20, height: 18)
                }
                .buttonStyle(Press()).help("Copy without pasting")
                Button { withAnimation(.easeOut(duration: 0.18)) { Clips.shared.remove(clip) } } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.55))
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(Press()).help("Forget this")
            } else {
                Text(ago).font(.system(size: 10)).foregroundStyle(.white.opacity(0.28)).monospacedDigit()
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.white.opacity(selected ? 0.12 : hovered ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { Clips.shared.paste(clip) }
        .onHover { hovered = $0 }
        .task(id: clip.imagePath) {
            guard let path = clip.imagePath else { return }
            ChatView.thumbnail(path) { picture = $0 }
        }
    }

    private var ago: String {
        let s = Int(Date().timeIntervalSince(clip.at))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

// MARK: Clickable references

/// Turns the things an agent mentions in `code` into links: a file name, a folder, a Claude
/// Code session to reopen. Clicking a file shows it in Finder; a session opens in the Claude app.
enum References {
    private static let session = try! NSRegularExpression(pattern: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
    private static let fileName = try! NSRegularExpression(pattern: #"^[^\s/]+\.[A-Za-z0-9]{1,6}$"#)

    static func link(_ text: inout AttributedString) {
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true && run.link == nil {
            let piece = String(text[run.range].characters).trimmingCharacters(in: .whitespaces)
            guard let url = target(piece) else { continue }
            text[run.range].link = url
            text[run.range].foregroundColor = Color(red: 0.56, green: 0.74, blue: 1)
            text[run.range].underlineStyle = Text.LineStyle(pattern: .dot, color: Color(red: 0.56, green: 0.74, blue: 1).opacity(0.6))
        }
    }

    private static func target(_ piece: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "perch"
        let whole = NSRange(piece.startIndex..., in: piece)
        if piece.contains("claude") || piece.count == 36, let m = session.firstMatch(in: piece, range: whole), let r = Range(m.range, in: piece) {
            parts.host = "session"
            parts.queryItems = [URLQueryItem(name: "id", value: String(piece[r]))]
            return parts.url
        }
        if piece.hasPrefix("~/") || piece == "~" || piece.hasPrefix("/") {
            let path = (piece as NSString).expandingTildeInPath
            guard !piece.contains(" --"), FileManager.default.fileExists(atPath: path) else { return nil }
            parts.host = "path"
            parts.queryItems = [URLQueryItem(name: "p", value: path)]
            return parts.url
        }
        if fileName.firstMatch(in: piece, range: whole) != nil, piece.count > 4 {
            parts.host = "find"
            parts.queryItems = [URLQueryItem(name: "name", value: piece)]
            return parts.url
        }
        return nil
    }

    /// Handles a click on one of these links. Returns false for anything that is not one.
    static func open(_ url: URL) -> Bool {
        guard url.scheme == "perch", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        let value = items.first?.value ?? ""
        switch url.host {
        case "session":
            if let link = URL(string: "claude://resume?session=\(value)") { NSWorkspace.shared.open(link) }
            NotchUI.shared.collapse()
        case "path":
            show(value)
        case "find":
            // Ask Spotlight where a file of that name is, newest first, and show the first hit.
            guard let mdfind = Shell.find("mdfind") else { break }
            Shell.run(mdfind, ["-onlyin", Shell.home, "-name", value]) { _, out in
                let fm = FileManager.default
                let hits = out.split(separator: "\n").map(String.init)
                    .filter { URL(fileURLWithPath: $0).lastPathComponent == value && !$0.contains("/Library/") }
                    .sorted { a, b in
                        let da = (try? fm.attributesOfItem(atPath: a))?[.modificationDate] as? Date ?? .distantPast
                        let db = (try? fm.attributesOfItem(atPath: b))?[.modificationDate] as? Date ?? .distantPast
                        return da > db
                    }
                if let first = hits.first { show(first) } else { NSSound.beep() }
            }
        default:
            return false
        }
        return true
    }

    private static func show(_ path: String) {
        var folder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &folder) else { NSSound.beep(); return }
        if folder.boolValue {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        NotchUI.shared.collapse()
    }
}

// MARK: Slack

private extension SlackTarget {
    var railID: String { "\(workspace):\(id)" }
}

private struct SlackRailRow: View {
    let target: SlackTarget
    let selected: Bool
    @Environment(NotchUI.self) private var ui
    @State private var hovered = false
    private var whatsapp: Bool { target.workspace == WhatsAppSource.workspace }

    var body: some View {
        let waiting = max(ui.slackUnread["\(target.workspace):\(target.id)"] ?? 0,
                          whatsapp ? (WhatsAppSource.shared.chats.first { $0.id == target.id }?.unread ?? 0) : 0)
        HStack(spacing: SidebarStyle.spacing) {
            SlackAvatar(url: livePicture(target), channel: target.channel, size: SidebarStyle.avatar,
                        whatsapp: whatsapp, sidebar: true)
            Text(liveName(target))
                .font(.system(size: SidebarStyle.nameSize, weight: waiting > 0 || selected ? .semibold : .regular))
                .foregroundStyle(.white.opacity(waiting > 0 || selected ? 0.95 : 0.6))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if waiting > 0 {
                Text(waiting > 99 ? "99+" : "\(waiting)").font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(whatsapp ? .white : .black)
                    .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16)
                    .background(whatsapp ? Color(red: 0.10, green: 0.67, blue: 0.36) : .white, in: Capsule())
            }
            SidebarActions(chat: .conversation(target))
        }
        .frame(height: SidebarStyle.rowHeight)
        .padding(.horizontal, SidebarStyle.inset)
        .background(.white.opacity(selected ? 0.14 : hovered ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { ui.openSlack(target) }
        // Double-click: straight to the chat in WhatsApp or Slack itself.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            SlackSource.shared.open(target)
            ui.collapse()
        })
        .onHover { hovered = $0 }
        .contextMenu { SidebarActionButtons(chat: .conversation(target)) }
        .modifier(SidebarSwipeRow(chat: .conversation(target)))
    }
}

/// A profile picture (or workspace icon for a channel) with the Slack logo in its corner, so a
/// Slack row is told apart from a chat at a glance.
/// A reaction's emoji: the character, or the workspace's uploaded picture for a custom one.
private struct ReactionEmoji: View {
    let reaction: SlackReaction
    let workspace: String?
    @State private var image: NSImage?

    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    private var url: URL? { workspace.flatMap { SlackCustomEmoji.shared.url($0, reaction.name) } }

    var body: some View {
        if let url {
            Group {
                if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
                else { Color.white.opacity(0.08) }
            }
            .frame(width: 15, height: 15)
            .help(":\(reaction.name):")
            .task(id: url) {
                if let hit = Self.cache.object(forKey: url as NSURL) { image = hit; return }
                if let (data, _) = try? await URLSession.shared.data(from: url), let img = NSImage(data: data) {
                    Self.cache.setObject(img, forKey: url as NSURL)
                    image = img
                }
            }
        } else {
            Text(reaction.emoji).font(.system(size: 12))
        }
    }
}

private struct SlackAvatar: View {
    let url: URL?
    let channel: Bool
    let size: CGFloat
    /// A WhatsApp chat: WhatsApp's logo in the corner instead of Slack's.
    var whatsapp = false
    var plainWhatsApp = false
    var sidebar = false
    @State private var image: NSImage?

    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 128
        return cache
    }()
    static let slackLogo = NSWorkspace.shared.icon(forFile: "/Applications/Slack.app")
    static let whatsappLogo: NSImage = {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp") {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "message.fill", accessibilityDescription: nil) ?? NSImage()
    }()
    private var logo: NSImage { whatsapp ? Self.whatsappLogo : Self.slackLogo }

    @ViewBuilder private var picture: some View {
        if let image {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            Color.white.opacity(0.12)
                .overlay(Image(systemName: channel ? "number" : "person.fill").font(.system(size: size * 0.42 * (channel ? 0.5 : 1)))
                    .foregroundStyle(.white.opacity(0.6)))
        }
    }

    /// A person shows their picture with a small Slack logo; a channel shows the Slack logo
    /// with the workspace's icon small in the corner.
    var body: some View {
        Group {
            if channel {
                Image(nsImage: logo).resizable()
                    .frame(width: sidebar ? size * 0.72 : size, height: sidebar ? size * 0.72 : size)
                    .frame(width: size, height: size)
                    .background(.white.opacity(sidebar ? 0.10 : 0), in: Circle())
            } else {
                picture.frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: plainWhatsApp || sidebar ? size / 2 : size * 0.28, style: .continuous))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !plainWhatsApp && !sidebar { Group {
                if channel {
                    picture.frame(width: size * 0.46, height: size * 0.46)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous))
                        .padding(1)
                } else {
                    Image(nsImage: logo).resizable().frame(width: size * 0.5, height: size * 0.5)
                }
            }
            .background(Color.black, in: RoundedRectangle(cornerRadius: size * 0.14, style: .continuous))
            .offset(x: size * 0.16, y: size * 0.16)
            }
        }
        .task(id: url) {
            guard let url else { return }
            if let hit = Self.cache.object(forKey: url as NSURL) { image = hit; return }
            if let (data, _) = try? await URLSession.shared.data(from: url), let img = NSImage(data: data) {
                Self.cache.setObject(img, forKey: url as NSURL)
                image = img
            }
        }
    }
}

/// A fresh Slack message to someone or a channel, chosen from search. Sends as you.
private struct SlackComposer: View {
    let target: SlackTarget
    @Environment(NotchUI.self) private var ui
    @Environment(\.sideWindow) private var sideWindow
    @State private var voice = VoiceRecording()
    @State private var sent = 0
    /// The reply being written, kept with the other drafts so it survives switching chats and
    /// restarts, and so dictation can write into it.
    private var draftKey: String { "conversation:\(target.workspace):\(target.id)" }
    private var text: String { ui.drafts[draftKey] ?? "" }
    private var draft: Binding<String> {
        Binding(get: { ui.drafts[draftKey] ?? "" }, set: { ui.drafts[draftKey] = $0 })
    }
    @State private var files: [URL] = []
    @State private var state: String?
    @State private var ask = 0

    private var lines: [SlackLine]? {
        let store = SlackConversations.shared
        let channel = target.channel || target.workspace == WhatsAppSource.workspace ? target.id : store.dmChannel["\(target.workspace):\(target.id)"]
        return channel.flatMap { store.lines[store.key(target.workspace, $0)] }
    }

    /// The thread open beside the conversation, by its first message's ts.
    private var threadTS: String? { target.workspace == WhatsAppSource.workspace ? nil : ui.openThreads[replyKey] }
    private func showThread(_ ts: String?) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { ui.openThreads[replyKey] = ts }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            conversation
            if sideWindow == nil, let ts = threadTS {
                // Beside the conversation, as Slack has it.
                Rectangle().fill(.white.opacity(0.08)).frame(width: 1).padding(.horizontal, 10)
                SlackThreadView(target: target, parentTS: ts, fallback: lines?.first { $0.id == ts }) { showThread(nil) }
                    .id(ts)
                    .frame(width: 370, height: 452, alignment: .top)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                if sideWindow == nil {
                    Button { ui.slackTarget = nil; ui.browse() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6)).frame(width: 18, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(Press())
                }
                SlackAvatar(url: livePicture(target), channel: target.channel, size: 22, whatsapp: target.workspace == WhatsAppSource.workspace)
                VStack(alignment: .leading, spacing: 0) {
                    Text(liveName(target)).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    // As WhatsApp shows it, under the name.
                    if target.workspace == WhatsAppSource.workspace, let doing = WhatsAppSource.shared.typingLine(target.id) {
                        Text(doing).font(.system(size: 10.5)).foregroundStyle(Color(red: 0.33, green: 0.85, blue: 0.62))
                            .lineLimit(1).transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: WhatsAppSource.shared.typingLine(target.id))
                if target.workspace != WhatsAppSource.workspace {
                    Text("Slack · \(target.workspace.capitalized)")
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                }
                Spacer()
                if sideWindow != nil {
                    // Back into the notch, on this same conversation.
                    Button { SidePanel.shared.returnToNotch(target) } label: {
                        Image(systemName: "rectangle.topthird.inset.filled").font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6)).frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(Press()).help("Back to the notch")
                    Button { SidePanel.shared.close() } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6)).frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(Press()).help("Close")
                } else {
                    // Keep this conversation open in a slim panel at the side of the screen.
                    Button { SidePanel.shared.show(conversation: target) } label: {
                        Image(systemName: "sidebar.right").font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6)).frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(Press()).help("Keep open at the side")
                }
            }
            .background(DoubleClick {
                SlackSource.shared.open(target)
                ui.collapse()
            })
            // The conversation so far, newest at the bottom, live as messages arrive.
            ScrollViewReader { proxy in
                ScrollView {
                    // Lazy: only the messages in view are laid out, so opening a long
                    // conversation and jumping to its end stays instant.
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if let lines {
                            if lines.isEmpty {
                                Text("No messages yet.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4))
                            }
                            let newDays = Self.dayStarts(lines)
                            ForEach(lines, id: \.viewKey) { line in
                                if newDays.contains(line.viewKey), let time = line.time {
                                    // Each day starts with its date, as in WhatsApp.
                                    Text(Self.dayLabel(time)).font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.55))
                                        .padding(.horizontal, 9).padding(.vertical, 3)
                                        .background(Color(white: 0.14), in: Capsule())
                                        .frame(maxWidth: .infinity).padding(.vertical, 2)
                                }
                                if newMessages == line.viewKey {
                                    NewMessagesMark(whatsapp: target.workspace == WhatsAppSource.workspace, count: unreadAtOpen)
                                }
                                if target.workspace != WhatsAppSource.workspace {
                                    // Slack looks like Slack: flat rows, a square picture, name and
                                    // time, and follow-ups from the same person tucked under.
                                    SlackRow(line: line, workspace: target.workspace,
                                             continued: Self.continues(line, after: lines.prevLine(line)),
                                             onThread: { showThread(threadTS == line.id ? nil : line.id) },
                                             react: { name, add in SlackSource.shared.react(target, ts: line.id, name: name, add: add) },
                                             target: target, highlighted: threadTS == line.id)
                                        .id(line.viewKey)
                                        .transition(line.mine ? .sent : .arrived)
                                        .reportsTop(line.viewKey == lines.last?.viewKey)
                                } else {
                                // As in WhatsApp, a run of messages from one person shows their
                                // name and picture once, with the rest stacked close underneath.
                                let run = Self.sameSender(line, after: lines.prevLine(line))
                                HStack(alignment: .top, spacing: 8) {
                                    if line.mine { Spacer(minLength: 50) }
                                    if !line.mine && !(target.workspace == WhatsAppSource.workspace && !target.id.hasSuffix("@g.us")) {
                                        if run { Color.clear.frame(width: 22, height: 1) }
                                        else { SlackAvatar(url: line.picture, channel: false, size: 22, whatsapp: target.workspace == WhatsAppSource.workspace) }
                                    }
                                    VStack(alignment: line.mine ? .trailing : .leading, spacing: 2) {
                                        if !line.mine && !run && !(target.workspace == WhatsAppSource.workspace && !target.id.hasSuffix("@g.us")) {
                                            Text(line.sender).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                                        }
                                        if target.workspace == WhatsAppSource.workspace {
                                            WhatsAppBubble(line: line, chat: target.id)
                                        } else if !line.text.isEmpty {
                                            Text(line.text).font(.system(size: 12.5)).textSelection(.enabled)
                                                .foregroundStyle(line.mine ? Color.black.opacity(0.88) : .white.opacity(0.9))
                                                .fixedSize(horizontal: false, vertical: true)
                                                .padding(.horizontal, 10).padding(.vertical, 7)
                                                .background(line.mine ? Color(red: 0.92, green: 0.87, blue: 0.95) : Color(white: 0.17),
                                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        }
                                        if target.workspace != WhatsAppSource.workspace { ForEach(line.files) { SlackFileView(file: $0) } }
                                    }
                                    if !line.mine { Spacer(minLength: 40) }
                                }
                                .padding(.top, run ? -6 : 0)
                                .offset(x: target.workspace == WhatsAppSource.workspace && ui.swipe?.id == line.viewKey ? ui.swipe!.x : 0)
                                .background(alignment: line.mine ? .trailing : .leading) {
                                    // Pulled far enough, the reply arrow shows.
                                    if ui.swipe?.id == line.viewKey, abs(ui.swipe!.x) > 28 {
                                        Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 12))
                                            .foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 6)
                                    }
                                }
                                .onHover { over in
                                    guard target.workspace == WhatsAppSource.workspace, !line.id.hasPrefix("local-") else { return }
                                    if over { ui.hoveredLine = (replyKey, line); ui.hoveredMessage = nil }
                                    else if ui.hoveredLine?.line.id == line.id { ui.hoveredLine = nil }
                                }
                                .contextMenu {
                                    if target.workspace == WhatsAppSource.workspace, !line.id.hasPrefix("local-") {
                                        Button("Reply") { ui.lineReply[replyKey] = line }
                                    }
                                }
                                .id(line.viewKey)
                                .transition(line.mine ? .sent : .arrived)
                                .reportsTop(line.viewKey == lines.last?.viewKey)
                                }
                            }
                        } else {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 30)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .coordinateSpace(name: "chat")
                .opacity(ready || lines?.isEmpty != false ? 1 : 0)
                .background(GeometryReader { g in Color.clear.onAppear { viewHeight = g.size.height }
                    .onChange(of: g.size.height) { _, h in viewHeight = h } })
                .onPreferenceChange(LastTopKey.self) { top in
                    // At the bottom: the end of the newest message is in view.
                    following = top.maxY < viewHeight + 30
                    if following, newBelow { withAnimation(.easeOut(duration: 0.2)) { newBelow = false; newCount = 0 } }
                }
                .overlay(alignment: .bottom) {
                    if newBelow, let last = lines?.last {
                        NewBelowButton(count: newCount) {
                            withAnimation(.sendSpring) { proxy.scrollTo(last.viewKey, anchor: .bottom) }
                            newBelow = false
                            newCount = 0
                        }
                    }
                }
                // Earlier messages arriving above (a fuller reload) push the view up: if the user
                // was at the end, or it only just opened, it goes back to where it was landed.
                .onChange(of: lines?.first?.viewKey) { old, new in
                    guard landed, old != nil, new != old else { return }
                    if Date().timeIntervalSince(landedAt) < 4 { return land(proxy) }
                    if following, let last = lines?.last?.viewKey { proxy.scrollTo(last, anchor: .bottom) }
                }
                .onChange(of: lines?.last?.viewKey) { _, id in
                    guard let id else { return }
                    // The first load lands on the first unread message; later ones follow the newest,
                    // unless the user is reading further up: then a button says something came.
                    if !landed { return land(proxy) }
                    if lines?.last?.mine != true && !following {
                        withAnimation(.easeOut(duration: 0.2)) { newBelow = true; newCount += 1 }
                        return
                    }
                    glide(proxy, to: id) { following }
                }
                .onAppear {
                    if lines?.isEmpty == false { land(proxy) }
                    // Opening a chat is reading it, in Slack too. Without this only a new message
                    // arriving while it was open marked anything read.
                    if target.workspace != WhatsAppSource.workspace {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { SlackSource.shared.markRead(target) }
                    }
                    // Slack's own read marker decides where "New" goes; it may answer a moment later.
                    if target.workspace != WhatsAppSource.workspace {
                        SlackSource.shared.lastRead(target) { at in
                            readUpTo = at
                            if Date().timeIntervalSince(landedAt) < 2.5 { land(proxy) }
                        }
                    }
                }
                // Seen here means read there too, including messages that arrive while it is open.
                .onChange(of: lines?.last?.viewKey) { _, id in
                    guard id != nil, target.workspace != WhatsAppSource.workspace else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { SlackSource.shared.markRead(target) }
                }
            }
            if let problem = voice.problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(Palette.red)
            }
            if voice.recording {
                HStack {
                    Label("Recording voice message…", systemImage: "record.circle").foregroundStyle(Palette.red)
                    Spacer()
                    Button("Cancel") { voice.cancel() }.buttonStyle(.plain)
                }.font(.system(size: 11))
            }
            if state == "failed" {
                Text("Did not send. Check Slack is set up to send for this workspace.")
                    .font(.system(size: 11)).foregroundStyle(Palette.red)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let replying = ui.lineReply[replyKey] {
                    WhatsAppQuote(quote: SlackQuote(id: replying.id, sender: replying.mine ? "You" : replying.sender,
                                                    text: replying.text.isEmpty ? (replying.files.first?.name ?? "") : replying.text),
                                  closable: { ui.lineReply[replyKey] = nil })
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if !files.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(files, id: \.self) { file in
                            if let thumb = NSImage(contentsOf: file), SlackFile.sending(file, workspace: "").image {
                                // A picture waiting to go shows as itself, as in WhatsApp.
                                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .overlay(alignment: .topTrailing) {
                                        Button { withAnimation(.easeOut(duration: 0.15)) { files.removeAll { $0 == file } } } label: {
                                            Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold)).foregroundStyle(.white)
                                                .frame(width: 16, height: 16).background(.black.opacity(0.6), in: Circle())
                                        }
                                        .buttonStyle(Press()).padding(3)
                                    }
                                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                            } else {
                                HStack(spacing: 4) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 16, height: 16)
                                    Text(file.lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                                    Button { files.removeAll { $0 == file } } label: {
                                        Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold))
                                    }
                                    .buttonStyle(Press())
                                }
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(.white.opacity(0.1), in: Capsule())
                                .frame(maxWidth: 170)
                            }
                        }
                    }
                }
                HStack(alignment: .bottom, spacing: 6) {
                    DraftText(store: ui.drafts, id: draftKey, placeholder: "Message \(liveName(target))", focusAsk: ask,
                                onFocus: { _ in }, onSubmit: send, onTab: { false })
                        .fixedSize(horizontal: false, vertical: true)
                        .overlay(alignment: .topLeading) {
                            if !ui.drafts.hasText(draftKey) {
                                Text("Message \(liveName(target))").font(.system(size: 13)).foregroundStyle(.white.opacity(0.35))
                                    .allowsHitTesting(false)
                            }
                        }
                    EmojiButton { ui.drafts[draftKey, default: ""] += $0 }
                    Button(action: choose) {
                        Image(systemName: "paperclip").font(.system(size: 13)).foregroundStyle(.white.opacity(0.45))
                    }
                    .buttonStyle(Press()).help("Attach files")
                    if target.workspace != WhatsAppSource.workspace {
                        let listening = Dictation.shared.activeAgentID == draftKey
                        Button { Dictation.shared.toggle(for: draftKey) } label: {
                            Image(systemName: listening ? "mic.fill" : "mic").font(.system(size: 13))
                                .foregroundStyle(listening ? Palette.red : .white.opacity(0.45))
                        }
                        .buttonStyle(Press()).help(listening ? "Stop dictating" : "Dictate a reply")
                    }
                    if target.workspace == WhatsAppSource.workspace {
                        Button {
                            if voice.recording { voice.finish { files.append($0) } }
                            else { voice.start() }
                        } label: {
                            Image(systemName: voice.recording ? "stop.circle.fill" : "mic.fill")
                                .font(.system(size: 14)).foregroundStyle(voice.recording ? Palette.red : .white.opacity(0.6))
                        }
                        .buttonStyle(Press()).disabled(voice.preparing || state == "sending")
                        .help(voice.recording ? "Stop and attach voice message" : "Record a voice message")
                    }
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 15)).symbolEffect(.bounce, value: sent)
                            .foregroundStyle(!ui.drafts.hasText(draftKey) && files.isEmpty ? .white.opacity(0.2) : .white)
                    }
                    .buttonStyle(Press()).disabled((!ui.drafts.hasText(draftKey) && files.isEmpty) || state == "sending" || voice.recording || voice.preparing)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(.white.opacity(0.2), lineWidth: 1))
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { files.append(url) } }
                    }
                }
                return true
            }
        }
        .frame(height: sideWindow == nil ? 452 : nil, alignment: .top)
        .frame(maxHeight: sideWindow == nil ? 452 : .infinity, alignment: .top)
        .overlay {
            // A floating window is too narrow to have it beside: the thread slides over instead.
            if sideWindow != nil, let ts = threadTS {
                SlackThreadView(target: target, parentTS: ts, fallback: lines?.first { $0.id == ts }) { showThread(nil) }
                    .id(ts)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay { Lightbox(side: sideWindow != nil) }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: ui.lineReply[replyKey]?.id)
        // Aiming a reply puts the cursor in the box, ready to type.
        .onChange(of: ui.lineReply[replyKey]?.id) { _, id in if id != nil { ask += 1 } }
        // Pictures pasted with Cmd+V join the files waiting to go.
        .onChange(of: ui.pastedFiles[replyKey]) { _, pasted in
            guard let pasted, !pasted.isEmpty else { return }
            files.append(contentsOf: pasted)
            ui.pastedFiles[replyKey] = nil
        }
        .onDisappear {
            voice.cancel(); ui.hoveredLine = nil
            if target.workspace == WhatsAppSource.workspace { WhatsAppSource.shared.unwatch(target.id) }
        }
        .onAppear { if target.workspace == WhatsAppSource.workspace { WhatsAppSource.shared.watch(target.id) } }
        // Slack's live feed can drop quietly; an open conversation checks itself now and then.
        .task(id: target.id) {
            guard target.workspace != WhatsAppSource.workspace else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                SlackSource.shared.history(for: target)
            }
        }
        .onAppear {
            SlackSource.shared.history(for: target)
            // In the notch the keyboard comes straight here; a floating window waits for a click.
            if sideWindow == nil {
                ui.controller?.panel.makeKey()
                ask += 1
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        panel.level = .popUpMenu
        let side = sideWindow
        if side == nil { ui.heldOpen = true }
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            if side == nil { ui.heldOpen = false }
            if response == .OK { files.append(contentsOf: panel.urls) }
            if let side { side.makeKey() } else { ui.openSlack(target) }
        }
    }

    private var replyKey: String { "\(target.workspace):\(target.id)" }

    @State private var landed = false
    /// Hidden until it has come to rest, so opening never shows it jumping.
    @State private var ready = false
    @State private var following = true
    @State private var newBelow = false
    @State private var newCount = 0
    @State private var viewHeight: CGFloat = 0
    /// How many were unread when this opened, and the first of them (where it opens).
    private var unreadAtOpen: Int { ui.openedUnread[replyKey] ?? 0 }
    /// Where Slack itself says the user had read up to, once it has answered.
    @State private var readUpTo: Double?
    @State private var landedAt = Date.distantPast

    private var newMessages: String? {
        if target.workspace != WhatsAppSource.workspace, let readUpTo, let lines {
            return lines.first { !$0.mine && (Double($0.id) ?? 0) > readUpTo }?.viewKey
        }
        guard unreadAtOpen > 0, let lines else { return nil }
        var left = unreadAtOpen
        for line in lines.reversed() where !line.mine {
            left -= 1
            if left == 0 { return line.viewKey }
        }
        // More unread than is loaded (a busy group): the first of them is not here, and opening
        // at the top of an old page reads as broken. Open at the newest instead.
        return nil
    }

    /// Opens at the first unread message, with the ones before it just above; otherwise at
    /// the newest.
    private func land(_ proxy: ScrollViewProxy) {
        landed = true
        landedAt = Date()
        guard let lines, let last = lines.last else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { withAnimation(.easeOut(duration: 0.14)) { ready = true } }
        if let first = newMessages, let line = lines.first(where: { $0.viewKey == first }) {
            proxy.scrollTo(line.viewKey, anchor: UnitPoint(x: 0.5, y: 0.25))
        } else {
            proxy.scrollTo(last.viewKey, anchor: .bottom)
            // Pictures take their size once loaded, which pushes the end down: settle again, but
            // only if it did. Each jump lays out the whole conversation, so none are spare.
            for delay in [0.3, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard !self.following, let id = self.lines?.last?.viewKey else { return }
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    /// A follow-up from the same person within a few minutes, shown without their name again.
    static func continues(_ line: SlackLine, after prev: SlackLine?) -> Bool {
        guard let prev, prev.mine == line.mine, prev.sender == line.sender,
              let a = prev.time, let b = line.time, Calendar.current.isDate(a, inSameDayAs: b) else { return false }
        return b.timeIntervalSince(a) < 300
    }

    /// The next message in a run from the same person on the same day, however far apart, the
    /// way WhatsApp groups them.
    static func sameSender(_ line: SlackLine, after prev: SlackLine?) -> Bool {
        guard let prev, prev.mine == line.mine, prev.sender == line.sender else { return false }
        guard let a = prev.time, let b = line.time else { return true }
        return Calendar.current.isDate(a, inSameDayAs: b)
    }

    /// The messages that are the first of their day.
    static func dayStarts(_ lines: [SlackLine]) -> Set<String> {
        var seen: Date?
        var starts = Set<String>()
        for line in lines {
            guard let time = line.time else { continue }
            let day = Calendar.current.startOfDay(for: time)
            if day != seen { starts.insert(line.viewKey); seen = day }
        }
        return starts
    }

    static func dayLabel(_ time: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(time) { return "Today" }
        if calendar.isDateInYesterday(time) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = calendar.isDate(time, equalTo: Date(), toGranularity: .year) ? "EEE d MMM" : "d MMM yyyy"
        return f.string(from: time)
    }

    private func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || !files.isEmpty, state != "sending", !voice.recording, !voice.preparing else { return }
        state = "sending"
        Settings.sentFeel()
        let sending = files
        // A reply only goes with words; files go as they are.
        let replying = files.isEmpty ? ui.lineReply[replyKey] : nil
        let quote = replying.map { SlackQuote(id: $0.id, sender: $0.mine ? "You" : $0.sender,
                                              text: $0.text.isEmpty ? ($0.files.first?.name ?? "") : $0.text) }
        if replying != nil { ui.lineReply[replyKey] = nil }
        // Shown straight away, rising into place; the real copy takes its spot when it is back.
        let store = SlackConversations.shared
        let whatsapp = target.workspace == WhatsAppSource.workspace
        let channel = target.channel || whatsapp ? target.id : store.dmChannel["\(target.workspace):\(target.id)"]
        if let channel {
            let key = store.key(target.workspace, channel)
            let me = whatsapp ? "You" : (SlackSource.shared.myName(in: target.workspace) ?? "You")
            let face = whatsapp ? nil : SlackSource.shared.myPicture(in: target.workspace)
            let sending = sending.map { SlackFile.sending($0, workspace: target.workspace) }
            if whatsapp && !sending.isEmpty {
                // WhatsApp sends each file as its own message, the words going with the first.
                for (i, file) in sending.enumerated() {
                    store.showSent(key, text: i == 0 ? message : "", whatsapp: true, files: [file])
                }
            } else if !message.isEmpty || !sending.isEmpty {
                store.showSent(key, text: message, whatsapp: whatsapp, quote: quote, sender: me, picture: face, files: sending)
            }
        }
        Dictation.shared.stop()
        ui.drafts[draftKey] = nil
        sent += 1
        ui.touch(target)
        SlackSource.shared.send(to: target, text: message, files: sending, replyTo: replying?.id) { ok in
            state = ok ? nil : "failed"
            if ok {
                files = []
                // The real copy, from Slack's or WhatsApp's own record.
                DispatchQueue.main.asyncAfter(deadline: .now() + (whatsapp ? 0.1 : 0.8)) { SlackSource.shared.history(for: target) }
            } else {
                ui.drafts[draftKey] = message
                if let replying { ui.lineReply[replyKey] = replying }
            }
        }
    }
}

/// Where the newest message starts, relative to the top of the chat's visible area, so the chat
/// knows whether the user is following along or has scrolled up to read something.
struct LastTopKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

extension View {
    /// Marks this as the newest message, for `LastTopKey`.
    func reportsTop(_ on: Bool) -> some View {
        background {
            if on {
                GeometryReader { g in Color.clear.preference(key: LastTopKey.self, value: g.frame(in: .named("chat"))) }
            }
        }
    }
}

/// Something new arrived while the user was reading further up: a small button to go to it,
/// instead of the chat pulling them down.
struct NewBelowButton: View {
    var count = 0
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(count == 1 ? "1 new message" : count > 1 ? "\(count) new messages" : "New messages", systemImage: "arrow.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.black).padding(.horizontal, 11).padding(.vertical, 6)
                .background(.white, in: Capsule())
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        }
        .buttonStyle(Press())
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private extension Array where Element == SlackLine {
    func prevLine(_ line: SlackLine) -> SlackLine? {
        guard let i = firstIndex(where: { $0.viewKey == line.viewKey }), i > 0 else { return nil }
        return self[i - 1]
    }
}

/// Where the unread messages start: Slack's red "New" line, or WhatsApp's unread pill.
private struct NewMessagesMark: View {
    let whatsapp: Bool
    let count: Int

    var body: some View {
        if whatsapp {
            Text(count == 1 ? "1 unread message" : "\(count) unread messages")
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Color(white: 0.16), in: Capsule())
                .frame(maxWidth: .infinity).padding(.vertical, 3)
        } else {
            HStack(spacing: 6) {
                Rectangle().fill(Palette.red.opacity(0.7)).frame(height: 1)
                Text("New").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.red)
            }
            .padding(.vertical, 2)
        }
    }
}

/// One Slack message the way Slack shows it: picture, name and time on top, then the text.
private struct SlackRow: View {
    let line: SlackLine
    let workspace: String
    let continued: Bool
    /// Opens this message's thread; nil inside a thread itself.
    var onThread: (() -> Void)?
    /// Adds or takes away the user's reaction, by Slack's emoji name.
    var react: ((String, Bool) -> Void)?
    /// The conversation it is in, so the user's own messages can be edited and deleted.
    var target: SlackTarget?
    /// Its thread is open beside the conversation: picked out, as Slack does.
    var highlighted = false
    @State private var hovered = false
    @State private var reacting = false
    @State private var adding = false
    /// The text being edited, while editing.
    @State private var editing: String?
    @State private var confirmDelete = false
    @State private var copied = false

    private static let blue = Color(red: 0.45, green: 0.7, blue: 1)
    private var canChange: Bool { line.mine && target != nil && !line.id.hasPrefix("local-") }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if continued {
                // Slack shows the time in the gutter on hover for a follow-up.
                Text(hovered ? (line.time?.formatted(.dateTime.hour().minute()) ?? "") : "")
                    .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.35))
                    .frame(width: 30, alignment: .trailing).padding(.top, 2)
            } else {
                SquareFace(url: line.picture, name: line.sender)
            }
            VStack(alignment: .leading, spacing: 3) {
                if !continued {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(line.sender.isEmpty ? "Someone" : line.sender)
                            .font(.system(size: 12.5, weight: .bold)).foregroundStyle(.white)
                        if let time = line.time {
                            Text(time.formatted(.dateTime.hour().minute())).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
                if editing != nil {
                    editor
                } else if !line.text.isEmpty {
                    SlackMarkup(text: line.rich.isEmpty ? line.text : line.rich, workspace: workspace, edited: line.edited)
                }
                ForEach(line.files) { SlackFileView(file: $0) }
                if !line.slackReactions.isEmpty { reactions }
                if line.replyCount > 0, let onThread { threadSummary(onThread) }
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .topTrailing) {
            if (hovered || reacting || confirmDelete) && editing == nil && !line.id.hasPrefix("local-") { toolbar.offset(y: -10) }
        }
        .padding(.horizontal, 6).padding(.vertical, continued ? 1 : 4)
        .padding(.top, continued ? 0 : 2)
        .background(highlighted ? Color(red: 0.95, green: 0.78, blue: 0.27).opacity(0.11) : .white.opacity(hovered ? 0.04 : 0),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { over in
            hovered = over
            if !over { confirmDelete = false }
        }
        .animation(.easeOut(duration: 0.15), value: highlighted)
    }

    /// Slack's bar of actions over a message on hover.
    private var toolbar: some View {
        HStack(spacing: 1) {
            if let react {
                ReactFace(hovered: true, open: $reacting) { emoji in
                    guard let name = SlackEmojiName.byEmoji[emoji] else { return }
                    react(name, !line.slackReactions.contains { $0.name == name && $0.mine })
                }
                .scaleEffect(0.85)
            }
            if let onThread { tool("bubble.left.and.text.bubble.right", "Reply in thread", action: onThread) }
            tool(copied ? "checkmark" : "doc.on.doc", "Copy text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line.text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
            if canChange {
                tool("pencil", "Edit message") { editing = line.text }
                if confirmDelete {
                    Button { delete() } label: {
                        Text("Delete?").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).frame(height: 22)
                            .background(Palette.red, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(Press()).transition(.opacity)
                } else {
                    tool("trash", "Delete message") { withAnimation(.easeOut(duration: 0.15)) { confirmDelete = true } }
                }
            }
        }
        .padding(2)
        .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
    }

    private func tool(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
                .frame(width: 26, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(Press()).help(help)
    }

    /// Reactions as Slack shows them: a chip each, yours outlined in blue, then a button to add one.
    private var reactions: some View {
        HStack(spacing: 4) {
            ForEach(line.slackReactions, id: \.self) { r in
                Button { react?(r.name, !r.mine) } label: {
                    HStack(spacing: 3) {
                        ReactionEmoji(reaction: r, workspace: target?.workspace)
                        Text("\(r.count)").font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(r.mine ? Self.blue : .white.opacity(0.7))
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(r.mine ? Color(red: 0.3, green: 0.55, blue: 1).opacity(0.18) : .white.opacity(0.07), in: Capsule())
                    .overlay(Capsule().stroke(r.mine ? Self.blue.opacity(0.6) : .clear, lineWidth: 1))
                }
                .buttonStyle(Press())
            }
            if let react {
                ReactFace(hovered: true, open: $adding) { emoji in
                    guard let name = SlackEmojiName.byEmoji[emoji] else { return }
                    react(name, !line.slackReactions.contains { $0.name == name && $0.mine })
                }
                .scaleEffect(0.8)
                .opacity(hovered || adding ? 1 : 0.6)
            }
        }
        .padding(.top, 2)
    }

    /// Slack's thread summary: who replied, how many, and when last, in a box on hover.
    private func threadSummary(_ open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 7) {
                HStack(spacing: 3) {
                    ForEach(line.repliers.prefix(4), id: \.self) { SquareFace(url: $0, name: "", size: 20) }
                }
                Text(line.replyCount == 1 ? "1 reply" : "\(line.replyCount) replies")
                    .font(.system(size: 11.5, weight: .bold)).foregroundStyle(Self.blue)
                if let at = line.replyAt {
                    Text(hovered ? "View thread" : "Last reply \(Self.lastReply(at))")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45)).opacity(hovered ? 1 : 0)
            }
            .padding(.horizontal, 5).padding(.vertical, 4)
            .frame(maxWidth: 360, alignment: .leading)
            .background(.white.opacity(hovered || highlighted ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(.white.opacity(hovered || highlighted ? 0.13 : 0), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(Press()).padding(.top, 2)
    }

    /// Editing in place, as Slack does: the text in a box, Cancel and Save under it.
    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("", text: Binding(get: { editing ?? "" }, set: { editing = $0 }), axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 12.5)).lineLimit(1...10)
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 1))
                .onSubmit(save)
                .onExitCommand { editing = nil }
            HStack(spacing: 6) {
                Spacer()
                Button("Cancel") { editing = nil }.buttonStyle(LinkButton()).font(.system(size: 11))
                Button(action: save) {
                    Text("Save").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).frame(height: 22)
                        .background(Color(red: 0.0, green: 0.48, blue: 0.35), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(Press())
            }
        }
        .padding(.vertical, 2)
    }

    private func save() {
        guard let text = editing?.trimmingCharacters(in: .whitespacesAndNewlines), let target else { return }
        editing = nil
        guard !text.isEmpty, text != line.text else { return }
        SlackSource.shared.edit(target, ts: line.id, text: text) { _ in }
    }

    private func delete() {
        guard let target else { return }
        confirmDelete = false
        SlackSource.shared.delete(target, ts: line.id) { _ in }
    }

    /// "today at 11:12", "yesterday at 09:40", or the date, as Slack writes it under a thread.
    static func lastReply(_ date: Date) -> String {
        let cal = Calendar.current, time = date.formatted(.dateTime.hour().minute())
        if Date().timeIntervalSince(date) < 60 { return "just now" }
        if cal.isDateInToday(date) { return "today at \(time)" }
        if cal.isDateInYesterday(date) { return "yesterday at \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// Slack's own markup as Slack shows it: *bold*, _italic_, ~strike~, `code` and links in the
/// text, code blocks and quotes set apart, and mentions picked out (of you on yellow, of anyone
/// else in blue).
struct SlackMarkup: View {
    let text: String
    let workspace: String
    var edited = false

    private enum Block { case text(String), code(String), quote(String) }

    var body: some View {
        let blocks = Self.blocks(text)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                let last = i == blocks.count - 1
                switch block {
                case .code(let code):
                    FencedBlock(text: code, writing: false)
                    if last && edited { editedMark }
                case .quote(let quoted):
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5).fill(.white.opacity(0.3)).frame(width: 3)
                        inline(quoted, edited: last && edited)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .text(let t):
                    inline(t, edited: last && edited)
                }
            }
        }
    }

    private var editedMark: some View {
        Text("(edited)").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
    }

    @ViewBuilder private func inline(_ t: String, edited: Bool) -> some View {
        if Self.plain(t) {
            // Most messages have no formatting: plain text measures far faster than styled.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: t).font(.system(size: 12.5)).lineSpacing(2).foregroundStyle(.white.opacity(0.9))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if edited { editedMark.padding(.leading, 4) }
            }
        } else {
            rich(t, edited: edited)
        }
    }

    /// Nothing in it that would be shown differently from plain text.
    private static func plain(_ t: String) -> Bool {
        !t.contains { "*_~`[@#".contains($0) }
    }

    /// Styled text, worked out once per message and kept.
    private static var made: [String: AttributedString] = [:]

    private func rich(_ t: String, edited: Bool) -> some View {
        let key = workspace + "\u{0}" + t
        if Self.made[key] == nil {
            if Self.made.count > 600 { Self.made.removeAll() }
            Self.made[key] = Self.styled(t, workspace: workspace)
        }
        var out = Self.made[key]!
        if edited {
            var mark = AttributedString(" (edited)")
            mark.foregroundColor = .white.opacity(0.4)
            mark.font = .system(size: 10.5)
            out += mark
        }
        return Text(out).font(.system(size: 12.5)).lineSpacing(2).foregroundStyle(.white.opacity(0.9))
            .tint(Color(red: 0.45, green: 0.7, blue: 1))
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    /// Code blocks (```), quotes (> at the start of a line) and plain text, in order.
    private static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        let parts = text.components(separatedBy: "```")
        for (i, part) in parts.enumerated() {
            if i % 2 == 1 && i < parts.count - 1 {
                let code = part.trimmingCharacters(in: .newlines)
                if !code.isEmpty { out.append(.code(code)) }
                continue
            }
            var prose: [String] = [], quoted: [String] = []
            func flush() {
                let p = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
                if !p.isEmpty { out.append(.text(p)) }
                prose = []
                let q = quoted.joined(separator: "\n")
                if !q.isEmpty { out.append(.quote(q)) }
                quoted = []
            }
            for row in (i % 2 == 1 ? "```" + part : part).components(separatedBy: "\n") {
                if row.hasPrefix(">") {
                    if !prose.isEmpty { flush() }
                    quoted.append(String(row.dropFirst(row.hasPrefix("> ") ? 2 : 1)))
                } else {
                    if !quoted.isEmpty { flush() }
                    prose.append(row)
                }
            }
            flush()
        }
        return out
    }

    static func styled(_ text: String, workspace: String) -> AttributedString {
        var md = text
        md = md.replacingOccurrences(of: #"(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])"#, with: "**$1**", options: .regularExpression)
        md = md.replacingOccurrences(of: #"(?<![\w_/])_(?=\S)([^_\n]+?)(?<=\S)_(?![\w_])"#, with: "*$1*", options: .regularExpression)
        md = md.replacingOccurrences(of: #"(?<![\w~])~(?=\S)([^~\n]+?)(?<=\S)~(?![\w~])"#, with: "~~$1~~", options: .regularExpression)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var out = (try? AttributedString(markdown: md, options: options)) ?? AttributedString(text)
        for run in out.runs where run.link != nil { out[run.range].foregroundColor = Color(red: 0.45, green: 0.7, blue: 1) }
        for run in out.runs where run.inlinePresentationIntent?.contains(.code) == true {
            out[run.range].foregroundColor = Color(red: 0.95, green: 0.55, blue: 0.45)
            out[run.range].backgroundColor = .white.opacity(0.08)
        }
        let me = SlackSource.shared.myName(in: workspace)
        let names = Set(SlackDirectory.shared.targets.filter { $0.workspace == workspace && !$0.channel }.map(\.name))
            .union(me.map { [$0] } ?? []).union(["here", "channel", "everyone"])
        for name in names.sorted(by: { $0.count > $1.count }) where !name.isEmpty {
            var from = out.startIndex
            while let r = out[from...].range(of: "@" + name) {
                let mine = name == me || ["here", "channel", "everyone"].contains(name)
                out[r].foregroundColor = mine ? Color(red: 0.98, green: 0.84, blue: 0.45) : Color(red: 0.45, green: 0.7, blue: 1)
                out[r].backgroundColor = mine ? Color(red: 0.98, green: 0.84, blue: 0.45).opacity(0.18) : Color(red: 0.3, green: 0.55, blue: 1).opacity(0.15)
                from = r.upperBound
            }
        }
        return out
    }
}

/// A Slack thread, as Slack's own Thread panel: the message it hangs off, a line with the
/// number of replies, the replies (with "New" at the first unread one), and a box to reply in
/// the thread, with "Also send to" the conversation.
private struct SlackThreadView: View {
    let target: SlackTarget
    let parentTS: String
    /// The first message as the conversation has it, shown while the thread loads.
    var fallback: SlackLine?
    let close: () -> Void
    @Environment(NotchUI.self) private var ui
    @State private var state: String?
    @State private var sent = 0
    @State private var broadcast = false
    @State private var unreadAtOpen = 0
    @State private var landed = false

    private var draftKey: String { "thread:\(target.workspace):\(target.id):\(parentTS)" }
    private var key: String? { SlackSource.shared.threadKey(target, ts: parentTS) }
    private var lines: [SlackLine]? { key.flatMap { SlackConversations.shared.threads[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("Thread").font(.system(size: 13.5, weight: .bold)).foregroundStyle(.white)
                Text(target.label).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(Press()).help("Close thread")
            }
            .frame(height: 22)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        let all = lines ?? fallback.map { [$0] } ?? []
                        if let first = all.first {
                            SlackRow(line: first, workspace: target.workspace, continued: false,
                                     react: { name, add in SlackSource.shared.react(target, ts: first.id, name: name, add: add) },
                                     target: target)
                        } else {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 30)
                        }
                        let replies = Array(all.dropFirst())
                        if lines != nil {
                            HStack(spacing: 8) {
                                Text(replies.isEmpty ? "No replies yet" : replies.count == 1 ? "1 reply" : "\(replies.count) replies")
                                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                                Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                            }
                            .padding(.vertical, 5).padding(.horizontal, 6)
                        }
                        ForEach(Array(replies.enumerated()), id: \.element.viewKey) { i, line in
                            if unreadAtOpen > 0, i == replies.count - unreadAtOpen {
                                NewMessagesMark(whatsapp: false, count: unreadAtOpen).id("new")
                            }
                            SlackRow(line: line, workspace: target.workspace,
                                     continued: SlackComposer.continues(line, after: replies.prevLine(line)),
                                     react: { name, add in SlackSource.shared.react(target, ts: line.id, name: name, add: add) },
                                     target: target)
                                .id(line.viewKey)
                                .transition(line.mine ? .sent : .opacity)
                        }
                    }
                    .padding(.horizontal, 2).padding(.top, 8)
                }
                .onChange(of: lines?.last?.viewKey) { _, id in
                    guard let id else { return }
                    if !landed {
                        landed = true
                        // Opens at the first new reply, as Slack does; otherwise at the newest.
                        if unreadAtOpen > 0 { return proxy.scrollTo("new", anchor: .top) }
                        return proxy.scrollTo(id, anchor: .bottom)
                    }
                    follow(proxy, to: id)
                    if let key { SlackThreads.shared.read(key) }
                }
            }
            if state == "failed" {
                Text("Did not send.").font(.system(size: 11)).foregroundStyle(Palette.red)
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .bottom, spacing: 6) {
                    DraftText(store: ui.drafts, id: draftKey, placeholder: "Reply…", focusAsk: 1, onFocus: { _ in }, onSubmit: send, onTab: { false })
                        .fixedSize(horizontal: false, vertical: true)
                        .overlay(alignment: .topLeading) {
                            if !ui.drafts.hasText(draftKey) {
                                Text("Reply…").font(.system(size: 13)).foregroundStyle(.white.opacity(0.35)).allowsHitTesting(false)
                            }
                        }
                }
                HStack(spacing: 8) {
                    Toggle(isOn: $broadcast) {
                        HStack(spacing: 3) {
                            Text(target.channel ? "Also send to" : "Also send as direct message")
                                .foregroundStyle(.white.opacity(0.5))
                            if target.channel {
                                Text(target.label).fontWeight(.semibold).foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        .font(.system(size: 10.5)).lineLimit(1)
                    }
                    .toggleStyle(.checkbox).controlSize(.small)
                    Spacer(minLength: 0)
                    EmojiButton { ui.drafts[draftKey, default: ""] += $0 }
                    Button(action: send) {
                        Image(systemName: "paperplane.fill").font(.system(size: 12))
                            .symbolEffect(.bounce, value: sent)
                            .foregroundStyle(ui.drafts.hasText(draftKey) ? .white : .white.opacity(0.25))
                            .frame(width: 26, height: 22)
                            .background(ui.drafts.hasText(draftKey) ? Color(red: 0.0, green: 0.48, blue: 0.35) : .clear,
                                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(Press()).disabled(!ui.drafts.hasText(draftKey) || state == "sending")
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(.white.opacity(0.2), lineWidth: 1))
        }
        .background(.black)
        .onAppear {
            if let key {
                unreadAtOpen = SlackThreads.shared.unread(key)
                SlackThreads.shared.read(key)
            }
            SlackSource.shared.thread(target, ts: parentTS)
        }
        .task(id: parentTS) {
            // Replies from others keep arriving live; this is a backstop.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                SlackSource.shared.thread(target, ts: parentTS)
            }
        }
        .onExitCommand(perform: close)
    }

    private func send() {
        let text = (ui.drafts[draftKey] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, state != "sending" else { return }
        state = "sending"
        Settings.sentFeel()
        sent += 1
        ui.drafts[draftKey] = nil
        ui.touch(target)
        let also = broadcast
        broadcast = false
        // Shown at once, rising into place, while it goes.
        if let key {
            let id = "local-\(UUID().uuidString)"
            withAnimation(.sendSpring) {
                SlackConversations.shared.threads[key, default: fallback.map { [$0] } ?? []].append(
                    SlackLine(id: id, viewID: id, sender: SlackSource.shared.myName(in: target.workspace) ?? "You", mine: true, text: text,
                              picture: SlackSource.shared.myPicture(in: target.workspace), time: Date()))
            }
        }
        SlackSource.shared.replyInThread(target, ts: parentTS, text: text, broadcast: also) { ok in
            state = ok ? nil : "failed"
            if !ok { ui.drafts[draftKey] = text }
        }
    }
}

/// A small emoji picker for any reply box: tap one and it goes in where you are writing.
struct EmojiButton: View {
    let insert: (String) -> Void
    @State private var open = false
    static let common = ["😀", "😂", "🙂", "😉", "😍", "🥲", "😅", "🤔", "😎", "🙃", "😬", "😴",
                         "👍", "👎", "👏", "🙌", "🙏", "💪", "👀", "🤝", "👋", "✌️", "🤞", "🫡",
                         "❤️", "🔥", "🎉", "✅", "❌", "⚠️", "💯", "🚀", "⭐️", "💡", "📌", "⏰",
                         "😢", "😮", "😡", "🤯", "🥳", "🤣", "😇", "🤷", "🤦", "💀", "☕️", "🍻"]

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "face.smiling").font(.system(size: 13)).foregroundStyle(.white.opacity(open ? 0.85 : 0.45))
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(Press()).help("Emoji")
        .popover(isPresented: $open, arrowEdge: .top) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 2), count: 8), spacing: 2) {
                ForEach(Self.common, id: \.self) { e in
                    Button { insert(e) } label: {
                        Text(e).font(.system(size: 19)).frame(width: 30, height: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(Press())
                }
            }
            .padding(8)
        }
    }
}

/// A person's picture as Slack draws it: a rounded square.
private struct SquareFace: View {
    let url: URL?
    let name: String
    var size: CGFloat = 30
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            else {
                Color(white: 0.2).overlay(Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous).stroke(.black, lineWidth: size < 24 ? 1.5 : 0))
        .task(id: url) {
            guard let url, image == nil, let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            image = NSImage(data: data)
        }
    }
}

/// A small coloured tile naming a file's kind, like a document icon with "CSV" on it.
private struct FileBadge: View {
    let kind: String

    private var color: Color {
        switch kind.lowercased() {
        case "csv", "xls", "xlsx", "numbers", "gsheet": return Color(red: 0.2, green: 0.66, blue: 0.4)
        case "pdf": return Color(red: 0.88, green: 0.3, blue: 0.28)
        case "doc", "docx", "pages", "gdoc", "txt", "text", "rtf", "markdown", "md": return Color(red: 0.27, green: 0.5, blue: 0.92)
        case "ppt", "pptx", "key", "keynote", "gpres": return Color(red: 0.93, green: 0.48, blue: 0.22)
        case "zip", "gzip", "tar", "rar": return Color(white: 0.5)
        case "mp4", "mov", "mp3", "m4a", "wav": return Color(red: 0.6, green: 0.4, blue: 0.9)
        default: return Color(white: 0.42)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.gradient)
            Image(systemName: "doc.text").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                .frame(maxHeight: .infinity, alignment: .center).padding(.bottom, 10)
            Text(kind.isEmpty ? "FILE" : String(kind.uppercased().prefix(4)))
                .font(.system(size: 8, weight: .heavy)).foregroundStyle(.white).padding(.bottom, 5)
        }
        .frame(width: 34, height: 40)
    }
}

/// When a conversation last had a message: WhatsApp's own record, or when Slack last said something.
private func lastAt(_ t: SlackTarget) -> Double {
    if t.workspace == WhatsAppSource.workspace, let chat = WhatsAppSource.shared.chats.first(where: { $0.id == t.id }) {
        return chat.ts.timeIntervalSince1970
    }
    return NotchUI.shared.slackLastAt["\(t.workspace):\(t.id)"] ?? 0
}

/// A conversation's name: for WhatsApp, as the chat list has it now (contact name, or the name
/// they gave WhatsApp).
private func liveName(_ t: SlackTarget) -> String {
    guard t.workspace == WhatsAppSource.workspace,
          let chat = WhatsAppSource.shared.chats.first(where: { $0.id == t.id }), !chat.name.isEmpty else { return t.label }
    return chat.name
}

/// A conversation's picture: for WhatsApp, the profile picture as WhatsApp has it now.
private func livePicture(_ t: SlackTarget) -> URL? {
    t.workspace == WhatsAppSource.workspace ? (WhatsAppSource.shared.picture(for: t.id) ?? t.picture) : t.picture
}

/// Linking WhatsApp: a QR code to scan from the phone, as for WhatsApp Web.
private struct WhatsAppLinkView: View {
    @Environment(NotchUI.self) private var ui
    private var source: WhatsAppSource { WhatsAppSource.shared }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect WhatsApp").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Group {
                    switch source.state {
                    case .scan:
                        Text("On your phone, open WhatsApp, go to Settings, then Linked devices, tap Link a device, and scan this code.")
                    case .ready:
                        Text("Connected. Your chats are in the sidebar, and new messages come through here.")
                    case .failed(let why):
                        Text("That did not work: \(why)")
                    case .loggedOut:
                        Text("WhatsApp was unlinked. Connect again to carry on.")
                    default:
                        Text("Starting up…")
                    }
                }
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                Text("Perch joins as a linked device, like WhatsApp Web. Messages stay on this Mac.")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if case .loggedOut = source.state {
                        Button("Connect again") { source.connect() }.buttonStyle(ChipButton(fill: .white))
                    }
                    Button(source.state == .ready ? "Done" : "Close") { ui.showingWhatsAppLink = false }.buttonStyle(ChipButton())
                }
            }
            Spacer(minLength: 0)
            if case .scan(let code) = source.state, let image = Self.qr(code) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 190, height: 190)
                    .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if source.state == .ready {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(Palette.green).frame(width: 210, height: 120)
            } else {
                ProgressView().controlSize(.small).frame(width: 210, height: 120)
            }
        }
        .padding(16)
        .frame(width: 560)
        .onChange(of: source.state) { _, state in
            if state == .ready { DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { ui.showingWhatsAppLink = false } }
        }
    }

    private static func qr(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)))
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// How a message the user sends arrives: rising from the reply box, growing out of its corner.
struct SendRise: ViewModifier {
    let away: Bool
    func body(content: Content) -> some View {
        // Up out of the reply box, growing from its corner: no blur, so it stays crisp in flight.
        content
            .scaleEffect(away ? 0.95 : 1, anchor: .bottomTrailing)
            .offset(y: away ? 22 : 0)
            .opacity(away ? 0 : 1)
    }
}

struct ArriveRise: ViewModifier {
    let away: Bool
    func body(content: Content) -> some View {
        content.offset(y: away ? 10 : 0).opacity(away ? 0 : 1)
    }
}

/// Takes a chat to its newest message and keeps it there while that message lands: straight
/// away, once it has been laid out, and again after the reply box has shrunk back, all on the
/// send spring. A single scroll at the moment of sending lands short, under the typing bar.
func follow(_ proxy: ScrollViewProxy, to id: String, anchor: UnitPoint = .bottom) {
    withAnimation(.sendSpring) { proxy.scrollTo(id, anchor: anchor) }
    DispatchQueue.main.async { withAnimation(.sendSpring) { proxy.scrollTo(id, anchor: anchor) } }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { withAnimation(.sendSpring) { proxy.scrollTo(id, anchor: anchor) } }
}

/// The same for a conversation (Slack or WhatsApp): one smooth glide, once the new message has
/// been laid out, and a quiet correction only if a picture then pushed the end further down.
/// Three springs started on top of each other were what made the chat jolt.
func glide(_ proxy: ScrollViewProxy, to id: String, stillFollowing: @escaping () -> Bool) {
    DispatchQueue.main.async { withAnimation(.sendSpring) { proxy.scrollTo(id, anchor: .bottom) } }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
        guard !stillFollowing() else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
    }
}

extension Animation {
    /// One spring for a message going out: it carries the bubble up and the chat along with it,
    /// so the two move as one.
    static let sendSpring = Animation.spring(response: 0.3, dampingFraction: 0.86)
}

extension AnyTransition {
    /// Someone else's message coming in: a short rise from just below, fading up.
    static var arrived: AnyTransition {
        .asymmetric(insertion: .modifier(active: ArriveRise(away: true), identity: ArriveRise(away: false)), removal: .opacity)
    }

    static var sent: AnyTransition {
        .asymmetric(insertion: .modifier(active: SendRise(away: true), identity: SendRise(away: false)), removal: .opacity)
    }
}

/// A WhatsApp message as WhatsApp's dark theme draws it: green for the user's own, grey for
/// everyone else's, with the time and (on the user's own) the ticks tucked into the corner.
private struct WhatsAppBubble: View {
    let line: SlackLine
    var chat: String = ""
    @State private var hovered = false

    static let mine = Color(red: 0.0, green: 0.36, blue: 0.29)
    static let theirs = Color(red: 0.13, green: 0.17, blue: 0.2)

    /// The words, with the time (and ticks) tucked after the last line.
    private var words: some View { wordsOnly.overlay(alignment: .bottomTrailing) { stamp.padding(.trailing, 7).padding(.bottom, 4) } }

    private var wordsOnly: some View {
        Text(WhatsAppText.styled(line.text) + spacer)
            .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.95)).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 9).padding(.trailing, 9).padding(.top, 6).padding(.bottom, 7)
    }

    /// A photo or file sits inside the bubble, as in WhatsApp: the caption under it, and with
    /// no caption the time over the picture's corner.
    @ViewBuilder private var content: some View {
        if let quote = line.quote, line.files.isEmpty {
            // The time and ticks go in the bubble's corner, which the quote can make wider than
            // the reply itself, as WhatsApp does; not straight after a short reply's last word.
            VStack(alignment: .leading, spacing: 0) {
                WhatsAppQuote(quote: quote).padding([.horizontal, .top], 3)
                wordsOnly
            }
            .overlay(alignment: .bottomTrailing) { stamp.padding(.trailing, 7).padding(.bottom, 4) }
        } else if let quote = line.quote {
            VStack(alignment: .leading, spacing: 0) {
                WhatsAppQuote(quote: quote).padding([.horizontal, .top], 3)
                media
            }
        } else {
            media
        }
    }

    @ViewBuilder private var media: some View {
        if line.files.isEmpty {
            words
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(line.files) { file in
                    SlackFileView(file: file, bare: true)
                        .overlay(alignment: .bottomTrailing) {
                            if line.text.isEmpty && file.image {
                                stamp.padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(.black.opacity(0.45), in: Capsule()).padding(6)
                            }
                        }
                }
                if !line.text.isEmpty {
                    words
                } else if !(line.files.last?.image ?? false) {
                    HStack { Spacer(minLength: 0); stamp }.padding(.horizontal, 6).padding(.bottom, 3)
                }
            }
            // As wide as the picture or file, with the caption wrapping under it in full.
            .frame(width: 260, alignment: .leading)
            .padding(3)
        }
    }

    @State private var reacting = false

    var body: some View {
        // The reaction face sits beside the bubble on its open side, as in WhatsApp.
        HStack(alignment: .center, spacing: 6) {
            if line.mine { face }
            bubble
            if !line.mine { face }
        }
        .contentShape(Rectangle())
        .onHover { over in withAnimation(.easeOut(duration: 0.12)) { hovered = over } }
        .zIndex(reacting ? 5 : 0)
    }

    @ViewBuilder private var face: some View {
        if !chat.isEmpty, !line.id.hasPrefix("local-") {
            ReactFace(hovered: hovered, open: $reacting, opensRight: line.mine) { emoji in
                WhatsAppSource.shared.react(chat: chat, id: line.id, emoji: emoji)
            }
        }
    }

    private var bubble: some View {
        content
            .background(line.mine ? Self.mine : Self.theirs, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            // Reactions sit on the bottom edge, as in WhatsApp.
            .overlay(alignment: line.mine ? .bottomTrailing : .bottomLeading) {
                if !line.reactions.isEmpty {
                    let counts = Dictionary(grouping: line.reactions.values, by: { $0 }).mapValues(\.count)
                    HStack(spacing: 2) {
                        ForEach(counts.keys.sorted(), id: \.self) { e in
                            Text(counts[e]! > 1 ? "\(e) \(counts[e]!)" : e).font(.system(size: 11))
                                // Each emoji pops in on its own, so a change reads as a change.
                                .transition(.scale(scale: 0.2).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color(white: 0.2), in: Capsule())
                    .overlay(Capsule().stroke(.black, lineWidth: 1.5))
                    .offset(x: line.mine ? -8 : 8, y: 14)
                    // Lands on the message with a little bounce, from where the reaction was picked.
                    .transition(.scale(scale: 0.3, anchor: line.mine ? .bottomTrailing : .bottomLeading).combined(with: .opacity))
                }
            }
            .padding(.bottom, line.reactions.isEmpty ? 0 : 14)
            .animation(.spring(response: 0.38, dampingFraction: 0.55), value: line.reactions)
    }

    /// Invisible text as wide as the time and ticks, so the last line always leaves room for them.
    private var spacer: AttributedString {
        var gap = AttributedString("\u{2002}\u{2002}" + (line.time?.formatted(.dateTime.hour().minute()) ?? "") + (line.mine ? "\u{2009}✓✓" : ""))
        gap.foregroundColor = .clear
        gap.font = .system(size: 9.5)
        return gap
    }

    private var stamp: some View {
        HStack(spacing: 3) {
            if let time = line.time {
                Text(time.formatted(.dateTime.hour().minute())).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.55))
            }
            if line.mine, let ticks = line.ticks { Ticks(level: ticks) }
        }
    }
}

/// A WhatsApp banner's recent messages, as small bubbles: theirs on the left, yours in green on
/// the right with ticks, the way the chat itself looks.
private struct BannerThread: View {
    let lines: [SlackLine]
    let group: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(lines, id: \.viewKey) { line in
                HStack(spacing: 0) {
                    if line.mine { Spacer(minLength: 36) }
                    VStack(alignment: .leading, spacing: 1) {
                        if group && !line.mine && !line.sender.isEmpty {
                            Text(line.sender).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.colors[3])
                        }
                        HStack(alignment: .lastTextBaseline, spacing: 6) {
                            // In full: a long message cut to a few lines lost its ending.
                            Text(WhatsAppText.styled(words(line))).font(.system(size: 12)).foregroundStyle(.white.opacity(0.95))
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 3) {
                                if let time = line.time {
                                    Text(time.formatted(.dateTime.hour().minute())).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                                }
                                if line.mine, let ticks = line.ticks { Ticks(level: ticks) }
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(line.mine ? WhatsAppBubble.mine : WhatsAppBubble.theirs,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    if !line.mine { Spacer(minLength: 36) }
                }
            }
        }
    }

    private func words(_ line: SlackLine) -> String {
        if !line.text.isEmpty { return line.text }
        guard let file = line.files.first else { return "Message" }
        return file.image ? "Photo" : file.kind.capitalized
    }
}

/// The message a WhatsApp reply quotes, as a tinted block with a coloured edge, as in WhatsApp.
struct WhatsAppQuote: View {
    let quote: SlackQuote
    var closable: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Self.accent).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(quote.sender.isEmpty ? "Message" : quote.sender)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Self.accent).lineLimit(1)
                Text(oneLine(quote.text, max: 200)).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.65))
                    .lineLimit(2).truncationMode(.tail)
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            Spacer(minLength: 0)
            if let closable {
                Button(action: closable) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(Press()).padding(.trailing, 4).help("Cancel the reply")
            }
        }
        .background(.black.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        // Only as tall as its lines (the coloured edge would otherwise stretch to fill), and as
        // wide as a bubble, or the whole reply box when it is the reply being written.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: closable == nil ? 260 : .infinity, alignment: .leading)
    }

    static let accent = Color(red: 0.33, green: 0.85, blue: 0.62)
}

/// A row of quick reactions for a WhatsApp message; the one already chosen is ringed, and
/// choosing it again takes it away.
struct WhatsAppReactions: View {
    let chat: String
    let id: String
    let mine: String?
    static let quick = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Self.quick, id: \.self) { e in
                Button { WhatsAppSource.shared.react(chat: chat, id: id, emoji: e) } label: {
                    Text(e).font(.system(size: 14)).frame(width: 26, height: 24)
                        .background(mine == e ? Color.white.opacity(0.22) : .clear, in: Circle())
                }
                .buttonStyle(Press(reach: 1))
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(Color(white: 0.16), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
    }
}

/// WhatsApp's ticks: one grey once sent, two grey once delivered, two blue once read.
struct Ticks: View {
    let level: Int
    var size: CGFloat = 9

    var body: some View {
        let color = level >= 3 ? Color(red: 0.33, green: 0.74, blue: 0.92) : .white.opacity(0.55)
        if level <= 0 {
            // Still on its way.
            Image(systemName: "clock").font(.system(size: size * 0.9)).foregroundStyle(color).frame(width: size * 1.5, alignment: .leading)
        } else {
        ZStack(alignment: .leading) {
            Image(systemName: "checkmark").font(.system(size: size, weight: .bold))
            if level >= 2 {
                Image(systemName: "checkmark").font(.system(size: size, weight: .bold)).offset(x: size * 0.45)
            }
        }
        .foregroundStyle(color)
        .frame(width: size * (level >= 2 ? 1.5 : 1.05), alignment: .leading)
        }
    }
}

/// WhatsApp's own formatting (*bold*, _italic_, ~strike~, `code`) into styled text.
enum WhatsAppText {
    static func styled(_ text: String) -> AttributedString {
        var md = text
        md = md.replacingOccurrences(of: #"(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])"#, with: "**$1**", options: .regularExpression)
        md = md.replacingOccurrences(of: #"(?<![\w_])_(?=\S)([^_\n]+?)(?<=\S)_(?![\w_])"#, with: "*$1*", options: .regularExpression)
        md = md.replacingOccurrences(of: #"(?<![\w~])~(?=\S)([^~\n]+?)(?<=\S)~(?![\w~])"#, with: "~~$1~~", options: .regularExpression)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: md, options: options)) ?? AttributedString(text)
    }
}

/// A file shared in Slack: pictures as a preview, anything else as a chip. Clicking opens it;
/// when the workspace's key can't read files, it opens in Slack instead.
private struct SlackFileView: View {
    let file: SlackFile
    /// Inside a WhatsApp bubble: tighter corners and no card of its own.
    var bare = false
    @State private var failed = false
    @Environment(NotchUI.self) private var ui
    @State private var image: NSImage?
    @State private var hovered = false
    @State private var opening = false

    var body: some View {
        Group {
            if file.kind == "audio" {
                VoiceMessageView(file: file)
            } else if file.image, let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: bare ? 260 : 300, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: bare ? 6 : 10, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if hovered { SaveButton { save() } }
                    }
            } else {
                HStack(spacing: 10) {
                    FileBadge(kind: file.kind)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                            .lineLimit(2).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
                        if failed {
                            // Said on the card, with the way out, rather than jumping into Slack.
                            HStack(spacing: 6) {
                                Text("Could not download").font(.system(size: 10.5)).foregroundStyle(Palette.red)
                                if file.link != nil { Button("Open in Slack") { openInSlack() }.buttonStyle(LinkButton()) }
                            }
                        } else {
                            Text(details).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    Spacer(minLength: 4)
                    Group {
                        if opening { ProgressView().controlSize(.mini) }
                        else {
                            Button(action: save) {
                                Image(systemName: "arrow.down.to.line").font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.75)).frame(width: 24, height: 24)
                                    .background(.white.opacity(0.1), in: Circle())
                            }
                            .buttonStyle(Press()).help("Save to Downloads")
                            .opacity(hovered ? 1 : 0)
                        }
                    }
                    .frame(width: 24)
                }
                .padding(.leading, 9).padding(.trailing, 10).padding(.vertical, 9)
                .frame(width: bare ? 260 : 270, alignment: .leading)
                // Inside a message bubble: a darker strip, as WhatsApp draws a file in a bubble.
                .background(bare ? Color.black.opacity(hovered ? 0.28 : 0.2) : Color(white: hovered ? 0.2 : 0.16),
                            in: RoundedRectangle(cornerRadius: bare ? 6 : 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(bare ? 0 : 0.08), lineWidth: 1))
                .animation(.easeOut(duration: 0.12), value: hovered)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture {
            guard file.kind != "audio" else { return }
            guard file.image, let image else { return open() }
            // The preview first, swapped for the full picture once it has downloaded.
            ui.enlarge(image, name: file.name, side: false)
            download { data in
                if let data, let full = NSImage(data: data), ImageViewer.shared.name == file.name {
                    ui.enlarge(full, name: file.name, side: false)
                }
            }
        }
        .help(file.image ? "Enlarge" : "Open \(file.name)")
        .task(id: file.id) {
            // The small preview that came with the message shows at once; the full picture follows.
            if image == nil, let preview = file.preview { image = NSImage(data: preview) }
            guard file.image, let thumb = file.thumb ?? file.url else { return }
            SlackSource.shared.fetch(thumb, workspace: file.workspace) { data in
                if let full = data.flatMap(NSImage.init(data:)) { image = full }
            }
        }
    }

    /// "CSV · 24 KB"
    private var details: String {
        let kind = file.kind.isEmpty ? "File" : file.kind.uppercased()
        guard file.size > 0 else { return kind }
        return "\(kind) · " + ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
    }

    private func download(_ done: @escaping (Data?) -> Void) {
        guard let url = file.url else { return done(nil) }
        opening = true
        SlackSource.shared.fetch(url, workspace: file.workspace) { data in
            opening = false
            done(data)
        }
    }

    private func open() {
        download { data in
            guard let data else { return failed = true }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perch-slack/\(file.id)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent(file.name)
            guard (try? data.write(to: target)) != nil else { return openInSlack() }
            NSWorkspace.shared.open(target)
        }
    }

    private func save() {
        download { data in
            guard let data else { return failed = true }
            guard (try? data.write(to: freeDownloadsURL(file.name))) != nil else { return NSSound.beep() }
        }
    }

    private func openInSlack() {
        if let link = file.link { NSWorkspace.shared.open(link) } else { NSSound.beep() }
    }
}

private func notificationMediaSymbol(_ kind: String) -> String? {
    switch kind.lowercased() {
    case "image", "sticker": return "camera.fill"
    case "video": return "video.fill"
    case "audio": return "mic.fill"
    case "document": return "doc.fill"
    case "reaction": return "face.smiling"
    default: return nil
    }
}

/// Notification content retains the caption and makes attachments visible before opening a chat.
private struct NotificationMessagePreview: View {
    let alert: SlackAlert
    var compact = false
    var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            VStack(alignment: .leading, spacing: 4) {
                if let file = alert.files.first {
                    Label(file.image ? "Photo" : file.kind.capitalized,
                          systemImage: file.image ? "photo" : (notificationMediaSymbol(file.kind) ?? "paperclip"))
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                }
                if !alert.text.isEmpty && !(alert.files.first?.image == true && alert.text == "Photo") {
                    Text(WhatsAppText.styled(alert.text))
                        .font(.system(size: compact ? 11.5 : 12)).foregroundStyle(.white.opacity(0.85))
                        .lineLimit(expanded ? 40 : compact ? 3 : 6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let data = alert.files.first?.preview, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: compact ? 56 : 92, height: compact ? 56 : 76)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

/// A message from another chat while one is open: who and what, sliding down over the top of
/// the island. Click to go to it; it slips away by itself after a few seconds.
private struct ToastBanner: View {
    @Environment(NotchUI.self) private var ui
    @Environment(AgentStore.self) private var store

    var body: some View {
        if let toast = ui.toast {
            HStack(spacing: 10) {
                switch toast {
                case .agent(let id):
                    if let agent = store.find(id) {
                        FaceView(agent: agent, size: 26)
                        lines(agent.name, agent.lastMessage.isEmpty ? agent.detail : agent.lastMessage)
                    }
                case .slack(let alert):
                    SlackAvatar(url: alert.workspace == WhatsAppSource.workspace ? livePicture(alert.target) : alert.picture,
                                channel: false, size: 26, whatsapp: alert.workspace == WhatsAppSource.workspace)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(alert.direct ? alert.sender : "\(alert.sender) in \(alert.place)")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        NotificationMessagePreview(alert: alert, compact: true)
                    }
                }
                Spacer(minLength: 4)
                Button {
                    withAnimation(.easeIn(duration: 0.15)) { ui.toast = nil }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(Press())
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: 440)
            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
            .contentShape(Rectangle())
            .onTapGesture { open(toast) }
            .onHover { ui.toastHovered = $0 }
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(toast.key)
        }
    }

    private func lines(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Text(bannerText(oneLine(text, max: 140))).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
        }
    }

    private func open(_ toast: NotchUI.Toast) {
        withAnimation(.easeIn(duration: 0.15)) { ui.toast = nil }
        switch toast {
        case .agent(let id):
            ui.select(id)
        case .slack(let alert) where alert.workspace == WhatsAppSource.workspace:
            ui.openSlack(alert.target)
        case .slack(let alert):
            // Into that conversation in the notch, if Perch knows it; otherwise Slack itself.
            let store = SlackConversations.shared
            let directory = SlackDirectory.shared.targets.filter { $0.workspace == alert.workspace }
            let person = store.dmChannel.first { $0.value == alert.channel && $0.key.hasPrefix("\(alert.workspace):") }
                .map { String($0.key.dropFirst(alert.workspace.count + 1)) }
            if let target = directory.first(where: { $0.id == (person ?? alert.channel) }) {
                ui.openSlack(target, thread: alert.threadParent)
            } else if let link = alert.link {
                NSWorkspace.shared.open(link)
            }
        }
    }
}

/// A Slack message in the notch: who, where, and what they said. Click to open it in Slack.
/// A meeting about to start: what it is, when, and one click to join it with Granola taking notes.
private struct MeetingBanner: View {
    let meeting: Meeting
    @Environment(NotchUI.self) private var ui

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            HStack(spacing: 11) {
                Image(systemName: "video.fill").font(.system(size: 14)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(Color(red: 0.2, green: 0.55, blue: 0.95), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(Self.when(meeting.start, now: context.date) + " · " + meeting.service)
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 6)
                Button {
                    MeetingWatch.join(meeting, granola: true)
                    ui.endMeetingAlert()
                } label: {
                    Text("Join + Granola").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 11).padding(.vertical, 6).background(.white, in: Capsule())
                }
                .buttonStyle(Press())
                Button {
                    MeetingWatch.join(meeting, granola: false)
                    ui.endMeetingAlert()
                } label: {
                    Text("Join").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(Press())
                Button { ui.endMeetingAlert() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(Press()).help("Dismiss")
            }
            .padding(10)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    static func when(_ start: Date, now: Date) -> String {
        let s = Int(start.timeIntervalSince(now))
        if s > 60 { return "Starts in \(Int((Double(s) / 60).rounded())) min" }
        if s > 0 { return "Starts in under a minute" }
        if s > -60 { return "Starting now" }
        return "Started \(-s / 60) min ago"
    }
}

/// Keyboard cleaning mode is on: say so, show how long is left, and unlock with a click.
private struct KeyboardLockCard: View {
    var body: some View {
        let lock = KeyboardLock.shared
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 11) {
                Image(systemName: "keyboard.badge.ellipsis").font(.system(size: 15)).foregroundStyle(.white)
                    .frame(width: 34, height: 34).background(Color(red: 0.95, green: 0.55, blue: 0.2), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keyboard locked for cleaning").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    let left = max(0, Int(lock.until.timeIntervalSince(context.date)))
                    Text("Unlocks by itself in \(left / 60):\(String(format: "%02d", left % 60))")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).monospacedDigit()
                }
                Spacer(minLength: 8)
                Button { lock.unlock() } label: {
                    Text("Unlock").font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 14).padding(.vertical, 7).background(.white, in: Capsule())
                }
                .buttonStyle(Press())
            }
            .padding(10)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// One quiet line under a chat's header: where the work has got to. Working, what it is doing
/// right now; otherwise the opening of its latest update. Read from the chat itself, so it costs
/// no tokens.
private struct StatusLine: View {
    let agent: Agent
    let messages: [ChatMessage]

    /// Where the work has got to, broadest first: the chat's own step list ("3 of 6 done ·
    /// Building the streams"), else the opening of its latest update, and only failing both
    /// whatever it is doing this second.
    private var text: String? {
        let steps = agent.steps
        let done = steps.filter { $0.status == "completed" }.count
        if !steps.isEmpty, done < steps.count {
            let now = steps.first { $0.status == "in_progress" }.map(\.doing)
                ?? steps.first { $0.status == "pending" }.map { "Next: \($0.subject)" } ?? ""
            return "\(done) of \(steps.count) done" + (now.isEmpty ? "" : " · \(now)")
        }
        if let latest = messages.last(where: { !$0.fromUser && !$0.text.isEmpty })?.text {
            let line = oneLine(latest.replacingOccurrences(of: "**", with: ""), max: 400)
            // The first sentence says where things are; the rest is detail.
            if let end = line.firstIndex(where: { ".!?".contains($0) }), line.distance(from: line.startIndex, to: end) > 20 {
                return String(line[...end])
            }
            return line
        }
        if agent.status == .working { return agent.activity ?? (agent.detail.isEmpty ? nil : agent.detail) }
        return nil
    }

    var body: some View {
        if let text {
            HStack(spacing: 6) {
                Circle().fill(agent.status == .working ? Palette.green : .white.opacity(0.3)).frame(width: 5, height: 5)
                Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 2)
            .help(text)
            .animation(.easeOut(duration: 0.2), value: text)
        }
    }
}

/// The reactions offered on a banner, with Slack's name for each.
enum BannerReactions {
    static let quick: [(emoji: String, slack: String)] = [("👍", "+1"), ("❤️", "heart"), ("😂", "joy"), ("😮", "open_mouth"),
                                                         ("🙏", "pray")]
}

private struct SlackBanner: View {
    let alert: SlackAlert
    @Environment(NotchUI.self) private var ui
    @State private var hovered = false
    @State private var reacted: String?
    @State private var reacting = false
    @FocusState private var focused: Bool

    private var key: String { NotchUI.bannerKey(alert) }
    private var reply: Binding<String> { Binding(get: { ui.drafts[key] ?? "" }, set: { ui.drafts[key] = $0 }) }
    private var failed: Bool { ui.bannerFailed.contains(key) }
    private var sent: [NotchUI.BannerMessage] { ui.bannerSent[key] ?? [] }

    /// The WhatsApp chat's latest messages, loaded from the helper, so new ones appear here live.
    private var thread: [SlackLine] {
        guard alert.workspace == WhatsAppSource.workspace else { return [] }
        let store = SlackConversations.shared
        return store.lines[store.key(alert.workspace, alert.target.id)] ?? []
    }

    @State private var previewHeight: CGFloat = 36
    private static let chatHeight: CGFloat = 230
    private var chatOpen: Bool { !thread.isEmpty && !ui.bannerFolding && (hovered || focused || !sent.isEmpty) }

    /// The notification as it arrives: any earlier lines in a burst, then the newest message.
    @ViewBuilder private var preview: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !alert.earlier.isEmpty {
                ForEach(Array(alert.earlier.enumerated()), id: \.offset) { _, text in
                    Text(WhatsAppText.styled(oneLine(text, max: 200))).font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6)).lineLimit(hovered && thread.isEmpty ? 4 : 1)
                }
            }
            NotificationMessagePreview(alert: alert, expanded: hovered && thread.isEmpty)
        }
    }

    private var unlanded: [NotchUI.BannerMessage] {
        let mine = Set(thread.filter(\.mine).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) })
        return sent.filter { !$0.sent || !mine.contains($0.text) }
    }

    /// The chat as bubbles, with what the user has just sent already in it as their own bubble
    /// (a clock until it goes). The real message takes over the same bubble when it lands, so
    /// nothing changes style or jumps.
    private var bubbles: [SlackLine] {
        var lines = Array(thread.suffix(40))
        var waiting = sent
        // Newest first, so the copy that landed is matched to the message just sent.
        for i in lines.indices.reversed() where lines[i].mine {
            let text = lines[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let j = waiting.lastIndex(where: { $0.sent && $0.text == text }) {
                lines[i].viewID = "banner-\(waiting[j].id)"
                waiting.remove(at: j)
            }
        }
        for message in waiting {
            let label = message.files.isEmpty ? message.text
                : [message.files.count == 1 ? "📷 Photo" : "📷 \(message.files.count) photos", message.text].filter { !$0.isEmpty }.joined(separator: " ")
            var line = SlackLine(id: "banner-\(message.id)", sender: "", mine: true, text: label)
            line.time = Date()
            line.ticks = message.sent ? 1 : 0
            lines.append(line)
        }
        return lines
    }

    /// Hover in and out with a short pause, so brushing the edge does not flick the chat open
    /// and shut.
    @State private var hoverWork: DispatchWorkItem?
    private func hover(_ over: Bool) {
        hoverWork?.cancel()
        guard over != hovered else { return }
        let work = DispatchWorkItem { withAnimation(.smooth(duration: 0.34)) { hovered = over } }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (over ? 0.15 : 0.45), execute: work)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            card
            waitingList
        }
        // Moved on from replying to someone else: the keyboard carries on here.
        .onAppear {
            if ui.controller?.panel.isKeyWindow == true { DispatchQueue.main.async { focused = true } }
        }
        .task(id: alert.target.id) {
            if alert.workspace == WhatsAppSource.workspace { SlackSource.shared.history(for: alert.target) }
        }
        .onChange(of: chatOpen, initial: true) { _, open in ui.bannerChatOpen = open }
        .onDisappear { ui.bannerChatOpen = false }
        // Replying here is reading: what arrives while the box has the keyboard is read too.
        .onChange(of: thread.last?.viewKey) {
            guard ui.controller?.panel.isKeyWindow == true, thread.last?.mine == false else { return }
            SlackSource.shared.markRead(alert.target, upTo: alert.ts)
        }
    }

    private func react(_ q: (emoji: String, slack: String)) {
        reacted = q.emoji
        Settings.sentFeel()
        if alert.workspace == WhatsAppSource.workspace {
            WhatsAppSource.shared.react(chat: alert.channel, id: alert.ts, emoji: q.emoji)
        } else {
            SlackSource.shared.react(alert.target, ts: alert.ts, name: q.slack, add: true)
        }
        SlackSource.shared.markRead(alert.target, upTo: alert.ts)
        ui.slackUnread["\(alert.target.workspace):\(alert.target.id)"] = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { ui.nextBanner(after: alert.target) }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                SlackAvatar(url: alert.workspace == WhatsAppSource.workspace ? livePicture(alert.target) : alert.picture,
                            channel: false, size: 30, whatsapp: alert.workspace == WhatsAppSource.workspace)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(alert.sender).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        Text(alert.workspace == WhatsAppSource.workspace ? alert.place : "\(alert.place) · \(alert.workspace.capitalized)").font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                        Spacer(minLength: 0)
                        if !alert.earlier.isEmpty {
                            Text("\(alert.earlier.count + 1) messages").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                        }
                        // React to the newest message: a small icon, the choices in a pop-up.
                        Button { reacting.toggle() } label: {
                            Image(systemName: "face.smiling").font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(reacting ? 0.9 : 0.5))
                        }
                        .buttonStyle(Press()).help("React")
                        .popover(isPresented: $reacting, arrowEdge: .bottom) {
                            HStack(spacing: 2) {
                                ForEach(BannerReactions.quick, id: \.emoji) { q in
                                    Button { reacting = false; react(q) } label: {
                                        Text(q.emoji).font(.system(size: 18)).frame(width: 32, height: 30).contentShape(Rectangle())
                                    }
                                    .buttonStyle(Press())
                                }
                            }
                            .padding(5)
                        }
                        Button {
                            if alert.workspace == WhatsAppSource.workspace {
                                ui.openConversation(alert.target, thread: alert.threadParent)
                            } else {
                                if let link = alert.link { NSWorkspace.shared.open(link) }
                                ui.collapse()
                            }
                        } label: {
                            Image(systemName: "arrow.up.forward.app").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                        }
                        .buttonStyle(Press()).help(alert.workspace == WhatsAppSource.workspace ? "Open the chat" : "Open in Slack")
                    }
                    if thread.isEmpty {
                        preview
                    } else {
                        // WhatsApp: it arrives as the notification, then grows into the chat itself
                        // (bubbles, yours included, scrollable) when the user comes to it. One
                        // block changes height while the two fade across, so it opens in one smooth
                        // movement rather than swapping layouts.
                        ZStack(alignment: .top) {
                            preview
                                .fixedSize(horizontal: false, vertical: true)
                                .background(GeometryReader { g in
                                    Color.clear.onAppear { previewHeight = g.size.height }
                                        .onChange(of: g.size.height) { _, h in previewHeight = h }
                                })
                                .opacity(chatOpen ? 0 : 1)
                            ScrollViewReader { reader in
                                ScrollView(.vertical, showsIndicators: false) {
                                    BannerThread(lines: bubbles, group: alert.channel.hasSuffix("@g.us"))
                                        .padding(.vertical, 2)
                                    Color.clear.frame(height: 1).id("end")
                                }
                                .defaultScrollAnchor(.bottom)
                                // A new message slides the chat up smoothly rather than jumping.
                                .onChange(of: bubbles.last?.viewKey) {
                                    withAnimation(.smooth(duration: 0.3)) { reader.scrollTo("end", anchor: .bottom) }
                                }
                            }
                            .frame(height: Self.chatHeight)
                            .opacity(chatOpen ? 1 : 0)
                            .allowsHitTesting(chatOpen)
                        }
                        .frame(height: chatOpen ? Self.chatHeight : previewHeight, alignment: .top)
                        .clipped()
                        // Messages scrolling up fade out at the top edge rather than being cut.
                        .mask {
                            VStack(spacing: 0) {
                                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: chatOpen ? 12 : 0)
                                Color.black
                            }
                        }
                        // Open, the chat takes the banner's full width, so their messages start
                        // at the left edge as in WhatsApp rather than indented past the picture;
                        // it starts below the picture, so nothing scrolls up over it.
                        .padding(.top, chatOpen ? 14 : 0)
                        .padding(.leading, chatOpen ? -40 : 0)
                    }
                }
            }
            // A click anywhere but the reply box opens the chat, in Perch.
            .contentShape(Rectangle())
            .onTapGesture { ui.openConversation(alert.target, thread: alert.threadParent) }
            // Reply straight from here; it posts as you, in the same conversation or thread.
            // What has gone so far, with the box still open underneath for another message. In a
            // WhatsApp chat shown as bubbles, only what has not yet landed in it.
            if thread.isEmpty && !unlanded.isEmpty {
                VStack(alignment: .trailing, spacing: 3) {
                    ForEach(unlanded) { message in
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(oneLine(message.text, max: 200)).font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                            Image(systemName: message.sent ? "checkmark" : "clock").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(message.sent ? Palette.green : .white.opacity(0.4))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let reacted {
                Text("Reacted \(reacted)").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.green)
            } else {
                if !pictures.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(pictures) { picture in
                                Image(nsImage: picture.thumbnail).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    .overlay(alignment: .topTrailing) {
                                        Button { ui.bannerFiles[key]?.removeAll { $0.id == picture.id } } label: {
                                            Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                                                .foregroundStyle(.white, .black.opacity(0.6))
                                        }
                                        .buttonStyle(Press(reach: 1)).offset(x: 4, y: -4)
                                    }
                            }
                        }
                        .padding(.top, 4).padding(.trailing, 4)
                    }
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                HStack(spacing: 6) {
                    TextField(failed ? "Did not send. Try again, or open Slack" : sent.isEmpty ? "Reply to \(alert.sender)" : "Send another",
                              text: reply)
                        .textFieldStyle(.plain).font(.system(size: 12)).focused($focused)
                        .onSubmit(send)
                    EmojiButton { reply.wrappedValue += $0 }
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 15))
                            .foregroundStyle(reply.wrappedValue.isEmpty && pictures.isEmpty ? .white.opacity(0.25) : .white)
                    }
                    .buttonStyle(Press()).disabled(reply.wrappedValue.isEmpty && pictures.isEmpty)
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded {
                    ui.controller?.panel.makeKey()
                    focused = true
                })
                if failed {
                    // Said plainly, with Slack's reason, so a reply never just sits there.
                    Text(failure)
                        .font(.system(size: 10.5)).foregroundStyle(Palette.red).padding(.top, 4)
                }
            }
        }
        .padding(10)
        .background(.white.opacity(hovered ? 0.1 : 0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover(perform: hover)
        .animation(.easeOut(duration: 0.15), value: thread.isEmpty ? sent.count : 0)
        .animation(.smooth(duration: 0.34), value: focused)
    }

    /// Whatever came in meanwhile, so nothing is missed while replying. Click one to see it.
    @ViewBuilder private var waitingList: some View {
        if !ui.slackQueue.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ui.slackQueue.prefix(3)) { waiting in
                    HStack(spacing: 7) {
                        SlackAvatar(url: waiting.workspace == WhatsAppSource.workspace ? livePicture(waiting.target) : waiting.picture,
                                    channel: false, size: 18, whatsapp: waiting.workspace == WhatsAppSource.workspace, sidebar: true)
                        Text(waiting.sender).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1).fixedSize()
                        Text(WhatsAppText.styled(oneLine(waiting.text, max: 120))).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { ui.showQueued(waiting) }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if ui.slackQueue.count > 3 {
                    Text("\(ui.slackQueue.count - 3) more").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                        .padding(.leading, 8)
                }
            }
            .padding(.top, 5)
        }
    }

    private func send() {
        let text = reply.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = pictures.map { URL(fileURLWithPath: $0.path) }
        guard !text.isEmpty || !files.isEmpty else { return }
        reply.wrappedValue = ""
        ui.bannerFiles[key] = nil
        Settings.sentFeel()
        ui.touch(alert.target)
        ui.sendFromBanner(alert, text: text, files: files)
        focused = true
    }

    /// Pictures pasted into the reply box with Cmd+V.
    private var pictures: [Attachment] { ui.bannerFiles[key] ?? [] }

    /// Why the reply did not go, in Slack's words where it gave any.
    private var failure: String {
        let raw = SlackSource.status["\(alert.workspace) error"] ?? ""
        let reason = raw.split(separator: " ").dropFirst().joined(separator: " ")
        return reason.isEmpty ? "Did not send. Press Return to try again." : "Did not send (\(reason)). Press Return to try again."
    }
}

// MARK: Growing text box

// MARK: Side panel

private struct SideWindowKey: EnvironmentKey { static let defaultValue: NSWindow? = nil }

extension EnvironmentValues {
    /// Set inside the side panel: its window, which takes the keyboard instead of the notch.
    var sideWindow: NSWindow? {
        get { self[SideWindowKey.self] }
        set { self[SideWindowKey.self] = newValue }
    }
}

final class SidePanelWindow: NSPanel {
    /// A panel put back after a relaunch must not take the keyboard from whatever the user is
    /// typing in. It only can once they click into it.
    var waitsForClick = false
    override var canBecomeKey: Bool { !waitsForClick }

    override func sendEvent(_ event: NSEvent) {
        if waitsForClick, event.type == .leftMouseDown || event.type == .rightMouseDown {
            waitsForClick = false
            makeKey()
        }
        super.sendEvent(event)
    }

    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        if firstResponder is NSTextView { FrontApp.take(for: self) }
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let done = super.makeFirstResponder(responder)
        if done, responder is NSTextView { FrontApp.take(for: self) }
        return done
    }
}

/// One chat kept open in a slim floating panel down the right of the screen, so instructions
/// stay in view while the user works through them in another app. It floats above other
/// windows, stays put until closed, can be dragged anywhere, and never steals focus until clicked.
final class SidePanel {
    static let shared = SidePanel()
    private var window: SidePanelWindow?
    /// The chat the side panel is showing, for pictures pasted into it.
    private(set) var agentID: String?
    /// Or the Slack or WhatsApp conversation it is showing.
    private(set) var conversation: SlackTarget?

    /// Whether this conversation is open in the panel right now (so it counts as being read).
    func showing(_ workspace: String, _ id: String) -> Bool {
        window != nil && conversation?.workspace == workspace && conversation?.id == id
    }

    private static let savedKey = "sidePanel"
    private var moves: [NSObjectProtocol] = []

    /// Puts back the panel that was open when Perch last quit, once its chat has loaded.
    func restore(tries: Int = 0) {
        guard window == nil, let saved = UserDefaults.standard.dictionary(forKey: Self.savedKey) else { return }
        let frame = NSRectFromString(saved["frame"] as? String ?? "")
        let fits = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        if let c = saved["conversation"] as? [String: String], let w = c["w"], let id = c["id"] {
            let t = SlackTarget(workspace: w, id: id, name: c["name"] ?? "", channel: c["c"] == "1",
                                picture: c["p"].flatMap(URL.init(string:)))
            return show(conversation: t, at: fits && frame.width > 0 ? frame : nil, quietly: true)
        }
        guard let id = saved["agent"] as? String else { return }
        guard let agent = AgentStore.shared.agents.first(where: { $0.id == id }) else {
            // Chats arrive over the first few seconds; give up after a minute.
            if tries < 60 { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.restore(tries: tries + 1) } }
            return
        }
        show(agent, at: fits && frame.width > 0 ? frame : nil, quietly: true)
    }

    private func remember() {
        guard let window else { return UserDefaults.standard.removeObject(forKey: Self.savedKey) }
        let frame = NSStringFromRect(window.frame)
        if let t = conversation {
            var c = ["w": t.workspace, "id": t.id, "name": t.name, "c": t.channel ? "1" : "0"]
            if let p = t.picture { c["p"] = p.absoluteString }
            UserDefaults.standard.set(["conversation": c, "frame": frame], forKey: Self.savedKey)
        } else if let agentID {
            UserDefaults.standard.set(["agent": agentID, "frame": frame], forKey: Self.savedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.savedKey)
        }
    }

    func show(_ agent: Agent, at saved: NSRect? = nil, quietly: Bool = false) {
        agentID = agent.id
        conversation = nil
        present(SideRoot(agent: agent), at: saved, quietly: quietly)
    }

    /// A Slack or WhatsApp conversation in the panel. Opening it reads it, as in the notch.
    func show(conversation t: SlackTarget, at saved: NSRect? = nil, quietly: Bool = false) {
        agentID = nil
        conversation = t
        if NotchUI.shared.slackTarget?.workspace == t.workspace, NotchUI.shared.slackTarget?.id == t.id {
            NotchUI.shared.slackTarget = nil
        }
        NotchUI.shared.read(t)
        present(SideRoot(target: t), at: saved, quietly: quietly)
    }

    private func present(_ content: SideRoot, at saved: NSRect?, quietly: Bool) {
        if !quietly { NotchUI.shared.collapse() }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = NSSize(width: 380, height: min(720, visible.height - 40))
        let frame = saved ?? window?.frame ?? NSRect(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16,
                                            width: size.width, height: size.height)
        window?.close()
        let panel = SidePanelWindow(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                                    backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 300, height: 320)
        let root = content
            .environment(AgentStore.shared).environment(NotchUI.shared)
            .environment(\.sideWindow, panel)
        panel.contentView = FirstClickHostingView(rootView: root)
        moves.forEach(NotificationCenter.default.removeObserver)
        moves = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: panel, queue: .main) { [weak self] _ in self?.remember() }
        }
        if quietly {
            // Back where it was after a relaunch, without the flourish or the keyboard.
            panel.waitsForClick = true
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            window = panel
            return remember()
        }
        // Grows out of the notch and glides over to the side.
        panel.setFrame(notchRect(on: screen), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        window = panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.38
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { self.remember() })
        // Opened from the notch, where the user was likely mid-reply: the same draft carries on
        // in the panel's box with the cursor already in it, so typing never stops.
        panel.makeKey()
        for delay in [0.0, 0.15, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard panel.isVisible, let box = Self.textBox(in: panel.contentView),
                      panel.firstResponder !== box else { return }
                panel.makeFirstResponder(box)
                box.setSelectedRange(NSRange(location: (box.string as NSString).length, length: 0))
            }
        }
    }

    private static func textBox(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView, text.isEditable { return text }
        for child in view.subviews { if let found = textBox(in: child) { return found } }
        return nil
    }

    /// A small rectangle where the notch is, for the panel to grow out of and shrink back into.
    private func notchRect(on screen: NSScreen) -> NSRect {
        NSRect(x: screen.frame.midX - 120, y: screen.frame.maxY - 60, width: 240, height: 50)
    }

    func close() {
        FrontApp.giveBack()
        window?.close()
        window = nil
        agentID = nil
        conversation = nil
        remember()
    }

    /// The conversation goes back into the notch, opened there.
    func returnToNotch(_ t: SlackTarget) {
        close()
        NotchUI.shared.openConversation(t)
    }

    /// Shrinks back up into the notch, then the chat opens there.
    func returnToNotch(_ agent: Agent) {
        guard let panel = window else { return NotchUI.shared.show(agent.id) }
        window = nil
        agentID = nil
        moves.forEach(NotificationCenter.default.removeObserver)
        moves = []
        remember()
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
        // The reverse of going out: the notch opens on this chat while the panel glides over
        // into it and melts away, so it lands already open.
        NotchUI.shared.show(agent.id)
        let open = NSRect(x: screen.frame.midX - 340, y: screen.frame.maxY - 560, width: 680, height: 560)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.38
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().setFrame(open, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.close()
        })
    }
}

private struct SideRoot: View {
    var agent: Agent?
    var target: SlackTarget?

    var body: some View {
        Group {
            if let agent { ChatView(agent: agent) }
            else if let target { SlackComposer(target: target) }
        }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
            .preferredColorScheme(.dark)
    }
}

// MARK: Enlarged pictures

/// A clicked picture, shown big over the chat it came from. The ✕, a click outside it, or Esc
/// goes back to the chat.
private struct Lightbox: View {
    let side: Bool
    @Environment(NotchUI.self) private var ui

    var body: some View {
        if let shown = ui.enlarged, shown.side == side {
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.92)
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                Image(nsImage: shown.image).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 16).padding(.vertical, 34)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                HStack(spacing: 6) {
                    SaveButton { saveToDownloads(image: shown.image, name: shown.name) }
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white).frame(width: 26, height: 26)
                            .background(.white.opacity(0.16), in: Circle())
                    }
                    .buttonStyle(Press()).help("Back to the chat")
                    .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.15)) { ui.enlarged = nil }
    }
}

// MARK: Saving pictures

/// A small download button for the corner of a picture.
private struct SaveButton: View {
    let action: () -> Void
    @State private var done = false

    var body: some View {
        Button {
            action()
            done = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { done = false }
        } label: {
            Image(systemName: done ? "checkmark" : "arrow.down.to.line").font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white).frame(width: 26, height: 26)
                .background(.black.opacity(0.65), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(6)
        .help(done ? "Saved to Downloads" : "Save to Downloads")
    }
}

/// Copies a picture into Downloads quietly (never overwriting one already there).
private func saveToDownloads(path: String) {
    let source = URL(fileURLWithPath: path)
    let target = freeDownloadsURL(source.lastPathComponent)
    guard (try? FileManager.default.copyItem(at: source, to: target)) != nil else { return NSSound.beep() }
}

func saveToDownloads(image: NSImage, name: String) {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return NSSound.beep() }
    let base = (name as NSString).deletingPathExtension
    let target = freeDownloadsURL("\(base).png")
    guard (try? png.write(to: target)) != nil else { return NSSound.beep() }
}

private func freeDownloadsURL(_ name: String) -> URL {
    let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    var url = dir.appendingPathComponent(name)
    let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = dir.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
        n += 1
    }
    return url
}

/// Draws the search results for a query into a picture, off screen, for checking the design.
@MainActor func renderSearchPreview(_ query: String, to path: String) {
    let ui = NotchUI.shared
    let before = ui.query, shown = ui.searchResults
    ui.query = query
    ui.searchResults = SearchItem.compute(AgentStore.shared, ui)
    let view = SearchResults().environment(AgentStore.shared).environment(ui)
        .frame(width: 520).padding(12).background(.black)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    ui.query = before
    ui.searchResults = shown
}

/// Draws the in-island banner for a chat into a picture, off screen, for checking the design.
@MainActor func renderToastPreview(_ id: String, to path: String) {
    let ui = NotchUI.shared
    let before = ui.toast
    ui.toast = .agent(id)
    let view = VStack { ToastBanner() }.environment(AgentStore.shared).environment(ui)
        .frame(width: 560, height: 90).background(.black)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    ui.toast = before
}

/// Draws a message body into a picture, off screen, for checking formatting.
@MainActor func renderMessagePreview(_ text: String, to path: String) {
    let view = MessageBody(text: text).frame(width: 460).padding(12).background(Color(white: 0.17))
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// The working loop as a grid of frames, off screen, for comparing with a recording of Grok Bot.
@MainActor func renderBallPreview(to path: String) {
    let ball = GrokBall(size: 60, color: .black, outlined: false, working: true)
    let times = stride(from: 0.0, to: 14.4, by: 0.3).map { $0 }
    let view = LazyVGrid(columns: Array(repeating: GridItem(.fixed(70)), count: 12), spacing: 8) {
        ForEach(times, id: \.self) { t in
            VStack(spacing: 2) {
                ball.still(BallPose.at(t, in: BallPose.working, looping: false))
                Text(String(format: "%.1f", t)).font(.system(size: 9)).foregroundStyle(.gray)
            }
            .frame(width: 70, height: 80).background(Color(white: 0.88))
        }
    }
    .padding(8).background(Color(white: 0.95))
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// Every Grok shape at rest, off screen, for comparing with Grok Bot's own picker.
@MainActor func renderShapesPreview(to path: String) {
    let names = ["blob"] + GrokShapes.all.keys.sorted()
    let colors: [Color] = [.blue, .green, .purple, .brown, .pink, .orange, .cyan, .red]
    let view = LazyVGrid(columns: Array(repeating: GridItem(.fixed(78)), count: 9), spacing: 8) {
        ForEach(Array(names.enumerated()), id: \.offset) { i, name in
            VStack(spacing: 3) {
                GrokBall(size: 56, color: colors[i % colors.count], outlined: false, working: false,
                         shape: GrokShapes.named(name)).still(BallPose.rest)
                Text(name).font(.system(size: 9)).foregroundStyle(.gray)
            }
            .frame(width: 78, height: 80).background(Color(white: 0.96))
        }
    }
    .padding(8).background(.white)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}


/// WhatsApp bubbles drawn off screen, for checking the look.
@MainActor func renderWhatsAppPreview(to path: String) {
    let now = Date()
    let lines = [
        SlackLine(id: "1", sender: "Ollie", mine: false, text: "yh i was just setting the same up but would be better to sort it out", time: now),
        SlackLine(id: "2", sender: "You", mine: true, text: "Weird", time: now, ticks: 3),
        SlackLine(id: "3", sender: "You", mine: true, text: "Ah ok looks like it was just that yh", time: now, ticks: 2),
        SlackLine(id: "4", sender: "You", mine: true, text: "Sent *just* now", time: now, ticks: 1),
    ]
    let view = VStack(alignment: .leading, spacing: 6) {
        ForEach(lines, id: \.id) { line in
            HStack { if line.mine { Spacer() }; WhatsAppBubble(line: line); if !line.mine { Spacer() } }
        }
    }
    .frame(width: 420).padding(14).background(.black)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

@MainActor func renderNotificationMediaPreview(to path: String) {
    let art = ImageRenderer(content: ZStack {
        LinearGradient(colors: [.indigo, .cyan], startPoint: .top, endPoint: .bottom)
        Image(systemName: "mountain.2.fill").font(.system(size: 42)).foregroundStyle(.white.opacity(0.8))
    }.frame(width: 128, height: 96))
    let thumbnail = art.nsImage?.tiffRepresentation
    var photo = SlackAlert(id: "photo-fixture", workspace: "whatsapp", priority: 1, team: "", channel: "fixture",
                           place: "WhatsApp", sender: "Grandad Derek", text: "It is a new one to us. Here’s the photo — we thought you’d like to see the rest of it too.", ts: "fixture")
    photo.files = [SlackFile(id: "fixture", workspace: "whatsapp", name: "Photo", image: true,
                            thumb: nil, url: nil, link: nil, kind: "image", preview: thumbnail)]
    let reaction = SlackAlert(id: "reaction-fixture", workspace: "whatsapp", priority: 1, team: "", channel: "fixture",
                              place: "WhatsApp", sender: "Ollie Buckie", text: "You reacted 👍 to “yh i’ll do that all good”", ts: "fixture")
    let view = VStack(alignment: .leading, spacing: 14) {
        ForEach([photo, reaction]) { alert in
            VStack(alignment: .leading, spacing: 6) {
                Text(alert.sender).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                NotificationMessagePreview(alert: alert)
            }.padding(12).background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 12))
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Compact banner").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            NotificationMessagePreview(alert: photo, compact: true)
        }.padding(12).background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 12))
    }.padding(16).frame(width: 460).background(.black)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
