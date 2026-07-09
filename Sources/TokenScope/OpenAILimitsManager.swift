import Foundation
import SwiftUI
import Combine

/// Codex writes the current quota state alongside local token counts. This is
/// deliberately an observed value, not a web scrape: it refreshes whenever a
/// local Codex session emits a token_count record.
final class OpenAILimitsManager: ObservableObject {
    static let monitoringKey = "CodexMonitoringEnabled"
    static let monitoringChanged = Notification.Name("TokenScopeCodexMonitoringChanged")

    @Published private(set) var windows: [LimitWindow] = []
    @Published private(set) var lastUpdated: Date?
    @Published var monitoringEnabled: Bool

    init() {
        if UserDefaults.standard.object(forKey: Self.monitoringKey) == nil {
            monitoringEnabled = true
        } else {
            monitoringEnabled = UserDefaults.standard.bool(forKey: Self.monitoringKey)
        }
    }

    func setMonitoring(_ on: Bool) {
        monitoringEnabled = on
        UserDefaults.standard.set(on, forKey: Self.monitoringKey)
        NotificationCenter.default.post(name: Self.monitoringChanged, object: nil)
    }

    /// Keeps the newest observed telemetry while the watcher replays old files
    /// at launch. Codex's window durations are supplied by the client rather
    /// than assumed to be five hours / seven days.
    func observe(primary: ObservedWindow?, secondary: ObservedWindow?, at date: Date) {
        guard monitoringEnabled else { return }
        DispatchQueue.main.async {
            guard self.lastUpdated == nil || date >= self.lastUpdated! else { return }
            let candidates = [("primary", primary), ("secondary", secondary)]
            self.windows = candidates.compactMap { kind, window in
                guard let window else { return nil }
                return LimitWindow(
                    id: "codex-\(kind)",
                    label: "Codex · \(Self.duration(window.minutes))",
                    utilization: window.percent,
                    resetsAt: window.resetsAt)
            }
            self.lastUpdated = date
        }
    }

    private static func duration(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "limit" }
        if minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

struct ObservedWindow {
    let percent: Double
    let minutes: Int?
    let resetsAt: Date?
}
