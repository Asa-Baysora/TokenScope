import Foundation
import SwiftUI
import Combine

/// Polls Anthropic's public status page (no auth) so the menu can answer
/// "is it me, or is Claude down?". Surfaces the overall indicator, any
/// non-operational components, and active incidents, and notifies on change.
final class StatusManager: ObservableObject {
    @Published private(set) var indicator = "none"     // none | minor | major | critical
    @Published private(set) var summary = "All systems operational"
    @Published private(set) var degraded: [Component] = []
    @Published private(set) var incidents: [Incident] = []
    @Published private(set) var lastUpdated: Date?
    @Published var notificationsEnabled = true

    struct Component: Identifiable { let id: String; let name: String; let status: String }
    struct Incident: Identifiable { let id: String; let name: String; let status: String; let update: String }

    private let endpoint = URL(string: "https://status.claude.com/api/v2/summary.json")!
    private var timer: Timer?
    private static let notifKey = "status_notifications_enabled"

    init() {
        if UserDefaults.standard.object(forKey: Self.notifKey) != nil {
            notificationsEnabled = UserDefaults.standard.bool(forKey: Self.notifKey)
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
        UserDefaults.standard.set(on, forKey: Self.notifKey)
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
        let req = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
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
                let updates = inc["incident_updates"] as? [[String: Any]] ?? []
                let body = (updates.first?["body"] as? String) ?? ""
                incs.append(Incident(id: id, name: name, status: st, update: body))
            }
        }

        DispatchQueue.main.async {
            let previous = self.indicator
            let firstFetch = self.lastUpdated == nil
            self.indicator = ind
            self.summary = desc
            self.degraded = degradedComps
            self.incidents = incs
            self.lastUpdated = Date()
            FileLog.log("status: \(ind) — \(desc); degraded=\(degradedComps.count) incidents=\(incs.count)")
            if !firstFetch, previous != ind, self.notificationsEnabled {
                if ind == "none" {
                    Notifier.post(title: "Claude is back online", body: "All systems operational.", id: "status-none")
                } else {
                    Notifier.post(title: "Claude status: \(desc)", body: "See status.claude.com for details.", id: "status-\(ind)")
                }
            }
        }
    }
}
