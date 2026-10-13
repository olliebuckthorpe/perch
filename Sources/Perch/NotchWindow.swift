import AppKit
import SwiftUI
import Observation

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit would otherwise nudge the window down to keep it clear of the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// View state for the island: open or closed, which row is selected, and reply drafts.
@Observable
final class NotchUI {
    static let shared = NotchUI()

    private(set) var expanded = false
    var selectedID: String?
    /// True when the island opened itself for a prompt, so it shows only that prompt.
    private(set) var cardsOnly = false
    /// Half-written replies, kept across closing the island and across restarts.
    var drafts: [String: String] = UserDefaults.standard.dictionary(forKey: "drafts") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(drafts.filter { !$0.value.isEmpty }, forKey: "drafts") }
    }
    var attachments: [String: [Attachment]] = [:]
    /// The agent whose reply field has the cursor, so a pasted image knows where to go.
    @ObservationIgnored var focusedAgentID: String?
    var notch = CGSize(width: 185, height: 33)
    /// Grok bots that always sit in the notch. The rest only show up when they have something.
    var pinned: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "pinnedGrok") ?? ["Remmi"]) {
        didSet { UserDefaults.standard.set(Array(pinned), forKey: "pinnedGrok") }
    }

    func inPill(_ agent: Agent) -> Bool {
        agent.status != .idle || agent.pending != nil || (agent.source == .grok && pinned.contains(agent.name))
    }

    @ObservationIgnored weak var controller: NotchController?
    @ObservationIgnored private var hovering = false
    @ObservationIgnored private var autoOpened = false
    @ObservationIgnored private var holdOpenUntil = Date.distantPast
    @ObservationIgnored private var expandWork: DispatchWorkItem?
    @ObservationIgnored private var collapseWork: DispatchWorkItem?

    func isDrafting(_ id: String) -> Bool { !(drafts[id] ?? "").isEmpty || !(attachments[id] ?? []).isEmpty }

    /// Once a row is open the island has keyboard focus, and it stays until Esc or a click elsewhere.
    private var typing: Bool { controller?.panel.isKeyWindow ?? false }

    /// Cmd+V with an image on the clipboard attaches it to the reply being written.
    func pasteImages() -> Bool {
        guard expanded, let id = focusedAgentID ?? selectedID else { return false }
        let images = Attachment.fromPasteboard()
        guard !images.isEmpty else { return false }
        attachments[id, default: []].append(contentsOf: images)
        return true
    }

    func hover(_ inside: Bool) {
        guard inside != hovering else { return }
        hovering = inside
        if inside {
            collapseWork?.cancel()
            autoOpened = false
            guard !expanded else { return }
            // A short pause so brushing past the menu bar does not open it.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hovering else { return }
                self.expand()
            }
            expandWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else {
            expandWork?.cancel()
            scheduleCollapse(after: 0.22)
        }
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering, !self.typing, !self.autoOpened else { return }
            // The settings menu is open: its window sits outside the island, so wait for it.
            if RunLoop.current.currentMode == .eventTracking {
                self.scheduleCollapse(after: 0.5)
                return
            }
            self.collapse()
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func expand() {
        expanded = true
        resumeDraft()
    }

    /// Reopening with a reply half written puts the cursor straight back in it.
    private func resumeDraft() {
        if let id = selectedID, isDrafting(id) { controller?.panel.makeKey() }
    }

    func collapse() {
        guard expanded else { return }
        expanded = false
        cardsOnly = false
        // Keep the row with an unsent reply selected, so it is right there on reopening.
        if let id = selectedID, !isDrafting(id) { selectedID = nil }
        autoOpened = false
        controller?.releaseKey()
    }

    func select(_ id: String) {
        selectedID = selectedID == id ? nil : id
        if selectedID != nil {
            controller?.panel.makeKey()
            markSeen(id)
        }
    }

    func show(_ id: String) {
        cardsOnly = false
        expanded = true
        selectedID = id
        controller?.panel.makeKey()
        markSeen(id)
    }

    /// Opening a row counts as reading it, so its badge clears here and in the agent's own app.
    private func markSeen(_ id: String) {
        guard let agent = AgentStore.shared.find(id) else { return }
        if agent.source == .grok {
            GrokSource.shared.markRead(agent)
        } else if agent.status == .done, agent.pending == nil {
            agent.status = .idle
        }
    }

    /// Something is being held for the user: open up so they notice.
    func attention(_ store: AgentStore) {
        guard let id = store.attentionAgentID, store.find(id)?.pending != nil else { return }
        if !expanded {
            autoOpened = true
            cardsOnly = true
        }
        holdOpenUntil = Date().addingTimeInterval(4)
        expanded = true
    }

    func pendingChanged(_ count: Int) {
        if count == 0, autoOpened {
            autoOpened = false
            scheduleCollapse(after: 0.9)
        }
    }

    func outsideClick() {
        guard expanded, Date() >= holdOpenUntil else { return }
        collapse()
    }
}

