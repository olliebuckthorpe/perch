import AppKit

/// The user's Chrome profiles, read from Chrome's own list, so the notch can jump straight
/// to the right one (and open a link there).
struct ChromeProfile: Identifiable {
    let id: String        // Chrome's folder name for it, e.g. "Profile 3"
    let name: String
    let email: String
    let lastUsed: Double

    static func all() -> [ChromeProfile] {
        let path = "\(Shell.home)/Library/Application Support/Google/Chrome/Local State"
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: [String: Any]] else { return [] }
        let order = profile["profiles_order"] as? [String] ?? []
        return cache.map { dir, info in
            ChromeProfile(id: dir, name: info["name"] as? String ?? dir, email: info["user_name"] as? String ?? "",
                          lastUsed: info["active_time"] as? Double ?? 0)
        }.sorted {
            // Chrome's own order when it has one, otherwise most recently used first.
            let (a, b) = (order.firstIndex(of: $0.id), order.firstIndex(of: $1.id))
            if let a, let b { return a < b }
            return $0.lastUsed > $1.lastUsed
        }
    }

    /// Opens a window in this profile, on `url` if one is given.
    func open(_ url: URL? = nil) {
        var args = ["-na", "Google Chrome", "--args", "--profile-directory=\(id)"]
        if let url { args.append(url.absoluteString) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        try? p.run()
    }

    /// A web link sitting on the clipboard, if there is one.
    static var copiedLink: URL? {
        guard let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              s.count < 2000, !s.contains(" "), let url = URL(string: s),
              url.scheme == "http" || url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}
