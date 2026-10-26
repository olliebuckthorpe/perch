import Foundation
import Security

/// The private code Perch signs relayed messages with, so a session can tell a message really
/// typed in Perch from text that only claims to be (in a web page, an email, a file). Made once,
/// kept in `~/.perch/relay-key`, readable by this user only, and never shown in Perch.
enum RelayKey {
    private static let path = "\(Shell.home)/.perch/relay-key"

    static let code: String = {
        if let saved = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           saved.count >= 16 { return saved }
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let letters = Array("abcdefghjkmnpqrstuvwxyz23456789")
        let made = String(bytes.flatMap { b in [letters[Int(b) % letters.count], letters[Int(b / 7) % letters.count]] }.prefix(20))
        FileManager.default.createFile(atPath: path, contents: Data(made.utf8), attributes: [.posixPermissions: 0o600])
        return made
    }()

    static var signature: String { "[perch-signed \(code)]" }

    /// The text without the signature, for showing in Perch.
    static func unsigned(_ text: String) -> String {
        guard let r = text.range(of: "[perch-signed ") else { return text }
        let rest = text[r.lowerBound...]
        guard let end = rest.firstIndex(of: "]") else { return text }
        var out = text
        out.removeSubrange(r.lowerBound...end)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
