import SwiftUI

/// One sidebar action target, shared by bots, coding sessions, WhatsApp and Slack.
enum SidebarChat: Identifiable {
    case agent(Agent)
    case conversation(SlackTarget)

    var id: String {
        switch self {
        case .agent(let a): return a.id
        case .conversation(let t): return "conversation:\(t.workspace):\(t.id)"
        }
    }
    var name: String {
        switch self {
        case .agent(let a): return a.name
        case .conversation(let t):
            if t.workspace == WhatsAppSource.workspace,
               let live = WhatsAppSource.shared.chats.first(where: { $0.id == t.id }) { return live.name }
            return t.label
        }
    }
}

extension NotchUI {
    func sidebarPinned(_ chat: SidebarChat) -> Bool {
        switch chat {
        case .agent(let a): return a.source == .grok ? pinned.contains(a.name) : pinnedChats.contains(a.id)
        case .conversation(let t): return pinnedConversations.contains("\(t.workspace):\(t.id)")
        }
    }

    func toggleSidebarPin(_ chat: SidebarChat) {
        switch chat {
        case .agent(let a):
            if a.source == .grok {
                if pinned.contains(a.name) { pinned.remove(a.name) }
                else { pinned.insert(a.name); GrokSource.hidden.remove(a.sessionID) }
            } else { togglePin(a) }
        case .conversation(let t):
            let key = "\(t.workspace):\(t.id)"
            if pinnedConversations.contains(key) { pinnedConversations.remove(key) }
            else { pinnedConversations.insert(key) }
        }
    }

    static func sidebarActivity(_ agent: Agent) -> String {
        "\(agent.status.rawValue)|\(agent.lastTurnAt?.timeIntervalSince1970 ?? 0)|\(agent.lastMessage)"
    }

    func removeSidebarChat(_ chat: SidebarChat) {
        let wasPinned = sidebarPinned(chat)
        // Swiping away the chat on screen glides back to the lead bot (Remmi), the base.
        let wasOpen: Bool
        switch chat {
        case .agent(let a): wasOpen = selectedID == a.id
        case .conversation(let t): wasOpen = slackTarget?.workspace == t.workspace && slackTarget?.id == t.id
        }
        defer {
            if wasOpen, let base = AgentStore.shared.grokBots.first(where: { pinned.contains($0.name) && $0.id != chat.id }) {
                withAnimation(.easeOut(duration: 0.2)) { select(base.id) }
            }
        }
        switch chat {
        case .agent(let a):
            let kept = a.kept, oldDismissal = dismissed[a.id], oldRemoval = sidebarRemovals[a.id]
            let hidden = GrokSource.hidden.contains(a.sessionID)
            if a.source == .grok {
                pinned.remove(a.name)
                GrokSource.shared.hide(a)
                if selectedID == a.id { selectedID = nil }
            } else {
                dismiss(a)
                sidebarRemovals[a.id] = Self.sidebarActivity(a)
            }
            sidebarUndoAction = { [weak self, weak a] in
                guard let self, let a else { return }
                a.kept = kept
                self.dismissed[a.id] = oldDismissal
                self.sidebarRemovals[a.id] = oldRemoval
                if a.source == .grok {
                    if !hidden { GrokSource.hidden.remove(a.sessionID) }
                    if wasPinned { self.pinned.insert(a.name) }
                } else if wasPinned { self.pinnedChats.insert(a.id) }
                AgentStore.shared.save()
            }
        case .conversation(let t):
            let key = "\(t.workspace):\(t.id)"
            let index = slackRecent.firstIndex { $0.workspace == t.workspace && $0.id == t.id } ?? slackRecent.count
            let unread = slackUnread[key], dismissal = slackDismissed[key]
            pinnedConversations.remove(key)
            dropSlack(t)
            sidebarUndoAction = { [weak self] in
                guard let self else { return }
                self.slackDismissed[key] = dismissal
                self.slackUnread[key] = unread
                if !self.slackRecent.contains(where: { $0.workspace == t.workspace && $0.id == t.id }) {
                    self.slackRecent.insert(t, at: min(index, self.slackRecent.count))
                }
                if wasPinned { self.pinnedConversations.insert(key) }
            }
        }
        sidebarUndoName = chat.name
        // The offer to undo lasts a few seconds, then goes.
        let name = chat.name
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.sidebarUndoName == name else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                self.sidebarUndoName = nil
                self.sidebarUndoAction = nil
            }
        }
    }

    func undoSidebarRemoval() {
        let undo = sidebarUndoAction
        sidebarUndoAction = nil
        sidebarUndoName = nil
        undo?()
    }
}
