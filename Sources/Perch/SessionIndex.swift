import Foundation
import Observation

/// Titles of recent Claude Code sessions that are not live in the notch, so search can find them.
@Observable
final class SessionIndex {
    static let shared = SessionIndex()

    struct Entry: Identifiable, Equatable {
        let id: String
        let title: String
        let path: String
        let cwd: String?
        let modified: Date
        var source: AgentSource = .claude
    }

    private(set) var entries: [Entry] = []
    @ObservationIgnored private var builtAt = Date.distantPast
    @ObservationIgnored private var building = false
    @ObservationIgnored private let worker = DispatchQueue(label: "perch.session-titles", qos: .utility)
    // Worker-owned, including nil results for helper transcripts that have no title.
    @ObservationIgnored private var titles: [String: (stamp: Date, entry: Entry?)] = [:]

    func refresh() {
        guard !building, Date().timeIntervalSince(builtAt) > 60 else { return }
        building = true
        worker.async {
            let root = "\(Shell.home)/.claude/projects"
            let fm = FileManager.default
            let cutoff = Date().addingTimeInterval(-14 * 86400)
            var files: [(String, Date)] = []
            // Perch's own helper runs (titles, the usage check) are not chats.
            for project in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !project.hasSuffix("--perch") {
                for file in (try? fm.contentsOfDirectory(atPath: "\(root)/\(project)")) ?? [] where file.hasSuffix(".jsonl") {
                    let path = "\(root)/\(project)/\(file)"
                    if let m = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date, m > cutoff {
                        files.append((path, m))
                    }
                }
            }
            // Newest first, and capped, so a big history does not turn into a long disk crawl.
            let found: [Entry] = files.sorted { $0.1 > $1.1 }.prefix(200).compactMap { path, modified in
                if let known = self.titles[path], known.stamp == modified { return known.entry }
                return autoreleasepool {
                    let info = CodingSessions.transcriptInfo(path, span: 96 << 10)
                    let entry = info.title.map { title in
                        Entry(id: String(URL(fileURLWithPath: path).lastPathComponent.dropLast(6)),
                              title: title, path: path, cwd: info.cwd, modified: modified)
                    }
                    self.titles[path] = (modified, entry)
                    return entry
                }
            }
            let retained = Set(files.sorted { $0.1 > $1.1 }.prefix(200).map(\.0))
            self.titles = self.titles.filter { retained.contains($0.key) }
            DispatchQueue.main.async {
                if self.entries != found { self.entries = found }
                self.builtAt = Date()
                self.building = false
            }
        }
    }
}
