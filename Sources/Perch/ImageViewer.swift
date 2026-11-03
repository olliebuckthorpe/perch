import AppKit
import SwiftUI

/// A picture from a chat, shown large in its own window over Perch and everything else. A click
/// anywhere or Esc closes it.
final class ImageViewer {
    static let shared = ImageViewer()
    /// The file on show, so a sharper copy that finishes downloading can replace the preview.
    private(set) var name: String?
    private var panel: ViewerPanel?

    func show(_ image: NSImage, name: String) {
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame.insetBy(dx: 40, dy: 40)
        // As large as fits, keeping its shape, never blown up past twice its own size.
        let natural = image.size.width > 0 && image.size.height > 0 ? image.size : CGSize(width: 800, height: 600)
        let scale = min(area.width / natural.width, area.height / natural.height, 2)
        let size = CGSize(width: max(natural.width * scale, 240), height: max(natural.height * scale, 180))
        let frame = NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)

        let isNew = panel == nil
        let panel = self.panel ?? ViewerPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                              backing: .buffered, defer: false)
        self.panel = panel
        self.name = name
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onClose = { [weak self] in self?.close() }
        panel.contentView = NSHostingView(rootView: ViewerContent(image: image, name: name) { [weak self] in self?.close() })
        panel.setFrame(frame, display: true)
        if isNew {
            openedAt = Date()
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { $0.duration = 0.16; panel.animator().alphaValue = 1 }
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// When it opened: the second click of a double-click lands on it and must not close it.
    private var openedAt = Date.distantPast

    func close() {
        guard let panel, Date().timeIntervalSince(openedAt) > 0.5 else { return }
        self.panel = nil
        name = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 }) {
            panel.orderOut(nil)
        }
    }
}

private final class ViewerPanel: NSPanel {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onClose?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || event.keyCode == 49 { onClose?() } else { super.keyDown(with: event) }
    }
    override func resignKey() {
        super.resignKey()
        // Clicking somewhere else puts it away, as Quick Look does.
        onClose?()
    }
}

private struct ViewerContent: View {
    let image: NSImage
    let name: String
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
            HStack(spacing: 6) {
                Button { saveToDownloads(image: image, name: name) } label: {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white).frame(width: 28, height: 28)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain).help("Save to Downloads")
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white).frame(width: 28, height: 28)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain).help("Close (Esc)")
            }
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
