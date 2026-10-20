import Foundation

// Pure, Foundation-only helpers behind the "keep steady-state light" work:
// poll backoff, publish-on-change comparison, today-range binary search and
// log rotation. Framework-free so tools/verify-lightness.swift can compile it
// alone on a CommandLineTools-only Mac.

/// One rate-limit window reported by claude.ai / ChatGPT / Codex.
struct LimitWindow: Identifiable, Equatable {
    let id: String        // "five_hour" | "seven_day" | "seven_day_sonnet" | "codex-primary" …
    let label: String     // "Session · 5h" etc.
    var utilization: Double   // 0…100
    var resetsAt: Date?
    var period: String?   // short rolling-window label ("5h"/"7d") for the menu bar

    var fraction: Double { min(max(utilization / 100, 0), 1) }

    /// "Would the UI render differently?" Utilization is compared at 0.1 pt and
    /// the reset time at 1 s, so float/ms jitter in a response never counts as a
    /// change (and so never re-renders the scene).
    func displayEquals(_ other: LimitWindow) -> Bool {
        guard id == other.id, label == other.label, period == other.period else { return false }
        guard (utilization * 10).rounded() == (other.utilization * 10).rounded() else { return false }
        switch (resetsAt, other.resetsAt) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.timeIntervalSince(b)) < 1
        default: return false
        }
    }

    static func displayEqual(_ a: [LimitWindow], _ b: [LimitWindow]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.displayEquals($1) }
    }
}

/// Consecutive-failure backoff. Schedule with base 60 s, threshold 3, cap 1800 s:
/// failures 0-2 → 60 s, 3 → 120, 4 → 240, 5 → 480, 6 → 960, 7+ → 1800 (cap).
/// One success resets to `base`.
struct PollBackoff: Equatable {
    let base: TimeInterval
    let cap: TimeInterval
    let threshold: Int
    private(set) var failures = 0

    init(base: TimeInterval, cap: TimeInterval = 1800, threshold: Int = 3) {
        self.base = base
        self.cap = max(cap, base)
        self.threshold = max(threshold, 1)
    }

    static func interval(base: TimeInterval, cap: TimeInterval, threshold: Int, failures: Int) -> TimeInterval {
        guard failures >= threshold else { return base }
        let doublings = min(failures - threshold + 1, 30)
        return min(cap, base * pow(2, Double(doublings)))
    }

    var interval: TimeInterval {
        Self.interval(base: base, cap: cap, threshold: threshold, failures: failures)
    }
    var isBackedOff: Bool { failures >= threshold }

    /// Returns true on the ok → error transition (first failure of a streak).
    @discardableResult
    mutating func recordFailure() -> Bool {
        failures += 1
        return failures == 1
    }

    /// Returns true on the error → ok transition.
    @discardableResult
    mutating func recordSuccess() -> Bool {
        let wasFailing = failures > 0
        failures = 0
        return wasFailing
    }

    /// Text for a tooltip/error line while backed off, else nil.
    var note: String? {
        guard isBackedOff else { return nil }
        let s = Int(interval)
        return s >= 120 ? "retrying every \(s / 60) min" : "retrying every \(s) s"
    }
}

/// Adaptive one-shot poll timer. Re-arms itself on every fire (so a poll that
/// never reports back can't stall the schedule) and again whenever a completion
/// reports success/failure, using the backed-off interval. Main thread only.
final class PollScheduler {
    private(set) var backoff: PollBackoff
    private var timer: Timer?
    private var fire: (() -> Void)?

    init(base: TimeInterval, cap: TimeInterval = 1800, threshold: Int = 3) {
        backoff = PollBackoff(base: base, cap: cap, threshold: threshold)
    }

    var isRunning: Bool { fire != nil }
    var note: String? { backoff.note }

    func start(fire: @escaping () -> Void) {
        guard self.fire == nil else { return }
        self.fire = fire
        arm()
        fire()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        fire = nil
        _ = backoff.recordSuccess()
    }

    /// Returns true when this ends a failure streak.
    @discardableResult
    func succeeded() -> Bool {
        let t = backoff.recordSuccess()
        arm()
        return t
    }

    /// Returns true when this starts a failure streak.
    @discardableResult
    func failed() -> Bool {
        let t = backoff.recordFailure()
        arm()
        return t
    }

    private func arm() {
        guard fire != nil else { return }
        timer?.invalidate()
        let interval = backoff.interval
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self, let fire = self.fire else { return }
            self.arm()
            fire()
        }
        t.tolerance = interval * 0.1      // let the system coalesce wakeups
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

enum EventRange {
    /// First index whose timestamp is >= `t` in a collection sorted ascending by
    /// timestamp (`count` when none). O(log n) replacement for a full filter.
    static func firstIndex<C: RandomAccessCollection>(
        in c: C, timestamp: (C.Element) -> Date, atOrAfter t: Date
    ) -> Int where C.Index == Int {
        var low = c.startIndex, high = c.endIndex
        while low < high {
            let mid = (low + high) / 2
            if timestamp(c[mid]) < t { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

enum LogRotator {
    static let defaultMaxBytes = 1_000_000

    static func rotatedURL(_ url: URL) -> URL { URL(fileURLWithPath: url.path + ".1") }

    /// Truncate-and-rename: current → `<name>.1` (replacing any older copy). If the
    /// file is far past the cap (e.g. an old unrotated log), `.1` keeps only the
    /// last `maxBytes` so the on-disk total stays bounded. Caller must have closed
    /// its handle; returns true if a rotation happened.
    @discardableResult
    static func rotateIfNeeded(url: URL, maxBytes: Int = defaultMaxBytes) -> Bool {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > maxBytes else { return false }
        let old = rotatedURL(url)
        try? fm.removeItem(at: old)
        if size > maxBytes * 2, let r = try? FileHandle(forReadingFrom: url) {
            defer { try? r.close() }
            try? r.seek(toOffset: UInt64(size - maxBytes))
            var tail = (try? r.readToEnd()) ?? Data()
            if let nl = tail.firstIndex(of: 0x0A) { tail = tail.suffix(from: tail.index(after: nl)) }  // whole lines only
            try? tail.write(to: old)
            try? fm.removeItem(at: url)
        } else {
            do { try fm.moveItem(at: url, to: old) } catch { try? fm.removeItem(at: url) }
        }
        return true
    }
}
