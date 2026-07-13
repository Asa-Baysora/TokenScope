import Foundation

/// Polls lightweight, documented Ollama endpoints. `/api/version` is the
/// upstream health check; `/api/ps` supplies resident model/runtime metadata.
final class OllamaStatusPoller {
    private let store: UsageStore
    private let queue = DispatchQueue(label: "tokenscope.ollama-status", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastModelFingerprint: String?

    init(store: UsageStore) { self.store = store }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 10.0)
        timer.setEventHandler { [weak self] in self?.fetch() }
        timer.resume()
        self.timer = timer
    }

    private func fetch() {
        fetchVersion()
        fetchModels()
    }

    private func request(_ path: String, completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(store.upstreamPort)\(path)") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { data, response, error in
            completion(data, response as? HTTPURLResponse, error)
        }.resume()
    }

    private func fetchVersion() {
        request("/api/version") { [weak self] data, response, error in
            guard let self else { return }
            let ok = response?.statusCode == 200
            var version: String?
            if let data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                version = object["version"] as? String
            }
            self.store.updateRuntimeHealth(.ollama) {
                $0.version = version ?? $0.version
                $0.serverRunning = ok
                $0.lastSuccess = ok ? Date() : $0.lastSuccess
                $0.state = ok ? ($0.collectorRunning ? .connected : .degraded) : .unavailable
                $0.lastError = ok ? nil : (error == nil ? "Ollama returned HTTP \(response?.statusCode ?? 0)" : "Ollama daemon unavailable")
            }
        }
    }

    private func fetchModels() {
        request("/api/ps") { [weak self] data, response, _ in
            guard let self else { return }
            // A failed poll (daemon stopped, port unreachable) must BLANK the list —
            // early-returning kept the last value, leaving a phantom "loaded model"
            // row beside an "unavailable" health state. Falling through with an
            // empty list also fires the fingerprint log on the transition.
            // (Matches LMStudioStatusPoller.)
            var models: [LoadedModel] = []
            if response?.statusCode == 200,
               let data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let array = object["models"] as? [[String: Any]] {
                let iso = ISO8601DateFormatter()
                for item in array {
                    let details = item["details"] as? [String: Any]
                    let name = (item["name"] as? String) ?? (item["model"] as? String) ?? "?"
                    let expires = (item["expires_at"] as? String).flatMap(iso.date(from:))
                    models.append(LoadedModel(
                        provider: .ollama,
                        name: name,
                        instanceId: item["digest"] as? String,
                        kind: .llm,
                        sizeBytes: (item["size"] as? NSNumber)?.int64Value ?? 0,
                        vramBytes: (item["size_vram"] as? NSNumber)?.int64Value ?? 0,
                        contextLength: (item["context_length"] as? NSNumber)?.intValue,
                        expiresAt: expires,
                        family: details?["family"] as? String,
                        parameterSize: details?["parameter_size"] as? String,
                        quantization: details?["quantization_level"] as? String,
                        format: details?["format"] as? String))
                }
            }
            self.store.setLoadedModels(models, for: .ollama)
            let fingerprint = models
                .map { "\($0.instanceId ?? $0.name):\($0.expiresAt?.timeIntervalSince1970 ?? 0)" }
                .sorted().joined(separator: "|")
            if self.lastModelFingerprint != fingerprint {
                self.lastModelFingerprint = fingerprint
                FileLog.log("ollama loaded: \(models.map(\.name).joined(separator: ", ").ifEmpty("none"))")
            }
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
