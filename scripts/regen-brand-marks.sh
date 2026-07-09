#!/bin/bash
# Regenerates Sources/TokenScope/BrandMarks.swift from the Simple Icons brand
# marks. Run from the repo root: scripts/regen-brand-marks.sh
#
# Pipeline (see CLAUDE.md "Provider brand marks"):
#   1. Fetch the monochrome SVGs (claude/openai/ollama) from Simple Icons.
#   2. Rasterize to 128px PNG with qlmanage (built into macOS).
#   3. Convert black-on-white → alpha mask (alpha = 255 − luminance) in a
#      known RGBA8 CGContext, so the shape lives in the alpha channel.
#   4. base64 the mask PNGs and emit BrandMarks.swift.
#
# Marks: Claude = the Claude spark, Codex = the OpenAI mark, Ollama = the llama.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Sources/TokenScope/BrandMarks.swift"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# icon name in Simple Icons -> logical mark name used in the Swift source
declare -a ICONS=("claude:claude" "openai:codex" "ollama:ollama")

for pair in "${ICONS[@]}"; do
  src="${pair%%:*}"
  curl -fsSL --max-time 20 \
    "https://cdn.jsdelivr.net/npm/simple-icons@latest/icons/${src}.svg" \
    -o "$TMP/${src}.svg"
  qlmanage -t -s 128 -o "$TMP" "$TMP/${src}.svg" >/dev/null 2>&1
done

TMP="$TMP" OUT="$OUT" swift - <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

let tmp = ProcessInfo.processInfo.environment["TMP"]!
let out = ProcessInfo.processInfo.environment["OUT"]!

func mask(_ svgName: String) -> String {
    guard let img = NSImage(contentsOfFile: "\(tmp)/\(svgName).svg.png") else { fatalError("no raster for \(svgName)") }
    var r = NSRect(origin: .zero, size: img.size)
    let src = img.cgImage(forProposedRect: &r, context: nil, hints: nil)!
    let w = src.width, h = src.height, bpr = w * 4
    var buf = [UInt8](repeating: 0, count: bpr * h)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
    for i in stride(from: 0, to: buf.count, by: 4) {
        let lum = (0.299 * Double(buf[i]) + 0.587 * Double(buf[i+1]) + 0.114 * Double(buf[i+2])) / 255.0
        let a = UInt8(max(0, min(255, (1.0 - lum) * (Double(buf[i+3]) / 255.0) * 255)))
        buf[i] = 0; buf[i+1] = 0; buf[i+2] = 0; buf[i+3] = a
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!.base64EncodedString()
}

func chunked(_ s: String, _ width: Int = 120) -> String {
    var parts: [String] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: width, limitedBy: s.endIndex) ?? s.endIndex
        parts.append("        \"\(s[i..<j])\"")
        i = j
    }
    return parts.joined(separator: " +\n")
}

let claude = mask("claude"), codex = mask("openai"), ollama = mask("ollama")
let src = """
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
        }
        let img = Data(base64Encoded: b64).flatMap { NSImage(data: $0) } ?? NSImage()
        img.isTemplate = true
        cache.setObject(img, forKey: key)
        return img
    }

    /// The single source of truth for provider accent colors, shared by the
    /// brand marks and everywhere else a provider is color-coded.
    static func color(_ origin: UsageOrigin) -> Color {
        switch origin {
        case .claudeCode: return .orange
        case .codex:      return .purple
        case .ollama:     return .blue
        }
    }

    private static let claudeMark =
\(chunked(claude))

    private static let codexMark =
\(chunked(codex))

    private static let ollamaMark =
\(chunked(ollama))
}

/// A provider's brand mark tinted in its accent color — the drop-in replacement
/// for the small colored provider dots used across the menu.
struct BrandMarkView: View {
    let origin: UsageOrigin
    var size: CGFloat = 12
    var tint: Color? = nil

    var body: some View {
        Image(nsImage: BrandMark.image(origin))
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .frame(width: size, height: size)
            .foregroundStyle(tint ?? BrandMark.color(origin))
    }
}
"""
try! src.write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
print("wrote \(out)")
SWIFT
