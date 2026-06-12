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

    static func log(_ message: String) {
        queue.async {
            let line = "\(stamp.string(from: Date())) \(message)\n"
            if handle == nil {
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: url)
                _ = try? handle?.seekToEnd()
            }
            try? handle?.write(contentsOf: Data(line.utf8))
        }
    }
}
