import Foundation
import Security

/// Secrets in owner-only files under `~/.perch/secrets` (the folder 700, each file 600), as the
/// Notion token already was.
///
/// They used to live in the macOS Keychain, but macOS ties a Keychain item to the exact build
/// that may read it, so every rebuild of Perch asked for the Mac password again. A key still in
/// the Keychain is copied into its file the first time it is read (one last prompt), and the
/// Keychain is not asked again.
enum Keychain {
    private static let dir = "\(Shell.home)/.perch/secrets"

    private static func path(_ service: String, _ account: String) -> String {
        // Account names are workspace names plus ".app" / ".user", already limited to safe characters.
        "\(dir)/\(service).\(account)"
    }

    static func get(_ service: String, _ account: String) -> String? {
        if let data = FileManager.default.contents(atPath: path(service, account)),
           let value = String(data: data, encoding: .utf8), !value.isEmpty {
            return value
        }
        guard let old = keychainGet(service, account) else { return nil }
        set(service, account, old)
        return old
    }

    @discardableResult
    static func set(_ service: String, _ account: String, _ value: String) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        let file = path(service, account)
        // Written to a temporary file that is already owner-only, then moved into place, so the
        // key is never readable by anyone else even for a moment.
        let temp = "\(file).tmp"
        try? fm.removeItem(atPath: temp) // a stale one from an interrupted write
        guard fm.createFile(atPath: temp, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600]) else { return false }
        _ = try? fm.removeItem(atPath: file)
        return (try? fm.moveItem(atPath: temp, toPath: file)) != nil
    }

    static func delete(_ service: String, _ account: String) {
        try? FileManager.default.removeItem(atPath: path(service, account))
    }

    /// The old home of the keys, read once for the move.
    private static func keychainGet(_ service: String, _ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
