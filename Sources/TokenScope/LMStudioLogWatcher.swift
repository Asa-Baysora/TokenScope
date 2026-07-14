import Foundation

/// Meters LM Studio by tapping its shared inference layer via
/// `lms log stream --source model --stats --json`. That one stream captures
/// completed LLM-generation telemetry from LM Studio's shared model log,
/// independent of whether the HTTP API server is running.
///
/// Privacy: output events may also carry the generated text. This watcher reads
/// only stats and model/lifecycle metadata; content fields and stderr are never
/// stored, logged, or forwarded.
final class LMStudioLogWatcher {
    private let store: UsageStore
    private let queue = DispatchQueue(label: "tokenscope.lmstudio", qos: .utility)
    private var process: Process?
    private var buffer = Data()
    private var stopped = false

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

    /// Synchronous stop for app-exit paths (applicationWillTerminate, SIGTERM):
    /// the child must be signaled BEFORE exit(0), or it outlives us as an orphan.
    func stopAndWait() {
        queue.sync {
            stopped = true
            process?.terminate()
            process = nil
        }
    }

    private var cliPath: String? {
        LMStudioCLI.path
    }

    private func launch() {
        guard !stopped else { return }
        guard let cli = cliPath else {
            store.updateRuntimeHealth(.lmStudio) {
                $0.state = .unavailable
                $0.collectorRunning = false
                $0.lastError = "LM Studio CLI not installed"
            }
            FileLog.log("LM Studio CLI not found; LM Studio tracking disabled")
            return   // no lms installed → provider simply off (no respawn churn)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        // Request output events only. This avoids ingesting formatted prompts at
        // the process boundary while retaining the completion stats we need.
        p.arguments = ["log", "stream", "--source", "model", "--filter", "output", "--stats", "--json"]
        let out = Pipe()
        p.standardOutput = out
        let errors = Pipe()
        p.standardError = errors
        buffer.removeAll(keepingCapacity: true)
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consume(data) }
        }
        // Drain and discard diagnostics so a noisy child cannot fill its stderr
        // pipe and block. Raw CLI output is deliberately never logged.
        errors.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }
        // `lms log stream` exits if LM Studio isn't running or on a transient error.
        // Relaunch on a delay so we reconnect once LM Studio comes up, without a
        // tight respawn loop (and without spinning when the CLI is too old).
        p.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.queue.async {
                out.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.store.updateRuntimeHealth(.lmStudio) {
                    $0.collectorRunning = false
                    $0.state = .degraded
                    $0.lastError = "model log stream exited (\(process.terminationStatus))"
                }
                guard !self.stopped else { return }
                self.scheduleRelaunch()
            }
        }
        do {
            try p.run()
            process = p
            store.updateRuntimeHealth(.lmStudio) {
                $0.state = .connected
                $0.collectorRunning = true
                $0.lastSuccess = Date()
                $0.lastError = nil
            }
            FileLog.log("LM Studio watcher started (model output stats)")
        } catch {
            store.updateRuntimeHealth(.lmStudio) {
                $0.state = .degraded
                $0.collectorRunning = false
                $0.lastError = "model log stream failed to start"
            }
            FileLog.log("LM Studio watcher failed to start: \(error.localizedDescription)")
            guard !stopped else { return }
            scheduleRelaunch()
        }
    }

    /// Retry every 30s, but only SPAWN when the LM Studio app is actually
    /// running — `lms log stream` exits instantly otherwise, and blind respawns
    /// meant a subprocess launch every 30s around the clock while LM Studio was
    /// closed. The workspace check is an optimization only: the 30s cadence
    /// itself never stops, so a wrong bundle id degrades to the old behavior at
    /// worst. All hops are async (stopAndWait queue.syncs from main — a
    /// main.sync here would deadlock).
    private func scheduleRelaunch() {
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, !self.stopped else { return }
            DispatchQueue.main.async {
                let appRunning = LMStudioCLI.appIsRunning
                self.queue.async { [weak self] in
                    guard let self, !self.stopped else { return }
                    if appRunning { self.launch() } else { self.scheduleRelaunch() }
                }
            }
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
        guard let parsed = LMStudioEventParser.parse(line) else { return }
        store.addLocalEvent(parsed.event, dedupKey: parsed.key)
        store.updateRuntimeHealth(.lmStudio) {
            $0.state = .connected
            $0.collectorRunning = true
            $0.lastEvent = parsed.event.timestamp
            $0.lastSuccess = Date()
            $0.lastError = nil
        }
    }

}
