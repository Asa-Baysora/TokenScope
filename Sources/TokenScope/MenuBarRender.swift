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
        // The 5h/7d labels only earn their space when both gauges are shown and
        // would otherwise be ambiguous; a lone gauge needs no label.
        let labelLimits = sessionPct != nil && weeklyPct != nil
        var segments: [AnyView] = []
        if let s = sessionPct {
            segments.append(AnyView(gaugeItem(fraction: Double(s) / 100, label: labelLimits ? "5h" : nil, pct: s)))
        }
        if let w = weeklyPct {
            segments.append(AnyView(gaugeItem(fraction: Double(w) / 100, label: labelLimits ? "7d" : nil, pct: w)))
        }
        if let t = tokens {
            segments.append(AnyView(Text(t).font(.system(size: 12, weight: .medium)).monospacedDigit()))
        }

        let content = HStack(spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                if idx > 0 {
                    Text("|").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                seg
            }
        }
        .foregroundStyle(.primary)
        .environment(\.colorScheme, dark ? .dark : .light)
        .padding(.horizontal, 1)
        .fixedSize()   // intrinsic width — without this ImageRenderer truncates ("28%"→"2…")

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2   // retina menu bar
        let img = renderer.nsImage ?? NSImage(size: NSSize(width: 1, height: 1))
        img.isTemplate = false   // keep baked colors; don't let the bar monochrome it
        return img
    }

    @ViewBuilder
    private static func gaugeItem(fraction: Double, label: String?, pct: Int) -> some View {
        HStack(spacing: 3) {
            Image(nsImage: MenuBarGauge.image(fraction: fraction))
            Text(label.map { "\($0) \(pct)%" } ?? "\(pct)%")
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
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
