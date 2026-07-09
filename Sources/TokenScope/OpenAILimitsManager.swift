import Foundation
import SwiftUI
import Combine

/// Codex writes the current quota state alongside local token counts. This is
/// deliberately an observed value, not a web scrape: it refreshes whenever a
/// local Codex session emits a token_count record.
final class OpenAILimitsManager: ObservableObject {
    static let monitoringKey = "CodexMonitoringEnabled"
    static let monitoringChanged = Notification.Name("TokenScopeCodexMonitoringChanged")
    static let refreshRequested = Notification.Name("TokenScopeCodexLimitsRefreshRequested")

    @Published private(set) var windows: [LimitWindow] = []
    @Published private(set) var lastUpdated: Date?
    @Published var monitoringEnabled: Bool
    @Published var notificationsEnabled = true

    private var primaryThreshold = ThresholdTracker(
        key: "chatgpt_limit_notified_primary", thresholds: [25, 50, 75, 90])
    private var secondaryThreshold = ThresholdTracker(
        key: "chatgpt_limit_notified_secondary", thresholds: [50, 75, 90])
    private static let notificationKey = "chatgpt_limit_notifications_enabled"

    init() {
        if UserDefaults.standard.object(forKey: Self.monitoringKey) == nil {
            monitoringEnabled = true
        } else {
            monitoringEnabled = UserDefaults.standard.bool(forKey: Self.monitoringKey)
        }
        if UserDefaults.standard.object(forKey: Self.notificationKey) != nil {
            notificationsEnabled = UserDefaults.standard.bool(forKey: Self.notificationKey)
        }
    }

    func setMonitoring(_ on: Bool) {
        monitoringEnabled = on
        UserDefaults.standard.set(on, forKey: Self.monitoringKey)
        NotificationCenter.default.post(name: Self.monitoringChanged, object: nil)
    }

    /// Codex quota telemetry is local rather than HTTP-backed. Refresh asks the
    /// watcher to rescan its current session files immediately, mirroring the
    /// user-visible refresh affordance on Claude's limits card.
    func refresh() {
        guard monitoringEnabled else { return }
        NotificationCenter.default.post(name: Self.refreshRequested, object: nil)
    }

    func setNotifications(_ on: Bool) {
        notificationsEnabled = on
        UserDefaults.standard.set(on, forKey: Self.notificationKey)
    }

    private func percent(_ id: String) -> Int? {
        windows.first(where: { $0.id == id }).map { Int($0.utilization.rounded()) }
    }
    var primaryPercent: Int? { percent("codex-primary") }
    var secondaryPercent: Int? { percent("codex-secondary") }

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
                    label: "ChatGPT · \(Self.duration(window.minutes))",
                    utilization: window.percent,
                    resetsAt: window.resetsAt)
            }
            self.lastUpdated = date
            self.maybeNotify()
        }
    }

    private func maybeNotify() {
        guard notificationsEnabled else { return }
        if let primary = windows.first(where: { $0.id == "codex-primary" }),
           let threshold = primaryThreshold.evaluate(percent: Int(primary.utilization)) {
            Notifier.post(title: primary.label + " limit " + String(threshold) + "%",
                          body: "You've used " + String(Int(primary.utilization)) + "% of this ChatGPT limit.",
                          id: "chatgpt-limit-primary-" + String(threshold))
        }
        if let secondary = windows.first(where: { $0.id == "codex-secondary" }),
           let threshold = secondaryThreshold.evaluate(percent: Int(secondary.utilization)) {
            Notifier.post(title: secondary.label + " limit " + String(threshold) + "%",
                          body: "You've used " + String(Int(secondary.utilization)) + "% of this ChatGPT limit.",
                          id: "chatgpt-limit-secondary-" + String(threshold))
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
