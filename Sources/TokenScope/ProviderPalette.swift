import SwiftUI
import AppKit

/// The single source of truth for each provider's accent color, user-customizable
/// in Settings and persisted as `#RRGGBB` hex in UserDefaults. It drives the brand
/// marks, the Usage bar chart, the History heatmap (including its per-day blend),
/// the legend, and the menu-bar gauges.
///
/// It is an `ObservableObject` (not `@AppStorage`) on purpose: the values must be
/// readable synchronously from non-View contexts — `BrandMark.color`, and the
/// bare `--snapshot`/`--menubar` binaries where `NSApp` is nil — which `@AppStorage`
/// (a View-only DynamicProperty) can't do. Views observe it to re-render on edits.
final class ProviderPalette: ObservableObject {
    static let shared = ProviderPalette()
    private let defaults = UserDefaults.standard

    /// Concrete sRGB defaults (resolve identically in the headless binary, unlike
    /// system `.orange`/`.purple`/`.blue`). Chosen to keep the heatmap visually
    /// unchanged by default while unifying the marks/bars onto one palette.
    private static let fallback: [UsageOrigin: (Double, Double, Double)] = [
        .claudeCode: (0.96, 0.58, 0.20),
        .codex:      (0.69, 0.32, 0.87),
        .ollama:     (0.35, 0.62, 0.98),
    ]

    private func key(_ o: UsageOrigin) -> String {
        switch o {
        case .claudeCode: return "ProviderColorClaude"
        case .codex:      return "ProviderColorCodex"
        case .ollama:     return "ProviderColorOllama"
        }
    }

    func color(_ o: UsageOrigin) -> Color {
        if let hex = defaults.string(forKey: key(o)), let c = Self.color(fromHex: hex) { return c }
        let d = Self.fallback[o]!
        return Color(.sRGB, red: d.0, green: d.1, blue: d.2, opacity: 1)
    }

    func setColor(_ c: Color, for o: UsageOrigin) {
        defaults.set(Self.hex(fromColor: c), forKey: key(o))
        okCache.removeValue(forKey: o)
        objectWillChange.send()
    }

    func resetAll() {
        UsageOrigin.allCases.forEach { defaults.removeObject(forKey: key($0)) }
        okCache.removeAll()
        objectWillChange.send()
    }

    var isDefault: Bool {
        UsageOrigin.allCases.allSatisfy { defaults.string(forKey: key($0)) == nil }
    }

    // MARK: hex <-> sRGB Color (clamped)

    static func color(fromHex s: String) -> Color? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6, let v = UInt64(t, radix: 16) else { return nil }
        return Color(.sRGB,
                     red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255, opacity: 1)
    }

    static func hex(fromColor c: Color) -> String {
        // ColorPicker can emit Display-P3 / out-of-[0,1]; normalize to sRGB and clamp.
        let n = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c).usingColorSpace(.deviceRGB) ?? .gray
        func b(_ x: CGFloat) -> Int { Int((min(max(Double(x), 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", b(n.redComponent), b(n.greenComponent), b(n.blueComponent))
    }

    // MARK: OKLab blend (cached per origin; cleared on edit)

    private var okCache: [UsageOrigin: OKLab.Lab] = [:]
    private func oklab(_ o: UsageOrigin) -> OKLab.Lab {
        if let hit = okCache[o] { return hit }
        let n = NSColor(color(o)).usingColorSpace(.sRGB) ?? .gray
        let lab = OKLab.from(Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent))
        okCache[o] = lab
        return lab
    }

    /// Proportion-weighted perceptual (OKLab) blend of the three provider colors,
    /// with capped, guarded chroma restoration so near-complementary pairs (the
    /// common Claude+Ollama day) don't collapse to grey mud. Weights need not sum
    /// to 1; returns nil when all are zero.
    func blend(claude wc: Double, codex wx: Double, ollama wo: Double) -> Color? {
        let sum = wc + wx + wo
        guard sum > 0 else { return nil }
        let c = oklab(.claudeCode), x = oklab(.codex), o = oklab(.ollama)
        let L = (wc * c.L + wx * x.L + wo * o.L) / sum
        var a = (wc * c.a + wx * x.a + wo * o.a) / sum
        var b = (wc * c.b + wx * x.b + wo * o.b) / sum
        let cMix = (a * a + b * b).squareRoot()
        let cTarget = (wc * hypot(c.a, c.b) + wx * hypot(x.a, x.b) + wo * hypot(o.a, o.b)) / sum
        if cMix > 1e-4 {
            let k = min(cTarget / cMix, 1.6)   // lift mud, cap phantom saturation
            a *= k; b *= k
        }
        return OKLab.color(OKLab.Lab(L: L, a: a, b: b))
    }
}

/// Minimal OKLab (Björn Ottosson) forward/inverse transform — pure Swift, no deps,
/// no NSApp. Used for perceptually even color blending in the heatmap.
enum OKLab {
    struct Lab { var L, a, b: Double }

    static func from(_ r: Double, _ g: Double, _ b: Double) -> Lab {
        func lin(_ u: Double) -> Double { u <= 0.04045 ? u / 12.92 : pow((u + 0.055) / 1.055, 2.4) }
        let R = lin(r), G = lin(g), B = lin(b)
        let l = cbrt(0.4122214708 * R + 0.5363325363 * G + 0.0514459929 * B)
        let m = cbrt(0.2119034982 * R + 0.6806995451 * G + 0.1073969566 * B)
        let s = cbrt(0.0883024619 * R + 0.2817188376 * G + 0.6299787005 * B)
        return Lab(L: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                   a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                   b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func color(_ x: Lab) -> Color {
        let l_ = x.L + 0.3963377774 * x.a + 0.2158037573 * x.b
        let m_ = x.L - 0.1055613458 * x.a - 0.0638541728 * x.b
        let s_ = x.L - 0.0894841775 * x.a - 1.2914855480 * x.b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        func g(_ u: Double) -> Double {
            let v = min(max(u, 0), 1)
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return Color(.sRGB,
                     red:   g(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                     green: g(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                     blue:  g(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s), opacity: 1)
    }
}
