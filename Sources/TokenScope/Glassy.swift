import SwiftUI

/// Liquid Glass helpers (macOS 26+) with material fallbacks, so the same call
/// sites work regardless of OS. Apple's guidance: glass is for the floating
/// control/navigation layer, not every surface — so we use it for the tab bar,
/// the grouped section "cards", and buttons, while keeping dense data rows flat.
extension View {
    /// A grouped content card: Liquid Glass on 26+, ultra-thin material otherwise.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 12, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0.opacity(0.5)) } ?? .regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.06)))
        }
    }

    /// Grouped content card on the BASE layer. Per Apple's Liquid Glass guidance,
    /// content stays legible on a solid-ish surface — glass is reserved for the
    /// floating navigation/control layer (tab bar, buttons), not stacked here.
    func sectionCard(cornerRadius: CGFloat = 13) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(shape.fill(Color.primary.opacity(0.045)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.07)))
    }

    /// A small interactive glass pill (tab items, segment-like chips).
    @ViewBuilder
    func glassPill(selected: Bool, tint: Color) -> some View {
        let shape = Capsule(style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(selected ? Glass.regular.tint(tint.opacity(0.55)).interactive()
                                      : Glass.regular.interactive(),
                             in: shape)
        } else {
            self.background(selected ? AnyShapeStyle(tint.opacity(0.25)) : AnyShapeStyle(.ultraThinMaterial),
                            in: shape)
        }
    }
}

/// Button style: Liquid Glass on 26+, bordered fallback otherwise. Use for
/// footer actions and Save/Disconnect.
struct GlassyButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            // Defer to the system glass button styles for correct shape/feedback.
            AnyView(
                configuration.label
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .glassPill(selected: prominent, tint: .accentColor)
                    .opacity(configuration.isPressed ? 0.7 : 1)
            )
        } else {
            AnyView(
                configuration.label
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .opacity(configuration.isPressed ? 0.7 : 1)
            )
        }
    }
}
