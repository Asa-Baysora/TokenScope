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

enum FileLog {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TokenScope.log")
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
