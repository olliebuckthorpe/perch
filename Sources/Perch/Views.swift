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
        let right = Array(store.sessions.filter(ui.inPill).prefix(maxFaces))
        let l = earWidth(left.count), r = earWidth(right.count)
        // Opened, the island is at least 340 wide; the extra is shared between both sides
        // so the gap always stays lined up with the hardware notch.
        let extra = ui.expanded ? max(0, 340 - (l + ui.notch.width + r)) : 0
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
        .offset(x: (r - l) / 2)
        .animation(island, value: ui.expanded)
        .animation(island, value: ui.cardsOnly)
        .animation(island, value: ui.selectedID)
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
        VStack(alignment: .leading, spacing: 6) {
            ForEach(store.needing) { PendingCard(agent: $0) }
            // Opened by itself to ask something: show just the ask, not the whole roster.
            if !(ui.cardsOnly && !store.needing.isEmpty) { roster }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var roster: some View {
        let sessions = store.sessions
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
        let selected = ui.selectedID == agent.id
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                FaceView(agent: agent, size: 18)
                Text(agent.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1).layoutPriority(1)
                Text(agent.detail.isEmpty ? "Idle" : agent.detail)
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                StatusChip(agent: agent).layoutPriority(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { ui.select(agent.id) }

            if selected {
                if !agent.lastMessage.isEmpty {
                    Text(agent.lastMessage.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.82))
                        .lineLimit(5).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if agent.pending == nil { ReplyField(agent: agent, autofocus: true) }
                HStack {
                    Spacer()
                    Button(openLabel) { open() }.buttonStyle(ChipButton())
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(.white.opacity(selected ? 0.09 : hovered ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hovered = $0 }
    }

    private var openLabel: String {
        switch agent.source {
        case .grok: return "Open Grok Bot"
        case .codex: return "Open Codex"
        case .claude: return agent.hostBundleID == CodingSessions.claudeBundleID ? "Open Claude" : "Open terminal"
        }
    }

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

    /// A coding session cannot take a second prompt while it is mid-turn.
    private var busy: Bool { agent.source != .grok && agent.status == .working && agent.pending == nil }

    private var placeholder: String {
        if agent.source == .grok { return "Message \(agent.name), paste images too" }
        if busy { return "Busy. Reply when it finishes." }
        if agent.pending != nil { return "Tell it what to do next" }
        return agent.waiter != nil ? "Reply to this session" : "Reply in the background"
    }

    var body: some View {
        let draft = Binding(get: { ui.drafts[agent.id] ?? "" }, set: { ui.drafts[agent.id] = $0 })
        let files = ui.attachments[agent.id] ?? []
        let empty = draft.wrappedValue.isEmpty && files.isEmpty
        VStack(alignment: .leading, spacing: 6) {
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
                                .buttonStyle(.plain).offset(x: 4, y: -4)
                            }
                    }
                }
                .padding(.top, 3)
            }
        HStack(alignment: .bottom, spacing: 6) {
            TextField(placeholder, text: draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 12)).lineLimit(1...3)
                .focused($focused)
                .onSubmit { send() }
                .disabled(busy)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 15))
                    .foregroundStyle(empty || busy ? .white.opacity(0.2) : agent.color)
            }
            .buttonStyle(.plain)
            .disabled(empty || busy)
        }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onChange(of: focused) { _, on in if on { ui.focusedAgentID = agent.id } }
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
        case .permission(let tool, _): return tool == "Bash" ? "Run this command?" : "Allow \(tool)?"
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
                ForEach(["Keep going", "Run the tests"], id: \.self) { quick in
                    Button(quick) { CodingSessions.shared.reply(agent, text: quick) }.buttonStyle(ChipButton())
                }
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
    @State private var replyWindow = Settings.replyWindow
    @State private var loginItem = SMAppService.mainApp.status == .enabled

    var body: some View {
        HStack {
            Text("Perch").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.25))
            Spacer()
            Menu {
                Menu("Always in the notch") {
                    ForEach(store.grokBots) { bot in
                        Toggle(bot.name, isOn: Binding(
                            get: { ui.pinned.contains(bot.name) },
                            set: { on in if on { ui.pinned.insert(bot.name) } else { ui.pinned.remove(bot.name) } }))
                    }
                }
                Toggle("Launch at login", isOn: $loginItem)
                Toggle("Sounds", isOn: $sounds)
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
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 6)
        .onChange(of: sounds) { _, on in Settings.sounds = on }
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
            .contentShape(Rectangle())
    }
}

private struct LinkButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11)).foregroundStyle(.white.opacity(configuration.isPressed ? 0.3 : 0.5))
    }
}
