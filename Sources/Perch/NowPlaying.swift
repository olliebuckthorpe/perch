import AppKit
import Observation
import SwiftUI

/// What the Mac is playing, from any app that reports to Control Center's Now Playing (Spotify,
/// Music, a browser tab, a podcast app).
///
/// Since macOS 15.4 only Apple's own processes may read that, so Perch runs the bundled
/// mediaremote-adapter under `/usr/bin/perl` (which may) and reads the JSON lines it streams.
/// The same script sends play, pause, skip and seek. See `vendor/mediaremote-adapter`.
@Observable
final class NowPlaying {
    static let shared = NowPlaying()

    private(set) var title: String?
    private(set) var artist: String?
    private(set) var album: String?
    private(set) var playing = false
    /// Seconds. Nil for a live stream or a player that does not say.
    private(set) var duration: Double?
    private(set) var artwork: NSImage?
    /// The cover's own colour, lifted so it reads on black. White for a grey cover or none.
    private(set) var accent: Color = .white
    /// The app the media belongs to: the browser for a web page, otherwise the player itself.
    private(set) var appBundleID: String?
    /// Shown in the closed notch: while playing, and for a little while after a pause so a quick
    /// pause does not make the notch jump.
    private(set) var inNotch = false

    var active: Bool { title != nil }

    /// Where playback is now. The adapter gives the position at a moment and the rate since, so
    /// this is worked out rather than polled.
    func elapsed(at now: Date = Date()) -> Double {
        var t = elapsedAt
        if playing, let stamp { t += now.timeIntervalSince(stamp) * rate }
        if let duration { t = min(t, duration) }
        return max(0, t)
    }

    var appName: String? {
        guard let id = appBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    @ObservationIgnored private var elapsedAt: Double = 0
    @ObservationIgnored private var stamp: Date?
    @ObservationIgnored private var rate: Double = 1
    @ObservationIgnored private var pid: pid_t?
    @ObservationIgnored private var info: [String: Any] = [:]
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var retryDelay: TimeInterval = 2
    @ObservationIgnored private var lingerWork: DispatchWorkItem?
    @ObservationIgnored private let parse = DispatchQueue(label: "perch.nowplaying", qos: .utility)

    private static let folder = Bundle.main.resourceURL?.appendingPathComponent("mediaremote")
    private static var script: String? {
        guard let p = folder?.appendingPathComponent("mediaremote-adapter.pl").path,
              FileManager.default.fileExists(atPath: p) else { return nil }
        return p
    }
    private static var framework: String? { folder?.appendingPathComponent("MediaRemoteAdapter.framework").path }

    // MARK: Stream

    func start() {
        guard process == nil, let script = Self.script, let framework = Self.framework else { return }
        stopping = false
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script, framework, "stream", "--debounce=150"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            self.parse.async { self.take(chunk) }
        }
        p.terminationHandler = { [weak self] _ in
            out.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.ended() }
        }
        do {
            try p.run()
            process = p
        } catch {
            NSLog("Perch: Now Playing adapter did not start: \(error)")
        }
    }

    func stop() {
        stopping = true
        process?.terminate()
        process = nil
    }

    /// The adapter quit by itself (an update to macOS can do that): try again, backing off.
    private func ended() {
        process = nil
        guard !stopping else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in self?.start() }
        retryDelay = min(retryDelay * 2, 120)
    }

    /// Runs on the parse queue. Lines can be several hundred kilobytes (the cover, in base64), so
    /// a line can arrive over many chunks.
    private func take(_ chunk: Data) {
        buffer.append(chunk)
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<end]
            buffer.removeSubrange(buffer.startIndex...end)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = json["payload"] as? [String: Any] else { continue }
            let diff = json["diff"] as? Bool ?? false
            // The cover is decoded here, off the main thread, and only when it changed.
            var cover: (NSImage?, Color)?
            if payload.keys.contains("artworkData") {
                let image = (payload["artworkData"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
                cover = (image, image.map(Self.accent(of:)) ?? .white)
            }
            DispatchQueue.main.async { self.apply(payload, diff: diff, cover: cover) }
        }
    }

    private func apply(_ payload: [String: Any], diff: Bool, cover: (NSImage?, Color)?) {
        retryDelay = 2
        if diff {
            for (key, value) in payload {
                if value is NSNull { info.removeValue(forKey: key) } else { info[key] = value }
            }
        } else {
            info = payload
        }
        title = (info["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        artist = (info["artist"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        album = (info["album"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        duration = (info["duration"] as? Double).flatMap { $0 > 0 ? $0 : nil }
        elapsedAt = info["elapsedTime"] as? Double ?? 0
        stamp = (info["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        rate = info["playbackRate"] as? Double ?? 1
        pid = (info["processIdentifier"] as? Int).map { pid_t($0) }
        appBundleID = info["parentApplicationBundleIdentifier"] as? String ?? info["bundleIdentifier"] as? String
        if let cover {
            artwork = cover.0
            accent = cover.1
        } else if !diff, info["artworkData"] == nil {
            artwork = nil
            accent = .white
        }
        setPlaying(info["playing"] as? Bool ?? false)
        if title == nil { inNotch = false }
    }

    private func setPlaying(_ now: Bool) {
        playing = now
        lingerWork?.cancel()
        if now {
            if active { inNotch = true }
        } else if inNotch {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.playing else { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { self.inNotch = false }
            }
            lingerWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
        }
    }

    // MARK: Controls

    func togglePlay() {
        // Shown at once; the stream confirms it a moment later.
        elapsedAt = elapsed()
        stamp = Date()
        setPlaying(!playing)
        send(["send", "2"])
    }

    func next() { send(["send", "4"]) }
    func previous() { send(["send", "5"]) }

    func seek(to seconds: Double) {
        elapsedAt = max(0, seconds)
        stamp = Date()
        send(["seek", String(Int(elapsedAt * 1_000_000))])
    }

    /// Brings the player to the front: the browser for a web page, otherwise the app itself.
    func openPlayer() {
        if let id = appBundleID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            app.activate()
        } else if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        } else if let id = appBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    private func send(_ args: [String]) {
        guard let script = Self.script, let framework = Self.framework else { return }
        Shell.run("/usr/bin/perl", [script, framework] + args)
    }

    // MARK: Cover colour

    /// The cover's average colour, brightened and given some saturation so bars in it stand out
    /// on the black notch. A cover that is mostly grey gives white.
    static func accent(of image: NSImage) -> Color {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let average = NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        average.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.12 { return .white }
        return Color(hue: Double(h), saturation: Double(min(1, max(s, 0.45))), brightness: Double(max(b, 0.85)))
    }
}
