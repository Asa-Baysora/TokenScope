import SwiftUI
import AppKit

/// Provider brand marks, embedded as base64 alpha-mask PNGs (128px; the brand
/// shape lives in the alpha channel, RGB is black). Embedding rather than
/// bundling matters here: `--snapshot` and `--menubar` run as a bare binary
/// with no app bundle, where `Bundle.module` resource loading is unreliable —
/// a base64 constant loads identically in every entry point, keeping snapshot
/// verification honest.
///
/// The shapes are Simple Icons' monochrome brand marks, rasterized at build
/// time. Regenerate with scripts/regen-brand-marks.sh (do not hand-edit the
/// base64 below): Claude = the Claude spark, Codex = the OpenAI mark,
/// Ollama = the llama. They are template images — tint with
/// `.renderingMode(.template).foregroundStyle(color)`, which works both in-app
/// and inside the menu-bar ImageRenderer content.
enum BrandMark {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ origin: UsageOrigin) -> NSImage {
        let key = origin.rawValue as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let b64: String
        switch origin {
        case .claudeCode: b64 = claudeMark
        case .codex:      b64 = codexMark
        case .ollama:     b64 = ollamaMark
        case .lmStudio:   b64 = lmStudioMark
        }
        let img = Data(base64Encoded: b64).flatMap { NSImage(data: $0) } ?? NSImage()
        img.isTemplate = true
        cache.setObject(img, forKey: key)
        return img
    }

    /// Provider accent color — delegates to the user-customizable palette, the
    /// single source of truth shared by marks, bars, heatmap, and menu-bar gauges.
    static func color(_ origin: UsageOrigin) -> Color {
        ProviderPalette.shared.color(origin)
    }

    private static let claudeMark =
        "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"

    private static let codexMark =
        "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" +
        "YII="

    private static let ollamaMark =
        "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"

    private static let lmStudioMark =
        "iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAYAAADDPmHLAAAAAXNSR0IArs4c6QAAADhlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAAB" +
        "AAAAgKADAAQAAAABAAAAgAAAAABrRiZNAAAKJElEQVR4Ae2dXYhd1RXHR5toBUsQ6weI0QFNBJEYUDE+iAZsMRil4pNWBIWAgp99kBT1RUEUET8eBEWhYPMg" +
        "RS1KO62YiKKVKKjoS6JQowgqaokGNR2N/n/D3Jm545wza9979r7r3LMW/Od+rb33Wv//uufcs/e+dw6ayGer1PW5wnphjbBWOFr4zSxW6DZsnoEfdPebWXyu" +
        "213CbuEt4WVhr+DeVivCrcJOgYR+CjTCAVzCKdzCsTvbpIi2CweEED0vB3AM13A+crtYEXCICtFHwwHco0Fxm9SIzwshvA8O0AJNitgWjfKtEOL74gBN0Cab" +
        "Ha6etwkhvG8O0AitGrWj1NsbQojfDg7QCs0asRPUC9ejIX67OEAztBvKqKIQv13CL3yjol3tkeCgmvLgPLJDOKPGJ+Wl/XJ+X/hMYMZrWgibZ2Cl7jJLeoxw" +
        "snCo0IS9qU7OF/aldtbEB75XNejNwjqhrthSYxt3f7iCM7iDw4Xv6kHuo2WSbZH3IAPRhnf6YwJVHNYMA2vUDZzC7aC6oKnJJuU16HX+lNqeZBolnAZhAG7h" +
        "eJAiQFO0XdYGmeH7Xr1et2zP4dAUA3AN56mFgLa1xrxyaqdfqc2G2l7jxRwMwDncp+pVu3aQurBDAKflyC76NDEA96lFgMZLGsuLKdXEISje+UtSWfRJNEg9" +
        "HSy5lMwac0oBxDm/qM61g6FFinZo3Wer9eiAYO1kqq91PPDAAJpY9UNrNJ+zrbpnbbxfvnGpN0edmztogjZWHdF8znbqnrUhExJhPhlAG6uOaD5jq/Q3ZQNn" +
        "zPDNEufwhhlDawGgOdpPbE5oxLx0mG8GUtYONh+sXNi3b7W/WR3Db2QMpGi0foXC5LBhte1Wx0V+LG2eI/DJs6llzkVDuHjI9fh/hdeF6RFFlKLRjPasF1vO" +
        "GySXuqRLgd0u8K0Wyxjj4vOF8r1FSOVLTYY2xkQrC5dsHZvYY3R+F+cE453+omAJZFx9nlX+nGZLG1pZON1DcOxCsRg7eVLsATlvTGkwhr6XKKe7RpCXVasZ" +
        "7TlXWarlmYREmJT40divZew2+3A4PjaBuyZc0crC2TRHAM7TFkv5UHOpOhzFoc+SR2kfToVcapc0q1Yrcom0tmS2LRjLLR+5CqAFmkSIMJCrAHYFvX0MuOUj" +
        "VwE8rfQP9FHQ3Qes0D3nNf1cBfCBEn7Ua9KF47pf431aeEzzcLkKgABuElKmJc1Bt8jx74r1Ns/x5iwADn2/F+4QvvZMQobYvlSffxL+ILg+FVrnAAbliDXn" +
        "O4V7hVgMGpTFjO1yF0AvdI4GO3oP4tYPAzlPAX6yjEgqGYgCqKSmGy9EAXRD58osowAqqenGC1EA3dC5MssogEpquvFCqcvAJtn8tToD42pcMn9XKrm2FABf" +
        "RrlVuEjgR5TG3dhUOiXcI7yXO1nL1iF8nsodSEX/V+l53hXWOMfJj5nU6yt4qXsarUw8eP8MsEmJPCEcUpftGL/2K+X2kHB5rhw9FwB76R4RPMeYS5fF/T6o" +
        "J2Z28C5+YdjHnsn9nZJbPWyCY9L+t8qDlcXGzXMBnNV4tu3uMAsfngtg5qvL7das0eiz8OG5AD5plL72d5aFD88F8K/2a9ZoBln48FwAb4u+FxqlsL2d8S3e" +
        "l3KE77kAyPcawe2O2hyCLNHn//TcHwUmdho37wXwsTLeILzeeObt6PAdhcleyt25wm3DWsCHSp4iYIcxawEnCuO8GMS3iSn8fwq9H+7W3TzWhgLoZc6HoCwf" +
        "hHoDdPHW+ymgi5oUzTkKoCjd/gaLAvCnSdGIogCK0u1vsCgAf5oUjSgKoCjd/gaLAvCnSdGISswD8MuVTOBcKBwvjPskzofKkQmc1sxZmDYPKqFBNoWeonYs" +
        "6ljHGCe//yjvE4VRmItNofwQ8WvCulEw4GDMsxUDRcBRz63l+gzAYf9J4Qi3mZcJjF8IfbzMUIONkqsAzlM4Zw4W0ti1ukAZne41q1wFwMpd2DwDbvnIVQDH" +
        "zece98SAWz5yFcDekL2PAbd85CqAnX3pxwO3fOQqgGelOd9wDZuY+Egk/NsrEbkKgB+GvNFr0gXj4kcirxX2FxwzaahcBUAQ24QbBP5zSBft/0r6auEfnpPP" +
        "WQDk/bDANTCTQl05JfD/epj8OVX4i+DaSiwG8QsXV86ycJhuD3XNyHDBsaMXtMZKFMBCMr7TAxDmhIHcpwAnaUYYVQxEAVQx05HnowA6InRVmlEAVcx05Pko" +
        "gI4IXZVmFEAVMx15vvRl4DC0rlRjtllNCuO8sZRp448EttNln0JuQwGwvexm4c/CkUJXjPWU+4S7BX4xNJtZd+IOsit42KA5RbGyaI1xHP1eVP6ps6cudgUP" +
        "Kz7t7xIuaaKjFvexUbE/kCt+zx8C2VF7S67EW9bvFsV7Uo6YPRfAZiWceujLwZGHPtHp0hyBeC6AtTkSbnGfWfjwXAAt1qo9oXsugF3tobFIpFn4oACs15hM" +
        "xJS05zRY9omQkgkNMRZ7C59OaG/VapoC+MbYcZZ/WFAz9qd67f6a17v00qNK9oOEhK1a7aPPPYJlAuXdhACacqVAYyIo/WoIrSyaov0EP0RscWavG9OypY0x" +
        "mQ9gU6klznHx4dtEtwup0/XwhVYWHt7A+UnhCsFi7PB9x+KYwScWg2yk8nsMb9tcJ/5Kde02OuO2URhVAUxr7FdmoZuwCgbQyGq7Oce+ZfWW32UJvuE6GgZS" +
        "NJrRfpXi5FLQcs7A5+TR5BWjGhhYIx+rjmiO9jPGt1etDR+bbRM3/hhAG6uOfd9Y3prQkMmZLCtT/vhsVURogjbWAkDzOeMfNDLbZG08Ndcy7nhhAE2s+qE1" +
        "mvfZdj2ydoDfdX2t48EoGUCLFO3Q+he2Sc+kdMJkw4Zf9BJPlGYADawTPz190XpJ47Kg52S5/Ur+py3ZUzxZggG4RwOLVj2fmUu/quAuTuyMTgkgjgRVjOZ7" +
        "Hs5TxUcvNK615/Vqr1qstxyC4jNBLa2NvgjXqYd9tETbZW1SHt8KVvEX+k2pXVwiLkvxwA5wC8cLObfeR1O0NRm7UK0dL/bbr7ZMSMSMoYlqkxNcwincLubb" +
        "+hhNk2ybvK2dV/m9qj74Vs86gZXHMBsDcAVncAeHVfxan0fLJa1OlMPVYodwxpIt05+ket8X+BEldiFNC2HzDKzUXXbyHCPwjm9qS/yb6ut8YZ+QbEepBcvF" +
        "1koLP19coR0aDmUnqHUUgS9hLW80NEO7Rowqsm4dswQXPnkLCq2Gfucvrhw+EzTxwTDEzys+GqFVNtuingedJwjx84mPJmhTxCY1yiAzhlEAeQoALdCkuDGv" +
        "nLqAFEXQXBHA/bJz+yWqguVF1pgPCCFwXg7gGK4rl3T12shstUbeKuwUUjaaRtHUFw1cwincwnFjVjcTOOwgq9TBucJ6YY3A99uPFpjtAiuEsHkGEJkZUvC5" +
        "sEvgWp7D/MvCXqFx+xn4KAc/jqqEkgAAAABJRU5ErkJggg=="
}

/// A provider's brand mark tinted in its accent color — the drop-in replacement
/// for the small colored provider dots used across the menu.
struct BrandMarkView: View {
    // Leaf-observe the palette so a color edit re-renders the mark even when
    // SwiftUI would otherwise diff this view as unchanged by its stored props.
    @ObservedObject private var palette = ProviderPalette.shared
    let origin: UsageOrigin
    var size: CGFloat = 12
    var tint: Color? = nil

    var body: some View {
        Image(nsImage: BrandMark.image(origin))
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .frame(width: size, height: size)
            .foregroundStyle(tint ?? palette.color(origin))
    }
}