import Foundation
import NaturalLanguage
import Observation

/// Search across every chat Perch knows about: live and older Claude Code and Codex sessions,
/// Grok bots, and Slack conversations. It reads what was said, not only titles.
///
/// Matching is forgiving: whole words, the start of words, small typos, and words that mean
/// much the same thing ("prices" finds "pricing"). On top of that an on-device language model
/// spots threads about the same topic even when they share no words. Nothing leaves the Mac.
@Observable
final class ThreadSearch {
    static let shared = ThreadSearch()

    enum Target {
        case agent(String)
        case older(SessionIndex.Entry)
        case slack(SlackTarget)
    }

    struct Doc {
        let key: String
        let target: Target
        let title: String
        let text: String
        let modified: Date
        var words: Set<String> = []
        var titleWords: Set<String> = []
        /// How often each word comes up, for weighting a thread that is about it over a passing mention.
        var counts: [String: Int] = [:]
        /// Meaning vectors for a few passages of the thread (its start, then spread through it).
        var vectors: [[Float]] = []
    }

    struct Hit {
        let target: Target
        let snippet: String?
        let score: Double
        /// Found by meaning alone, sharing no words with the search.
        let related: Bool
        /// The words in the thread that matched, for highlighting.
        var matches: [String] = []
        var modified = Date()
        var close = 0.0
    }

    /// Bumped when the index or a meaning lookup changes, so open results refresh.
    private(set) var version = 0

    @ObservationIgnored private var files: [String: Doc] = [:]
    @ObservationIgnored private var building = false
    /// Transcripts with nothing to search, by when they were last changed.
    @ObservationIgnored private var skipped: [String: Date] = [:]
    @ObservationIgnored private var builtAt = Date.distantPast
    @ObservationIgnored private var cache: (query: String, version: Int, hits: [Hit])?
    @ObservationIgnored private var meaning: [String: [String: Float]] = [:]
    @ObservationIgnored private var asking = Set<String>()
    @ObservationIgnored private let queue = DispatchQueue(label: "perch.search", qos: .utility)
    private static let store = "\(Shell.home)/.perch/search-index-4.json"

    // MARK: Building the index

    /// Reads chat transcripts in the background. Only files changed since last time are read again.
    func refresh() {
        guard !building, Date().timeIntervalSince(builtAt) > 90 else { return }
        building = true
        queue.async { [weak self] in
            guard let self else { return }
            if self.files.isEmpty { self.files = Self.loadSaved() }
            let fm = FileManager.default
            let cutoff = Date().addingTimeInterval(-60 * 86400)
            var paths: [(String, Date, AgentSource)] = []
            let claude = "\(Shell.home)/.claude/projects"
            for project in (try? fm.contentsOfDirectory(atPath: claude)) ?? [] where !project.hasSuffix("--perch") {
                for file in (try? fm.contentsOfDirectory(atPath: "\(claude)/\(project)")) ?? [] where file.hasSuffix(".jsonl") {
                    let path = "\(claude)/\(project)/\(file)"
                    if let m = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date, m > cutoff {
                        paths.append((path, m, .claude))
                    }
                }
            }
            if let walker = fm.enumerator(atPath: "\(Shell.home)/.codex/sessions") {
                for case let file as String in walker where file.hasSuffix(".jsonl") {
                    let path = "\(Shell.home)/.codex/sessions/\(file)"
                    if let m = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date, m > cutoff {
                        paths.append((path, m, .codex))
                    }
                }
            }
            var next: [String: Doc] = [:]
            var changed = false

            for (path, modified, source) in paths.sorted(by: { $0.1 > $1.1 }).prefix(500) {
                if var known = self.files[path], abs(known.modified.timeIntervalSince(modified)) < 1 {
                    if known.words.isEmpty { Self.tokenize(&known) }
                    next[path] = known
                    continue
                }
                // Each file's working memory is let go before the next, so a first full read
                // never balloons.
                // Helper runs and empty sessions have nothing to search: remembered, not re-read.
                if let skip = self.skipped[path], abs(skip.timeIntervalSince(modified)) < 1 { continue }
                autoreleasepool {
                    guard var doc = Self.read(path, source: source, modified: modified) else {
                        self.skipped[path] = modified
                        return
                    }
                    Self.tokenize(&doc)
                    doc.vectors = Self.passages(doc).compactMap(Embedder.shared.embed)
                    next[path] = doc
                    changed = true
                }
            }
            // Vectors for anything saved before the model was ready.
            if Embedder.shared.ready {
                for (path, doc) in next where doc.vectors.isEmpty {
                    next[path]?.vectors = Self.passages(doc).compactMap(Embedder.shared.embed)
                    changed = true
                }
            }
            if changed || next.count != self.files.count { Self.save(next) }
            DispatchQueue.main.async {
                self.files = next
                self.builtAt = Date()
                self.building = false
                self.version += 1
            }
        }
    }

