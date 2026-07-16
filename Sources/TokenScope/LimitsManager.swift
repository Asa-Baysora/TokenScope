import Foundation
import SwiftUI
import AppKit
import Combine

/// One rate-limit window reported by claude.ai's usage endpoint.
struct LimitWindow: Identifiable {
    let id: String        // "five_hour" | "seven_day" | "seven_day_sonnet"
    let label: String     // "Session · 5h" etc.
    var utilization: Double   // 0…100
    var resetsAt: Date?
    var period: String?   // short rolling-window label ("5h"/"7d") for the menu bar

    var fraction: Double { min(max(utilization / 100, 0), 1) }
}

/// Polls claude.ai for plan usage limits (the 5-hour session and 7-day weekly
/// caps that gate Claude Code / Claude.ai). This is the "how close to the wall"
/// view that complements TokenScope's raw token counting. Uses the user's
/// claude.ai session cookie against an internal endpoint, so it degrades
/// gracefully: no cookie → a connect prompt; bad cookie → an error string.
final class LimitsManager: ObservableObject {
    @Published private(set) var windows: [LimitWindow] = []
    @Published private(set) var connected = false
    @Published private(set) var lastUpdated: Date?
    @Published var errorMessage: String?
    @Published var notificationsEnabled = true

    private var cookie = ""
    private var timer: Timer?
    private var sessionThreshold = ThresholdTracker(key: "limit_notified_session", thresholds: [25, 50, 75, 90])
    private var weeklyThreshold = ThresholdTracker(key: "limit_notified_weekly", thresholds: [50, 75, 90])
    private var weeklySonnetThreshold = ThresholdTracker(key: "limit_notified_weekly_sonnet", thresholds: [50, 75, 90])

    private static let cookieKey = "claude_session_cookie"
    private static let notifKey = "limit_notifications_enabled"

