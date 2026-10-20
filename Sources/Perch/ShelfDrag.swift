import AppKit

/// The drag pasteboard outlives a drag. Only data written since this mouse press
/// belongs to the current gesture; an ordinary window move leaves it unchanged.
struct ShelfDrag {
    private let pasteboard: NSPasteboard
    private let initialChangeCount: Int

    init(pasteboard: NSPasteboard = NSPasteboard(name: .drag)) {
        self.pasteboard = pasteboard
        initialChangeCount = pasteboard.changeCount
    }

    var hasNewFilePayload: Bool {
        guard pasteboard.changeCount != initialChangeCount else { return false }
        return pasteboard.types?.contains {
            [.fileURL, .tiff, .png].contains($0) || NSFilePromiseReceiver.readableDraggedTypes.contains($0.rawValue)
        } == true
    }
}
