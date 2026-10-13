import AppKit

/// Keeps the pointer from touching the very top edge of the screen while it is over the
/// island, so a full screen app never gets the cue to slide its menu bar and title bar down.
///
/// This has to happen before macOS acts on the movement, which only an event tap can do,
/// and an event tap needs the Accessibility permission. It runs on its own thread so pointer
/// movement never waits on the app's interface.
final class EdgeGuard {
    static let shared = EdgeGuard()

    /// Horizontal span to guard and the top edge, in global display coordinates (y down).
    private var minX: CGFloat = 0
    private var maxX: CGFloat = 0
    private var topY: CGFloat = 0
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var poll: Timer?

    static var wanted: Bool {
        get { UserDefaults.standard.bool(forKey: "edgeGuard") }
        set { UserDefaults.standard.set(newValue, forKey: "edgeGuard") }
    }

    var active: Bool { tap != nil }

    func setZone(minX: CGFloat, maxX: CGFloat, topY: CGFloat) {
        lock.lock()
        self.minX = minX
        self.maxX = maxX
        self.topY = topY
        lock.unlock()
    }

    /// Turns the guard on, asking for Accessibility if it has not been granted yet.
    func start(prompt: Bool) {
        guard tap == nil else { return }
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            // Wait for the user to tick the box in System Settings, then carry on by itself.
            poll?.invalidate()
            poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard Self.wanted else { timer.invalidate(); return }
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    self?.start(prompt: false)
                }
            }
            return
        }
        let mask = (1 << CGEventType.mouseMoved.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: edgeGuardCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        tap = port
        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            // Starts switched off: see `engage`.
            CGEvent.tapEnable(tap: port, enable: false)
            CFRunLoopRun()
        }
        thread.name = "Perch edge guard"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private var engaged = false

    /// While the tap is on, every mouse movement on the Mac passes through Perch first, so if
    /// Perch is busy or restarting the pointer stutters. It is therefore only switched on while
    /// the pointer is up by the island, and off the rest of the time.
    func engage(_ on: Bool) {
        guard on != engaged else { return }
        engaged = on
        if let tap { CGEvent.tapEnable(tap: tap, enable: on) }
    }

    func stop() {
        poll?.invalidate()
        guard let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        tap = nil
        engaged = false
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap, engaged { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        lock.lock()
        let (lo, hi, top) = (minX, maxX, topY)
        lock.unlock()
        var p = event.location
        guard p.x >= lo, p.x <= hi, p.y < top + 3 else { return }
        p.y = top + 3
        event.location = p
        CGWarpMouseCursorPosition(p)
        // A warp makes macOS ignore the mouse for a quarter of a second, which at the top edge
        // happens on every movement and freezes the pointer. Re-associating cancels that pause.
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

private func edgeGuardCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon { Unmanaged<EdgeGuard>.fromOpaque(refcon).takeUnretainedValue().handle(type, event) }
    return Unmanaged.passUnretained(event)
}