/// Owns the panel. The window is a fixed transparent canvas hanging from the top of the
/// screen and never resizes, so opening the island is a pure in-window animation. The
/// canvas lets the mouse through everywhere except over the island itself.
final class NotchController {
    let panel: NotchPanel
    private let ui = NotchUI.shared
    private var liveRect = CGRect.zero
    /// Where the island will be once open: width, and how far its centre sits from the notch's.
    private var openWidth: CGFloat = 340
    private var openOffset: CGFloat = 0
    private var monitors: [Any] = []
    private static let canvas = CGSize(width: 720, height: 680)

    init(store: AgentStore) {
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        // Set after isFloatingPanel, which resets the level. Above the menu bar, even when it
        // slides down over a full screen app.
        panel.level = .popUpMenu
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true

        ui.controller = self
        let host = NSHostingView(rootView: NotchRoot().environment(store).environment(ui))
        host.sizingOptions = []
        // The canvas sits under the notch on purpose; without this the content is pushed below it.
        host.safeAreaRegions = []
        panel.contentView = host

        updateGeometry()
        panel.orderFrontRegardless()
        TopSpace.adopt(panel)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateGeometry() }

        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in self?.trackMouse() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            self?.trackMouse()
            return event
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.ui.outsideClick()
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 {
                self?.ui.collapse()
                return nil
            }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v",
               self?.ui.pasteImages() == true {
                return nil
            }
            return event
        }) { monitors.append(m) }
    }

    /// The built-in display is the one with the notch. Without it, hang from the top of the main screen.
    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    func updateGeometry() {
        guard let s = screen else { return }
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            ui.notch = CGSize(width: s.frame.width - l.width - r.width, height: s.safeAreaInsets.top)
        } else {
            ui.notch = CGSize(width: 0, height: max(24, s.frame.maxY - s.visibleFrame.maxY))
        }
        let size = CGSize(width: min(Self.canvas.width, s.frame.width),
                          height: min(Self.canvas.height, s.frame.height - 40))
        panel.setFrame(NSRect(x: (s.frame.midX - size.width / 2).rounded(), y: s.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    /// The island's frame inside the canvas, in SwiftUI's top-left coordinates.
    func islandFrameChanged(_ rect: CGRect) {
        liveRect = rect
        trackMouse()
    }

    func openShapeChanged(width: CGFloat, offset: CGFloat) {
        openWidth = width
        openOffset = offset
    }

    private var menuBarCheck = (at: Date.distantPast, hidden: false)

    /// True in a full screen space, where the menu bar is tucked away until the pointer hits the top.
    /// The menu bar's own window still reports as on screen there, so look instead for the
    /// overlay a full screen app keeps at the top to slide its title bar into.
    private func menuBarHidden() -> Bool {
        if Date().timeIntervalSince(menuBarCheck.at) < 0.4 { return menuBarCheck.hidden }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let width = Double(screen?.frame.width ?? 0)
        let hidden = list.contains { w in
            guard let layer = w[kCGWindowLayer as String] as? Int, (25...30).contains(layer),
                  w[kCGWindowOwnerName as String] as? String != "Window Server",
                  let bounds = w[kCGWindowBounds as String] as? [String: Any] else { return false }
            return bounds["Width"] as? Double == width && bounds["Y"] as? Double == 0
        }
        menuBarCheck = (Date(), hidden)
        return hidden
    }

    private func trackMouse() {
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        // Slack all round, and plenty upwards so pushing against the top edge still counts.
        let island = CGRect(x: frame.minX + liveRect.minX, y: frame.maxY - liveRect.maxY,
                            width: liveRect.width, height: liveRect.height + 20).insetBy(dx: -3, dy: -3)
        // Closed, the whole strip above where the island opens is the trigger, not just the pill.
        // With the menu bar hidden the trigger reaches a little below the notch band, so the
        // island opens before the pointer ever gets into the band.
        let hidden = menuBarHidden()
        let reach: CGFloat = hidden ? 26 : 0
        let strip = CGRect(x: frame.midX + openOffset - openWidth / 2, y: frame.maxY - ui.notch.height - reach,
                           width: openWidth, height: ui.notch.height + reach + 20)
        let onIsland = island.contains(mouse)
        // In a full screen app, the pointer entering the top band makes macOS slide the menu bar
        // and the app's title bar down. Over the island, hold it just below the band instead.
        let ceiling = frame.maxY - ui.notch.height - 8
        if hidden, onIsland || strip.contains(mouse), mouse.y > ceiling, let primary = NSScreen.screens.first {
            CGWarpMouseCursorPosition(CGPoint(x: mouse.x, y: primary.frame.maxY - ceiling))
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        if panel.ignoresMouseEvents == onIsland { panel.ignoresMouseEvents = !onIsland }
        ui.hover(onIsland || (!ui.expanded && strip.contains(mouse)))
    }

    /// Hand keyboard focus back to whatever the user was doing.
    func releaseKey() {
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        TopSpace.adopt(panel)
    }
}

struct NotchRoot: View {
    var body: some View {
        NotchContent()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .preferredColorScheme(.dark)
    }
}
