import AppKit
import Network
import SwiftUI
import WebKit

// Upshow's own calendar, running inside the Calendar tab: the web app from the
// calendar-event-details worktree, built into ~/.perch/upshow-web (scripts/build-upshow-web.sh),
// so every interaction is the real one rather than a copy. A small server on this Mac hands out
// those files and passes /api calls on to Upshow, as the live site's own hosting does.

final class UpshowWebServer {
    static let shared = UpshowWebServer()
    static let port: UInt16 = 53690
    static let root = URL(fileURLWithPath: "\(Shell.home)/.perch/upshow-web")
    static let api = URL(string: "https://api.upshow.co.uk")!
    static var home: URL { URL(string: "http://127.0.0.1:\(port)/app/meetings")! }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "perch.upshow-web", qos: .userInitiated, attributes: .concurrent)

    var built: Bool { FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("index.html").path) }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        l.start(queue: queue)
        listener = l
    }

    // MARK: Reading a request

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done || error != nil { connection.cancel() } else { self.read(connection, buffer) }
                return
            }
            let head = String(decoding: buffer[..<split.lowerBound], as: UTF8.self)
            var lines = head.components(separatedBy: "\r\n")
            let first = lines.removeFirst().split(separator: " ").map(String.init)
            guard first.count >= 2 else { return connection.cancel() }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "") ?? 0
            let body = buffer[split.upperBound...]
            if body.count < length, !done, error == nil { return self.read(connection, buffer) }
            self.answer(connection, method: first[0], target: first[1], headers: headers, body: Data(body.prefix(length)))
        }
    }

    // MARK: Answering

    private func answer(_ connection: NWConnection, method: String, target: String, headers: [String: String], body: Data) {
        if target.hasPrefix("/api/") { return proxy(connection, method: method, target: target, headers: headers, body: body) }
        let path = target.split(separator: "?").first.map(String.init) ?? "/"
        // The app's service worker would keep old builds; this one is a plain page.
        if path == "/sw.js" { return send(connection, 404, ["Content-Type": "text/plain"], Data()) }
        var file = Self.root.appendingPathComponent(String(path.dropFirst()))
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir) || isDir.boolValue {
            // Every app route is the one page, as on the live site.
            file = Self.root.appendingPathComponent("index.html")
        }
        guard let data = try? Data(contentsOf: file) else { return send(connection, 404, ["Content-Type": "text/plain"], Data()) }
        var out = ["Content-Type": Self.type(file.pathExtension)]
        out["Cache-Control"] = file.lastPathComponent == "index.html" ? "no-store" : "public, max-age=31536000, immutable"
        send(connection, 200, out, data)
    }

    private func proxy(_ connection: NWConnection, method: String, target: String, headers: [String: String], body: Data) {
        guard let url = URL(string: target, relativeTo: Self.api)?.absoluteURL else { return send(connection, 400, [:], Data()) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 60
        for (name, value) in headers where !["host", "connection", "accept-encoding", "content-length", "origin", "referer"].contains(name) {
            req.setValue(value, forHTTPHeaderField: name)
        }
        if !body.isEmpty { req.httpBody = body }
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            guard let http = response as? HTTPURLResponse else { return self.send(connection, 502, ["Content-Type": "text/plain"], Data("Could not reach Upshow".utf8)) }
            var out: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                let name = "\(key)"
                // URLSession has already undone any compression and chunking.
                if ["content-encoding", "content-length", "transfer-encoding", "connection"].contains(name.lowercased()) { continue }
                out[name] = "\(value)"
            }
            self.send(connection, http.statusCode, out, data ?? Data())
        }.resume()
    }

    private func send(_ connection: NWConnection, _ status: Int, _ headers: [String: String], _ body: Data) {
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func type(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "webmanifest": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ico": return "image/x-icon"
        default: return "application/octet-stream"
        }
    }
}

/// The web view the calendar runs in. One for the whole app, so it keeps its place (and the
/// signed-in session) when the tab is closed and opened again.
final class UpshowWebView {
    static let shared = UpshowWebView()

    lazy var view: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // Only the calendar: Upshow's own side bar and top bar are left out, so it fits the island.
        let fit = """
        (function(){var s=document.createElement('style');s.id='perch-fit';s.textContent=`
          html,body{background:transparent!important}
        `;document.documentElement.appendChild(s);})();
        """
        config.userContentController.addUserScript(WKUserScript(source: fit, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config)
        // Google turns sign-in away from anything that does not say it is Safari.
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        web.navigationDelegate = guide
        web.uiDelegate = guide
        web.setValue(false, forKey: "drawsBackground")
        web.isInspectable = true
        return web
    }()

    private let guide = Guide()

    func load() {
        UpshowWebServer.shared.start()
        if view.url == nil { view.load(URLRequest(url: UpshowWebServer.home)) }
    }

    func reload() { view.load(URLRequest(url: UpshowWebServer.home)) }

    final class Guide: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.allow) }
            // Signing in sends the browser back to Upshow's own address, which is not this
            // copy. Bring that return (and the session it carries) here instead.
            if let host = url.host, host.hasSuffix("upshow.co.uk"), host != "api.upshow.co.uk",
               var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                parts.scheme = "http"
                parts.host = "127.0.0.1"
                parts.port = Int(UpshowWebServer.port)
                if let back = parts.url {
                    decisionHandler(.cancel)
                    webView.load(URLRequest(url: back))
                    return
                }
            }
            // Meeting links and anything outside the app open in the browser.
            if action.navigationType == .linkActivated, url.host != "127.0.0.1", !(url.host ?? "").contains("supabase.co"),
               !(url.host ?? "").contains("google.com") {
                NSWorkspace.shared.open(url)
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // target=_blank (Join, Cal.com): the browser.
            if let url = action.request.url { NSWorkspace.shared.open(url) }
            return nil
        }
    }
}

struct UpshowWeb: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        UpshowWebView.shared.load()
        return UpshowWebView.shared.view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
