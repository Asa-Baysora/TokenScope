import Foundation

enum LMStudioCLI {
    static let candidates = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lmstudio/bin/lms").path,
        "/usr/local/bin/lms",
        "/opt/homebrew/bin/lms",
    ]

    static var path: String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct Output {
        let data: Data
        let exitCode: Int32
    }

    static func run(_ arguments: [String], timeout: TimeInterval = 5) -> Output? {
        guard let path else { return nil }
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            return nil
        }
        return Output(data: stdout.fileHandleForReading.readDataToEndOfFile(),
                      exitCode: process.terminationStatus)
    }
}
