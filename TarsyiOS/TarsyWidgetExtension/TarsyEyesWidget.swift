import SwiftUI

/// Animated Tarsy eyes for Live Activity / Dynamic Island.
/// Two solid white circles that move independently in a continuous loop
/// using PhaseAnimator (supported in widgets & Live Activities since iOS 17).
struct TarsyEyesWidget: View {
    let size: CGFloat

    // 5 phases the eyes cycle through — each eye moves slightly differently
    private enum Phase: CaseIterable {
        case center, lookRight, lookUp, lookLeft, lookDown
    }

    var body: some View {
        PhaseAnimator(Phase.allCases) { phase in
            HStack(spacing: size * 0.1) {
                // Left eye (slightly smaller, like the real logo)
                Circle()
                    .fill(.white)
                    .frame(width: size * 0.38, height: size * 0.38)
                    .offset(
                        x: leftEyeOffset(phase).x,
                        y: leftEyeOffset(phase).y
                    )

                // Right eye
                Circle()
                    .fill(.white)
                    .frame(width: size * 0.42, height: size * 0.42)
                    .offset(
                        x: rightEyeOffset(phase).x,
                        y: rightEyeOffset(phase).y
                    )
            }
        } animation: { _ in
            .easeInOut(duration: 1.8)
        }
    }

    // MARK: - Eye offsets per phase

    private var step: CGFloat { size * 0.045 }

    private func leftEyeOffset(_ phase: Phase) -> CGPoint {
        switch phase {
        case .center:    return .zero
        case .lookRight: return CGPoint(x: step,  y: -step * 0.3)
        case .lookUp:    return CGPoint(x: 0,     y: -step)
        case .lookLeft:  return CGPoint(x: -step, y: 0)
        case .lookDown:  return CGPoint(x: step * 0.4, y: step * 0.7)
        }
    }

    private func rightEyeOffset(_ phase: Phase) -> CGPoint {
        switch phase {
        case .center:    return .zero
        case .lookRight: return CGPoint(x: step,      y: 0)
        case .lookUp:    return CGPoint(x: step * 0.3, y: -step)
        case .lookLeft:  return CGPoint(x: -step,     y: -step * 0.3)
        case .lookDown:  return CGPoint(x: 0,         y: step * 0.7)
        }
    }
}
