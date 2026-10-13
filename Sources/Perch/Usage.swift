import Foundation
import Observation

/// How much of each subscription's allowance is used: the short rolling window (five hours)
/// and the week. Claude Code reports its own through its status line; Codex writes its into
/// every session file. Nothing is fetched and no account details are read.
@Observable
final class Usage {
    static let shared = Usage()

    struct Window: Equatable {
        var used: Double
        var resets: Date?

        /// A window that has rolled over since it was reported is empty again.
        var current: Double { if let resets, resets < Date() { return 0 } else { return min(100, max(0, used)) } }
    }

    struct Plan: Equatable {
        var short: Window?
        var week: Window?
        var at = Date.distantPast
    }

    private(set) var claude = Plan()
    private(set) var codex = Plan()
    /// Grok Bot has one allowance, counted over the week.
    private(set) var grok = Plan()

    /// Grok Bot's own usage status: a percentage and when the week resets.
    func takeGrok(_ json: [String: Any]) {
        guard let percent = (json["usagePercent"] as? NSNumber)?.doubleValue else { return }
        let resets = (json["nextResetTimestampUtc"] as? String).flatMap { s -> Date? in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        let plan = Plan(short: nil, week: Window(used: percent, resets: resets), at: Date())
        if plan.week != grok.week { grok = plan }
        Self.save(plan, "usageGrok")
    }

    private init() {
        grok = Self.load("usageGrok")
        claude = Self.load("usageClaude")
        codex = Self.load("usageCodex")
    }

    /// Claude Code's status line input: `rate_limits.five_hour` and `rate_limits.seven_day`.
    func takeClaude(_ json: [String: Any]) {
        guard let limits = json["rate_limits"] as? [String: Any] else { return }
        let plan = Plan(short: Self.window(limits["five_hour"]), week: Self.window(limits["seven_day"]), at: Date())
        guard plan.short != nil || plan.week != nil else { return }
        if plan.short != claude.short || plan.week != claude.week { claude = plan }
        Self.save(plan, "usageClaude")
    }

    /// Claude Code reports the plan's windows alongside every reply when it runs headless. Perch
    /// asks its smallest model for one word every so often and reads that report. It uses the
    /// `claude` command's own login, so Perch never touches the account's credentials.
    func refreshClaude() {
        guard let exe = Shell.find("claude") else { return }
        let args = ["-p", "Reply with the single word ok", "--model", "haiku", "--output-format", "stream-json", "--verbose"]
        Shell.run(exe, args, cwd: "\(Shell.home)/.perch", env: ["PERCH_SKIP": "1"]) { [weak self] _, output in
            for line in output.split(separator: "\n") where line.contains("rate_limit_event") {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let info = o["rate_limit_info"] as? [String: Any],
                      let windows = info["unifiedWindows"] as? [String: Any] else { continue }
                func window(_ key: String) -> Window? {
                    guard let d = windows[key] as? [String: Any], let part = (d["utilization"] as? NSNumber)?.doubleValue else { return nil }
                    let resets = (d["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                    return Window(used: part * 100, resets: resets)
                }
                let plan = Plan(short: window("five_hour"), week: window("seven_day"), at: Date())
                guard plan.short != nil || plan.week != nil else { continue }
                self?.claude = plan
                Self.save(plan, "usageClaude")
            }
        }
    }

    private var timer: Timer?

    /// Now, then every twenty minutes.
    func start() {
        refreshClaude()
        timer = Timer.scheduledTimer(withTimeInterval: 1200, repeats: true) { [weak self] _ in self?.refreshClaude() }
        timer?.tolerance = 120
    }

    /// Codex's `rate_limits` block: `primary` is the five hour window, `secondary` the week.
    func takeCodex(_ limits: [String: Any], at: Date) {
        guard at > codex.at else { return }
        let plan = Plan(short: Self.window(limits["primary"]), week: Self.window(limits["secondary"]), at: at)
        guard plan.short != nil || plan.week != nil else { return }
        codex = plan
        Self.save(plan, "usageCodex")
    }

    private static func window(_ value: Any?) -> Window? {
        guard let d = value as? [String: Any] else { return nil }
        let used = d["used_percentage"] ?? d["used_percent"] ?? d["utilization"]
        guard let percent = (used as? NSNumber)?.doubleValue else { return nil }
        var resets: Date?
        if let n = (d["resets_at"] as? NSNumber)?.doubleValue {
            resets = Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        } else if let s = d["resets_at"] as? String {
            resets = ISO8601DateFormatter().date(from: s)
        }
        return Window(used: percent, resets: resets)
    }

    private static func save(_ plan: Plan, _ key: String) {
        func row(_ w: Window?) -> [String: Double] {
            guard let w else { return [:] }
            return ["used": w.used, "resets": w.resets?.timeIntervalSince1970 ?? 0]
        }
        UserDefaults.standard.set(["short": row(plan.short), "week": row(plan.week), "at": ["t": plan.at.timeIntervalSince1970]], forKey: key)
    }

    private static func load(_ key: String) -> Plan {
        guard let d = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Double]] else { return Plan() }
        func window(_ r: [String: Double]?) -> Window? {
            guard let r, let used = r["used"] else { return nil }
            let t = r["resets"] ?? 0
            return Window(used: used, resets: t > 0 ? Date(timeIntervalSince1970: t) : nil)
        }
        return Plan(short: window(d["short"]), week: window(d["week"]), at: Date(timeIntervalSince1970: d["at"]?["t"] ?? 0))
    }
}
