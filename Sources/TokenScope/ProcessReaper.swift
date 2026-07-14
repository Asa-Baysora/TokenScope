import Foundation

/// Cleans up `lms log stream` children orphaned by a previous TokenScope
/// instance that died without cleanup (SIGKILL, crash, pre-fix builds). An
/// orphan is unambiguous: launchd has adopted it (ppid == 1) AND its argv is
/// exactly the stream this app spawns. A live instance's own child has that
/// instance's pid as ppid, and a user's hand-run `lms log stream` keeps their
/// shell as parent — neither matches.
enum ProcessReaper {
    /// The stable argv core every TokenScope-spawned stream has carried across
    /// versions (older builds lacked `--filter output`, and requiring it left
    /// their orphans alive). Still unambiguous: a hand-run `lms log stream`
    /// has no `--source model --stats --json`.
    static let lmsLogStreamArgv = [
        "lms", "log", "stream", "--source", "model", "--stats", "--json",
    ]

    /// Pure parser over `ps -axo pid=,ppid=,command=` output — separable so the
    /// framework-free suite can pin the orphan-selection rule with fixtures.
    static func candidates(psOutput: String, argvContains tokens: [String]) -> [Int32] {
        psOutput.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1]),
                  ppid == 1 else { return nil }
            let command = fields[2...].joined(separator: " ")
            guard tokens.allSatisfy({ command.contains($0) }) else { return nil }
            return pid
        }
    }

    /// Terminate stale orphans once at startup. TERM first; KILL only if a
    /// process ignores TERM for a second. Every reaped pid is logged.
    static func reapStaleLMStudioLogStreams() {
        guard let output = ps() else { return }
        let stale = candidates(psOutput: output, argvContains: lmsLogStreamArgv)
        guard !stale.isEmpty else { return }
        for pid in stale { kill(pid, SIGTERM) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            for pid in stale where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        FileLog.log("reaped \(stale.count) orphaned lms log stream process(es): \(stale.map(String.init).joined(separator: ", "))")
    }

    private static func ps() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
