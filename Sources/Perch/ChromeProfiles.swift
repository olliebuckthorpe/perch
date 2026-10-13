import AppKit

/// The user's Chrome profiles, read from Chrome's own list, so the notch can jump straight
/// to the right one (and open a link there).
struct ChromeProfile: Identifiable {
    let id: String        // Chrome's folder name for it, e.g. "Profile 3"
    let name: String
    let email: String
    /// The Google account's first name. Chrome's Profiles menu shows a signed-in profile as
    /// "First (Profile name)", or just the name when the two are the same or it is not signed in.
    let account: String
    let lastUsed: Double
    /// The Google account picture Chrome keeps for the profile, when it has one.
    let picturePath: String?
    /// Chrome's own colour for the profile, as it shows in its profile switcher.
    let argb: Int?

    /// What Perch calls the profile. Chrome's own name stays as it is (and is still what finds
    /// the profile in Chrome's menu); this is only the wording shown in the notch.
    var label: String {
        (UserDefaults.standard.dictionary(forKey: "profileLabels") as? [String: String])?[id] ?? name
    }

    /// A chosen icon for the profile (a client's favicon, say), which wins over the Google picture.
    var iconPath: String? {
        let path = "\(Shell.home)/.perch/profile-icons/\(id).png"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Profiles the user does not want offered in the notch. Chrome's folder names.
    static var hidden: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "hiddenProfiles") ?? ["Profile 1"]) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "hiddenProfiles") }
    }

    static func shown() -> [ChromeProfile] { all().filter { !hidden.contains($0.id) } }

    static func all() -> [ChromeProfile] {
        let path = "\(Shell.home)/Library/Application Support/Google/Chrome/Local State"
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: [String: Any]] else { return [] }
        let order = profile["profiles_order"] as? [String] ?? []
        let base = "\(Shell.home)/Library/Application Support/Google/Chrome"
        return cache.map { dir, info in
            let file = info["gaia_picture_file_name"] as? String ?? ""
            let picture = "\(base)/\(dir)/\(file)"
            return ChromeProfile(id: dir, name: info["name"] as? String ?? dir, email: info["user_name"] as? String ?? "",
                                 account: info["gaia_given_name"] as? String ?? "",
                                 lastUsed: info["active_time"] as? Double ?? 0,
                                 picturePath: !file.isEmpty && FileManager.default.fileExists(atPath: picture) ? picture : nil,
                                 argb: info["profile_highlight_color"] as? Int)
        }.sorted {
            // Chrome's own order when it has one, otherwise most recently used first.
            let (a, b) = (order.firstIndex(of: $0.id), order.firstIndex(of: $1.id))
            if let a, let b { return a < b }
            return $0.lastUsed > $1.lastUsed
        }
    }

    /// Takes you to this profile: the window it already has open if there is one, otherwise a new
    /// one. With a `url`, opens that link in the profile.
    func open(_ url: URL? = nil) {
        if url == nil {
            if !AXIsProcessTrusted() { Self.log("jump to \(name): Perch is not allowed under Accessibility, opening a new window") }
            if jumpToExistingWindow() { return }
        }
        var args = ["-na", "Google Chrome", "--args", "--profile-directory=\(id)"]
        if let url { args.append(url.absoluteString) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        try? p.run()
    }

    static var canJump: Bool { AXIsProcessTrusted() }

    static func askToJump() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Presses this profile's entry in Chrome's own Profiles menu, which is the one thing that
    /// brings a profile's existing window forward. Driving another app's menu needs the
    /// Accessibility permission; without it this returns false and a new window opens instead.
    private func jumpToExistingWindow() -> Bool {
        guard AXIsProcessTrusted(),
              let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first
        else { return false }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
            return value as? [AXUIElement] ?? []
        }
        func title(_ element: AXUIElement) -> String {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
            return value as? String ?? ""
        }
        let app = AXUIElementCreateApplication(chrome.processIdentifier)
        var bar: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar)
        guard let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return false }
        let menuBar = bar as! AXUIElement
        guard let profilesMenu = children(menuBar).first(where: { title($0) == "Profiles" }),
              let menu = children(profilesMenu).first else {
            Self.log("jump to \(name): no Profiles menu found; menu bar = \(children(menuBar).map(title))")
            return false
        }
        // Chrome writes a signed-in profile as "Account Name (Profile Name)" and a local one as
        // just its name, so accept either shape.
        let titles = children(menu).map(title)
        // The exact wording Chrome uses wins; looser matches are only a fallback.
        let expected = account.isEmpty || account == name ? name : "\(account) (\(name))"
        var matches = children(menu).filter { title($0) == expected }
        if matches.isEmpty { matches = children(menu).filter { title($0) == name || title($0).hasSuffix("(\(name))") } }
        let twins = ChromeProfile.all().filter { $0.name == name && $0.account == account }
        let position = min(twins.firstIndex { $0.id == id } ?? 0, max(0, matches.count - 1))
        let pressed = matches.indices.contains(position)
            && AXUIElementPerformAction(matches[position], kAXPressAction as CFString) == .success
        Self.log("jump to \(name) [\(id)]: menu = \(titles) | matched \(matches.map(title)) | pressed \(pressed)")
        guard pressed else { return false }
        chrome.activate()
        return true
    }

    /// A short record of the last few jumps, for working out why one went to the wrong place.
    static func log(_ line: String) {
        let path = "\(Shell.home)/.perch/chrome-jump.log"
        let entry = "\(Date()) \(line)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            _ = try? handle.seekToEnd()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// A web link sitting on the clipboard, if there is one.
    static var copiedLink: URL? {
        guard let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              s.count < 2000, !s.contains(" "), let url = URL(string: s),
              url.scheme == "http" || url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}