    init() {
        cookie = UserDefaults.standard.string(forKey: Self.cookieKey) ?? ""
        connected = !cookie.isEmpty
        if UserDefaults.standard.object(forKey: Self.notifKey) != nil {
            notificationsEnabled = UserDefaults.standard.bool(forKey: Self.notifKey)
        }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    private func percent(_ id: String) -> Int? {
        windows.first(where: { $0.id == id }).map { Int($0.utilization.rounded()) }
    }
    var sessionPercent: Int? { percent("five_hour") }
    var weeklyPercent: Int? { percent("seven_day") }

    // Shared redesign thresholds: <60 green, 60...85 amber, >85 red.
    // Concrete sRGB values match the popup rail and menu-bar gauges.
    private static let cGreen = (r: 48.0 / 255, g: 184.0 / 255, b: 92.0 / 255)
    private static let cAmber = (r: 232.0 / 255, g: 152.0 / 255, b: 27.0 / 255)
    private static let cRed = (r: 229.0 / 255, g: 72.0 / 255, b: 77.0 / 255)

    static func rgb(forPercent p: Double) -> (r: Double, g: Double, b: Double) {
        switch LimitSeverity(utilization: p) {
        case .healthy: return cGreen
        case .warning: return cAmber
        case .danger: return cRed
        }
    }

    static func color(forPercent p: Double) -> Color {
        let c = rgb(forPercent: p)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
    }

    static func nsColor(forPercent p: Double) -> NSColor {
        let c = rgb(forPercent: p)
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    // MARK: - Cookie

    func setCookie(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        cookie = trimmed
        UserDefaults.standard.set(trimmed, forKey: Self.cookieKey)
        connected = !trimmed.isEmpty
        errorMessage = nil
        if connected { refresh() } else { windows = [] }
    }

    func clearCookie() {
        cookie = ""
        UserDefaults.standard.removeObject(forKey: Self.cookieKey)
        connected = false
        windows = []
        errorMessage = nil
    }

    func setNotifications(_ on: Bool) {
        notificationsEnabled = on
        UserDefaults.standard.set(on, forKey: Self.notifKey)
    }

    // MARK: - Fetch

    func refresh() {
        guard !cookie.isEmpty else { return }
        resolveOrgId { [weak self] orgId in
            guard let self else { return }
            guard let orgId else {
                DispatchQueue.main.async { self.errorMessage = "Couldn't find org ID in cookie" }
                return
            }
            self.fetchUsage(orgId: orgId)
        }
    }

    private func authedRequest(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(cookie, forHTTPHeaderField: "Cookie")
        r.setValue("*/*", forHTTPHeaderField: "Accept")
        r.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        r.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 15
        return r
    }

    private func resolveOrgId(_ completion: @escaping (String?) -> Void) {
        // Preferred: the lastActiveOrg cookie crumb.
        for part in cookie.components(separatedBy: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            if kv.hasPrefix("lastActiveOrg=") {
                completion(String(kv.dropFirst("lastActiveOrg=".count)))
                return
            }
        }
        // Fallback: bootstrap endpoint.
        guard let url = URL(string: "https://claude.ai/api/bootstrap") else { completion(nil); return }
        URLSession.shared.dataTask(with: authedRequest(url)) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil); return
            }
            let account = json["account"] as? [String: Any]
            let memberships = (account?["memberships"] as? [[String: Any]]) ?? (json["memberships"] as? [[String: Any]])
            let org = memberships?.first?["organization"] as? [String: Any]
            completion(org?["uuid"] as? String)
        }.resume()
    }

    private func fetchUsage(orgId: String) {
        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/usage") else { return }
        URLSession.shared.dataTask(with: authedRequest(url)) { [weak self] data, response, error in
            guard let self else { return }
            DispatchQueue.main.async {
                if let error {
                    self.errorMessage = "Network error: \(error.localizedDescription)"
                    return
                }
                guard let http = response as? HTTPURLResponse else { self.errorMessage = "No response"; return }
                guard http.statusCode == 200, let data else {
                    self.errorMessage = http.statusCode == 401 || http.statusCode == 403
                        ? "Cookie rejected (expired?) — re-copy it"
                        : "HTTP \(http.statusCode)"
                    return
                }
                self.parse(data)
            }
        }.resume()
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func parse(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            errorMessage = "Couldn't parse usage response"
            return
        }
        func window(_ key: String, _ label: String, _ period: String) -> LimitWindow? {
            guard let obj = json[key] as? [String: Any] else { return nil }
            let util = (obj["utilization"] as? Double) ?? Double((obj["utilization"] as? Int) ?? 0)
            let reset = (obj["resets_at"] as? String).flatMap { Self.iso.date(from: $0) ?? Self.isoPlain.date(from: $0) }
            return LimitWindow(id: key, label: label, utilization: util, resetsAt: reset, period: period)
        }
        var ws: [LimitWindow] = []
        if let s = window("five_hour", "Session · 5h", "5h") { ws.append(s) }
        if let w = window("seven_day", "Weekly · 7d", "7d") { ws.append(w) }
        if let sn = window("seven_day_sonnet", "Weekly Sonnet · 7d", "7d") { ws.append(sn) }

        windows = ws
        lastUpdated = Date()
        errorMessage = nil
        FileLog.log("limits: " + ws.map { "\($0.id)=\(Int($0.utilization))%" }.joined(separator: " "))
        maybeNotify(ws)
    }

    private func maybeNotify(_ ws: [LimitWindow]) {
        guard notificationsEnabled else { return }
        if let s = ws.first(where: { $0.id == "five_hour" }),
           let t = sessionThreshold.evaluate(percent: Int(s.utilization)) {
            Notifier.post(title: "Claude session limit \(t)%",
                          body: "You've used \(Int(s.utilization))% of your 5-hour session limit.",
                          id: "limit-session-\(t)")
        }
        if let w = ws.first(where: { $0.id == "seven_day" }),
           let t = weeklyThreshold.evaluate(percent: Int(w.utilization)) {
            Notifier.post(title: "Claude weekly limit \(t)%",
                          body: "You've used \(Int(w.utilization))% of your weekly limit.",
                          id: "limit-weekly-\(t)")
        }
        if let sn = ws.first(where: { $0.id == "seven_day_sonnet" }),
           let t = weeklySonnetThreshold.evaluate(percent: Int(sn.utilization)) {
            Notifier.post(title: "Claude weekly Sonnet limit \(t)%",
                          body: "You've used \(Int(sn.utilization))% of your weekly Sonnet limit.",
                          id: "limit-weekly-sonnet-\(t)")
        }
    }
}
