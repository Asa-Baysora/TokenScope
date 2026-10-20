import Foundation

// Framework-free checks for PollSupport.swift: backoff schedule, publish-on-change
// comparator, today-range binary search vs naive filter, log rotation.
// Build: swiftc Sources/TokenScope/PollSupport.swift tools/verify-lightness.swift -o /tmp/tokenscope-lightness-checks

@main
struct LightnessChecks {
    nonisolated(unsafe) static var failures = 0
    static func check(_ ok: Bool, _ name: String) {
        if ok { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
    }
    static func main() {
        // MARK: backoff schedule (base 60, N=3, cap 1800)
        do {
            var b = PollBackoff(base: 60, cap: 1800, threshold: 3)
            var seen: [Int] = [Int(b.interval)]
            for _ in 0..<9 { b.recordFailure(); seen.append(Int(b.interval)) }
            check(seen == [60, 60, 60, 120, 240, 480, 960, 1800, 1800, 1800], "backoff schedule \(seen)")
            check(b.isBackedOff && b.note == "retrying every 30 min", "backoff note at cap: \(b.note ?? "nil")")
            check(b.recordSuccess() == true && b.interval == 60 && !b.isBackedOff && b.note == nil, "success resets and reports error->ok")
            check(b.recordSuccess() == false, "second success is not a transition")
            check(b.recordFailure() == true && b.recordFailure() == false, "first failure reports ok->error once")
            var s = PollBackoff(base: 300, cap: 1800, threshold: 3)
            for _ in 0..<3 { s.recordFailure() }
            check(Int(s.interval) == 600 && s.note == "retrying every 10 min", "status base 300 doubles to 600")
            let huge = PollBackoff.interval(base: 60, cap: 1800, threshold: 3, failures: 100_000)
            check(huge == 1800, "no overflow at huge failure counts")
        }

        // MARK: publish-on-change comparator
        do {
            let t = Date(timeIntervalSince1970: 1_800_000_000)
            let a = LimitWindow(id: "five_hour", label: "Session · 5h", utilization: 42.0, resetsAt: t, period: "5h")
            var b = a
            check(a.displayEquals(b), "identical windows equal")
            b.utilization = 42.04
            check(a.displayEquals(b), "sub-0.1pt jitter equal")
            b.utilization = 42.2
            check(!a.displayEquals(b), "0.2pt change differs")
            b = a; b.resetsAt = t.addingTimeInterval(0.4)
            check(a.displayEquals(b), "sub-second reset jitter equal")
            b.resetsAt = t.addingTimeInterval(30)
            check(!a.displayEquals(b), "30 s reset shift differs")
            b.resetsAt = nil
            check(!a.displayEquals(b), "reset nil vs set differs")
            let c = LimitWindow(id: "seven_day", label: "Weekly · 7d", utilization: 10, resetsAt: nil, period: "7d")
            check(LimitWindow.displayEqual([a, c], [a, c]), "array equal")
            check(!LimitWindow.displayEqual([a, c], [a]), "array length differs")
            check(!LimitWindow.displayEqual([a, c], [c, a]), "array order differs")
            check(LimitWindow.displayEqual([], []), "empty arrays equal")
        }

        // MARK: today-range binary search vs naive filter
        do {
            var rng = SystemRandomNumberGenerator()
            var mismatches = 0
            for trial in 0..<300 {
                let n = Int.random(in: 0...400, using: &rng)
                // Duplicate-heavy timestamps stress the >= boundary.
                var ts = (0..<n).map { _ in Date(timeIntervalSince1970: Double(Int.random(in: 0...200, using: &rng)) * 10) }
                ts.sort()
                let t = Date(timeIntervalSince1970: Double(Int.random(in: -20...2100, using: &rng)))
                let fast = EventRange.firstIndex(in: ts, timestamp: { $0 }, atOrAfter: t)
                let naive = ts.firstIndex { $0 >= t } ?? ts.count
                if fast != naive { mismatches += 1; print("  trial \(trial): fast \(fast) naive \(naive)") }
                let slice = Array(ts[fast...]).count, naiveCount = ts.filter { $0 >= t }.count
                if slice != naiveCount { mismatches += 1 }
            }
            check(mismatches == 0, "binary search matches naive filter (300 random sorted arrays)")
            check(EventRange.firstIndex(in: [Date](), timestamp: { $0 }, atOrAfter: Date()) == 0, "empty input")
        }

        // MARK: log rotation
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("tokenscope-lightness-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            let log = dir.appendingPathComponent("TokenScope.log")
            let line = String(repeating: "x", count: 99) + "\n"

            try? Data(String(repeating: line, count: 5).utf8).write(to: log)
            check(!LogRotator.rotateIfNeeded(url: log, maxBytes: 1000), "under cap: no rotation")

            try? Data(String(repeating: line, count: 15).utf8).write(to: log)   // 1500 B > 1000, < 2000
            check(LogRotator.rotateIfNeeded(url: log, maxBytes: 1000), "over cap: rotates")
            let rotated = LogRotator.rotatedURL(log)
            check(!fm.fileExists(atPath: log.path) && fm.fileExists(atPath: rotated.path), "current moved to .1")
            check((try? Data(contentsOf: rotated).count) == 1500, "mild overshoot keeps the whole file in .1")

            // second rotation replaces .1 (one rotated copy only)
            try? Data(String(repeating: "y" + String(repeating: "z", count: 98) + "\n", count: 12).utf8).write(to: log)
            LogRotator.rotateIfNeeded(url: log, maxBytes: 1000)
            let r2 = String(data: (try? Data(contentsOf: rotated)) ?? Data(), encoding: .utf8) ?? ""
            check(r2.hasPrefix("yz") && !r2.contains("x"), "second rotation replaces the old .1")
            check(!fm.fileExists(atPath: log.path + ".2"), "never more than one rotated copy")

            // huge file: .1 holds only the tail, whole lines
            var big = ""
            for i in 0..<100 { big += String(format: "%04d", i) + String(repeating: "a", count: 95) + "\n" }   // 10_000 B
            try? Data(big.utf8).write(to: log)
            LogRotator.rotateIfNeeded(url: log, maxBytes: 1000)
            let tail = (try? String(contentsOf: rotated, encoding: .utf8)) ?? ""
            let lines = tail.split(separator: "\n", omittingEmptySubsequences: true)
            check(tail.utf8.count <= 1000 && lines.count >= 8 && lines.last?.hasPrefix("0099") == true
                  && lines.allSatisfy { $0.count == 99 }, "oversize log: .1 is a <=1000 B tail of whole lines (\(tail.utf8.count) B)")
            check(!LogRotator.rotateIfNeeded(url: dir.appendingPathComponent("missing.log"), maxBytes: 10), "missing file: no-op")
        }

        print(failures == 0 ? "All lightness checks passed." : "\(failures) lightness check(s) FAILED.")
        exit(failures == 0 ? 0 : 1)

    }
}
