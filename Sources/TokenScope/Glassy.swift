import SwiftUI

/// The MenuBarExtra(.window) popup is ALREADY a system Liquid Glass surface.
/// Per Apple's guidance ("avoid glass on glass; glass is only the navigation
/// layer floating above content"), we add NO additional glass inside it — doing
/// so was the cluttered "mess of radius and glass". Instead, content is grouped
/// with a subtle, legible base-layer card and controls stay flat/standard.
extension View {
    func sectionCard(cornerRadius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(shape.fill(Color.primary.opacity(0.04)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.06)))
    }
}
