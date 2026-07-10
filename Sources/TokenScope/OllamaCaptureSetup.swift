import Foundation

enum OllamaCaptureSetup {
    private static let previousHostKey = "CaptureAllPreviousOllamaHost"
    private static let previousHostSavedKey = "CaptureAllPreviousOllamaHostSaved"

    /// Stages capture-all for the next restart. It deliberately does not quit
    /// either app: the user remains in control of process shutdown and ordering.
    static func stageCaptureAll() throws {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: previousHostSavedKey) {
            defaults.set(try launchctl(["getenv", "OLLAMA_HOST"]), forKey: previousHostKey)
            defaults.set(true, forKey: previousHostSavedKey)
        }
        _ = try launchctl(["setenv", "OLLAMA_HOST", "127.0.0.1:11435"])
        defaults.set(11434, forKey: "ProxyPort")
        defaults.set(11435, forKey: "OllamaPort")
    }

    static func stageRollback() throws {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: previousHostSavedKey),
           let previous = defaults.string(forKey: previousHostKey), !previous.isEmpty {
            _ = try launchctl(["setenv", "OLLAMA_HOST", previous])
        } else {
            _ = try launchctl(["unsetenv", "OLLAMA_HOST"])
        }
        defaults.removeObject(forKey: "ProxyPort")
        defaults.removeObject(forKey: "OllamaPort")
        defaults.removeObject(forKey: previousHostKey)
        defaults.removeObject(forKey: previousHostSavedKey)
    }

    private static func launchctl(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "TokenScope.OllamaCaptureSetup", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "launchctl failed" : detail])
        }
        return out
    }
}
