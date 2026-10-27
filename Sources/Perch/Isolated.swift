import AppKit
import SwiftUI

/// Draws a small, constantly moving view (a working face) in a hosting view of its own, so
/// each of its frames redraws just that view. Inline, every frame of an animation also made
/// SwiftUI re-check the whole island around it: with the notch open, the chat, the sidebar and
/// every other face, many times a second.
struct Isolated<Content: View>: NSViewRepresentable {
    let size: CGSize
    let content: Content

    init(width: CGFloat, height: CGFloat, @ViewBuilder content: () -> Content) {
        size = CGSize(width: width, height: height)
        self.content = content()
    }

    func makeNSView(context: Context) -> DrawingOnlyHostingView<Content> {
        let host = DrawingOnlyHostingView(rootView: content)
        host.sizingOptions = []
        host.safeAreaRegions = []
        return host
    }

    func updateNSView(_ host: DrawingOnlyHostingView<Content>, context: Context) {
        host.rootView = content
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DrawingOnlyHostingView<Content>, context: Context) -> CGSize? {
        size
    }
}

/// Draws only: clicks and hovering go to the view around it, which owns them.
final class DrawingOnlyHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
