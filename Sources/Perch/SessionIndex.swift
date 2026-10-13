import Foundation
import Observation

/// Titles of recent Claude Code sessions that are not live in the notch, so search can find them.
@Observable
final class SessionIndex {
    static let shared = SessionIndex()

    struct Entry: Identifiable {
        let id: String
        let title: String
        let path: String
        let cwd: String?
        let modified: Date
    }

    private(set) var entries: [Entry] = []
    @ObservationIgnored private var builtAt = Date.distantPast
    @ObservationIgnored private var building = false

    func refresh() {
        guard !building, Date().timeIntervalSince(builtAt) > 60 else { return }
        building = true
        DispatchQueue.global(qos: .utility).async {
            let root = "\(Shell.home)/.claude/projects"
            let fm = FileManager.default
            let cutoff = Date().addingTimeInterval(-14 * 86400)
            var files: [(String, Date)] = []
            for project in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                for file in (try? fm.contentsOfDirectory(atPath: "\(root)/\(project)")) ?? [] where file.hasSuffix(".jsonl") {
                    let path = "\(root)/\(project)/\(file)"
                    if let m = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date, m > cutoff {
                        files.append((path, m))
                    }
                }
            }
            // Newest first, and capped, so a big history does not turn into a long disk crawl.
            let found: [Entry] = files.sorted { $0.1 > $1.1 }.prefix(200).compactMap { path, modified in
                let info = CodingSessions.transcriptInfo(path, span: 96 << 10)
                guard let title = info.title else { return nil }
                let id = String(URL(fileURLWithPath: path).lastPathComponent.dropLast(6))
                return Entry(id: id, title: title, path: path, cwd: info.cwd, modified: modified)
            }
            DispatchQueue.main.async {
                self.entries = found
                self.builtAt = Date()
                self.building = false
            }
        }
    }
}
