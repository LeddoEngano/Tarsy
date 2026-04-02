import SwiftUI

/// Animated Tarsy eyes — two solid white circles (no pupils).
/// Left eye is smaller and sits slightly higher, matching the logo.
struct TarsyEyes: View {
    let size: CGFloat
    var animated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase: CaseIterable {
        case center, lookRight, lookUp, lookLeft, lookDown
    }

    var body: some View {
        if animated && !reduceMotion {
            PhaseAnimator(Phase.allCases) { phase in
                eyesLayout(phase: phase)
            } animation: { _ in
                .easeInOut(duration: 1.8)
            }
        } else {
            eyesLayout(phase: .center)
        }
    }

    // MARK: - Layout

    @ViewBuilder
    private func eyesLayout(phase: Phase) -> some View {
        HStack(spacing: size * 0.1) {
            // Left eye (smaller, sits higher)
            Circle()
                .fill(.white)
                .frame(width: size * 0.38, height: size * 0.38)
                .offset(
                    x: leftEyeOffset(phase).x,
                    y: leftEyeOffset(phase).y - size * 0.06
                )

            // Right eye (bigger)
            Circle()
                .fill(.white)
                .frame(width: size * 0.42, height: size * 0.42)
                .offset(
                    x: rightEyeOffset(phase).x,
                    y: rightEyeOffset(phase).y
                )
        }
        .frame(width: size, height: size * 0.5)
    }

    // MARK: - Eye offsets per phase

    private var step: CGFloat { size * 0.045 }

    private func leftEyeOffset(_ phase: Phase) -> CGPoint {
        switch phase {
        case .center:    return .zero
        case .lookRight: return CGPoint(x: step,        y: -step * 0.3)
        case .lookUp:    return CGPoint(x: 0,           y: -step)
        case .lookLeft:  return CGPoint(x: -step,       y: 0)
        case .lookDown:  return CGPoint(x: step * 0.4,  y: step * 0.7)
        }
    }

    private func rightEyeOffset(_ phase: Phase) -> CGPoint {
        switch phase {
        case .center:    return .zero
        case .lookRight: return CGPoint(x: step,        y: 0)
        case .lookUp:    return CGPoint(x: step * 0.3,  y: -step)
        case .lookLeft:  return CGPoint(x: -step,       y: -step * 0.3)
        case .lookDown:  return CGPoint(x: 0,           y: step * 0.7)
        }
    }
}

#if DEBUG
#Preview("Animated — Large") {
    TarsyEyes(size: 120)
        .padding()
        .background(Color(hex: "0a0a0a"))
        .preferredColorScheme(.dark)
}

#Preview("Animated — Small") {
    TarsyEyes(size: 40)
        .padding()
        .background(Color(hex: "0a0a0a"))
        .preferredColorScheme(.dark)
}

#Preview("Static") {
    TarsyEyes(size: 100, animated: false)
        .padding()
        .background(Color(hex: "0a0a0a"))
        .preferredColorScheme(.dark)
}
#endif
