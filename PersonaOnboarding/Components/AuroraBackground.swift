import SwiftUI

/// Near-black canvas with slow atmospheric blooms (never behind text at full strength) and film grain.
struct AuroraBackground: View {
    var boost: Double = 0.6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var start: Date { AnimationClock.epoch }

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30.0)) { ctx in
            let t = Float(ctx.date.timeIntervalSince(start))
            let b = boost
            ZStack {
                Theme.canvas
                MeshGradient(
                    width: 3, height: 3,
                    points: [
                        [0, 0], [0.5, 0], [1, 0],
                        [0, 0.45 + 0.08 * sin(t * 0.23)], [0.5 + 0.14 * sin(t * 0.17), 0.5 + 0.1 * cos(t * 0.21)], [1, 0.55 + 0.08 * cos(t * 0.19)],
                        [0, 1], [0.5, 1], [1, 1],
                    ],
                    colors: [
                        Theme.canvas, Theme.iris.opacity(0.42 * b), Theme.canvas,
                        Theme.teal.opacity(0.20 * b), Theme.canvas, Theme.violet.opacity(0.16 * b),
                        Theme.canvas, Theme.teal.opacity(0.26 * b), Theme.canvas,
                    ]
                )
                Grain().opacity(0.05)
            }
            .ignoresSafeArea()
        }
        .allowsHitTesting(false)
    }
}

/// Static noise tile, generated once.
struct Grain: View {
    private static let tile: CGImage? = {
        let w = 96, h = 96
        var bytes = [UInt8](repeating: 0, count: w * h)
        var seed: UInt32 = 0x9E3779B9
        for i in 0..<bytes.count {
            seed = seed &* 1664525 &+ 1013904223
            bytes[i] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)
        return provider.flatMap {
            CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                    provider: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }()

    var body: some View {
        if let tile = Self.tile {
            Image(decorative: tile, scale: 2)
                .resizable(resizingMode: .tile)
                .blendMode(.overlay)
        }
    }
}
