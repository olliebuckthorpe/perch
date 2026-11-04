import AppKit
import SwiftUI

/// A multi-line text box built on AppKit's own text view, so long messages type and scroll the
/// way they do in any Mac app. It grows to fit, up to `maxHeight`, then scrolls.
struct GrowingText: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusAsk: Int
    var onFocus: (Bool) -> Void
    var onSubmit: () -> Void
    var onTab: () -> Bool
    var maxHeight: CGFloat = 120
    /// The text's own height as it wraps, for a box that lays itself out around it.
    var onHeight: ((CGFloat) -> Void)?

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingText
        var asked = 0
        weak var view: NSTextView?
        init(_ parent: GrowingText) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let view else { return }
            // Avoid a model write and another render pass for redundant AppKit callbacks.
            if parent.text != view.string { parent.text = view.string }
        }
        func textDidBeginEditing(_ note: Notification) { parent.onFocus(true) }
        func textDidEndEditing(_ note: Notification) { parent.onFocus(false) }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            }
            if selector == #selector(NSResponder.insertTab(_:)) { return parent.onTab() }
            return false
        }
    }

    final class Box: NSScrollView {
        var maxHeight: CGFloat = 120
        var onHeight: ((CGFloat) -> Void)?
        private var reportedHeight: CGFloat = 18
        private var toldHeight: CGFloat = 0

        func textHeightMayHaveChanged() {
            let previous = reportedHeight
            let current = intrinsicContentSize.height
            // Most keystrokes change glyphs, not the box's height. Do not send them through
            // the surrounding chat/notch layout until a line wraps, is added, or is removed.
            if abs(current - previous) > 0.5 { invalidateIntrinsicContentSize() }
        }

        override var intrinsicContentSize: NSSize {
            guard let view = documentView as? NSTextView, let layout = view.layoutManager, let container = view.textContainer else {
                return NSSize(width: NSView.noIntrinsicMetric, height: 18)
            }
            layout.ensureLayout(for: container)
            let h = layout.usedRect(for: container).height
            reportedHeight = min(max(h, 17), maxHeight)
            if let onHeight, abs(h - toldHeight) > 0.5 {
                toldHeight = h
                DispatchQueue.main.async { onHeight(h) }
            }
            return NSSize(width: NSView.noIntrinsicMetric, height: reportedHeight)
        }
    }

    final class Field: NSTextView {
        override func didChangeText() {
            super.didChangeText()
            (enclosingScrollView as? Box)?.textHeightMayHaveChanged()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Box {
        Self.makeBox(coordinator: context.coordinator, maxHeight: maxHeight, text: text)
    }

    static func makeBox(coordinator: Coordinator, maxHeight: CGFloat, text: String) -> Box {
        let box = Box()
        box.maxHeight = maxHeight
        box.drawsBackground = false
        box.hasVerticalScroller = true
        box.autohidesScrollers = true
        box.borderType = .noBorder
        box.verticalScrollElasticity = .allowed

        let view = Field()
        view.delegate = coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.font = .systemFont(ofSize: 13)
        view.textColor = .white
        view.insertionPointColor = .white
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        // Plain typing: no curly quotes or dashes swapped in behind your back.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.string = text
        box.documentView = view
        coordinator.view = view
        return box
    }

    func updateNSView(_ box: Box, context: Context) {
        updateBox(box, coordinator: context.coordinator)
    }

    func updateBox(_ box: Box, coordinator: Coordinator) {
        coordinator.parent = self
        box.onHeight = onHeight
        guard let view = coordinator.view else { return }
        if view.string != text {
            // Changed from outside (dictation, a suggestion, sending): keep the cursor at the end.
            view.string = text
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            view.scrollToEndOfDocument(nil)
            box.textHeightMayHaveChanged()
        }
        if box.maxHeight != maxHeight {
            box.maxHeight = maxHeight
            box.invalidateIntrinsicContentSize()
        }
        if coordinator.asked != focusAsk {
            coordinator.asked = focusAsk
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }
}


/// The native text view owns its character updates. DraftStore still saves every edit and
/// updates empty-state/command controls, without sending each keystroke through SwiftUI layout.
struct DraftText: NSViewRepresentable {
    let store: DraftStore
    let id: String
    var placeholder: String
    var focusAsk: Int
    var onFocus: (Bool) -> Void
    var onSubmit: () -> Void
    var onTab: () -> Bool
    var maxHeight: CGFloat = 120
    var onHeight: ((CGFloat) -> Void)?

    private var configuration: GrowingText {
        GrowingText(text: Binding(get: { store.snapshot(id) }, set: { store[id] = $0 }),
                    placeholder: placeholder, focusAsk: focusAsk, onFocus: onFocus,
                    onSubmit: onSubmit, onTab: onTab, maxHeight: maxHeight, onHeight: onHeight)
    }

    final class Coordinator {
        let editor: GrowingText.Coordinator
        private var store: DraftStore?
        private var id: String?
        private var token: UUID?

        init(_ configuration: GrowingText) { editor = GrowingText.Coordinator(configuration) }

        func connect(store: DraftStore, id: String, box: GrowingText.Box) {
            guard self.store !== store || self.id != id else { return }
            disconnect()
            self.store = store
            self.id = id
            token = store.observeText(id) { [weak self, weak box] _ in
                guard let self, let box else { return }
                self.editor.parent.updateBox(box, coordinator: self.editor)
            }
        }

        func disconnect() {
            if let store, let id, let token { store.removeTextObserver(id, token: token) }
            token = nil
            store = nil
            id = nil
        }

        deinit { disconnect() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(configuration) }

    func makeNSView(context: Context) -> GrowingText.Box {
        let box = GrowingText.makeBox(coordinator: context.coordinator.editor, maxHeight: maxHeight,
                                      text: store.snapshot(id))
        context.coordinator.connect(store: store, id: id, box: box)
        return box
    }

    func updateNSView(_ box: GrowingText.Box, context: Context) {
        configuration.updateBox(box, coordinator: context.coordinator.editor)
        context.coordinator.connect(store: store, id: id, box: box)
    }

    static func dismantleNSView(_ box: GrowingText.Box, coordinator: Coordinator) {
        coordinator.disconnect()
        (box.documentView as? NSTextView)?.delegate = nil
    }
}


/// A message box's row: the text, then its buttons. While the message fits on one line they sit
/// beside it; once it wraps, the text takes the full width and the buttons drop to a row under
/// it, as in Messages or Slack. One layout for both, so the text view (and the cursor in it) is
/// never rebuilt when it changes over.
struct ComposerLayout: Layout {
    var tall: Bool
    var spacing: CGFloat = 6

    private func tools(_ subviews: Subviews) -> (sizes: [CGSize], width: CGFloat, height: CGFloat) {
        let sizes = subviews.dropFirst().map { $0.sizeThatFits(.unspecified) }
        let width = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(sizes.count - 1, 0))
        return (sizes, width, sizes.map(\.height).max() ?? 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let width = proposal.width ?? 320
        let row = tools(subviews)
        if tall {
            let t = text.sizeThatFits(ProposedViewSize(width: width, height: nil))
            return CGSize(width: width, height: t.height + spacing + row.height)
        }
        let t = text.sizeThatFits(ProposedViewSize(width: max(width - row.width - spacing, 40), height: nil))
        return CGSize(width: width, height: max(t.height, row.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let text = subviews.first else { return }
        let row = tools(subviews)
        let textWidth = tall ? bounds.width : max(bounds.width - row.width - spacing, 40)
        let textHeight = tall ? bounds.height - spacing - row.height : bounds.height
        text.place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: ProposedViewSize(width: textWidth, height: textHeight))
        var x = bounds.maxX - row.width
        for (view, size) in zip(subviews.dropFirst(), row.sizes) {
            view.place(at: CGPoint(x: x, y: bounds.maxY - (row.height + size.height) / 2), proposal: ProposedViewSize(size))
            x += size.width + spacing
        }
    }
}
