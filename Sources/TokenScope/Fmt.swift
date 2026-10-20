import Foundation

enum Fmt {
    static func compact(_ n: Int) -> String {
        switch n {
        case ..<1000:
            return "\(n)"
        case ..<1_000_000:
            let v = Double(n) / 1000
            return v < 100 ? String(format: "%.1fk", v) : String(format: "%.0fk", v)
        default:
            return String(format: "%.2fM", Double(n) / 1_000_000)
        }
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// Where TokenScope keeps its own files. `TOKENSCOPE_SUPPORT_DIR` (absolute or
/// `~`-prefixed path) redirects EVERYTHING the app persists (journal, daily
/// history) and moves the log next to it, so an end-to-end run can use a copy of
/// real data without touching `~/Library`. Unset = the normal locations.
enum AppPaths {
    static let envKey = "TOKENSCOPE_SUPPORT_DIR"

    static func override(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let raw = environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    static let supportDir: URL = override()
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TokenScope")

    static let logURL: URL = override().map { $0.appendingPathComponent("TokenScope.log") }
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TokenScope.log")
}

enum FileLog {
    private static let url = AppPaths.logURL
    private static let queue = DispatchQueue(label: "tokenscope.log", qos: .utility)
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    // Held open across writes (all serialized on `queue`) so logging isn't an
    // open/seek/write/close syscall storm.
    private static var handle: FileHandle?
    // Bytes in the current file; capped at ~1 MB with one rotated `.1` copy
    // (LogRotator) so the log can't grow without bound.
    private static var size = 0

    private static func open() {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        LogRotator.rotateIfNeeded(url: url)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }

    static func log(_ message: String) {
        queue.async {
            let line = "\(stamp.string(from: Date())) \(message)\n"
            if handle == nil { open() }
            let data = Data(line.utf8)
            try? handle?.write(contentsOf: data)
            size += data.count
            if size > LogRotator.defaultMaxBytes {
                try? handle?.close()
                handle = nil
                open()   // rotates (size > cap), then reopens a fresh file
                let note = Data("\(stamp.string(from: Date())) log rotated (previous: TokenScope.log.1)\n".utf8)
                try? handle?.write(contentsOf: note)
                size += note.count
            }
        }
    }
}
