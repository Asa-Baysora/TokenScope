import Foundation

/// Low-frequency CLI polling complements the persistent model-log stream with
/// server state and loaded-model metadata. Thirty seconds avoids turning a
/// 24/7 menu app into a process-launch loop.
final class LMStudioStatusPoller {
    private let store: UsageStore
    private let queue = DispatchQueue(label: "tokenscope.lmstudio-status", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var cachedVersion: String?

    init(store: UsageStore) { self.store = store }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 30)
        // The workspace check runs on main (AppKit), the CLI work on our queue —
        // async hops only. When the app is closed we skip both `lms` spawns
        // (2 per 30s, permanently, for nothing) and publish the state directly.
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                let appRunning = LMStudioCLI.appIsRunning
                self?.queue.async { self?.poll(appRunning: appRunning) }
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func poll(appRunning: Bool) {
        guard LMStudioCLI.path != nil else {
            store.updateRuntimeHealth(.lmStudio) {
                $0.state = .unavailable
                $0.serverRunning = false
                $0.collectorRunning = false
                $0.lastError = "LM Studio CLI not installed"
            }
            store.setLoadedModels([], for: .lmStudio)
            return
        }
        guard appRunning else {
            store.updateRuntimeHealth(.lmStudio) {
                $0.state = .installed
                $0.serverRunning = false
                $0.collectorRunning = false
                $0.lastError = nil
            }
            store.setLoadedModels([], for: .lmStudio)
            return
        }
        if cachedVersion == nil,
           let output = LMStudioCLI.run(["--version"]), output.exitCode == 0 {
            let raw = String(data: output.data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            cachedVersion = raw
        }
        let status = LMStudioCLI.run(["server", "status", "--json", "--quiet"])
        var serverRunning = false
        let statusOK = status?.exitCode == 0
        if statusOK, let data = status?.data,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            serverRunning = object["running"] as? Bool ?? false
        }
        store.updateRuntimeHealth(.lmStudio) {
            $0.version = self.cachedVersion ?? $0.version
            $0.serverRunning = serverRunning
            if statusOK { $0.lastSuccess = Date() }
            if !statusOK {
                $0.state = .degraded
                $0.lastError = "LM Studio status check failed"
            } else if $0.collectorRunning {
                $0.state = .connected
                $0.lastError = nil
            }
            else { $0.state = serverRunning ? .degraded : .installed }
        }
        pollModels()
    }

    private func pollModels() {
        guard let output = LMStudioCLI.run(["ps", "--json"]), output.exitCode == 0,
              let json = try? JSONSerialization.jsonObject(with: output.data) else {
            store.setLoadedModels([], for: .lmStudio)
            return
        }
        let array: [[String: Any]]
        if let direct = json as? [[String: Any]] {
            array = direct
        } else if let object = json as? [String: Any], let values = object["models"] as? [[String: Any]] {
            array = values
        } else {
            store.setLoadedModels([], for: .lmStudio)
            return
        }
        let models = array.map { item -> LoadedModel in
            func string(_ keys: String...) -> String? {
                for key in keys { if let value = item[key] as? String { return value } }
                return nil
            }
            func int(_ keys: String...) -> Int? {
                for key in keys { if let value = (item[key] as? NSNumber)?.intValue { return value } }
                return nil
            }
            let status = string("status", "state")?.lowercased()
            let type = string("type")?.lowercased()
            return LoadedModel(
                provider: .lmStudio,
                name: string("identifier", "modelIdentifier", "modelKey", "path") ?? "LM Studio model",
                instanceId: string("instanceIdentifier", "instance_id", "id"),
                kind: type == "embedding" ? .embedding : (type == "llm" ? .llm : .unknown),
                sizeBytes: Int64(int("sizeBytes", "size_bytes") ?? 0),
                contextLength: int("contextLength", "context_length"),
                family: string("architecture", "arch"),
                quantization: string("quantization", "quant"),
                format: string("format"),
                parallelCapacity: int("parallel", "maxConcurrentPredictions"),
                queuedRequests: int("queuedPredictionRequests", "queued_requests"),
                isGenerating: status.map { $0.contains("generat") || $0.contains("process") })
        }
        store.setLoadedModels(models, for: .lmStudio)
    }
}
