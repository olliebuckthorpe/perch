import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: HookServer?
    private var controller: NotchController?
    private let codex = CodexWatcher()
    private var pruneTimer: Timer?

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

        installEditMenu()
        controller = NotchController(store: AgentStore.shared)
        CodingSessions.shared.start()
        codex.start()
        GrokSource.shared.start()

        pruneTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in AgentStore.shared.prune() }
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
