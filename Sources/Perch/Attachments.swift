import AppKit
import UniformTypeIdentifiers

/// An image waiting to be sent with a reply. Saved to disk first, because that is how it
/// reaches every kind of agent: uploaded for Grok bots, read by path for Claude Code and Codex.
struct Attachment: Identifiable {
    let id: UUID
    let path: String
    let name: String
    let thumbnail: NSImage

    init(id: UUID = UUID(), path: String, name: String, thumbnail: NSImage) {
        self.id = id
        self.path = path
        self.name = name
        self.thumbnail = thumbnail
    }

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

/// Saves the association between reply drafts and their files; the files already live on disk.
enum DraftAttachments {
    struct Record: Codable {
        let id: UUID
        let path: String
        let name: String
    }
    static let file = URL(fileURLWithPath: "\(Shell.home)/.perch/draft-attachments.json")

    static func load(from url: URL = file) -> [String: [Attachment]] {
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([String: [Record]].self, from: data) else { return [:] }
        return rows.reduce(into: [:]) { result, row in
            let files = row.value.compactMap { record -> Attachment? in
                guard FileManager.default.fileExists(atPath: record.path) else { return nil }
                let image = NSImage(contentsOfFile: record.path) ?? NSWorkspace.shared.icon(forFile: record.path)
                return Attachment(id: record.id, path: record.path, name: record.name, thumbnail: image)
            }
            if !files.isEmpty { result[row.key] = files }
        }
    }

    static func save(_ drafts: [String: [Attachment]], to url: URL = file) throws {
        let rows = drafts.filter { !$0.value.isEmpty }.mapValues { files in
            files.map { Record(id: $0.id, path: $0.path, name: $0.name) }
        }
        let data = try JSONEncoder().encode(rows)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
