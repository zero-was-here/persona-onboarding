import SwiftUI

enum OrbMood: Equatable { case idle, listening, thinking, speaking, happy, ringing, sleepy }

/// The agent's living presence: a Metal glass orb with a tiny face.
struct AgentOrb: View {
    var size: CGFloat
    var level: Float = 0
    var mood: OrbMood = .idle
    var showsEyes = true
    var palette: OrbPalette = .brand

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.25 : nil)) { ctx in
            let t = ctx.date.timeIntervalSince(start)
            ZStack {
                Rectangle()
                    .fill(Color.white)
                    .colorEffect(
                        ShaderLibrary.agentOrb(
                            .float2(CGSize(width: size * 1.5, height: size * 1.5)),
                            .float(Float(t)),
                            .float(effectiveLevel),
                            .float(energy),
                            .float(mood == .happy || mood == .ringing ? 1 : 0),
                            .color(palette.a), .color(palette.b), .color(palette.c), .color(palette.irid)
                        )
                    )
                    .frame(width: size * 1.5, height: size * 1.5)
                    .allowsHitTesting(false)

                if showsEyes {
                    OrbEyes(size: size, t: t, mood: mood, level: effectiveLevel)
                }
            }
            .frame(width: size * 1.5, height: size * 1.5)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var effectiveLevel: Float { min(max(level, 0), 1) }
    private var energy: Float {
        switch mood {
        case .speaking: return 0.6 + effectiveLevel * 0.4
        case .listening: return 0.35
        case .thinking: return 0.5
        case .ringing, .happy: return 0.8
        case .idle: return 0.2
        case .sleepy: return 0.05
        }
    }
}

struct OrbPalette {
    var a: Color, b: Color, c: Color, irid: Color
    static let brand = OrbPalette(a: Theme.teal, b: Theme.aqua, c: Theme.ice, irid: Theme.iris)
    static let unnamed = OrbPalette(a: Color(hex: 0x3A4A5C), b: Color(hex: 0xB9C7D6), c: Theme.ice, irid: Theme.iris)
}

/// Two little eyes that blink, look around, and smile.
struct OrbEyes: View {
    let size: CGFloat
    let t: Double
    let mood: OrbMood
    let level: Float

    var body: some View {
        let phase = t.truncatingRemainder(dividingBy: 4.6)
        let blinking = phase < 0.13 || (phase > 0.32 && phase < 0.42 && Int(t / 4.6) % 3 == 0)
        let openness: CGFloat = mood == .sleepy ? 0.25 : (blinking ? 0.1 : 1)
        let tall = mood == .listening ? 1.14 : 1.0
        let gazeX = CGFloat(sin(t * 0.55)) * size * 0.02 + (mood == .thinking ? size * 0.035 : 0)
        let gazeY = (mood == .thinking ? -size * 0.035 : CGFloat(cos(t * 0.4)) * size * 0.006)
            - (mood == .speaking ? CGFloat(level) * size * 0.02 : 0)
        let w = size * 0.072
        let h = size * 0.135 * tall

        HStack(spacing: size * 0.12) {
            eye(w: w, h: h, openness: openness)
            eye(w: w, h: h, openness: openness)
        }
        .offset(x: gazeX, y: -size * 0.035 + gazeY)
        .animation(Motion.snappy, value: mood)
    }

    @ViewBuilder
    private func eye(w: CGFloat, h: CGFloat, openness: CGFloat) -> some View {
        if mood == .happy {
            HappyEye()
                .stroke(Color.white, style: StrokeStyle(lineWidth: w * 0.62, lineCap: .round))
                .frame(width: w * 1.5, height: h * 0.45)
                .shadow(color: .white.opacity(0.7), radius: size * 0.02)
        } else {
            Capsule()
                .fill(Color.white)
                .frame(width: w, height: max(h * openness, w * 0.35))
                .shadow(color: .white.opacity(0.75), radius: size * 0.025)
        }
    }
}

struct HappyEye: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.6))
        return p
    }
}

/// Expanding rings while the phone rings.
struct PulseRings: View {
    var color: Color = Theme.aqua
    var diameter: CGFloat
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .strokeBorder(color.opacity(0.35), lineWidth: 1)
                    .frame(width: diameter, height: diameter)
                    .scaleEffect(animate ? 1.9 : 1)
                    .opacity(animate ? 0 : 0.9)
                    .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(i) * 0.8), value: animate)
            }
        }
        .onAppear { animate = true }
        .allowsHitTesting(false)
    }
}

/// Radial audio bars around the orb that react while the user talks.
struct WaveRing: View {
    var level: Float
    var diameter: CGFloat
    var color: Color = Theme.aqua
    private let start = Date()

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSince(start)
            Canvas { gc, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let bars = 72
                let inner = diameter / 2
                let lvl = CGFloat(min(max(level, 0), 1))
                for i in 0..<bars {
                    let a = Double(i) / Double(bars) * .pi * 2
                    let wobble = (sin(a * 3 + t * 2.1) + sin(a * 7 - t * 3.3)) * 0.25 + 0.5
                    let len = 3 + lvl * 26 * CGFloat(wobble)
                    let p1 = CGPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner)
                    let p2 = CGPoint(x: center.x + cos(a) * (inner + len), y: center.y + sin(a) * (inner + len))
                    var path = Path()
                    path.move(to: p1)
                    path.addLine(to: p2)
                    gc.stroke(path, with: .color(color.opacity(0.18 + 0.5 * Double(lvl))), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
        }
        .frame(width: diameter + 70, height: diameter + 70)
        .allowsHitTesting(false)
    }
}
