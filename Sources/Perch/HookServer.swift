import Foundation
import Network

/// One hook invocation. The connection stays open until `respond` is called, which is
/// how the notch holds a permission prompt or a follow-up window.
final class HookRequest {
    let headers: [String: String]
    let json: [String: Any]
    var onCancel: (() -> Void)?
    private let connection: NWConnection
    private var finished = false

    init(headers: [String: String], json: [String: Any], connection: NWConnection) {
        self.headers = headers
        self.json = json
        self.connection = connection
    }

    func respond(_ body: Data = Data()) {
        guard !finished else { return }
        finished = true
        var out = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { [connection] _ in connection.cancel() })
    }

    fileprivate func peerClosed() {
        guard !finished else { return }
        finished = true
        connection.cancel()
        onCancel?()
    }
}

/// Minimal HTTP over a unix socket. Only the hook script talks to it, and the socket is
/// owner-only, so nothing else on the machine (or in a browser) can reach it.
final class HookServer {
    let path: String
    var handler: ((HookRequest) -> Void)?
    private var listener: NWListener?

    init(path: String) { self.path = path }

    func start() throws {
        unlink(path)
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [path] state in
            switch state {
            case .ready: chmod(path, 0o600)
            case .failed(let e): NSLog("Perch: hook server failed: \(e)")
            default: break
            }
        }
        l.start(queue: .main)
        listener = l
    }

    func stop() {
        listener?.cancel()
        unlink(path)
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: .main)
        read(c, buffer: Data())
    }

    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = self.parse(buf, connection: c) {
                self.watchForClose(c, req)
                self.handler?(req)
            } else if complete || error != nil || buf.count > 8 << 20 {
                c.cancel()
            } else {
                self.read(c, buffer: buf)
            }
        }
    }

    private func watchForClose(_ c: NWConnection, _ req: HookRequest) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, complete, error in
            if complete || error != nil { req.peerClosed() } else { self?.watchForClose(c, req) }
        }
    }

    private func parse(_ buf: Data, connection: NWConnection) -> HookRequest? {
        guard let split = buf.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buf[buf.startIndex..<split.lowerBound], encoding: .utf8) else { return nil }
        var headers: [String: String] = [:]
        for line in head.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buf[split.upperBound...]
        guard body.count >= length else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: body.prefix(length))) as? [String: Any] ?? [:]
        return HookRequest(headers: headers, json: json, connection: connection)
    }
}
