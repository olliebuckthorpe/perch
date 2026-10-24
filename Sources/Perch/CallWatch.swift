import Foundation
import Observation

/// Knows when the screen is being shared or recorded (Meet, Zoom, Slack, QuickTime, anything that
/// captures the screen). Perch stays quiet then, so nothing private pops up in front of an
/// audience: no banners, no sounds, no opening by itself. Everything still lands in the sidebar.
/// Calls without sharing are not affected.
///
/// macOS has no public way to ask this. The window server's own "is anything watching the
/// screen" check is used, looked up at run time; if a macOS update removes it, Perch simply
/// behaves as if nothing is being shared.
@Observable
final class CallWatch {
    static let shared = CallWatch()

    /// Something is capturing the screen right now.
    private(set) var sharing = false

    private typealias Check = @convention(c) () -> Bool
    @ObservationIgnored private lazy var watched: Check? = {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let sym = dlsym(lib, "SLSIsScreenWatcherPresent") ?? dlsym(lib, "CGSIsScreenWatcherPresent") else { return nil }
        return unsafeBitCast(sym, to: Check.self)
    }()
    @ObservationIgnored private var timer: Timer?
    /// When sharing started and stopped, for checking it is noticed.
    @ObservationIgnored private(set) var history: [String] = []

    func start() {
        guard watched != nil else { return }
        // A cheap call every two seconds; nothing to listen to instead.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
        timer?.tolerance = 1
        check()
    }

    private func check() {
        let now = watched?() ?? false
        guard now != sharing else { return }
        sharing = now
        history.append("\(Date().formatted(date: .omitted, time: .standard)) \(now ? "sharing" : "stopped")")
        history = Array(history.suffix(20))
    }
}
