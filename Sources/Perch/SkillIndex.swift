import Foundation
import Observation

/// The user's Claude Code skills, so a reply can start with `/name` and the reply box can
/// offer them as you type.
@Observable
final class SkillIndex {
    static let shared = SkillIndex()

    struct Skill: Identifiable {
        let id: String
        let summary: String
    }

    private(set) var skills: [Skill] = []
    @ObservationIgnored private var loadedAt = Date.distantPast
    @ObservationIgnored private var loading = false

    func refresh() {
        guard !loading, Date().timeIntervalSince(loadedAt) > 120 else { return }
        loading = true
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            var found: [String: String] = [:]
            func add(_ dir: String, prefix: String) {
                for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                    let file = "\(dir)/\(name)/SKILL.md"
                    guard let head = (try? String(contentsOfFile: file, encoding: .utf8))?.prefix(1500) else { continue }
                    var title = name, summary = ""
                    for line in head.split(separator: "\n").prefix(12) {
                        if line.hasPrefix("name:") { title = line.dropFirst(5).trimmingCharacters(in: .whitespaces) }
                        if line.hasPrefix("description:") { summary = line.dropFirst(12).trimmingCharacters(in: .whitespaces) }
                    }
                    found[prefix + title] = summary
                }
            }
            add("\(Shell.home)/.claude/skills", prefix: "")
            let cache = "\(Shell.home)/.claude/plugins/cache"
            for market in (try? fm.contentsOfDirectory(atPath: cache)) ?? [] {
                for plugin in (try? fm.contentsOfDirectory(atPath: "\(cache)/\(market)")) ?? [] {
                    for version in (try? fm.contentsOfDirectory(atPath: "\(cache)/\(market)/\(plugin)")) ?? [] {
                        add("\(cache)/\(market)/\(plugin)/\(version)/skills", prefix: "\(plugin):")
                    }
                }
            }
            let list = found.map { Skill(id: $0.key, summary: $0.value) }.sorted { $0.id < $1.id }
            DispatchQueue.main.async {
                self.skills = list
                self.loadedAt = Date()
                self.loading = false
            }
        }
    }

    func matching(_ typed: String) -> [Skill] {
        let q = typed.dropFirst().lowercased()
        return skills.filter { q.isEmpty || $0.id.lowercased().contains(q) }
            .sorted { ($0.id.lowercased().hasPrefix(q) ? 0 : 1) < ($1.id.lowercased().hasPrefix(q) ? 0 : 1) }
    }

    /// A reply typed as `/skill arguments`, split up if it names a real skill.
    func command(in text: String) -> (name: String, arguments: String)? {
        guard text.hasPrefix("/") else { return nil }
        let parts = text.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }
        let name = String(first)
        guard skills.contains(where: { $0.id == name }) else { return nil }
        return (name, parts.count > 1 ? String(parts[1]) : "")
    }
}