    /// The title, project and what was said in a Claude Code or Codex transcript.
    private static func read(_ path: String, source: AgentSource, modified: Date) -> Doc? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        // The start (what the chat is about) and the end (where it got to) are what matter;
        // the middle of a long session is mostly tool output.
        let span: UInt64 = 320 << 10
        var chunks: [Data] = []
        try? h.seek(toOffset: 0)
        if let head = try? h.read(upToCount: Int(min(size, span))) { chunks.append(head) }
        if size > span * 2 {
            try? h.seek(toOffset: size - span)
            if let tail = try? h.readToEnd() { chunks.append(tail) }
        }
        var said: [String] = []
        var firstPrompt: String?
        var cwd: String?
        var id: String?
        for chunk in chunks {
            for line in String(decoding: chunk, as: UTF8.self).split(separator: "\n") where line.utf8.count < 60_000 {
                // Only lines that can be messages (or the session's details) are worth parsing;
                // tool output is most of a transcript and none of what was said.
                guard line.contains("\"user\"") || line.contains("\"assistant\"") || line.contains("session_meta")
                        || (cwd == nil && line.contains("\"cwd\"")) else { continue }
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if source == .claude {
                    if cwd == nil { cwd = o["cwd"] as? String }
                    guard let type = o["type"] as? String, type == "user" || type == "assistant",
                          o["isMeta"] as? Bool != true, let message = o["message"] as? [String: Any] else { continue }
                    let text = Self.text(message["content"])
                    guard Self.isChat(text) else { continue }
                    if type == "user", firstPrompt == nil { firstPrompt = text }
                    said.append(text)
                } else {
                    let payload = o["payload"] as? [String: Any]
                    if o["type"] as? String == "session_meta" {
                        // Codex's own helpers (its safety reviewer and the like) are not chats.
                        if payload?["thread_source"] as? String == "subagent" { return nil }
                        cwd = payload?["cwd"] as? String
                        id = payload?["id"] as? String
                        continue
                    }
                    guard o["type"] as? String == "response_item", payload?["type"] as? String == "message",
                          let role = payload?["role"] as? String, role == "user" || role == "assistant" else { continue }
                    let text = Self.text(payload?["content"])
                    guard Self.isChat(text) else { continue }
                    if role == "user", firstPrompt == nil { firstPrompt = text }
                    said.append(text)
                }
            }
        }
        guard !said.isEmpty else { return nil }
        // One-off helper runs that ask for a fixed reply.
        if let first = firstPrompt, first.hasPrefix("Reply with") || first.hasPrefix("The following is the Codex agent history") { return nil }
        let file = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let sessionID = id ?? (source == .codex ? String(file.suffix(36)) : file)
        var title = source == .claude ? CodingSessions.transcriptInfo(path, span: 96 << 10).title : nil
        if title == nil { title = firstPrompt.map { oneLine($0, max: 70) } }
        let entry = SessionIndex.Entry(id: sessionID, title: title ?? "Untitled chat", path: path, cwd: cwd,
                                       modified: modified, source: source)
        // Enough of the conversation to search, without holding whole transcripts in memory.
        var text = said.joined(separator: "\n")
        if text.count > 12_000 { text = String(text.prefix(5_000)) + "\n" + String(text.suffix(7_000)) }
        return Doc(key: path, target: .older(entry), title: entry.title, text: text, modified: modified)
    }

    private static func text(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts.compactMap { part -> String? in
            let type = part["type"] as? String
            guard type == "text" || type == "input_text" || type == "output_text" else { return nil }
            return part["text"] as? String
        }.joined(separator: "\n")
    }

    /// Real conversation, not the context and instructions tools slip into the transcript.
    private static func isChat(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        // Context that tools wrap in tags, like <recommended_plugins>, rather than anything typed.
        if t.range(of: #"^<[a-z_\-]+>"#, options: .regularExpression) != nil { return false }
        for prefix in ["<environment_context", "<user_instructions", "<app-context", "<command-", "<local-command",
                       "<system-reminder", "# AGENTS.md", "<permissions", "<external_", "<multi_agent", "Caveat:"] where t.hasPrefix(prefix) {
            return false
        }
        return true
    }

    private static func tokenize(_ doc: inout Doc) {
        let title = terms(doc.title), body = terms(doc.text)
        var counts: [String: Int] = [:]
        for (i, w) in body.enumerated() {
            counts[w, default: 0] += 1
            // "clean up" and "clean-up" are also found as "cleanup".
            if i + 1 < body.count, w.count + body[i + 1].count <= 12 { counts[w + body[i + 1], default: 0] += 1 }
        }
        doc.counts = counts
        doc.titleWords = Set(title).union(zip(title, title.dropFirst()).map { $0 + $1 })
        doc.words = Set(counts.keys).union(doc.titleWords)
    }

    static func terms(_ s: String) -> [String] {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count >= 2 }.map(String.init)
    }

    // MARK: Meaning

    /// The parts of a thread worth reading for meaning: its title and opening, then a few
    /// passages spread through the rest.
    private static func passages(_ doc: Doc) -> [String] {
        let text = doc.text
        var out = [doc.title + ". " + String(text.prefix(700))]
        let count = text.count
        guard count > 900 else { return out }
        let picks = min(4, count / 900)
        for i in 1...picks {
            let at = count * i / (picks + 1)
            let start = text.index(text.startIndex, offsetBy: max(0, at - 450))
            let end = text.index(start, offsetBy: min(900, text.distance(from: start, to: text.endIndex)))
            out.append(String(text[start..<end]))
        }
        return out
    }

    /// How close in meaning each thread is to the search (its closest passage), worked out in
    /// the background.
    private func askMeaning(_ query: String, docs: [Doc]) {
        guard query.count >= 3, Embedder.shared.ready, meaning[query] == nil, !asking.contains(query) else { return }
        asking.insert(query)
        let keyed = docs.filter { !$0.vectors.isEmpty }.map { ($0.key, $0.vectors) }
        queue.async { [weak self] in
            guard let self, let q = Embedder.shared.query(query), !keyed.isEmpty else {
                DispatchQueue.main.async { self?.asking.remove(query) }
                return
            }
            var scores: [String: Float] = [:]
            for (key, vectors) in keyed {
                scores[key] = vectors.map { v in zip(q, v).reduce(0) { $0 + $1.0 * $1.1 } }.max() ?? 0
            }
            DispatchQueue.main.async {
                self.asking.remove(query)
                if self.meaning.count > 40 { self.meaning.removeAll() }
                self.meaning[query] = scores
                self.version += 1
            }
        }
    }

    /// The threads closest in meaning to a search, with how close, for tuning.
    func nearest(_ query: String) -> [(String, Float)] {
        guard let q = Embedder.shared.query(query) else { return [] }
        return files.values.compactMap { d -> (String, Float)? in
            guard !d.vectors.isEmpty else { return nil }
            return (d.title, d.vectors.map { v in zip(q, v).reduce(0) { $0 + $1.0 * $1.1 } }.max() ?? 0)
        }.sorted { $0.1 > $1.1 }
    }

    // MARK: Searching

    /// The best threads for a search, best first.
    func search(_ raw: String, live: [Agent], slack: [(SlackTarget, [SlackLine])]) -> [Hit] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        if let cache, cache.query == query, cache.version == version { return cache.hits }

        // Live chats are searched from what is on screen; their transcripts are skipped to avoid doubles.
        var docs: [Doc] = []
        var liveKeys = Set<String>()
        for agent in live {
            let text = agent.thread.suffix(60).map(\.text).joined(separator: "\n") + "\n" + agent.detail + "\n" + agent.lastMessage
            var doc = Doc(key: agent.id, target: .agent(agent.id), title: agent.name, text: text, modified: agent.lastActivity)
            if let path = agent.transcriptPath, let indexed = files[path] {
                // What is on screen now plus everything said earlier in the session.
                doc = Doc(key: agent.id, target: .agent(agent.id), title: agent.name, text: text + "\n" + indexed.text,
                          modified: agent.lastActivity, vectors: indexed.vectors)
                liveKeys.insert(path)
            }
            Self.tokenize(&doc)
            docs.append(doc)
        }
        for (path, doc) in files where !liveKeys.contains(path) {
            if case .older(let e) = doc.target, live.contains(where: { $0.id == "\(e.source.rawValue):\(e.id)" }) { continue }
            docs.append(doc)
        }
        for (target, lines) in slack {
            let text = lines.map { "\($0.sender): \($0.text)" }.joined(separator: "\n")
            var doc = Doc(key: "slack:\(target.workspace):\(target.id)", target: .slack(target), title: target.label,
                          text: text, modified: Date())
            Self.tokenize(&doc)
            docs.append(doc)
        }

        let tokens = Array(Set(Self.terms(query))).filter { !Self.stop.contains($0) || Self.terms(query).count == 1 }
        let expansions = tokens.map(expand)
        askMeaning(query, docs: docs)
        let closeness = meaning[query] ?? [:]
        // Closeness is judged against the typical thread for this search: the model scores
        // everything in a narrow band, so what matters is standing out from the middle.
        let values = closeness.values.map(Double.init).sorted(by: >)
        let median = values.isEmpty ? 1 : values[values.count / 2]
        let fourth = values.count > 3 ? values[3] : (values.last ?? 1)

        var hits: [Hit] = []
        for doc in docs {
            var total = 0.0
            var matched = 0
            var found: [String] = []
            for options in expansions {
                var best = 0.0
                var bestWord: String?
                for (word, weight) in options {
                    let inTitle = doc.titleWords.contains(word)
                    guard inTitle || doc.words.contains(word) else { continue }
                    let often = 1 + 0.18 * log2(Double(1 + min(doc.counts[word] ?? 0, 64)))
                    let w = weight * (inTitle ? 1.6 : 1) * often
                    if w > best { best = w; bestWord = word }
                }
                if best > 0 { matched += 1 }
                total += best
                if let bestWord { found.append(bestWord) }
            }
            let coverage = tokens.isEmpty ? 0 : Double(matched) / Double(tokens.count)
            // Threads with every word come first; ones missing a word drop well behind.
            var score = tokens.isEmpty ? 0 : total / Double(tokens.count) * coverage * coverage
            // Most of the words have to be there for a keyword match to count.
            if coverage < (tokens.count <= 2 ? 1 : 0.6) { score = 0 }
            if doc.title.lowercased().contains(query) { score += 1 }
            // The search as a whole phrase ("case study") counts for much more than its words apart.
            var phrase = false
            if tokens.count > 1, doc.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                score += 0.9
                phrase = true
            }
            let close = Double(closeness[doc.key] ?? 0)
            // About the same thing without sharing the words: clearly closer than most threads.
            let related = score == 0 && close >= fourth && close >= median + 0.08
            if score == 0 && !related { continue }
            score += max(0, close - median - 0.03) * 7
            if related { score += 0.4 }
            // A gentle nudge towards recent threads.
            let age = Date().timeIntervalSince(doc.modified) / 86400
            score += 0.25 * exp(-max(0, age) / 7)
            let near = found.isEmpty ? nil : Self.snippet(doc.text, around: phrase ? [query] + found : found)
            // The words side by side in one passage, not scattered across the thread.
            if let near, tokens.count > 1 { score += 0.3 * Double(min(near.together, tokens.count) - 1) }
            let snippet = near?.text
            hits.append(Hit(target: doc.target, snippet: snippet, score: score, related: related,
                            matches: phrase ? [query] + found : found, modified: doc.modified, close: close))
        }
        hits.sort { $0.score > $1.score }
        // Meaning alone is a weaker signal, so only a few of those.
        var relatedLeft = 4
        hits = hits.filter { !$0.related || { relatedLeft -= 1; return relatedLeft >= 0 }() }
        cache = (query, version, hits)
        return hits
    }

    private static let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "about", "from", "to", "of", "in", "on", "my", "me", "it", "is", "was", "where", "what", "we", "chat", "thread", "up", "an", "do", "be", "at", "by", "or", "as", "so", "if", "into", "all"]

    @ObservationIgnored private var vocabulary: (count: Int, words: [String])?

    /// Each search word and what it can match, with how much each counts: the word itself, longer
    /// words it starts, near misspellings, and words with a similar meaning.
    @ObservationIgnored private var expanded: [String: (Int, [String: Double])] = [:]

    private func expand(_ token: String) -> [String: Double] {
        if let (count, known) = expanded[token], count == files.count { return known }
        let out = expanding(token)
        if expanded.count > 300 { expanded.removeAll() }
        expanded[token] = (files.count, out)
        return out
    }

    private func expanding(_ token: String) -> [String: Double] {
        var out: [String: Double] = [token: 1]
        let vocab = allWords()
        if token.count >= 2 {
            for word in vocab where word.count > token.count && word.hasPrefix(token) { out[word] = max(out[word] ?? 0, 0.85) }
        }
        // Typos only count on longer words, and never in the first letter: short words have too
        // many near neighbours ("lead" and "read").
        if token.count >= 5 {
            let limit = token.count >= 8 ? 2 : 1
            for word in vocab where out[word] == nil && word.first == token.first && abs(word.count - token.count) <= limit {
                if Self.distance(token, word, limit: limit) <= limit { out[word] = 0.7 }
            }
        }
        return out
    }

    private func allWords() -> [String] {
        let count = files.count
        if let vocabulary, vocabulary.count == count { return vocabulary.words }
        var set = Set<String>()
        for doc in files.values { set.formUnion(doc.words) }
        let list = Array(set)
        vocabulary = (count, list)
        return list
    }

    /// Edit distance, giving up once it passes the limit.
    private static func distance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        var prev = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var cur = [i] + Array(repeating: 0, count: b.count)
            var rowMin = i
            for j in 1...max(1, b.count) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            prev = cur
        }
        return prev[b.count]
    }

    /// A short stretch of the conversation where the most search words appear together.
    private static func snippet(_ text: String, around words: [String]) -> (text: String, together: Int)? {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let wanted = Array(Set(words.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }))
        var spots: [(Int, String)] = []
        for word in wanted {
            var from = folded.startIndex
            var n = 0
            while n < 40, let r = folded.range(of: word, range: from..<folded.endIndex) {
                spots.append((folded.distance(from: folded.startIndex, to: r.lowerBound), word))
                from = r.upperBound
                n += 1
            }
        }
        guard !spots.isEmpty else { return nil }
        spots.sort { $0.0 < $1.0 }
        // The spot with the most different words within a short reach, phrases first.
        var best = spots[0].0, bestScore = -1, together = 1
        for (i, spot) in spots.enumerated() {
            var seen = Set<String>()
            for other in spots[i...] where other.0 - spot.0 < 120 { seen.insert(other.1) }
            let score = seen.reduce(0) { $0 + ($1.contains(" ") ? 3 : 1) }
            if score > bestScore { bestScore = score; best = spot.0; together = seen.count }
        }
        let count = text.count
        let lo = max(0, best - 45), hi = min(count, best + 150)
        let start = text.index(text.startIndex, offsetBy: lo), end = text.index(text.startIndex, offsetBy: hi)
        let piece = text[start..<end].replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)?"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\*\*|__|`|^#+ | #+ "#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return ((lo > 0 ? "…" : "") + piece + (hi < count ? "…" : ""), together)
    }

    // MARK: Saving

    private struct Saved: Codable {
        let path: String, id: String, title: String, cwd: String?, source: String, modified: Date, text: String, vectors: [Data]?
    }

    private static func save(_ docs: [String: Doc]) {
        let rows: [Saved] = docs.values.compactMap { d in
            guard case .older(let e) = d.target else { return nil }
            return Saved(path: d.key, id: e.id, title: d.title, cwd: e.cwd, source: e.source.rawValue,
                         modified: d.modified, text: d.text,
                         vectors: d.vectors.map { v in v.withUnsafeBufferPointer { Data(buffer: $0) } })
        }
        guard let data = try? JSONEncoder().encode(rows) else { return }
        FileManager.default.createFile(atPath: store, contents: data, attributes: [.posixPermissions: 0o600])
    }

    private static func loadSaved() -> [String: Doc] {
        guard let data = FileManager.default.contents(atPath: store),
              let rows = try? JSONDecoder().decode([Saved].self, from: data) else { return [:] }
        var out: [String: Doc] = [:]
        for r in rows {
            let entry = SessionIndex.Entry(id: r.id, title: r.title, path: r.path, cwd: r.cwd, modified: r.modified,
                                           source: AgentSource(rawValue: r.source) ?? .claude)
            out[r.path] = Doc(key: r.path, target: .older(entry), title: r.title, text: r.text, modified: r.modified,
                              vectors: (r.vectors ?? []).map { d in d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } })
        }
        return out
    }
}
