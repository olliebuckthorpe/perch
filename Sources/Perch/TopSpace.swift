import AppKit

// Private window server calls. A window placed in its own top-level space sits above every
// desktop and full screen space, and does not slide down when a full screen app reveals the
// menu bar. This is the same trick other notch apps use; it can break with a macOS update,
// in which case the island simply behaves like a normal floating panel again.
@_silgen_name("_CGSDefaultConnection") private func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSSpaceCreate") private func CGSSpaceCreate(_ cid: Int32, _ flag: Int32, _ options: CFDictionary?) -> Int
@_silgen_name("CGSSpaceSetAbsoluteLevel") private func CGSSpaceSetAbsoluteLevel(_ cid: Int32, _ space: Int, _ level: Int32)
@_silgen_name("CGSShowSpaces") private func CGSShowSpaces(_ cid: Int32, _ spaces: CFArray)
@_silgen_name("CGSAddWindowsToSpaces") private func CGSAddWindowsToSpaces(_ cid: Int32, _ windows: CFArray, _ spaces: CFArray)

enum TopSpace {
    private static let space: Int = {
        let cid = _CGSDefaultConnection()
        let id = CGSSpaceCreate(cid, 1, nil)
        CGSSpaceSetAbsoluteLevel(cid, id, Int32.max)
        CGSShowSpaces(cid, [id] as CFArray)
        return id
    }()

    static func adopt(_ window: NSWindow) {
        CGSAddWindowsToSpaces(_CGSDefaultConnection(), [window.windowNumber] as CFArray, [space] as CFArray)
    }
}
