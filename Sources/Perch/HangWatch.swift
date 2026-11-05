import Darwin
import Foundation

/// Notices when Perch freezes or spins, and keeps a record of what it was doing at the time in
/// ~/.perch/hangs, so a freeze that ends in Force Quit still leaves something to fix it from.
/// Watches from its own thread: the main thread is the one that gets stuck.
final class HangWatch {
    static let shared = HangWatch()
    static let folder = URL(fileURLWithPath: "\(Shell.home)/.perch/hangs")

    private let queue = DispatchQueue(label: "perch.hangwatch", qos: .utility)
    private var lastAnswer = Date()
    private var asked = false
    private var recorded: Date?
    private var busyWindows = 0
    private var lastCPU: Double = 0
    private var lastCheck = Date()

    func start() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        lastCPU = Self.cpuSeconds()
        queue.async { self.tick() }
    }

    private func tick() {
        let now = Date()
        // The main thread answers within a moment unless something holds it.
        if !asked {
            asked = true
            DispatchQueue.main.async { [weak self] in
                self?.queue.async { self?.lastAnswer = Date(); self?.asked = false }
            }
        }
        if now.timeIntervalSince(lastAnswer) > 4 { record("frozen") }

        // Busy: most of a core for half a minute running, which nothing in Perch should need.
        if now.timeIntervalSince(lastCheck) >= 10 {
            let cpu = Self.cpuSeconds()
            let share = (cpu - lastCPU) / now.timeIntervalSince(lastCheck)
            busyWindows = share > 0.8 ? busyWindows + 1 : 0
            lastCPU = cpu
            lastCheck = now
            if busyWindows >= 3 { record("busy"); busyWindows = 0 }
        }
        queue.asyncAfter(deadline: .now() + 1) { self.tick() }
    }

    /// A few seconds of stacks from every thread, by the system's own `sample`. Once a minute at
    /// most, and only the newest twenty are kept.
    private func record(_ why: String) {
        if let recorded, Date().timeIntervalSince(recorded) < 60 { return }
        recorded = Date()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = Self.folder.appendingPathComponent("\(why)-\(stamp).txt")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        task.arguments = ["\(getpid())", "3", "1", "-file", file.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        let old = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let sorted = old.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for gone in sorted.dropFirst(20) { try? FileManager.default.removeItem(at: gone) }
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }
}
