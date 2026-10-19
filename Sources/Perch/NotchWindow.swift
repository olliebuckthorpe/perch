import AppKit
import SwiftUI
import Observation

/// The island is never the active window, and AppKit normally spends the first click on a
/// window like that just focusing it. Taking the first click makes every click count.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

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
    var query = ""
    /// Showing the full list in the right-hand pane instead of a chat.
    var browsing = false
    /// Showing the Chrome profile switcher in the right-hand pane.
    var showingProfiles = false
    /// Showing the Notion to-do list in the right-hand pane.
    var showingTasks = false
    var showingClips = false
    /// The Slack conversation open in the notch.
    var slackTarget: SlackTarget? {
        didSet { if let t = slackTarget { keepSlack(t) } }
    }

    /// Slack conversations opened recently: they stay in the sidebar until cleared.
    var slackRecent: [SlackTarget] = {
        guard let rows = UserDefaults.standard.array(forKey: "slackRecent") as? [[String: String]] else { return [] }
        return rows.compactMap { r in
            guard let w = r["w"], let id = r["id"], let name = r["name"] else { return nil }
            return SlackTarget(workspace: w, id: id, name: name, channel: r["c"] == "1", picture: r["p"].flatMap(URL.init(string:)))
        }
    }() {
        didSet {
            let rows = slackRecent.map { t -> [String: String] in
                var r = ["w": t.workspace, "id": t.id, "name": t.name, "c": t.channel ? "1" : "0"]
                if let p = t.picture { r["p"] = p.absoluteString }
                return r
            }
            UserDefaults.standard.set(rows, forKey: "slackRecent")
        }
    }

    /// Slack messages waiting to be read, by conversation ("workspace:id"). They keep their
    /// conversation in the sidebar until it is opened, so a banner missed is not a message lost.
    var slackUnread: [String: Int] = (UserDefaults.standard.dictionary(forKey: "slackUnread") as? [String: Int]) ?? [:] {
        didSet { UserDefaults.standard.set(slackUnread, forKey: "slackUnread") }
    }

    /// When each conversation last had a message, for putting the newest first.
    var slackLastAt: [String: Double] = (UserDefaults.standard.dictionary(forKey: "slackLastAt") as? [String: Double]) ?? [:] {
        didSet { UserDefaults.standard.set(slackLastAt, forKey: "slackLastAt") }
    }

    /// A Slack message came in: its conversation goes to the top of the sidebar, marked unread.
    func noteSlack(_ alert: SlackAlert) {
        slackLastAt["\(alert.target.workspace):\(alert.target.id)"] = Date().timeIntervalSince1970
        // Something new: a cleared conversation may come back.
        slackDismissed["\(alert.target.workspace):\(alert.target.id)"] = nil
        let t = alert.target
        let key = "\(t.workspace):\(t.id)"
        if slackTarget?.workspace == t.workspace, slackTarget?.id == t.id, expanded, !cardsOnly { return }
        slackRecent.removeAll { $0.id == t.id && $0.workspace == t.workspace }
        slackRecent.insert(t, at: 0)
        slackUnread[key, default: 0] += 1
    }

    private func keepSlack(_ t: SlackTarget) {
        // Opening a WhatsApp chat is reading it: the phone shows it read too.
        if t.workspace == WhatsAppSource.workspace, (slackUnread["\(t.workspace):\(t.id)"] ?? 0) > 0 || WhatsAppSource.shared.chats.contains(where: { $0.id == t.id && $0.unread > 0 }) {
            WhatsAppSource.shared.markRead(t.id)
        }
        slackUnread["\(t.workspace):\(t.id)"] = nil
        guard !slackRecent.contains(where: { $0.id == t.id && $0.workspace == t.workspace }) else { return }
        slackRecent.append(t)
    }

    /// Conversations the user cleared from the sidebar, and when: they stay away until a new
    /// message arrives in them.
    var slackDismissed: [String: Double] = (UserDefaults.standard.dictionary(forKey: "slackDismissed") as? [String: Double]) ?? [:] {
        didSet { UserDefaults.standard.set(slackDismissed, forKey: "slackDismissed") }
    }

    func dropSlack(_ t: SlackTarget) {
        slackDismissed["\(t.workspace):\(t.id)"] = Date().timeIntervalSince1970
        slackUnread["\(t.workspace):\(t.id)"] = nil
        slackRecent.removeAll { $0.id == t.id && $0.workspace == t.workspace }
        if slackTarget?.id == t.id { slackTarget = nil }
    }

    func openSlack(_ t: SlackTarget) {
        composing = false
        browsing = false
        showingTasks = false
        showingProfiles = false
        selectedID = nil
        slackTarget = t
    }
    /// Back from the clipboard: to the chat if it was opened beside one, otherwise closed.
    func closeClips() {
        if clipsInline {
            showingClips = false
            clipsInline = false
            focusReply = true
        } else {
            collapse()
        }
    }

    /// Small clipboard panel to the full island, chats and all.
    func clipsToFull() {
        clipsInline = true
        expand()
    }

    /// The small shelf panel is showing.
    var showingShelf = false
    /// A file is being dragged somewhere on screen right now.
    private(set) var fileInHand = false

    /// The tray in the top bar: show what is being held.
    func openShelf() {
        cardsOnly = false
        showingClips = false
        showingTasks = false
        showingShelf = true
        expanded = true
    }

    /// A file has been picked up somewhere: drop the shelf down as a place to put it. Left
    /// alone if the island is already open and in use.
    func fileDrag(_ active: Bool) {
        guard active != fileInHand else { return }
        fileInHand = active
        if active {
            guard !expanded, pendingLinks.isEmpty else { return }
            autoOpened = true
            cardsOnly = false
            showingClips = false
            showingShelf = true
            collapseWork?.cancel()
            expanded = true
        } else if showingShelf, autoOpened {
            // Let go somewhere else: tuck away again, unless the pointer is on the shelf.
            autoOpened = false
            scheduleCollapse(after: 0.5)
        }
    }

    /// Something was just dropped on the shelf: show it there for a moment, then tuck away.
    func fileLanded() {
        fileInHand = false
        autoOpened = false
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.showingShelf, !self.hovering else { return }
            self.collapse()
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
    /// Which clipboard row the keyboard is on.
    var clipIndex = 0

    /// The keyboard shortcut for the clipboard: opens straight onto it, or closes it again.
    /// Opened from inside the full island: the clipboard takes the right-hand pane, chats stay
    /// down the left, and closing it goes straight back to the chat that was open.
    var clipsInline = false

    func toggleClips() {
        if expanded, showingClips {
            closeClips()
            return
        }
        // Open in full already (and not a banner): the clipboard slots in beside the chats.
        clipsInline = expanded && !cardsOnly && pendingLinks.isEmpty && !showingShelf
        if clipsInline {
            showingTasks = false
            showingClips = true
            clipIndex = 0
            controller?.panel.makeKey()
            return
        }
        cardsOnly = false
        composing = false
        browsing = false
        showingProfiles = false
        showingTasks = false
        showingShelf = false
        showingClips = true
        clipIndex = 0
        autoOpened = false
        expanded = true
        controller?.panel.makeKey()
    }

    /// The keyboard shortcut for the pinned bot: opens on its chat with the cursor in the reply box.
    func openPinned() {
        let bots = AgentStore.shared.grokBots
        guard let bot = bots.first(where: { pinned.contains($0.name) }) ?? bots.first else { return }
        if expanded, selectedID == bot.id, !showingClips, !showingTasks, !cardsOnly {
            collapse()
            return
        }
        show(bot.id)
    }
    /// Linking WhatsApp: the QR code to scan is showing.
    var showingWhatsAppLink = false

    /// Which search result the arrow keys are on.
    var searchIndex = 0
    /// The results for what has been typed, worked out once typing pauses.
    var searchResults: [SearchItem] = []
    @ObservationIgnored private var searchWork: DispatchWorkItem?

    /// Searches a moment after the last key, so the list changes once per pause rather than
    /// jumping on every letter.
    func searchSoon(immediately: Bool = false) {
        searchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let results = SearchItem.compute(AgentStore.shared, self)
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) {
                self.searchResults = results
                self.searchIndex = min(self.searchIndex, max(0, results.count - 1))
            }
        }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : 0.12), execute: work)
    }
    /// Whether the open chat should take the keyboard. Only after a deliberate click, never on hover.
    private(set) var focusReply = false
    /// A message the open chat should bring to the top, and a count so asking twice still works.
    var scrollTarget: (id: String, n: Int)?

    func bringToTop(_ id: String) { scrollTarget = (id, (scrollTarget?.n ?? 0) + 1) }

    /// The message a reply is aimed at, per chat (Grok bots only).
    var replyTo: [String: ChatMessage] = [:]
    /// A sideways swipe in progress over a message: which one, and how far it has been pulled.
    var swipe: (id: String, x: CGFloat)?
    /// The message under the pointer, for the swipe to act on.
    @ObservationIgnored var hoveredMessage: (agent: String, message: ChatMessage)?
    @ObservationIgnored private var swipeSum = CGSize.zero
    @ObservationIgnored private var swipeAxis: Bool?

    /// Two fingers sideways over a message pulls it aside; past a point, letting go aims the
    /// reply at it. Returns true when the gesture is being handled here, so the chat does not
    /// scroll at the same time.
    func scrolled(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas, expanded else { return false }
        if event.phase == .began {
            swipeSum = .zero
            swipeAxis = nil
        }
        guard let target = hoveredMessage else { return false }
        if event.phase == .changed {
            swipeSum.width += event.scrollingDeltaX
            swipeSum.height += event.scrollingDeltaY
            if swipeAxis == nil, abs(swipeSum.width) + abs(swipeSum.height) > 8 {
                swipeAxis = abs(swipeSum.width) > abs(swipeSum.height) * 1.6
            }
            guard swipeAxis == true else { return false }
            swipe = (target.message.id, max(-64, min(64, swipeSum.width * 0.7)))
            return true
        }
        if event.phase == .ended || event.phase == .cancelled {
            guard swipeAxis == true else { return false }
            if event.phase == .ended, abs(swipeSum.width) * 0.7 > 40 {
                replyTo[target.agent] = target.message
                focusReply = true
                controller?.panel.makeKey()
            }
            swipeAxis = nil
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { swipe = nil }
            return true
        }
        // Momentum after the fingers lift belongs to whichever gesture it was.
        return swipeAxis == true
    }
    /// Writing the first message of a new chat.
    var composing = false
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

    /// Chats the user has cleared out of the notch, and when. One comes back by itself the
    /// next time it does something.
    var dismissed: [String: Double] = UserDefaults.standard.dictionary(forKey: "dismissed") as? [String: Double] ?? [:] {
        didSet { UserDefaults.standard.set(dismissed, forKey: "dismissed") }
    }

    func isDismissed(_ agent: Agent) -> Bool {
        guard !pinnedChats.contains(agent.id), let at = dismissed[agent.id] else { return false }
        // It stays cleared through restarts and background housekeeping. Only something the user
        // would care about brings it back: it is working, it needs them, it has a new message,
        // or a turn started or finished after it was cleared.
        if agent.pending != nil || agent.status == .working || agent.status == .needsYou || agent.status == .unread { return false }
        return (agent.lastTurnAt?.timeIntervalSince1970 ?? 0) <= at
    }

    func dismiss(_ agent: Agent) {
        pinnedChats.remove(agent.id)
        agent.kept = false
        defer { AgentStore.shared.save() }
        dismissed[agent.id] = Date().timeIntervalSince1970
        if dismissed.count > 300 { dismissed = dismissed.filter { Date().timeIntervalSince1970 - $0.value < 14 * 86400 } }
        if selectedID == agent.id {
            let store = AgentStore.shared
            selectedID = (store.sessions + store.grokBots).first { !isDismissed($0) && $0.id != agent.id }?.id
        }
    }

    /// The order the user has dragged the sidebar into. Chats not in it follow in their usual order.
    var order: [String] = UserDefaults.standard.stringArray(forKey: "sidebarOrder") ?? [] {
        didSet { UserDefaults.standard.set(order, forKey: "sidebarOrder") }
    }

    /// Moves `id` to sit just above `target`, given what is currently shown, top to bottom.
    func move(_ id: String, before target: String, in shown: [String]) {
        guard id != target, shown.contains(id) else { return }
        // Arranging a chat is a sign it should stay.
        AgentStore.shared.find(id)?.kept = true
        defer { AgentStore.shared.save() }
        var list = shown.filter { $0 != id }
        list.insert(id, at: list.firstIndex(of: target) ?? list.count)
        order = list + order.filter { !list.contains($0) }.prefix(200)
    }

    /// Chats pinned to the notch: always shown, never tidied away, sat under the bots.
    var pinnedChats: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "pinnedChats") ?? []) {
        didSet { UserDefaults.standard.set(Array(pinnedChats), forKey: "pinnedChats") }
    }

    func togglePin(_ agent: Agent) {
        if pinnedChats.contains(agent.id) {
            pinnedChats.remove(agent.id)
        } else {
            pinnedChats.insert(agent.id)
            agent.kept = true
            dismissed[agent.id] = nil
        }
        AgentStore.shared.save()
    }

    func inPill(_ agent: Agent) -> Bool {
        if agent.source == .grok, GrokSource.hidden.contains(agent.sessionID) { return selectedID == agent.id }
        return agent.status != .idle || agent.pending != nil || (agent.source == .grok && pinned.contains(agent.name))
    }

    @ObservationIgnored weak var controller: NotchController?
    @ObservationIgnored private var hovering = false
    /// Held open on purpose (a file chooser is up for it): moving away or clicking elsewhere
    /// does not close it.
    @ObservationIgnored var heldOpen = false
    @ObservationIgnored private var autoOpened = false
    @ObservationIgnored private var holdOpenUntil = Date.distantPast
    @ObservationIgnored private var expandWork: DispatchWorkItem?
    @ObservationIgnored private var collapseWork: DispatchWorkItem?

    func isDrafting(_ id: String) -> Bool { !(drafts[id] ?? "").isEmpty || !(attachments[id] ?? []).isEmpty }

    /// Once a row is open the island has keyboard focus, and it stays until Esc or a click elsewhere.
    private var typing: Bool { controller?.panel.isKeyWindow ?? false }

    /// Cmd+V with an image on the clipboard attaches it to the reply being written.
    struct Enlarged {
        let image: NSImage
        let name: String
        /// Shown over the side panel's chat rather than the notch's.
        let side: Bool
    }

    /// A picture clicked in a chat, shown big over it.
    var enlarged: Enlarged?

    func enlarge(_ image: NSImage, name: String, side: Bool) {
        withAnimation(.easeOut(duration: 0.18)) { enlarged = Enlarged(image: image, name: name, side: side) }
    }

    /// Pictures pasted into a chat open in the side panel go to that chat.
    func pasteImages(into id: String) -> Bool {
        let images = Attachment.fromPasteboard()
        guard !images.isEmpty else { return false }
        attachments[id, default: []].append(contentsOf: images)
        return true
    }

    func pasteImages() -> Bool {
        // The chat on screen is the one being written to. (Going by which box last had the
        // cursor could point at a chat that is no longer showing, and the picture vanished.)
        // Starting a new chat collects them under "new"; otherwise the chat on screen.
        guard expanded, !showingClips, !showingShelf, !showingTasks,
              let id = composing ? "new" : (selectedID ?? focusedAgentID) else { return false }
        let images = Attachment.fromPasteboard()
        guard !images.isEmpty else { return false }
        attachments[id, default: []].append(contentsOf: images)
        return true
    }

    @ObservationIgnored private var stripWork: DispatchWorkItem?

    /// From a banner to everything: the banner gives way to the whole island.
    func showEverything() {
        guard expanded, cardsOnly else { return }
        stripWork?.cancel()
        collapseWork?.cancel()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            cardsOnly = false
            slackAlert = nil
            noticeID = nil
            autoOpened = false
        }
    }

    /// The pointer resting on the notch strip above a banner means the user wants the rest of
    /// the notch, not that message: after a moment, open it all.
    func overStrip(_ over: Bool) {
        stripWork?.cancel()
        guard over, expanded, cardsOnly else { return }
        let work = DispatchWorkItem { [weak self] in self?.showEverything() }
        stripWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func hover(_ inside: Bool) {
        guard inside != hovering else { return }
        hovering = inside
        if inside {
            // The banner dropped down onto a pointer that was already there. That is not someone
            // coming up to read it, so it stays a banner and still times out.
            if expanded, cardsOnly, noticeID != nil, !noticeArmed { return }
            collapseWork?.cancel()
            autoOpened = false
            // A Slack banner stays a banner: clicking it opens Slack.
            if expanded, cardsOnly, slackAlert != nil {
                collapseWork?.cancel()
                autoOpened = false
                return
            }
            if expanded, cardsOnly, let id = noticeID {
                // Coming up to a notification opens it into the full conversation, after a beat
                // so a pointer just passing through does not trigger it.
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.hovering, self.cardsOnly, self.noticeID == id else { return }
                    self.cardsOnly = false
                    self.composing = false
                    self.browsing = false
                    self.selectedID = id
                    self.focusReply = false
                    // Opening it this way is reading it, same as a click.
                    UserDefaults.standard.set(id, forKey: "lastChat")
                    self.markSeen(id)
                }
                expandWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
                return
            }
            guard !expanded else { return }
            // A short pause so brushing past the menu bar does not open it.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hovering else { return }
                self.expand()
            }
            expandWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        } else {
            expandWork?.cancel()
            noticeArmed = true
            scheduleCollapse(after: 0.22)
        }
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering, !self.typing, !self.autoOpened, !self.heldOpen, self.pendingLinks.isEmpty else { return }
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
        if selectedID == nil, !browsing, !composing {
            // Open straight onto a conversation: whoever needs you, else the one you last had open.
            let store = AgentStore.shared
            let last = UserDefaults.standard.string(forKey: "lastChat").flatMap { store.find($0) }
            let pick = store.needing.first ?? last ?? store.sessions.first ?? store.grokBots.first
            selectedID = pick?.id
            focusReply = false
        }
        resumeDraft()
    }

    /// Back to the full list.
    func browse() {
        selectedID = nil
        composing = false
        showingProfiles = false
        showingTasks = false
        showingClips = false
        slackTarget = nil
        clipsInline = false
        showingShelf = false
        browsing = true
        searchIndex = 0
        // Straight into typing: the search field takes the keyboard.
        controller?.panel.makeKey()
    }

    /// Reopening with a reply half written puts the cursor straight back in it.
    private func resumeDraft() {
        if let id = selectedID, isDrafting(id) { controller?.panel.makeKey() }
    }

    func collapse() {
        enlarged = nil
        toast = nil
        guard expanded else { return }
        expanded = false
        cardsOnly = false
        slackAlert = nil
        pendingLinks = []
        justOpened = nil
        query = ""
        if !isDrafting("new") { composing = false }
        // Keep the row with an unsent reply selected, so it is right there on reopening.
        if let id = selectedID, !isDrafting(id) { selectedID = nil }
        browsing = false
        showingProfiles = false
        showingTasks = false
        showingClips = false
        slackTarget = nil
        clipsInline = false
        showingShelf = false
        focusReply = false
        Dictation.shared.stop()
        autoOpened = false
        controller?.releaseKey()
    }

    func select(_ id: String) {
        enlarged = nil
        composing = false
        browsing = false
        showingProfiles = false
        showingTasks = false
        showingClips = false
        slackTarget = nil
        clipsInline = false
        showingShelf = false
        selectedID = id
        focusReply = true
        UserDefaults.standard.set(id, forKey: "lastChat")
        controller?.panel.makeKey()
        markSeen(id)
    }

    /// Puts a chat on screen without taking the keyboard. For checking, not for use.
    func peek(_ id: String) {
        composing = false
        browsing = false
        selectedID = id
    }

    func show(_ id: String) {
        cardsOnly = false
        composing = false
        browsing = false
        showingProfiles = false
        showingTasks = false
        showingClips = false
        slackTarget = nil
        clipsInline = false
        showingShelf = false
        focusReply = true
        UserDefaults.standard.set(id, forKey: "lastChat")
        expanded = true
        selectedID = id
        controller?.panel.makeKey()
        markSeen(id)
    }

    /// Opening a row counts as reading it, so its badge clears here and in the agent's own app.
    func markSeen(_ id: String) {
        guard let agent = AgentStore.shared.find(id) else { return }
        if agent.source == .grok {
            GrokSource.shared.markRead(agent)
        } else if agent.status == .done {
            // It may still be holding the door open for a follow-up, so the status stays; the
            // hop and the green dot are what stop.
            agent.seen = true
            if agent.pending == nil { agent.status = .idle }
        }
    }

    /// Links waiting for a profile to be chosen, oldest first.
    private(set) var pendingLinks: [PendingLink] = []
    /// A link that was just opened without asking, shown briefly so it can be changed.
    private(set) var justOpened: (url: URL, site: String, profile: ChromeProfile)?
    @ObservationIgnored private var announceWork: DispatchWorkItem?

    /// A link was clicked and Perch does not know where it goes: ask, and wait for the answer.
    func present(_ link: PendingLink) {
        pendingLinks.append(link)
        justOpened = nil
        autoOpened = true
        cardsOnly = true
        noticeID = nil
        holdOpenUntil = Date().addingTimeInterval(1)
        collapseWork?.cancel()
        expanded = true
        // The user has just clicked a link, so number keys go to the picker.
        controller?.panel.makeKey()
    }

    func resolveLink(_ profile: ChromeProfile, always: Bool) {
        guard let link = pendingLinks.first else { return }
        pendingLinks.removeFirst()
        LinkRouter.shared.open(link, in: profile, always: always)
        if pendingLinks.isEmpty { collapse() }
    }

    /// Says where a link went when Perch chose by itself, with a way to change it.
    func announce(url: URL, site: String, openedIn profile: ChromeProfile) {
        guard pendingLinks.isEmpty, !expanded || autoOpened else { return }
        justOpened = (url, site, profile)
        autoOpened = true
        cardsOnly = true
        noticeID = nil
        expanded = true
        announceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.justOpened != nil, !self.hovering else { return }
            self.collapse()
        }
        announceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    /// The automatic choice was wrong: forget it and ask.
    func reconsider() {
        guard let last = justOpened else { return }
        LinkRouter.shared.forget(last.site)
        justOpened = nil
        present(PendingLink(url: last.url, site: last.site, sourceName: nil, sourceBundle: nil, choices: ChromeProfile.shown()))
    }

    /// A Slack message being shown as a banner.
    private(set) var slackAlert: SlackAlert?

    /// A Slack message: drop the banner down, like an agent's. A less important workspace does
    /// not push aside a banner from a more important one that is still showing.
    /// Something new from another conversation while the island is open on a chat: a small
    /// banner over the top of it, like a phone's, rather than pulling the view away.
    enum Toast: Equatable {
        case agent(String)
        case slack(SlackAlert)
        var key: String {
            switch self {
            case .agent(let id): return id
            case .slack(let a): return a.id
            }
        }
    }
    var toast: Toast?
    var toastHovered = false
    @ObservationIgnored private var toastWork: DispatchWorkItem?

    func showToast(_ toast: Toast) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { self.toast = toast }
        hideToastSoon()
    }

    func hideToastSoon(after delay: Double = 5) {
        toastWork?.cancel()
        let key = toast?.key
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.toast?.key == key else { return }
            if self.toastHovered { return self.hideToastSoon(after: 2) }
            withAnimation(.easeIn(duration: 0.2)) { self.toast = nil }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func slack(_ alert: SlackAlert) {
        noteSlack(alert)
        guard pendingLinks.isEmpty else { return }
        if expanded && !autoOpened {
            // Already reading that very conversation: it shows up there by itself.
            let reading = slackTarget.map { t in t.workspace == alert.workspace && (t.id == alert.channel || alert.direct) } ?? false
            if !reading {
                if Settings.sounds { Settings.playSound() }
                showToast(.slack(alert))
            }
            return
        }
        if let showing = slackAlert, expanded, cardsOnly, showing.priority < alert.priority { return }
        if Settings.sounds { Settings.playSound() }
        autoOpened = true
        cardsOnly = true
        noticeID = nil
        slackAlert = alert
        expanded = true
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.slackAlert?.id == alert.id, !self.hovering, !self.typing else { return }
            self.collapse()
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    /// The agent a self-opened summary banner is about.
    private(set) var noticeID: String?
    /// Hovering only opens a banner once the pointer has been seen away from it.
    @ObservationIgnored private var noticeArmed = true

    /// Something wants the user: drop down a short summary, like a notification. It shows for a
    /// few seconds and tucks away unless the pointer has come up to it; clicking it opens the
    /// full chat. The face in the notch keeps signalling until it is dealt with.
    func attention(_ store: AgentStore) {
        guard let id = store.attentionAgentID, store.find(id) != nil else { return }
        // A link picker is waiting on an answer; do not replace it with a notification.
        guard pendingLinks.isEmpty else { return }
        // Already open and in use: do not pull the view out from under the user. Unless it is the
        // chat on screen, a small banner says what came in.
        if expanded && !autoOpened {
            if id != selectedID || cardsOnly { showToast(.agent(id)) }
            return
        }
        if !expanded || noticeID != id {
            noticeArmed = false
            // Once it has finished dropping, a pointer that is clear of it can come up and open it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.noticeID == id, !self.hovering else { return }
                self.noticeArmed = true
            }
        }
        autoOpened = true
        cardsOnly = true
        slackAlert = nil
        noticeID = id
        holdOpenUntil = Date().addingTimeInterval(1.5)
        expanded = true
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.autoOpened || self.cardsOnly, !(self.hovering && self.noticeArmed), !self.typing else { return }
            self.collapse()
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    func pendingChanged(_ count: Int) {
        if count == 0, autoOpened {
            autoOpened = false
            scheduleCollapse(after: 0.9)
        }
    }

    func outsideClick() {
        // A notification banner is not dismissed by carrying on working; it times out by itself.
        // Clicking away from a link picker cancels it; a plain notification just times out.
        guard expanded, !heldOpen, !cardsOnly || !pendingLinks.isEmpty, Date() >= holdOpenUntil else { return }
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
    private var dragWatch: Timer?
    private static let canvas = CGSize(width: 860, height: 680)

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
        let host = FirstClickHostingView(rootView: NotchRoot().environment(store).environment(ui))
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
        // While a mouse button is held (a file being dragged up from another app, say) the pointer
        // is followed on a timer, because ordinary movement events stop arriving during a drag.
        // A file being dragged towards the notch drops the shelf down to take it. Watched on a timer
        // while the button is held, because ordinary movement events stop arriving during a drag
        // from another app. It opens once the pointer, still held, comes up near the notch with a
        // file or picture on the drag clipboard; dragging things around elsewhere leaves it alone.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            let start = NSEvent.mouseLocation
            self?.dragWatch?.invalidate()
            self?.dragWatch = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] timer in
                guard let self else { return timer.invalidate() }
                guard NSEvent.pressedMouseButtons & 1 == 1 else {
                    timer.invalidate()
                    self.ui.fileDrag(false)
                    return
                }
                let now = NSEvent.mouseLocation
                let frame = self.panel.frame
                let nearNotch = now.y > frame.maxY - 110 && abs(now.x - frame.midX) < 330
                let moved = hypot(now.x - start.x, now.y - start.y) > 40
                if nearNotch, moved, !self.ui.fileInHand,
                   NSPasteboard(name: .drag).types?.contains(where: { [.fileURL, .tiff, .png].contains($0) || $0.rawValue.contains("promise") }) == true {
                    self.ui.fileDrag(true)
                }
                self.trackMouse()
            }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.ui.outsideClick()
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            self?.ui.scrolled(event) == true ? nil : event
        }) { monitors.append(m) }
        // A click on the island gives it the keyboard straight away, so the first click on a text
        // box starts typing instead of only waking the window up.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            if let self, self.ui.expanded, event.window === self.panel, !self.panel.isKeyWindow { self.panel.makeKey() }
            return event
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53, self?.ui.enlarged != nil {
                withAnimation(.easeOut(duration: 0.15)) { self?.ui.enlarged = nil }
                return nil
            }
            if event.keyCode == 53 {
                if self?.ui.showingClips == true { self?.ui.closeClips() } else { self?.ui.collapse() }
                return nil
            }
            // With a link picker up: 1 to 9 picks that profile, Return takes the suggested one.
            if let ui = self?.ui, let link = ui.pendingLinks.first, !event.modifierFlags.contains(.command) {
                let key = event.charactersIgnoringModifiers ?? ""
                if let n = Int(key), n >= 1, n <= link.choices.count {
                    ui.resolveLink(link.choices[n - 1], always: false)
                    return nil
                }
                if event.keyCode == 36, let pick = link.choices.first(where: { $0.id == link.suggested }) {
                    ui.resolveLink(pick, always: false)
                    return nil
                }
            }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v",
               event.window is SidePanelWindow, let id = SidePanel.shared.agentID {
                return self?.ui.pasteImages(into: id) == true ? nil : event
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

    private func trackMouse() {
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        // Slack all round, and plenty upwards so pushing against the top edge still counts.
        let island = CGRect(x: frame.minX + liveRect.minX, y: frame.maxY - liveRect.maxY,
                            width: liveRect.width, height: liveRect.height + 20).insetBy(dx: -3, dy: -3)
        // Closed, the whole strip above where the island opens is the trigger, not just the pill.
        let strip = CGRect(x: frame.midX + openOffset - openWidth / 2, y: frame.maxY - ui.notch.height,
                           width: openWidth, height: ui.notch.height + 20)
        let onIsland = island.contains(mouse)
        // Tell the edge guard which stretch of the top edge belongs to the island right now.
        if let primary = NSScreen.screens.first {
            let span = ui.expanded ? island : strip
            EdgeGuard.shared.setZone(minX: span.minX, maxX: span.maxX, topY: primary.frame.maxY - frame.maxY)
            EdgeGuard.shared.engage(mouse.x > span.minX - 60 && mouse.x < span.maxX + 60 && mouse.y > frame.maxY - 70)
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
            // Links Perch made itself (a file, a session) are handled here; real web links go on
            // to the browser as usual.
            .environment(\.openURL, OpenURLAction { url in References.open(url) ? .handled : .systemAction })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .preferredColorScheme(.dark)
    }
}
