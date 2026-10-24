import Foundation
import Observation

/// Per-chat observation: editing a reply only updates that reply's subscribers. Draft badges
/// observe emptiness separately, so they do not redraw for every character in a nonempty draft.
final class DraftStore {
    @Observable
    fileprivate final class Record {
        var text: String?
        var hasText: Bool
        var command: String?
        init(_ text: String?) {
            self.text = text
            hasText = !(text ?? "").isEmpty
            command = DraftStore.command(in: text)
        }
    }

    private let defaults: UserDefaults
    private var saved: [String: String]
    private var records: [String: Record]
    private var editors: [String: [UUID: (String) -> Void]] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: "drafts") as? [String: String] ?? [:]
        self.saved = saved
        records = saved.mapValues { Record($0) }
    }

    private func record(_ id: String) -> Record {
        if let record = records[id] { return record }
        let record = Record(nil)
        records[id] = record
        return record
    }

    subscript(_ id: String) -> String? {
        get { record(id).text }
        set {
            let record = record(id)
            guard record.text != newValue else { return }
            record.text = newValue
            let hasText = !(newValue ?? "").isEmpty
            if record.hasText != hasText { record.hasText = hasText }
            let command = Self.command(in: newValue)
            if record.command != command { record.command = command }
            saved[id] = hasText ? newValue : nil
            // Preserve immediate persistence for crashes/relaunches; no delayed-save window.
            defaults.set(saved, forKey: "drafts")
            let callbacks = editors[id].map { Array($0.values) } ?? []
            callbacks.forEach { $0(newValue ?? "") }
        }
    }

    subscript(_ id: String, default fallback: @autoclosure () -> String) -> String {
        get { self[id] ?? fallback() }
        set { self[id] = newValue }
    }

    func hasText(_ id: String) -> Bool { record(id).hasText }
    func command(_ id: String) -> String? { record(id).command }

    /// Native editors synchronize directly, below SwiftUI's layout graph. Reading this
    /// snapshot intentionally does not subscribe a whole composer to every character.
    func snapshot(_ id: String) -> String { saved[id] ?? "" }

    func observeText(_ id: String, changed: @escaping (String) -> Void) -> UUID {
        let token = UUID()
        editors[id, default: [:]][token] = changed
        return token
    }

    func removeTextObserver(_ id: String, token: UUID) {
        editors[id]?[token] = nil
        if editors[id]?.isEmpty == true { editors[id] = nil }
    }

    private static func command(in text: String?) -> String? {
        guard let text, text.hasPrefix("/"), !text.contains(" ") else { return nil }
        return text
    }
}
