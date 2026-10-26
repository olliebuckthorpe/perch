import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: HookServer?
    private var controller: NotchController?
    private let codex = CodexWatcher()
    private var pruneTimer: Timer?
    private var awake: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Links arrive as Apple events. Taking them this way also says which app sent each one.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(openLink(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    @objc private func openLink(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text), url.scheme == "http" || url.scheme == "https" else { return }
        let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value
        let source = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        // A link clicked before the island exists (Perch launched by the click) waits a moment.
        if controller == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { LinkRouter.shared.handle(url, from: source) }
        } else {
            LinkRouter.shared.handle(url, from: source)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundle = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundle).count > 1 {
            NSApp.terminate(nil)
            return
        }

        let dir = "\(Shell.home)/.perch"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let server = HookServer(path: "\(dir)/perch.sock")
        server.handler = { [weak self] req in
            if req.headers["x-perch-slack"] == "save" {
                // slack/add-workspace.sh: a workspace's keys, straight into the Keychain. Only the
                // outcome is answered; the keys are never logged or written to a file.
                DispatchQueue.main.async {
                    let j = req.json
                    let ok = SlackSource.shared.save(name: j["name"] as? String ?? "", priority: j["priority"] as? Int ?? 9,
                                                     alerts: j["alerts"] as? String ?? "apps",
                                                     app: j["app"] as? String ?? "", user: j["user"] as? String ?? "")
                    req.respond(Data((ok ? #"{"ok":true}"# : #"{"ok":false}"#).utf8))
                }
            } else if let command = req.headers["x-perch-whatsapp"] {
                // `perch-wa`: WhatsApp from the command line (Remmi uses it to send through Perch).
                DispatchQueue.main.async { WhatsAppSource.shared.command(command, json: req.json) { reply in
                    req.respond((try? JSONSerialization.data(withJSONObject: reply)) ?? Data())
                } }
            } else if let command = req.headers["x-perch-debug"] {
                self?.debug(command, json: req.json)
                req.respond()
            } else {
                CodingSessions.shared.handle(req)
            }
        }
        do { try server.start() } catch { NSLog("Perch: could not start hook server: \(error)") }
        self.server = server

        // Without this macOS naps the app while it sits idle, and the first open after a quiet
        // spell stutters while it wakes up. This does not stop the Mac itself from sleeping.
        awake = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                      reason: "Keeps the notch responsive")
        installEditMenu()
        controller = NotchController(store: AgentStore.shared)
        AgentStore.shared.restore()
        CodingSessions.shared.start()
        Headphones.shared.keepMacMicrophone()
        SlackSource.shared.start()
        CallWatch.shared.start()
        MeetingWatch.shared.start()
        WhatsAppSource.shared.start()
        SidePanel.shared.restore()
        // Search reads every chat; that happens quietly after launch, so it is ready when needed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { ThreadSearch.shared.refresh() }
        Clips.shared.start()
        // Control+Option+V: the clipboard. Control+Option+R: the pinned bot (Remmi).
        Hotkeys.shared.register(key: kVK_ANSI_V, modifiers: controlKey | optionKey) { NotchUI.shared.toggleClips() }
        Hotkeys.shared.register(key: kVK_ANSI_R, modifiers: controlKey | optionKey) { NotchUI.shared.openPinned() }
        // Control+Option+H: headphones to this Mac, or back again.
        Hotkeys.shared.register(key: kVK_ANSI_H, modifiers: controlKey | optionKey) { Headphones.shared.toggle() }
        Usage.shared.start()
        // The top-edge guard is retired: holding the pointer off the top edge meant pinning it
        // behind the notch, where it cannot be seen. Make sure it is off for good.
        EdgeGuard.wanted = false
        codex.start()
        GrokSource.shared.start()
        NotionTasks.shared.start()

        pruneTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in AgentStore.shared.prune() }
        // A restart can come without warning, so the list is written out as it changes.
        let saver = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in AgentStore.shared.save() }
        saver.tolerance = 2
        pruneTimer?.tolerance = 60
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Let go of every held hook so no agent is left waiting on a notch that is gone.
        for agent in AgentStore.shared.agents { agent.pending?.finish() }
        GrokSource.shared.stop()
        server?.stop()
    }

    /// Drives the island from a script, for checking the UI without a mouse:
    /// `expand`, `collapse`, `select:<agent id>`, `allow:<agent id>`, `reply:<agent id>|<text>`,
    /// `snapshot:<png path>`.
    private func debug(_ command: String, json: [String: Any] = [:]) {
        let ui = NotchUI.shared
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "sidebarcheck" where parts.count > 1:
            let store = AgentStore.shared
            let oldAgents = store.agents, oldRecent = ui.slackRecent, oldPins = ui.pinnedConversations
            let oldUnread = ui.slackUnread, oldGone = ui.slackDismissed, oldTarget = ui.slackTarget
            let oldCodingPins = ui.pinnedChats, oldDismissed = ui.dismissed, oldRemovals = ui.sidebarRemovals
            let oldSelection = ui.selectedID, oldUndo = ui.sidebarUndoAction, oldUndoName = ui.sidebarUndoName
            defer {
                store.agents = oldAgents
                ui.slackTarget = oldTarget
                ui.slackRecent = oldRecent; ui.pinnedConversations = oldPins
                ui.slackUnread = oldUnread; ui.slackDismissed = oldGone
                ui.pinnedChats = oldCodingPins; ui.dismissed = oldDismissed; ui.sidebarRemovals = oldRemovals
                ui.selectedID = oldSelection; ui.sidebarUndoAction = oldUndo; ui.sidebarUndoName = oldUndoName
                store.save()
            }
            var results: [String: Bool] = [:]
            let wa = SlackTarget(workspace: WhatsAppSource.workspace, id: "perch-sidebar-regression", name: "Test", channel: false)
            let slack = SlackTarget(workspace: "perch-regression", id: wa.id, name: "Test Slack", channel: true)
            let key = "\(wa.workspace):\(wa.id)"
            ui.slackRecent.append(wa); ui.slackRecent.append(slack); ui.slackUnread[key] = 3
            ui.toggleSidebarPin(.conversation(wa))
            results["WhatsApp pin persists"] = ui.sidebarPinned(.conversation(wa)) && (UserDefaults.standard.stringArray(forKey: "pinnedConversations") ?? []).contains(key)
            ui.slackTarget = slack
            ui.removeSidebarChat(.conversation(wa))
            results["WhatsApp removes and unpins"] = !ui.slackRecent.contains(where: { $0.id == wa.id && $0.workspace == wa.workspace }) && !ui.sidebarPinned(.conversation(wa))
            results["Other workspace selection survives"] = ui.slackTarget?.workspace == slack.workspace
            ui.undoSidebarRemoval()
            results["Undo restores WhatsApp, pin and unread"] = ui.slackRecent.contains(where: { $0.id == wa.id && $0.workspace == wa.workspace }) && ui.sidebarPinned(.conversation(wa)) && ui.slackUnread[key] == 3
            ui.toggleSidebarPin(.conversation(slack))
            results["Slack pin works"] = ui.sidebarPinned(.conversation(slack))
            let agent = store.upsert(source: .codex, sessionID: "perch-sidebar-regression", name: "Sidebar test")
            agent.status = .working; agent.kept = true
            ui.toggleSidebarPin(.agent(agent)); ui.removeSidebarChat(.agent(agent))
            results["Active coding chat stays removed"] = ui.isDismissed(agent)
            ui.undoSidebarRemoval()
            results["Undo restores coding chat and pin"] = !ui.isDismissed(agent) && ui.sidebarPinned(.agent(agent)) && agent.kept
            try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: parts[1]))
        case "performance" where parts.count > 1:
            var layers = 0
            func count(_ view: NSView) {
                if view.layer?.animationKeys()?.contains("perch.attention-bounce") == true { layers += 1 }
                view.subviews.forEach(count)
            }
            NSApp.windows.compactMap(\.contentView).forEach(count)
            let state: [String: Any] = ["expanded": ui.expanded, "cardsOnly": ui.cardsOnly,
                "compositorBounces": layers, "tasksVisible": ui.showingTasks,
                "visibleWindows": NSApp.windows.filter(\.isVisible).count]
            try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: parts[1]))
        case "expand": ui.expand()
        case "boardcheck" where parts.count > 1:
            checkBoardDrag(to: parts[1])
        case "tasks":
            ui.expand()
            ui.showingTasks = true
        case "peek" where parts.count > 1:
            ui.expand()
            ui.peek(parts[1])
        case "paste":
            let took = ui.pasteImages()
            NSLog("perch paste: %@ selected=%@ attachments=%@", String(took), ui.selectedID ?? "nil",
                  String(describing: ui.attachments.mapValues(\.count)))
        case "nearest" where parts.count > 1:
            let bits = parts[1].split(separator: "|", maxSplits: 1).map(String.init)
            DispatchQueue.global().async {
                let rows = ThreadSearch.shared.nearest(bits[0]).prefix(12).map { String(format: "%.3f ", $0.1) + $0.0 }
                let all = ThreadSearch.shared.nearest(bits[0]).map(\.1)
                let median = all.isEmpty ? 0 : all[all.count / 2]
                try? (rows + [String(format: "median %.3f of %d", median, all.count)]).joined(separator: "\n")
                    .write(toFile: bits[1], atomically: true, encoding: .utf8)
            }
        case "meetings" where parts.count > 1:
            // meetings:<file>: calendar access and today's meetings with join links (titles and times).
            let w = MeetingWatch.shared
            let rows = w.today().map { "\($0.start.formatted(date: .omitted, time: .shortened)) \($0.title) [\($0.service)]" }
            try? (["access \(String(describing: w.allowed)), calendars \(w.calendarCount), \(w.why)"] + rows)
                .joined(separator: "\n").write(toFile: parts[1], atomically: true, encoding: .utf8)
        case "meetingtest":
            // A pretend meeting two minutes out, to see the banner.
            if let link = URL(string: "https://meet.google.com/abc-defg-hij") {
                ui.meeting(Meeting(id: "test-\(UUID().uuidString)", title: "Test meeting", start: Date().addingTimeInterval(120),
                                   end: Date().addingTimeInterval(1800), link: link, service: "Google Meet"))
            }
        case "sharing" where parts.count > 1:
            // sharing:<file>: whether the screen is being shared now, and recent changes.
            try? ([CallWatch.shared.sharing ? "sharing now" : "not sharing"] + CallWatch.shared.history)
                .joined(separator: "\n").write(toFile: parts[1], atomically: true, encoding: .utf8)
        case "names" where parts.count > 1:
            // names:<query>|<file>: the search box's results for a query, as titles only.
            let bits = parts[1].split(separator: "|", maxSplits: 1).map(String.init)
            DispatchQueue.main.async {
                let before = ui.query
                ui.query = bits[0]
                let rows = SearchItem.compute(AgentStore.shared, ui).map { item -> String in
                    switch item {
                    case .agent(let a): return "bot/chat  " + a.name
                    case .older(let e): return "older     " + e.title
                    case .newChat: return "new chat"
                    case .slack(let t): return (t.workspace == WhatsAppSource.workspace ? "whatsapp  " : "slack     ") + t.label
                    }
                }
                ui.query = before
                try? rows.joined(separator: "\n").write(toFile: bits[1], atomically: true, encoding: .utf8)
            }
        case "search" where parts.count > 1:
            // search:<query>|<file>: writes the results as text, without touching the island.
            let bits = parts[1].split(separator: "|", maxSplits: 1).map(String.init)
            ThreadSearch.shared.refresh()
            func run(_ tries: Int) {
                let started = Date()
                let hits = ThreadSearch.shared.search(bits[0], live: AgentStore.shared.sessions + AgentStore.shared.grokBots, slack: [])
                let took = Date().timeIntervalSince(started)
                let lines = hits.prefix(12).map { hit -> String in
                    let name: String
                    switch hit.target {
                    case .agent(let id): name = "live " + (AgentStore.shared.find(id)?.name ?? id)
                    case .older(let e): name = "\(e.source.rawValue) " + e.title
                    case .slack(let t): name = "slack " + t.label
                    }
                    return String(format: "%.2f (%.2f) ", hit.score, hit.close) + (hit.related ? "[related] " : "") + name + " | " + (hit.snippet ?? "")
                }
                try? ([String(format: "took %.0f ms: ", took * 1000) + ThreadSearch.lastTimings] + lines).joined(separator: "\n").write(toFile: bits[1], atomically: true, encoding: .utf8)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { run(0) }
        case "attach" where parts.count > 1:
            let bits = parts[1].split(separator: "|", maxSplits: 1).map(String.init)
            if bits.count == 2, let file = Attachment.from(file: URL(fileURLWithPath: bits[1])) {
                ui.attachments[bits[0], default: []].append(file)
            }
        case "unattach" where parts.count > 1:
            ui.attachments[parts[1]] = nil
        case "slack" where parts.count > 1:
            let data = try? JSONSerialization.data(withJSONObject: SlackSource.status)
            try? data?.write(to: URL(fileURLWithPath: parts[1]))
        case "slackopen" where parts.count > 1:
            // workspace|channel name, opening its latest thread too.
            let bits = parts[1].split(separator: "|").map(String.init)
            guard bits.count >= 2, let t = SlackDirectory.shared.targets.first(where: { $0.workspace == bits[0] && $0.name == bits[1] }) else { return }
            ui.openConversation(t)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let store = SlackConversations.shared
                if bits.count > 2, let parent = store.lines[store.key(t.workspace, t.id)]?.last(where: { $0.replyCount > 0 }) {
                    ui.openThreads["\(t.workspace):\(t.id)"] = parent.id
                }
            }
        case "slackthreads": ui.expand(); ui.showThreads()
        case "slacklines" where parts.count > 1:
            // workspace|channel name|output path: the newest lines Perch has for it.
            let bits = parts[1].split(separator: "|").map(String.init)
            guard bits.count >= 3, let t = SlackDirectory.shared.targets.first(where: { $0.workspace == bits[0] && $0.name == bits[1] }) else { return }
            if bits.count > 3 { SlackSource.shared.thread(t, ts: bits[3]) } else { SlackSource.shared.history(for: t) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let store = SlackConversations.shared
                let lines = bits.count > 3 ? SlackSource.shared.threadKey(t, ts: bits[3]).flatMap { store.threads[$0] } ?? [] : store.lines[store.key(t.workspace, t.id)] ?? []
                let out = lines.suffix(8)
                    .map { "\($0.id) \($0.mine ? "ME" : $0.sender): \($0.text.prefix(80)) replies=\($0.replyCount)" }.joined(separator: "\n")
                try? (out + "\n\nstatus: \(SlackSource.status)").write(toFile: bits[2], atomically: true, encoding: .utf8)
            }
        case "compose":
            ui.expand()
            ui.composing = true
        case "collapse": ui.collapse()
        case "select" where parts.count > 1: ui.show(parts[1])
        case "answer" where parts.count > 1:
            if let agent = AgentStore.shared.find(parts[1]), let answers = json["answers"] as? [String: String] {
                CodingSessions.shared.answer(agent, answers: answers)
            }
        case "allow" where parts.count > 1:
            if let agent = AgentStore.shared.find(parts[1]) { CodingSessions.shared.allow(agent) }
        case "reply" where parts.count > 1:
            let bits = parts[1].components(separatedBy: "|")
            if bits.count == 2, let agent = AgentStore.shared.find(bits[0]) { CodingSessions.shared.reply(agent, text: bits[1]) }
        case "messageview" where parts.count > 1:
            let text = "1. **Dustin** (@dustinvarano)\nOperates high-ticket info offers. 8.2k followers.\n\n**Tweet** (14 Oct, 33 likes):\n> selling info is science\n>\n> it's all a data game and if you know what numbers to look at...\n>\n> You will make millions of dollars\n\n**DM**\nHey Dustin, your post stuck with me."
            DispatchQueue.main.async { MainActor.assumeIsolated { renderMessagePreview(text, to: parts[1]) } }
        case "shapesview" where parts.count > 1:
            DispatchQueue.main.async { MainActor.assumeIsolated { renderShapesPreview(to: parts[1]) } }
        case "notificationview" where parts.count > 1:
            DispatchQueue.main.async { MainActor.assumeIsolated { renderNotificationMediaPreview(to: parts[1]) } }
        case "waview" where parts.count > 1:
            DispatchQueue.main.async { MainActor.assumeIsolated { renderWhatsAppPreview(to: parts[1]) } }
        case "ballview" where parts.count > 1:
            DispatchQueue.main.async { MainActor.assumeIsolated { renderBallPreview(to: parts[1]) } }
        case "toastview" where parts.count > 1:
            let bits = parts[1].split(separator: "|", maxSplits: 1).map(String.init)
            DispatchQueue.main.async { MainActor.assumeIsolated { renderToastPreview(bits[0], to: bits[1]) } }
        case "searchview" where parts.count > 1:
            let bits = parts[1].split(separator: "|", maxSplits: 1).map(String.init)
            DispatchQueue.main.async { MainActor.assumeIsolated { renderSearchPreview(bits[0], to: bits[1]) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { renderSearchPreview(bits[0], to: bits[1]) } }
        case "snapshot" where parts.count > 1:
            guard let view = controller?.panel.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
        default: break
        }
    }

    /// There is no menu bar for this app, but the reply field still needs copy and paste.
    private func installEditMenu() {
        let main = NSMenu()
        let item = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        item.submenu = edit
        main.addItem(item)
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
