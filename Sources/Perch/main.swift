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
            if let command = req.headers["x-perch-debug"] {
                self?.debug(command)
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
        SlackSource.shared.start()
        Clips.shared.start()
        // Control+Option+V: the clipboard. Control+Option+R: the pinned bot (Remmi).
        Hotkeys.shared.register(key: kVK_ANSI_V, modifiers: controlKey | optionKey) { NotchUI.shared.toggleClips() }
        Hotkeys.shared.register(key: kVK_ANSI_R, modifiers: controlKey | optionKey) { NotchUI.shared.openPinned() }
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
    private func debug(_ command: String) {
        let ui = NotchUI.shared
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "expand": ui.expand()
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
        case "unattach" where parts.count > 1:
            ui.attachments[parts[1]] = nil
        case "compose":
            ui.expand()
            ui.composing = true
        case "collapse": ui.collapse()
        case "select" where parts.count > 1: ui.show(parts[1])
        case "allow" where parts.count > 1:
            if let agent = AgentStore.shared.find(parts[1]) { CodingSessions.shared.allow(agent) }
        case "reply" where parts.count > 1:
            let bits = parts[1].components(separatedBy: "|")
            if bits.count == 2, let agent = AgentStore.shared.find(bits[0]) { CodingSessions.shared.reply(agent, text: bits[1]) }
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
