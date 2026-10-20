import Foundation

struct CodexQuestionBatch: Equatable {
    struct Item: Equatable {
        let index: Int
        let title: String
        let options: [String]
    }
    let callID: String
    let tool: String
    var items: [Item]

    static func from(_ payload: [String: Any]) -> CodexQuestionBatch? {
        guard payload["type"] as? String == "function_call",
              let name = payload["name"] as? String,
              name.split(separator: ".").last == "request_user_input_async",
              let callID = payload["call_id"] as? String,
              let arguments = payload["arguments"] as? String,
              let data = arguments.data(using: .utf8),
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let questions = input["questions"] as? [[String: Any]] else { return nil }
        let items = questions.enumerated().compactMap { index, question -> Item? in
            guard let title = question["title"] as? String, !title.isEmpty else { return nil }
            return Item(index: index, title: title, options: question["options"] as? [String] ?? [])
        }
        return items.isEmpty ? nil : CodexQuestionBatch(callID: callID, tool: "request_user_input_async", items: items)
    }

    var summary: String {
        items.map { item in
            ([item.title] + item.options.map { "• \($0)" }).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    func reply(answers: [String: String]) -> String? {
        let rows: [[String: Any]] = items.compactMap { item in
            guard let answer = answers[item.title]?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty,
                  let idData = try? JSONSerialization.data(withJSONObject: [tool, callID, item.index]),
                  let id = String(data: idData, encoding: .utf8) else { return nil }
            return ["questionItemId": id, "question": item.title, "answer": answer]
        }
        guard rows.count == items.count, let data = try? JSONSerialization.data(withJSONObject: rows),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return "<send_user_message_question_reply>\n\(text)\n</send_user_message_question_reply>"
    }
}

/// Questions use tool-call records, rather than ordinary assistant messages or stop hooks.
struct CodexQuestionTracker {
    private(set) var pending: [CodexQuestionBatch] = []

    static func answerRows(in text: String) -> [[String: Any]]? {
        guard let begin = text.range(of: "<send_user_message_question_reply>"),
              let end = text.range(of: "</send_user_message_question_reply>", range: begin.upperBound..<text.endIndex),
              let data = String(text[begin.upperBound..<end.lowerBound]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    }

    static func readableAnswer(_ text: String) -> String? {
        guard let rows = answerRows(in: text) else { return nil }
        let parts = rows.compactMap { row -> String? in
            guard let title = row["question"] as? String, let answer = row["answer"] as? String else { return nil }
            return "\(title)\n\(answer)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    mutating func consume(_ record: [String: Any]) {
        guard let payload = record["payload"] as? [String: Any] else { return }
        if record["type"] as? String == "event_msg", payload["type"] as? String == "turn_aborted" {
            pending = []
            return
        }
        guard record["type"] as? String == "response_item" else { return }
        if let batch = CodexQuestionBatch.from(payload) {
            if !pending.contains(where: { $0.callID == batch.callID }) { pending.append(batch) }
            return
        }
        if payload["type"] as? String == "function_call_output", let id = payload["call_id"] as? String,
           let output = payload["output"] as? String, let data = output.data(using: .utf8),
           let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           result["accepted"] as? Bool == false || result["isError"] as? Bool == true {
            pending.removeAll { $0.callID == id }
            return
        }
        guard payload["type"] as? String == "message", payload["role"] as? String == "user",
              let content = payload["content"] as? [[String: Any]] else { return }
        for text in content.compactMap({ $0["text"] as? String }) {
            if let rows = Self.answerRows(in: text) {
                for row in rows {
                    guard let itemID = row["questionItemId"] as? String, let data = itemID.data(using: .utf8),
                          let id = try? JSONSerialization.jsonObject(with: data) as? [Any], id.count == 3,
                          let callID = id[1] as? String, let index = id[2] as? Int else { continue }
                    for i in pending.indices where pending[i].callID == callID {
                        pending[i].items.removeAll { $0.index == index }
                    }
                    pending.removeAll { $0.items.isEmpty }
                }
            } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
                // A new ordinary request supersedes an unanswered optional question.
                pending = []
            }
        }
    }
}

/// Incremental file reading keeps earlier questions alive as long tool outputs arrive.
final class CodexQuestionScanner {
    private var offsets: [String: UInt64] = [:]
    private var buffers: [String: Data] = [:]
    private var trackers: [String: CodexQuestionTracker] = [:]

    func scan(_ path: String) -> [CodexQuestionBatch] {
        guard let file = FileHandle(forReadingAtPath: path) else { return trackers[path]?.pending ?? [] }
        defer { try? file.close() }
        let size = (try? file.seekToEnd()) ?? 0
        var offset = offsets[path]
        if let prior = offset, prior > size { offset = nil; buffers[path] = nil; trackers[path] = nil }
        let first = offset == nil
        let start = offset ?? (size > 2 << 20 ? size - (2 << 20) : 0)
        try? file.seek(toOffset: start)
        guard var chunk = try? file.readToEnd() else { return trackers[path]?.pending ?? [] }
        offsets[path] = start + UInt64(chunk.count)
        if first && start > 0, let newline = chunk.firstIndex(of: 0x0A) { chunk = Data(chunk[chunk.index(after: newline)...]) }
        var buffer = buffers[path] ?? Data()
        buffer.append(chunk)
        var tracker = trackers[path] ?? CodexQuestionTracker()
        let lines = buffer.split(separator: 0x0A, omittingEmptySubsequences: false)
        for line in lines.dropLast() {
            if line.count < 400_000,
               let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] { tracker.consume(record) }
        }
        buffers[path] = lines.last.map { Data($0) } ?? Data()
        trackers[path] = tracker
        return tracker.pending
    }
}
