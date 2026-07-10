import Foundation
import SwiftUI
import Combine

/// Optional counterpart to LimitsManager for ChatGPT web quotas. The endpoint
/// is private/undocumented, so this class is intentionally isolated: a change
/// in ChatGPT's web surface can only affect this card, never local telemetry.
final class ChatGPTLimitsManager: ObservableObject {
    @Published private(set) var windows: [LimitWindow] = []
    @Published private(set) var connected = false
    @Published private(set) var lastUpdated: Date?
    @Published var errorMessage: String?

    private var cookie = ""
    private var timer: Timer?

    private static let cookieKey = "chatgpt_session_cookie"
    private let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    // The usage endpoint authenticates on a short-lived Bearer access token, NOT
    // the cookie. The cookie authenticates /api/auth/session, which mints that
    // token — so the user still pastes only the Cookie and we exchange it here.
    private let sessionEndpoint = URL(string: "https://chatgpt.com/api/auth/session")!

    init() {
        cookie = UserDefaults.standard.string(forKey: Self.cookieKey) ?? ""
        connected = !cookie.isEmpty
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func setCookie(_ raw: String) {
        cookie = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(cookie, forKey: Self.cookieKey)
        connected = !cookie.isEmpty
        windows = []
        errorMessage = nil
        refresh()
    }

    func clearCookie() {
        cookie = ""
        UserDefaults.standard.removeObject(forKey: Self.cookieKey)
        connected = false
        windows = []
        errorMessage = nil
    }

    func refresh() {
        guard !cookie.isEmpty else { return }
        // Two-step, mirroring the web app: the cookie mints a Bearer access token
        // via /api/auth/session, then that token authorizes the usage call.
        // (The usage endpoint rejects cookie-only auth with 401.)
        fetchAccessToken { [weak self] token in
            guard let self, let token else { return }
            self.fetchUsage(bearer: token)
        }
    }

    private func fetchAccessToken(_ completion: @escaping (String?) -> Void) {
        var request = URLRequest(url: sessionEndpoint)
        request.timeoutInterval = 15
        applyBrowserHeaders(to: &request)
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.errorMessage = "Network error: \(error.localizedDescription)"
                    completion(nil); return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200, let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.errorMessage = "Cookie rejected (expired?) — re-copy it"
                    completion(nil); return
                }
                guard let token = obj["accessToken"] as? String, !token.isEmpty else {
                    // 200 with no token = signed out for this cookie's session.
                    self.errorMessage = "Signed out on chatgpt.com — open ChatGPT in the browser, then re-copy the Cookie"
                    completion(nil); return
                }
                completion(token)
            }
        }.resume()
    }

    private func fetchUsage(bearer: String) {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        applyBrowserHeaders(to: &request)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            DispatchQueue.main.async {
                if let error {
                    self.errorMessage = "Network error: \(error.localizedDescription)"
                    return
                }
                guard let response = response as? HTTPURLResponse else {
                    self.errorMessage = "No response"
                    return
                }
                guard response.statusCode == 200, let data else {
                    self.errorMessage = response.statusCode == 401 || response.statusCode == 403
                        ? "ChatGPT rejected the request (session expired?) — re-copy the Cookie"
                        : "ChatGPT usage unavailable (HTTP \(response.statusCode))"
                    return
                }
                self.parse(data)
            }
        }.resume()
    }

    /// Headers common to both calls. The User-Agent must match the browser the
    /// cookie was copied from — Cloudflare binds the `cf_clearance` cookie to the
    /// UA that solved its challenge, so a mismatch triggers a fresh challenge.
    private func applyBrowserHeaders(to request: inout URLRequest) {
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    }

    // Current macOS Safari (the browser the cookie is expected to come from).
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.5 Safari/605.1.15"

    /// The private response has changed across ChatGPT releases. Parse the
    /// stable concepts rather than pinning the app to one exact nesting shape:
    /// percent plus an optional duration and reset time.
    private func parse(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            errorMessage = "Couldn't parse ChatGPT usage response"
            return
        }
        var found: [LimitWindow] = []
        collectWindows(root, path: [], into: &found)
        var seen = Set<String>()
        windows = found.filter { seen.insert($0.id).inserted }
        lastUpdated = Date()
        errorMessage = windows.isEmpty
            ? "No recognized limits returned — ChatGPT's web response may have changed"
            : nil
        FileLog.log("chatgpt limits: \(windows.map { "\($0.id)=\(Int($0.utilization))%" }.joined(separator: " "))")
    }

    private func collectWindows(_ value: Any, path: [String], into output: inout [LimitWindow]) {
        if let dict = value as? [String: Any] {
            let percent = number(dict["used_percent"]) ?? number(dict["utilization"])
            if let percent, percent >= 0, percent <= 100 {
                let seconds = number(dict["window_seconds"]) ?? number(dict["window_duration_seconds"])
                    ?? number(dict["limit_window_seconds"])
                let minutes = number(dict["window_minutes"]) ?? seconds.map { $0 / 60 }
                let reset = date(dict["resets_at"]) ?? date(dict["reset_at"])
                    ?? date(dict["reset_time"])
                let rawName = (dict["name"] as? String) ?? (dict["label"] as? String)
                    ?? path.last ?? "limit"
                let normalized = rawName.replacingOccurrences(of: "_", with: " ")
                let key = path.joined(separator: ".")
                let duration = minutes.map { Self.duration(Int($0)) }
                output.append(LimitWindow(
                    id: "chatgpt-\(key.isEmpty ? normalized : key)",
                    label: "ChatGPT · \(normalized)\(duration.map { " · \($0)" } ?? "")",
                    utilization: percent,
                    resetsAt: reset))
            }
            for (key, child) in dict { collectWindows(child, path: path + [key], into: &output) }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                collectWindows(child, path: path + ["\(index)"], into: &output)
            }
        }
    }

    private func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private func date(_ value: Any?) -> Date? {
        if let seconds = number(value), seconds > 1_000_000_000 {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = value as? String else { return nil }
        return Self.iso.date(from: text) ?? Self.isoPlain.date(from: text)
    }

    private static func duration(_ minutes: Int) -> String {
        if minutes > 0, minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))d" }
        if minutes > 0, minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
}
