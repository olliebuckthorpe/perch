import AppKit

/// A link someone clicked, waiting for the user to say which Chrome profile it belongs in.
struct PendingLink: Identifiable {
    let id = UUID()
    let url: URL
    let site: String
    let sourceName: String?
    let sourceBundle: String?
    /// The profiles, always in the same order, so 1 to 4 mean the same thing every time.
    let choices: [ChromeProfile]
    /// The one Perch thinks is most likely, if it has anything to go on. Return picks it.
    var suggested: String?
}

/// Decides where a clicked link opens. Perch is registered as the default browser purely to
/// catch links; it then opens each one in the right Chrome profile: straight away if it has
/// learned where that site goes, otherwise after asking in the notch.
final class LinkRouter {
    static let shared = LinkRouter()

    /// How many identical picks in a row before a site stops asking.
    private static let learnAfter = 3
    /// Sites where the right account genuinely varies from link to link, so they always ask.
    private static let alwaysAsk = ["google.com", "slack.com", "notion.so", "linkedin.com", "microsoftonline.com", "office.com", "zoom.us"]

    private struct Memory: Codable {
        var settled: [String: String] = [:]        // site -> profile it always opens in
        var recent: [String: [String]] = [:]       // site -> last few profiles picked
        var bySource: [String: [String: Int]] = [:] // app the link came from -> profile -> picks
    }

    private var memory: Memory = {
        guard let data = UserDefaults.standard.data(forKey: "linkMemory"),
              let m = try? JSONDecoder().decode(Memory.self, from: data) else { return Memory() }
        return m
    }() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(memory), forKey: "linkMemory") }
    }

    static func site(of url: URL) -> String {
        let host = (url.host ?? "").lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func asksEveryTime(_ site: String) -> Bool {
        Self.alwaysAsk.contains { site == $0 || site.hasSuffix(".\($0)") }
    }

    func handle(_ url: URL, from source: NSRunningApplication?) {
        let profiles = ChromeProfile.shown()
        let site = Self.site(of: url)
        guard !profiles.isEmpty else {
            // No profiles to choose between: just hand it to Chrome.
            ChromeProfile.openInChrome(url)
            return
        }
        if let id = memory.settled[site], let profile = profiles.first(where: { $0.id == id }) {
            profile.open(url)
            NotchUI.shared.announce(url: url, site: site, openedIn: profile)
            return
        }
        let bundle = source?.bundleIdentifier
        let picks = memory.recent[site] ?? []
        let fromApp = bundle.flatMap { memory.bySource[$0] } ?? [:]
        func score(_ p: ChromeProfile) -> Int { picks.filter { $0 == p.id }.count * 10 + (fromApp[p.id] ?? 0) }
        let best = profiles.max { score($0) < score($1) }
        NotchUI.shared.present(PendingLink(url: url, site: site, sourceName: source?.localizedName,
                                           sourceBundle: bundle, choices: profiles,
                                           suggested: best.flatMap { score($0) > 0 ? $0.id : nil }))
    }

    /// The user picked a profile. Opens the link and remembers the choice.
    func open(_ link: PendingLink, in profile: ChromeProfile, always: Bool) {
        profile.open(link.url)
        var m = memory
        var picks = (m.recent[link.site] ?? []) + [profile.id]
        picks = Array(picks.suffix(6))
        m.recent[link.site] = picks
        if let bundle = link.sourceBundle { m.bySource[bundle, default: [:]][profile.id, default: 0] += 1 }
        let steady = picks.suffix(Self.learnAfter).count == Self.learnAfter && Set(picks.suffix(Self.learnAfter)).count == 1
        if always || (steady && !asksEveryTime(link.site)) { m.settled[link.site] = profile.id }
        memory = m
    }

    /// Stop opening `site` automatically and ask again next time.
    func forget(_ site: String) {
        var m = memory
        m.settled[site] = nil
        m.recent[site] = nil
        memory = m
    }

    func forgetEverything() { memory = Memory() }

    var settledCount: Int { memory.settled.count }

    func canSettle(_ site: String) -> Bool { !asksEveryTime(site) }

    // MARK: Being the default browser

    static var isDefault: Bool {
        guard let probe = URL(string: "https://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Asks macOS to make Perch the default browser. macOS shows its own confirmation.
    static func makeDefault() {
        for scheme in ["http", "https"] {
            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme) { error in
                if let error { NSLog("Perch: could not become the default browser: \(error)") }
            }
        }
    }
}

extension ChromeProfile {
    /// Opens a link in Chrome without choosing a profile (Chrome uses whichever was last active).
    static func openInChrome(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Google Chrome", url.absoluteString]
        try? p.run()
    }
}
