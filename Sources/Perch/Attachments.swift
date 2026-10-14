import AppKit
import UniformTypeIdentifiers

/// An image waiting to be sent with a reply. Saved to disk first, because that is how it
/// reaches every kind of agent: uploaded for Grok bots, read by path for Claude Code and Codex.
struct Attachment: Identifiable {
    let id = UUID()
    let path: String
    let name: String
    let thumbnail: NSImage

    private static let dir = "\(Shell.home)/.perch/attachments"

    static func save(_ data: Data, ext: String) -> Attachment? {
        guard let image = NSImage(data: data) else { return nil }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let name = "image-\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
        let path = "\(dir)/\(name)"
        guard FileManager.default.createFile(atPath: path, contents: data) else { return nil }
        return Attachment(path: path, name: name, thumbnail: image)
    }

    static func from(_ image: NSImage) -> Attachment? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        // Screenshots are fine as PNG; anything heavy goes out as JPEG to keep uploads quick.
        if let png = rep.representation(using: .png, properties: [:]), png.count <= 2 << 20 {
            return save(png, ext: "png")
        }
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return save(jpeg, ext: "jpg")
    }

    var isImage: Bool { UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)?.conforms(to: .image) == true }

    /// Any file. A picture is copied in like a pasted one; anything else (a PDF, a spreadsheet)
    /// is sent from where it already is, shown with its Finder icon.
    static func from(file url: URL) -> Attachment? {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
           let data = try? Data(contentsOf: url), let copy = save(data, ext: url.pathExtension.lowercased()) {
            return copy
        }
        return Attachment(path: url.path, name: url.lastPathComponent, thumbnail: NSWorkspace.shared.icon(forFile: url.path))
    }

    /// The note a Claude Code or Codex message carries for it; the chat draws the note as the file.
    var note: String { isImage ? "[Image attached, saved at \(path)]" : "[File attached, saved at \(path)]" }

    /// Images on the clipboard, unless it also holds text (then it is an ordinary paste).
    static func fromPasteboard() -> [Attachment] {
        let pb = NSPasteboard.general
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            return urls.compactMap { from(file: $0) }
        }
        guard pb.string(forType: .string) == nil, let image = NSImage(pasteboard: pb) else { return [] }
        return from(image).map { [$0] } ?? []
    }
}
