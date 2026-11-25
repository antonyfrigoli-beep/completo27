import SwiftUI

struct GameSelectionView: View {
    let onSelectFreeFireNormal: () -> Void

    var body: some View {
        ZStack {
            ParticleFieldBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer(minLength: 40)

                    BrandXLogo(size: 76)
                        .padding(.bottom, 14)

                    Text("EXTERNAL SYSTEM")
                        .font(.system(size: 27, weight: .black, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(.white)

                    Text("Escolha seu jogo para continuar")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .padding(.top, 5)

                    Button(action: onSelectFreeFireNormal) {
                        HStack(spacing: 16) {
                            Image("FreeFireNormal")
                                .resizable()
                                .scaledToFill()
                                .frame(width: 66, height: 66)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(Color.white.opacity(0.16), lineWidth: 0.8)
                                }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("FF NORMAL")
                                    .font(.headline.weight(.black))
                                    .tracking(0.4)
                                    .foregroundStyle(.white)
                                Text("Free Fire Normal")
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.64))
                            }

                            Spacer(minLength: 0)

                            Image(systemName: "arrow.up.right")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(AppTheme.accent)
                                .frame(width: 36, height: 36)
                                .background(AppTheme.accent.opacity(0.12), in: Circle())
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 15)
                        .background(
                            Color(red: 0.075, green: 0.07, blue: 0.10).opacity(0.88),
                            in: RoundedRectangle(cornerRadius: 21, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 21, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [AppTheme.accent.opacity(0.42), Color.white.opacity(0.08)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        }
                        .shadow(color: AppTheme.accent.opacity(0.09), radius: 18, y: 7)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Selecionar FF NORMAL, Free Fire Normal")
                    .padding(.top, 28)
                    .padding(.horizontal, 18)

                    Text("Disponível: FF NORMAL")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.42))
                        .multilineTextAlignment(.center)
                        .padding(.top, 22)
                        .padding(.horizontal, 24)

                    Spacer(minLength: 48)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct BrandXLogo: View {
    var size: CGFloat = 54

    var body: some View {
        Image("BrandX")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct ParticleFieldBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { _ in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.018, green: 0.018, blue: 0.018),
                        Color(red: 0.032, green: 0.032, blue: 0.032),
                        .black
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 10.0 : 1.0 / 30.0)) { timeline in
                    Canvas { context, size in
                        let phaseSpeed = reduceMotion ? 0.45 : 1.15
                        let motionScale = reduceMotion ? 0.48 : 1.0
                        let phase = (timeline.date.timeIntervalSinceReferenceDate * phaseSpeed)
                            .truncatingRemainder(dividingBy: .pi * 2)
                        Self.drawConstellation(in: &context, size: size, phase: phase, motionScale: motionScale)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func drawConstellation(in context: inout GraphicsContext, size: CGSize, phase: Double, motionScale: Double) {
        guard size.width > 0, size.height > 0 else { return }
        let count = 25
        let points: [CGPoint] = (0..<count).map { index in
            let seed = Double(index)
            let baseX = 0.09 + (seed * 0.61803398875).truncatingRemainder(dividingBy: 1) * 0.82
            let baseY = 0.09 + (seed * 0.75487766625 + 0.17).truncatingRemainder(dividingBy: 1) * 0.82
            let driftX = sin(phase + seed * 1.73) * 0.09 * motionScale
            let driftY = cos(phase * 0.83 + seed * 1.21) * 0.09 * motionScale
            return CGPoint(
                x: CGFloat(min(1, max(0, baseX + driftX))) * size.width,
                y: CGFloat(min(1, max(0, baseY + driftY))) * size.height
            )
        }

        let maxDistance = min(size.width, size.height) * 0.31
        for first in 0..<count {
            for second in (first + 1)..<count {
                let a = points[first]
                let b = points[second]
                let dx = a.x - b.x
                let dy = a.y - b.y
                let distance = hypot(dx, dy)
                guard distance < maxDistance else { continue }
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                let opacity = Double(0.14 * (1 - distance / maxDistance))
                context.stroke(
                    path,
                    with: .color(Color(red: 0.62, green: 0.64, blue: 0.66).opacity(opacity)),
                    lineWidth: 0.55
                )
            }
        }

        for (index, point) in points.enumerated() {
            let twinkle = 0.72 + 0.28 * (0.5 + 0.5 * sin(phase * 1.7 + Double(index) * 1.9))
            let radius: CGFloat = index.isMultiple(of: 5) ? 2.2 : 1.4
            let dot = Path(
                ellipseIn: CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
            context.fill(
                dot,
                with: .color(
                    Color(red: 0.72, green: 0.74, blue: 0.76)
                        .opacity((index.isMultiple(of: 4) ? 0.52 : 0.26) * twinkle)
                )
            )
        }
    }
}
