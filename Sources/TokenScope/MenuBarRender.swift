import SwiftUI
import AppKit

/// The macOS menu bar unreliably renders a multi-element SwiftUI label (it drops
/// Images/Labels, keeping only some text) and forces text monochrome. So we
/// composite the whole thing — colored gauges + labels + token count — into ONE
/// bitmap via ImageRenderer and hand the menu bar a single `Image(nsImage:)`.
/// The bitmap preserves the gauge colors; text is rendered for the current
/// menu-bar appearance (light/dark) by the caller.
enum MenuBarRender {
    @MainActor
    static func image(sessionPct: Int?, weeklyPct: Int?, tokens: String?, dark: Bool) -> NSImage {
        let content = HStack(spacing: 7) {
            if let s = sessionPct { gaugeItem(fraction: Double(s) / 100, label: "5h", pct: s) }
            if let w = weeklyPct { gaugeItem(fraction: Double(w) / 100, label: "7d", pct: w) }
            if let t = tokens {
                Text(t).font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
        }
        .foregroundStyle(.primary)
        .environment(\.colorScheme, dark ? .dark : .light)
        .padding(.horizontal, 1)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2   // retina menu bar
        let img = renderer.nsImage ?? NSImage(size: NSSize(width: 1, height: 1))
        img.isTemplate = false   // keep baked colors; don't let the bar monochrome it
        return img
    }

    @ViewBuilder
    private static func gaugeItem(fraction: Double, label: String, pct: Int) -> some View {
        HStack(spacing: 3) {
            Image(nsImage: MenuBarGauge.image(fraction: fraction))
            Text("\(label) \(pct)%").font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
    }
}

/// Publishes when the system switches between light and dark so the menu-bar
/// bitmap can be re-rendered with legible text.
final class AppearanceWatcher: ObservableObject {
    @Published private(set) var dark = AppearanceWatcher.isDark()

    init() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(changed),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
    }

    @objc private func changed() {
        DispatchQueue.main.async { self.dark = Self.isDark() }
    }

    static func isDark() -> Bool {
        // NSApp is nil in headless --snapshot/--menubar paths; default to dark.
        guard let appearance = NSApp?.effectiveAppearance else { return true }
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
