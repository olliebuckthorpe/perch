import AppKit
import Observation

/// One to-do from the Notion tasks database.
struct TaskItem: Identifiable, Equatable {
    let id: String
    var name: String
    var column: String
    var due: Date?
    var priority: String?
    /// Which part of life or work it belongs to: Upshow, Pipeline Engine, Personal or Uni.
    var area: String?
    var url: String?
    /// When the card was made. Notion's API gives this as an ISO date, which sorts as text.
    var created = ""
}

/// The user's Notion to-do list: the same cards as "Jonny's board" (not done, not Ollie's),
/// grouped by column. Reads and writes through Notion's API with a token the user keeps in
/// `~/.perch/notion-token`; Perch never shows or sends it anywhere but Notion.
@Observable
final class NotionTasks {
    static let shared = NotionTasks()

    /// "✅ Jonny & Ollie Tasks".
    private static let database = UserDefaults.standard.string(forKey: "notionDatabase") ?? "65dc48ca8b7c4f3db300cdf1e87dafd2"
    static let tokenPath = "\(Shell.home)/.perch/notion-token"
    /// The board's columns. My to-dos leads because it is the one in daily use.
    static let columns = ["My to-dos", "Upshow to-dos", "Waiting On"]

    /// Columns folded down to a slim strip. My to-dos starts open; the others are opened when wanted.
    var folded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "foldedColumns") ?? ["Upshow to-dos", "Waiting On"]) {
        didSet { UserDefaults.standard.set(Array(folded), forKey: "foldedColumns") }
    }

    private(set) var tasks: [TaskItem] = []
    private(set) var problem: String?
    private(set) var loading = false
    private(set) var loadedOnce = false
    @ObservationIgnored private var timer: Timer?

    var connected: Bool { token != nil }

    private var token: String? {
        guard let raw = try? String(contentsOfFile: Self.tokenPath, encoding: .utf8) else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    func start() {
        refresh()
        // The list changes slowly; a gentle background refresh keeps the count honest.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 60
    }

    private func call(_ method: String, _ path: String, _ body: [String: Any]?, done: @escaping ([String: Any]?, String?) -> Void) {
        guard let token, let url = URL(string: "https://api.notion.com/v1/\(path)") else {
            done(nil, "not connected")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        URLSession.shared.dataTask(with: request) { data, response, error in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                if let error { done(nil, error.localizedDescription) }
                else if status >= 300 { done(nil, json?["message"] as? String ?? "Notion returned \(status)") }
                else { done(json, nil) }
            }
        }.resume()
    }

    func refresh() {
        guard connected, !loading else { return }
        loading = true
        // The same filter as the "Jonny's board" view.
        let filter: [String: Any] = ["and": [
            ["property": "Column", "select": ["does_not_equal": "Done"]],
            ["or": [
                ["property": "Owner", "select": ["does_not_equal": "Ollie"]],
                ["property": "Owner", "select": ["is_empty": true]],
            ]],
        ]]
        let body: [String: Any] = [
            "filter": filter, "page_size": 100,
            "sorts": [["property": "Due date", "direction": "ascending"], ["timestamp": "created_time", "direction": "ascending"]],
        ]
        call("POST", "databases/\(Self.database)/query", body) { [weak self] json, error in
            guard let self else { return }
            self.loading = false
            self.loadedOnce = true
            guard let rows = json?["results"] as? [[String: Any]] else {
                self.problem = error ?? "Could not read the list"
                return
            }
            self.problem = nil
            // The board's own order: soonest due first, cards with no date after all the dated
            // ones, and ties (or no date at all) in the order the cards were made.
            self.tasks = rows.compactMap(Self.item).sorted { a, b in
                switch (a.due, b.due) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.created < b.created
                }
            }
        }
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func item(_ row: [String: Any]) -> TaskItem? {
        guard let id = row["id"] as? String, let props = row["properties"] as? [String: Any] else { return nil }
        func select(_ name: String) -> String? { ((props[name] as? [String: Any])?["select"] as? [String: Any])?["name"] as? String }
        let title = ((props["Name"] as? [String: Any])?["title"] as? [[String: Any]] ?? [])
            .compactMap { $0["plain_text"] as? String }.joined()
        // The board keeps a marker card in the Done column; it is not a task.
        guard !title.isEmpty, !title.hasPrefix("⬇") else { return nil }
        let start = (((props["Due date"] as? [String: Any])?["date"] as? [String: Any])?["start"] as? String).map { String($0.prefix(10)) }
        return TaskItem(id: id, name: title, column: select("Column") ?? "My to-dos",
                        due: start.flatMap { day.date(from: $0) }, priority: select("Priority"), area: select("Area"),
                        url: row["url"] as? String, created: row["created_time"] as? String ?? "")
    }

    /// Ticks a card off: moves it to Done on the board, exactly as dragging it there would.
    func complete(_ task: TaskItem) {
        tasks.removeAll { $0.id == task.id }
        let props: [String: Any] = ["Column": ["select": ["name": "Done"]], "Status": ["select": ["name": "Done"]]]
        call("PATCH", "pages/\(task.id)", ["properties": props]) { [weak self] _, error in
            if let error {
                self?.problem = "Could not tick that off: \(error)"
                self?.refresh()
            }
        }
    }

    /// The order the user has dragged cards into. Notion's API cannot read or set a board's
    /// manual order, so this lives in Perch only: cards placed by hand come first, in that order,
    /// and the rest follow in the board's usual order.
    private(set) var order: [String] = UserDefaults.standard.stringArray(forKey: "taskOrder") ?? [] {
        didSet { UserDefaults.standard.set(order, forKey: "taskOrder") }
    }

    func cards(in column: String) -> [TaskItem] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return tasks.filter { $0.column == column }.enumerated().sorted {
            let (a, b) = (rank[$0.element.id] ?? Int.max, rank[$1.element.id] ?? Int.max)
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)
    }

    /// Puts card `id` just above `target`, moving it to that card's column if it came from another.
    func place(_ id: String, before target: TaskItem) {
        guard id != target.id else { return }
        move(id, to: target.column)
        var column = cards(in: target.column).map(\.id).filter { $0 != id }
        column.insert(id, at: column.firstIndex(of: target.id) ?? column.count)
        // Everything above the dropped card is now placed too, so it holds its position.
        let placed = Array(column.prefix((column.firstIndex(of: target.id) ?? 0) + 1))
        let known = Set(tasks.map(\.id))
        order = placed + order.filter { !placed.contains($0) && known.contains($0) }
    }

    /// Puts card `id` at the very bottom of `column`.
    func placeLast(_ id: String, in column: String) {
        move(id, to: column)
        let placed = cards(in: column).map(\.id).filter { $0 != id } + [id]
        let known = Set(tasks.map(\.id))
        order = placed + order.filter { !placed.contains($0) && known.contains($0) }
    }

    /// Moves a card to another column on the board, as dragging it in Notion would.
    func move(_ id: String, to column: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].column != column else { return }
        tasks[i].column = column
        let props: [String: Any] = [
            "Column": ["select": ["name": column]],
            "Status": ["select": ["name": column == "Waiting On" ? "Waiting" : "To do"]],
        ]
        call("PATCH", "pages/\(id)", ["properties": props]) { [weak self] _, error in
            if let error {
                self?.problem = "Could not move that: \(error)"
                self?.refresh()
            }
        }
    }

    func add(_ name: String, column: String = "My to-dos") {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let props: [String: Any] = [
            "Name": ["title": [["text": ["content": name]]]],
            "Column": ["select": ["name": column]],
            "Status": ["select": ["name": "To do"]],
            "Owner": ["select": ["name": "Jonny"]],
            "Source": ["select": ["name": "Manual"]],
        ]
        call("POST", "pages", ["parent": ["database_id": Self.database], "properties": props]) { [weak self] json, error in
            if let json, let item = Self.item(json) {
                self?.tasks.append(item)
            } else {
                self?.problem = "Could not add that: \(error ?? "unknown error")"
            }
        }
    }

    /// Opens the card in the Notion app.
    func open(_ task: TaskItem) {
        guard let web = task.url else { return }
        let app = web.replacingOccurrences(of: "https://", with: "notion://")
        if let url = URL(string: app), NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        }
    }
}
