import Foundation

/// Polls Ollama's /api/ps so the menu can show which model(s) are resident in
/// memory right now, independent of any in-flight call.
final class OllamaStatusPoller {
    private let store: UsageStore
    private let queue = DispatchQueue(label: "tokenscope.ollama-status", qos: .utility)
    private var timer: DispatchSourceTimer?

    init(store: UsageStore) { self.store = store }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 10.0)
        t.setEventHandler { [weak self] in self?.fetch() }
        t.resume()
        timer = t
    }

    private func fetch() {
        guard let url = URL(string: "http://127.0.0.1:\(store.upstreamPort)/api/ps") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            var models: [LoadedModel] = []
            if let data,
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let arr = obj["models"] as? [[String: Any]] {
                for m in arr {
                    let name = (m["name"] as? String) ?? (m["model"] as? String) ?? "?"
                    let vram = (m["size_vram"] as? NSNumber)?.int64Value ?? 0
                    models.append(LoadedModel(name: name, vramBytes: vram))
                }
            }
            DispatchQueue.main.async {
                if self.store.loadedModels != models {
                    self.store.loadedModels = models
                    FileLog.log("ollama loaded: \(models.map(\.name).joined(separator: ", ").ifEmpty("none"))")
                }
            }
        }.resume()
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
