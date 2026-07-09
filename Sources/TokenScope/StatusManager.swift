import Foundation
import SwiftUI
import Combine

/// Polls a provider's public Statuspage summary (no auth). Claude and OpenAI
/// use the same Statuspage response shape, so one implementation keeps their
/// refresh, incident, footer, and notification behavior in lockstep.
final class StatusManager: ObservableObject {
    enum Service {
        case claude
        case openAI

        var displayName: String {
            switch self {
            case .claude: return "Claude"
            case .openAI: return "OpenAI"
            }
        }

        var statusURL: URL {
            switch self {
            case .claude: return URL(string: "https://status.claude.com")!
            case .openAI: return URL(string: "https://status.openai.com")!
            }
        }

        var endpoint: URL { statusURL.appendingPathComponent("api/v2/summary.json") }
        var notificationKey: String {
            switch self {
            case .claude: return "status_notifications_enabled"
            case .openAI: return "openai_status_notifications_enabled"
            }
        }
        var notificationIDPrefix: String {
            switch self {
            case .claude: return "claude-status"
            case .openAI: return "openai-status"
            }
        }

        /// Surfaces the user doesn't consume — government / FedRAMP-only
        /// components and incidents. An issue confined to these is filtered out
        /// so the app still reads as operational (and won't notify). Matched as
        /// lowercased substrings of the component/incident name.
        var excludedNameSubstrings: [String] {
            switch self {
            case .claude: return ["government"]      // "Claude for Government", etc.
            case .openAI: return ["fedramp", "fed ramp"]
            }
        }
    }

    @Published private(set) var indicator = "none"     // none | minor | major | critical
    @Published private(set) var summary = "All systems operational"
    @Published private(set) var degraded: [Component] = []
    @Published private(set) var incidents: [Incident] = []
    @Published private(set) var lastUpdated: Date?
    @Published var notificationsEnabled = true

    struct Component: Identifiable { let id: String; let name: String; let status: String }
    struct Incident: Identifiable { let id: String; let name: String; let status: String; let update: String }

    let service: Service
    private var timer: Timer?

    init(service: Service = .claude) {
        self.service = service
        if UserDefaults.standard.object(forKey: service.notificationKey) != nil {
            notificationsEnabled = UserDefaults.standard.bool(forKey: service.notificationKey)
        }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func setNotifications(_ on: Bool) {
        notificationsEnabled = on
        UserDefaults.standard.set(on, forKey: service.notificationKey)
    }

    var color: Color {
        switch indicator {
        case "none": return .green
        case "minor": return .yellow
        case "major": return .orange
        case "critical": return .red
        default: return .gray
        }
    }

    var allOperational: Bool { indicator == "none" && degraded.isEmpty && incidents.isEmpty }

    func refresh() {
        let req = URLRequest(url: service.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data else { return }
            self.parse(data)
        }.resume()
    }

    private func parse(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? [String: Any],
              let ind = status["indicator"] as? String,
              let desc = status["description"] as? String else { return }

        var degradedComps: [Component] = []
        if let comps = json["components"] as? [[String: Any]] {
            for c in comps {
                guard let id = c["id"] as? String,
                      let name = c["name"] as? String,
                      let st = c["status"] as? String, st != "operational" else { continue }
                // Skip group rows (they have no own status meaning here).
                if (c["group"] as? Bool) == true { continue }
                if isExcluded(name) { continue }
                degradedComps.append(Component(id: id, name: name, status: st))
            }
        }

        var incs: [Incident] = []
        if let raw = json["incidents"] as? [[String: Any]] {
            for inc in raw {
                guard let id = inc["id"] as? String,
                      let name = inc["name"] as? String,
                      let st = inc["status"] as? String,
                      st != "resolved", st != "postmortem" else { continue }
                if isExcluded(name) { continue }
                let updates = inc["incident_updates"] as? [[String: Any]] ?? []
                let body = (updates.first?["body"] as? String) ?? ""
                incs.append(Incident(id: id, name: name, status: st, update: body))
            }
        }

        // The Statuspage top-level indicator/description can be elevated solely
        // by an excluded (government/FedRAMP) surface. Derive the DISPLAYED
        // status from what survives filtering: nothing left ⇒ operational, so a
        // gov/FedRAMP-only degradation reads green and doesn't notify.
        let anyIssues = !degradedComps.isEmpty || !incs.isEmpty
        let effectiveInd = anyIssues ? ind : "none"
        let effectiveDesc = anyIssues ? desc : "All systems operational"

        DispatchQueue.main.async {
            let previous = self.indicator
            let firstFetch = self.lastUpdated == nil
            self.indicator = effectiveInd
            self.summary = effectiveDesc
            self.degraded = degradedComps
            self.incidents = incs
            self.lastUpdated = Date()
            FileLog.log("\(self.service.displayName) status: \(effectiveInd) — \(effectiveDesc) (raw \(ind)); degraded=\(degradedComps.count) incidents=\(incs.count)")
            if !firstFetch, previous != effectiveInd, self.notificationsEnabled {
                if effectiveInd == "none" {
                    Notifier.post(title: "\(self.service.displayName) is back online",
                                  body: "All systems operational.",
                                  id: "\(self.service.notificationIDPrefix)-none")
                } else {
                    Notifier.post(title: "\(self.service.displayName) status: \(effectiveDesc)",
                                  body: "See \(self.service.statusURL.host ?? "the status page") for details.",
                                  id: "\(self.service.notificationIDPrefix)-\(effectiveInd)")
                }
            }
        }
    }

    /// True when a component/incident name matches one of this service's
    /// excluded (government/FedRAMP) surfaces.
    private func isExcluded(_ name: String) -> Bool {
        let n = name.lowercased()
        return service.excludedNameSubstrings.contains { n.contains($0) }
    }
}
