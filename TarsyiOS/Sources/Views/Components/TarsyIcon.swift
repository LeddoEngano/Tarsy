import SwiftUI

struct TarsyIcon: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "2a2218"), Color(hex: "1a1a1a")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)

            // Tarsier eyes
            VStack(spacing: size * 0.06) {
                HStack(spacing: size * 0.12) {
                    eye(diameter: size * 0.28)
                    eye(diameter: size * 0.28)
                }

                // Subtle mouth/nose
                Capsule()
                    .fill(Color(hex: "3a3025"))
                    .frame(width: size * 0.08, height: size * 0.04)
            }
            .offset(y: -size * 0.02)
        }
    }

    @ViewBuilder
    private func eye(diameter: CGFloat) -> some View {
        ZStack {
            // Outer glow
            Circle()
                .fill(Color(hex: "d4a574").opacity(0.3))
                .frame(width: diameter * 1.15, height: diameter * 1.15)

            // Eye
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: "e8c088"), Color(hex: "d4a574")],
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter * 0.5
                    )
                )
                .frame(width: diameter, height: diameter)

            // Pupil
            Circle()
                .fill(Color(hex: "1a1a1a"))
                .frame(width: diameter * 0.45, height: diameter * 0.45)
                .offset(x: diameter * 0.05, y: -diameter * 0.05)

            // Highlight
            Circle()
                .fill(.white.opacity(0.6))
                .frame(width: diameter * 0.15, height: diameter * 0.15)
                .offset(x: diameter * 0.12, y: -diameter * 0.12)
        }
    }
}

#Preview {
    TarsyIcon(size: 120)
        .preferredColorScheme(.dark)
}
