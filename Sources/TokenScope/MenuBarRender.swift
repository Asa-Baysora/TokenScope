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
    static func image(sessionPct: Int?, weeklyPct: Int?, chatGPTPrimaryPct: Int?, chatGPTSecondaryPct: Int?, tokens: String?, dark: Bool) -> NSImage {
        let gauges: [(label: String, pct: Int)] = [
            sessionPct.map { ("C 5h", $0) },
            weeklyPct.map { ("C 7d", $0) },
            chatGPTPrimaryPct.map { ("GPT 5h", $0) },
            chatGPTSecondaryPct.map { ("GPT 7d", $0) },
        ].compactMap { $0 }
        // A lone gauge needs no prefix; multiple windows must be labeled so the
        // provider and rolling period remain unambiguous in the menu bar.
        let labelLimits = gauges.count > 1
        var segments: [AnyView] = []
        for gauge in gauges {
            segments.append(AnyView(gaugeItem(
                fraction: Double(gauge.pct) / 100,
                label: labelLimits ? gauge.label : nil,
                pct: gauge.pct)))
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
