import Foundation
import AppKit

enum LMStudioCLI {
    static let candidates = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lmstudio/bin/lms").path,
        "/usr/local/bin/lms",
        "/opt/homebrew/bin/lms",
    ]

    static var path: String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Cheap, subprocess-free "is the LM Studio app running" check (verified
    /// bundle id: ai.elementlabs.lmstudio). Used ONLY as an optimization to
    /// skip pointless `lms` spawns while the app is closed — callers must keep
    /// their normal retry path so a renamed bundle id can never dead-end them.
    static var appIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "ai.elementlabs.lmstudio"
        }
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
