import Foundation

/// Codex's server-owned queue is separate from its accepted conversation history.
struct CodexQueuedMessage: Identifiable, Equatable {
    let id: String
    let clientUserMessageID: String
    let text: String
    let attachments: [String]

    static func parse(_ row: [String: Any]) -> Self? {
        guard let id = row["id"] as? String,
              let input = row["input"] as? [[String: Any]] else { return nil }
        var text: [String] = [], attachments: [String] = []
        for part in input {
            switch part["type"] as? String {
            case "text": if let value = part["text"] as? String { text.append(value) }
            case "localImage": attachments.append((part["path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Image")
            case "image": attachments.append("Image")
            case "audio", "localAudio": attachments.append("Audio")
            case "skill", "mention": attachments.append(part["name"] as? String ?? "Attachment")
            default: attachments.append("Attachment")
            }
        }
        return Self(id: id, clientUserMessageID: row["clientUserMessageId"] as? String ?? "",
                    text: text.joined(separator: "\n\n"), attachments: attachments)
    }
}

/// A read-only protocol connection. Never resumes a thread or takes its active writer.
/// Queue actions stay in Codex, whose owner coordinates steering and dispatch atomically.
final class CodexQueue {
    static let shared = CodexQueue()
    private let worker = DispatchQueue(label: "perch.codex-queue", qos: .utility)
    private var reading = Set<String>()
    // Owned exclusively by worker. A chat refresh must not boot a server every three seconds.
    private var connection: Connection?
    private var idleClose: DispatchWorkItem?

    func refresh(_ agent: Agent) {
        guard agent.source == .codex, !reading.contains(agent.id), let exe = Shell.find("codex") else { return }
        reading.insert(agent.id)
        let id = agent.id, threadID = agent.sessionID
        worker.async { [weak self, weak agent] in
            guard let self else { return }
            self.idleClose?.cancel()
            let result = Result { () throws -> [CodexQueuedMessage] in
                do {
                    if self.connection == nil { self.connection = try Connection(exe: exe) }
                    return try self.connection!.read(threadID: threadID)
                } catch {
                    self.connection?.close()
                    self.connection = nil
                    throw error
                }
            }
            // Release the helper once no visible chat is requesting queue updates.
            let close = DispatchWorkItem { [weak self] in
                self?.connection?.close()
                self?.connection = nil
            }
            self.idleClose = close
            self.worker.asyncAfter(deadline: .now() + 15, execute: close)
            DispatchQueue.main.async {
                self.reading.remove(id)
                guard let agent else { return }
                switch result {
                case .success(let items):
                    if agent.codexQueue != items { agent.codexQueue = items }
                    agent.codexQueueError = nil
                case .failure:
                    // Keep the last known queue; a failed read is not an empty queue.
                    agent.codexQueueError = "Queue unavailable. Check Codex for pending messages."
                }
            }
        }
    }

    private final class Connection {
        private let process = Process(), input = Pipe(), output = Pipe()
        private var buffer = Data()
        private var sequence = 0

        init(exe: String) throws {
            process.executableURL = URL(fileURLWithPath: exe)
            process.arguments = ["app-server", "--listen", "stdio://"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            do {
                _ = try request("initialize", ["clientInfo": ["name": "perch_queue_reader", "version": "0.1"],
                                               "capabilities": ["experimentalApi": true]])
            } catch {
                close()
                throw error
            }
        }

        func close() {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
        }

        deinit { close() }

        private func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            guard process.isRunning else { throw QueueError.unavailable }
            // Bound each request, including reads on an already established connection.
            let process = process
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: timeout)
            defer { timeout.cancel() }
            sequence += 1
            let expected = sequence
            var data = try JSONSerialization.data(withJSONObject: ["id": expected, "method": method, "params": params])
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.prefix(upTo: newline)
                    let row = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                    buffer.removeSubrange(...newline)
                    guard row?["id"] as? Int == expected else { continue }
                    guard let result = row?["result"] as? [String: Any] else { throw QueueError.unavailable }
                    return result
                }
                let data = output.fileHandleForReading.availableData
                guard !data.isEmpty, buffer.count + data.count < 8 << 20 else { throw QueueError.unavailable }
                buffer.append(data)
            }
        }

        func read(threadID: String) throws -> [CodexQueuedMessage] {
            var items: [CodexQueuedMessage] = [], cursor: String?, cursors = Set<String>()
            repeat {
                var params: [String: Any] = ["threadId": threadID, "limit": 100]
                if let cursor { params["cursor"] = cursor }
                let page = try request("thread/queue/list", params)
                guard let rows = page["data"] as? [[String: Any]] else { throw QueueError.unavailable }
                for row in rows {
                    guard let item = CodexQueuedMessage.parse(row) else { throw QueueError.unavailable }
                    items.append(item)
                }
                cursor = page["nextCursor"] as? String
                if let cursor, !cursors.insert(cursor).inserted { throw QueueError.unavailable }
            } while cursor != nil
            return items
        }
    }

    private enum QueueError: Error { case unavailable }
}
