import AppKit
import Observation

/// Keyboard cleaning mode: every key press on the Mac is swallowed (letters, function keys,
/// brightness, volume and media keys) so the keyboard can be wiped without typing anything.
/// The pointer still works, and the notch shows an Unlock button. It unlocks by itself after
/// two minutes, so it can never leave the Mac without a keyboard.
///
/// Uses an event tap, which needs the Accessibility permission Perch already has. The tap only
/// exists while locked. The power button cannot be blocked by any app.
@Observable
final class KeyboardLock {
    static let shared = KeyboardLock()
    static let limit: TimeInterval = 120

    private(set) var locked = false
    private(set) var until = Date.distantPast
    /// Shown when it could not lock (no Accessibility permission).
    private(set) var problem: String?

    @ObservationIgnored fileprivate var tap: CFMachPort?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var timer: Timer?

    func toggle() { locked ? unlock() : lock() }

    func lock() {
        guard !locked else { return }
        problem = nil
        // Key down and up, modifier keys, and the "system defined" events that carry the
        // brightness, volume and media keys.
        let types: [UInt32] = [CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue, CGEventType.flagsChanged.rawValue, 14]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1)) }
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: keyboardLockCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            problem = "Perch needs the Accessibility permission to lock the keyboard"
            return
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        locked = true
        until = Date().addingTimeInterval(Self.limit)
        timer = Timer.scheduledTimer(withTimeInterval: Self.limit, repeats: false) { [weak self] _ in self?.unlock() }
        NotchUI.shared.expand()
    }

    func unlock() {
        timer?.invalidate()
        timer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        locked = false
    }
}

private func keyboardLockCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                  userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // macOS switched the tap off; while locked, switch it straight back on.
        if let userInfo {
            let lock = Unmanaged<KeyboardLock>.fromOpaque(userInfo).takeUnretainedValue()
            if lock.locked, let tap = lock.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
        return Unmanaged.passUnretained(event)
    }
    // Locked: the key goes nowhere.
    return nil
}
