import SwiftUI

// Liquid Glass exists only on macOS 26; older systems get the closest standard look.

extension View {
    /// Glass button style, plain bordered before macOS 26.
    @ViewBuilder func pulseGlassButton() -> some View {
        if #available(macOS 26.0, *) { buttonStyle(.glass) } else { buttonStyle(.bordered) }
    }

    /// Interactive glass tile, a material card before macOS 26.
    @ViewBuilder func pulseGlassTile(tint: Color?, cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(tint.map { .regular.tint($0).interactive() } ?? .regular.interactive(),
                        in: .rect(cornerRadius: cornerRadius, style: .continuous))
        } else {
            background {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                shape.fill(.regularMaterial)
                if let tint { shape.fill(tint) }
            }
        }
    }
}

/// Groups glass tiles on macOS 26; a transparent wrapper before it.
struct PulseGlassContainer<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
