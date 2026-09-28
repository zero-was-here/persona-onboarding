import SwiftUI
import UIKit

/// "Double bezel": a machined outer shell holding an inner glass core with concentric corners.
struct DoubleBezel<Content: View>: View {
    var radius: CGFloat = Theme.radiusShell
    var padding: CGFloat = Theme.bezel
    var glow: Color? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: radius - padding, style: .continuous)
                    .fill(Theme.core)
                    .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: radius - padding, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius - padding, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.18), Color.white.opacity(0.03)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.75
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: radius - padding, style: .continuous))
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.shell))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .shadow(color: (glow ?? .clear).opacity(0.25), radius: 30, y: 10)
    }
}

/// Glass capsule used for chips and small controls. Uses Liquid Glass on iOS 26.
struct GlassCapsule: ViewModifier {
    var tint: Color? = nil
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(tint.map { Glass.regular.tint($0.opacity(0.35)) } ?? Glass.regular, in: Capsule())
        } else {
            content
                .background(Capsule().fill(.ultraThinMaterial))
                .background(Capsule().fill((tint ?? .white).opacity(tint == nil ? 0.04 : 0.18)))
                .overlay(Capsule().strokeBorder(Theme.hairlineStrong, lineWidth: 0.5))
        }
    }
}

struct GlassCircle: ViewModifier {
    var tint: Color? = nil
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(tint.map { Glass.regular.tint($0) } ?? Glass.regular, in: Circle())
        } else {
            content
                .background(Circle().fill(tint ?? Color.white.opacity(0.08)))
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(Theme.hairlineStrong, lineWidth: 0.5))
        }
    }
}

extension View {
    func glassCapsule(tint: Color? = nil) -> some View { modifier(GlassCapsule(tint: tint)) }
    func glassCircle(tint: Color? = nil) -> some View { modifier(GlassCircle(tint: tint)) }

    /// Content never pops in: it rises from a slightly lower, blurred resting state.
    func riseIn(delay: Double = 0) -> some View { modifier(RiseIn(delay: delay)) }
}

struct RiseIn: ViewModifier {
    let delay: Double
    @State private var shown = false
    @ViewBuilder func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .blur(radius: shown ? 0 : 6)
            .onAppear {
                withAnimation(Motion.spring.delay(delay)) { shown = true }
            }
    }
}

/// Pressable pill with an optional trailing icon nested in its own circle ("button-in-button").
struct IslandButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.sans(16, .medium))
            .foregroundStyle(kind == .primary ? Theme.canvas : Theme.ink)
            .padding(.leading, 22)
            .padding(.trailing, 6)
            .frame(height: 52)
            .background(
                Capsule().fill(kind == .primary ? AnyShapeStyle(Theme.ice) : AnyShapeStyle(Color.white.opacity(0.06)))
            )
            .overlay(Capsule().strokeBorder(kind == .primary ? Color.clear : Theme.hairlineStrong, lineWidth: 0.5))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

struct IslandLabel: View {
    let title: String
    var icon: String = "arrow.up.right"
    var kind: IslandButtonStyle.Kind = .primary
    var body: some View {
        HStack(spacing: 14) {
            Text(title)
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(Circle().fill(kind == .primary ? Theme.canvas.opacity(0.08) : Color.white.opacity(0.08)))
        }
    }
}

enum Haptics {
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func soft() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func rigid() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.9) }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}
