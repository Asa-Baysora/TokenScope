import Foundation

/// Meters LM Studio by tapping its shared inference layer via
/// `lms log stream --source model --stats --json`. That one stream captures
/// EVERY LM Studio inference — the desktop app's own chats, the `lms` CLI, and any
/// external client pointed at the local server (:1234) — each with exact token
/// counts, independent of whether the HTTP server is running. (Verified 2026-07-13.)
///
/// Privacy: the stream also carries the full prompt/response text. This watcher
/// reads ONLY the `stats` counts and the model id; it never touches, stores, or
/// forwards the message content — matching how Codex telemetry is handled.
final class LMStudioLogWatcher {
    private let store: UsageStore
    private let queue = DispatchQueue(label: "tokenscope.lmstudio", qos: .utility)
    private var process: Process?
    private var buffer = Data()
    private var stopped = false

    /// The CLI is installed here by LM Studio's bootstrap; check a couple of
    /// common spots so we don't depend on PATH.
    private static let cliCandidates = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lmstudio/bin/lms").path,
        "/usr/local/bin/lms",
        "/opt/homebrew/bin/lms",
    ]

    init(store: UsageStore) { self.store = store }

    func start() {
        queue.async { [weak self] in self?.launch() }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopped = true
            self?.process?.terminate()
            self?.process = nil
        }
    }

    private var cliPath: String? {
        Self.cliCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func launch() {
        guard !stopped else { return }
        guard let cli = cliPath else {
            FileLog.log("LM Studio CLI not found; LM Studio tracking disabled")
            return   // no lms installed → provider simply off (no respawn churn)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["log", "stream", "--source", "model", "--stats", "--json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()   // swallow CLI chatter/errors
        buffer.removeAll(keepingCapacity: true)
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consume(data) }
        }
        // `lms log stream` exits if LM Studio isn't running or on a transient error.
        // Relaunch on a delay so we reconnect once LM Studio comes up, without a
        // tight respawn loop (and without spinning when the CLI is too old).
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                out.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                guard !self.stopped else { return }
                self.queue.asyncAfter(deadline: .now() + 30) { [weak self] in self?.launch() }
            }
        }
        do {
            try p.run()
            process = p
            FileLog.log("LM Studio watcher started (lms log stream --source model)")
        } catch {
            FileLog.log("LM Studio watcher failed to start: \(error.localizedDescription)")
        }
    }

    /// Newline-framed NDJSON. Buffer partial lines across reads.
    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            handleLine(line)
        }
        // Guard against an unbounded buffer if a single line never terminates.
        if buffer.count > 4 << 20 { buffer.removeAll(keepingCapacity: true) }
    }

    private func handleLine(_ line: Data) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let d = obj["data"] as? [String: Any],
              d["type"] as? String == "llm.prediction.output",
              let stats = d["stats"] as? [String: Any] else { return }

        // Read ONLY counts + model id — never the input/output text.
        let prompt = intValue(stats["promptTokensCount"]) ?? 0
        let predicted = intValue(stats["predictedTokensCount"]) ?? 0
        guard prompt > 0 || predicted > 0 else { return }
        let model = (d["modelIdentifier"] as? String) ?? (d["modelPath"] as? String) ?? "LM Studio"
        let ts = doubleValue(obj["timestamp"]).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()

        let event = UsageEvent(
            timestamp: ts,
            provider: .lmStudio,
            source: .lmStudioLog,
            model: model,
            sessionId: "lmstudio:\(model)",   // no session id in the stream; group per model
            projectName: nil,
            inputTokens: prompt,
            outputTokens: predicted,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            reasoningTokens: 0)
        let key = "lmstudio:\(ts.timeIntervalSince1970):\(prompt):\(predicted):\(model)"
        store.addTranscriptEvent(event, dedupKey: key)
    }

    private func intValue(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }
    private func doubleValue(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
}
