import Foundation
import UserNotifications

/// Thin wrapper over UNUserNotificationCenter (the supported local-notification
/// path; NSUserNotification is removed on current macOS). Authorization is
/// requested once at launch; if denied, post() is a silent no-op.
enum Notifier {
    // UNUserNotificationCenter.current() raises an NSException if the process has
    // no bundle identifier (e.g. the bare --snapshot binary). Gate on that.
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, err in
            if let err { FileLog.log("notification auth error: \(err.localizedDescription)") }
            else { FileLog.log("notification auth granted=\(granted)") }
        }
    }

    static func post(title: String, body: String, id: String = UUID().uuidString) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err { FileLog.log("notification post error: \(err.localizedDescription)") }
        }
    }
}

/// Tracks the highest crossed threshold so each band fires once per climb and
/// re-arms when usage falls back (e.g. after a window reset). Persisted so a
/// relaunch mid-window doesn't re-alert.
struct ThresholdTracker {
    let key: String
    let thresholds: [Int]

    private var last: Int {
        get { UserDefaults.standard.integer(forKey: key) }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Returns the threshold to alert on this update, if any.
    func evaluate(percent: Int) -> Int? {
        var fired: Int?
        for t in thresholds where percent >= t && last < t {
            fired = t
        }
        if let fired { last = fired; return fired }
        if percent < last {
            last = thresholds.filter { $0 <= percent }.last ?? 0
        }
        return nil
    }
}
