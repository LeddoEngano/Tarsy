import SwiftUI

/// Animated Tarsy eyes — two solid white circles (no pupils).
/// Left eye is smaller, right eye is bigger. Aligned vertically.
/// Expressive like a little creature: random darts, blinks, waves,
/// shape morphs (heart/star), suspicious squints, and widens.
struct TarsyEyes: View {
    let size: CGFloat
    var animated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var leftEye = EyeState()
    @State private var rightEye = EyeState()
    @State private var morphShape: MorphShape = .none
    @State private var morphOpacity: Double = 0
    @State private var eyesOpacity: Double = 1

    private var step: CGFloat { size * 0.05 }

    var body: some View {
        let shouldAnimate = animated && !reduceMotion

        ZStack {
            // Eyes
            HStack(spacing: size * 0.1) {
                Circle()
                    .fill(.white)
                    .frame(width: size * 0.38, height: size * 0.38)
                    .scaleEffect(x: leftEye.scaleX, y: leftEye.scaleY)
                    .offset(x: leftEye.offsetX, y: leftEye.offsetY)

                Circle()
                    .fill(.white)
                    .frame(width: size * 0.42, height: size * 0.42)
                    .scaleEffect(x: rightEye.scaleX, y: rightEye.scaleY)
                    .offset(x: rightEye.offsetX, y: rightEye.offsetY)
            }
            .opacity(eyesOpacity)

            // Shape morph overlay
            Group {
                switch morphShape {
                case .heart:
                    Image(systemName: "heart.fill")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.white)
                case .star:
                    Image(systemName: "star.fill")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.white)
                case .none:
                    EmptyView()
                }
            }
            .opacity(morphOpacity)
        }
        .frame(width: size, height: size * 0.5)
        .task(id: shouldAnimate) {
            guard shouldAnimate else { return }
            await runLoop()
        }
    }

    // MARK: - Animation Loop

    private func runLoop() async {
        try? await Task.sleep(for: .milliseconds(500))
        while !Task.isCancelled {
            await perform(pickBehavior())
            try? await Task.sleep(for: .milliseconds(Int.random(in: 300...900)))
        }
    }

    // MARK: - Behaviors

    private enum Behavior {
        case blink, doubleBlink
        case dartRight, dartLeft
        case lookUp, lookDown
        case wave
        case widen
        case suspiciousSquint
        case morphHeart, morphStar
    }

    private func pickBehavior() -> Behavior {
        let table: [(Behavior, Int)] = [
            (.blink, 5),
            (.doubleBlink, 2),
            (.dartRight, 3),
            (.dartLeft, 3),
            (.lookUp, 2),
            (.lookDown, 2),
            (.wave, 3),
            (.widen, 2),
            (.suspiciousSquint, 2),
            (.morphHeart, 1),
            (.morphStar, 1),
        ]
        let total = table.reduce(0) { $0 + $1.1 }
        var roll = Int.random(in: 0..<total)
        for (behavior, weight) in table {
            roll -= weight
            if roll < 0 { return behavior }
        }
        return .blink
    }

    private func perform(_ behavior: Behavior) async {
        switch behavior {
        case .blink:            await doBlink()
        case .doubleBlink:      await doDoubleBlink()
        case .dartRight:        await doDart(direction: 1)
        case .dartLeft:         await doDart(direction: -1)
        case .lookUp:           await doLook(dy: -1)
        case .lookDown:         await doLook(dy: 1)
        case .wave:             await doWave()
        case .widen:            await doWiden()
        case .suspiciousSquint: await doSuspiciousSquint()
        case .morphHeart:       await doMorph(.heart)
        case .morphStar:        await doMorph(.star)
        }
    }

    // MARK: - Blink

    private func doBlink() async {
        withAnimation(.easeIn(duration: 0.06)) {
            leftEye.scaleY = 0.08
            rightEye.scaleY = 0.08
        }
        try? await Task.sleep(for: .milliseconds(80))
        withAnimation(.spring(duration: 0.12, bounce: 0.2)) {
            resetEyes()
        }
        try? await Task.sleep(for: .milliseconds(150))
    }

    private func doDoubleBlink() async {
        await doBlink()
        try? await Task.sleep(for: .milliseconds(100))
        await doBlink()
    }

    // MARK: - Dart

    private func doDart(direction: CGFloat) async {
        let dx = step * 1.6 * direction
        withAnimation(.spring(duration: 0.12, bounce: 0.15)) {
            leftEye.offsetX = dx
            rightEye.offsetX = dx
            leftEye.offsetY = -step * 0.2
            leftEye.scaleX = 0.95
            leftEye.scaleY = 0.95
            rightEye.scaleX = 0.95
            rightEye.scaleY = 0.95
        }
        try? await Task.sleep(for: .milliseconds(Int.random(in: 400...900)))
        withAnimation(.spring(duration: 0.14, bounce: 0.1)) {
            resetEyes()
        }
        try? await Task.sleep(for: .milliseconds(180))
    }

    // MARK: - Look

    private func doLook(dy: CGFloat) async {
        withAnimation(.easeInOut(duration: 0.3)) {
            leftEye.offsetY = step * 1.5 * dy
            rightEye.offsetY = step * 1.5 * dy
            rightEye.offsetX = step * 0.3
            let s: CGFloat = dy < 0 ? 1.06 : 0.96
            leftEye.scaleX = s
            leftEye.scaleY = s
            rightEye.scaleX = s
            rightEye.scaleY = s
        }
        try? await Task.sleep(for: .milliseconds(Int.random(in: 500...1000)))
        withAnimation(.easeInOut(duration: 0.3)) {
            resetEyes()
        }
        try? await Task.sleep(for: .milliseconds(350))
    }

    // MARK: - Wave (ola)

    private func doWave() async {
        let amp = step * 2.0
        let cycles = Int.random(in: 2...3)

        for _ in 0..<cycles {
            // Left up
            withAnimation(.easeInOut(duration: 0.18)) {
                leftEye.offsetY = -amp
            }
            try? await Task.sleep(for: .milliseconds(100))

            // Right up, left down
            withAnimation(.easeInOut(duration: 0.18)) {
                rightEye.offsetY = -amp
                leftEye.offsetY = 0
            }
            try? await Task.sleep(for: .milliseconds(100))

            // Right down
            withAnimation(.easeInOut(duration: 0.18)) {
                rightEye.offsetY = 0
            }
            try? await Task.sleep(for: .milliseconds(80))
        }

        withAnimation(.easeOut(duration: 0.15)) {
            resetEyes()
        }
        try? await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - Widen

    private func doWiden() async {
        withAnimation(.spring(duration: 0.2, bounce: 0.35)) {
            leftEye.scaleX = 1.22
            leftEye.scaleY = 1.22
            rightEye.scaleX = 1.22
            rightEye.scaleY = 1.22
        }
        try? await Task.sleep(for: .milliseconds(Int.random(in: 400...800)))
        withAnimation(.easeInOut(duration: 0.25)) {
            resetEyes()
        }
        try? await Task.sleep(for: .milliseconds(300))
    }

    // MARK: - Suspicious squint

    private func doSuspiciousSquint() async {
        // Slowly narrow the eyes
        withAnimation(.easeInOut(duration: 0.8)) {
            leftEye.scaleX = 0.75
            leftEye.scaleY = 0.45
            rightEye.scaleX = 0.75
            rightEye.scaleY = 0.45
        }
        try? await Task.sleep(for: .milliseconds(900))
        // Hold the stare...
        try? await Task.sleep(for: .milliseconds(Int.random(in: 600...1200)))
        // Slowly return
        withAnimation(.easeInOut(duration: 0.6)) {
            resetEyes()
        }
        try? await Task.sleep(for: .milliseconds(700))
    }

    // MARK: - Shape morph (heart / star)

    private enum MorphShape {
        case none, heart, star
    }

    private func doMorph(_ shape: MorphShape) async {
        morphShape = shape

        // Eyes converge and fade out, shape fades in
        withAnimation(.easeInOut(duration: 0.35)) {
            leftEye.offsetX = step * 2
            rightEye.offsetX = -step * 2
            leftEye.scaleX = 0.5
            leftEye.scaleY = 0.5
            rightEye.scaleX = 0.5
            rightEye.scaleY = 0.5
            eyesOpacity = 0
            morphOpacity = 1
        }
        try? await Task.sleep(for: .milliseconds(Int.random(in: 900...1500)))

        // Shape fades out, eyes return
        withAnimation(.easeInOut(duration: 0.35)) {
            resetEyes()
            eyesOpacity = 1
            morphOpacity = 0
        }
        try? await Task.sleep(for: .milliseconds(400))
        morphShape = .none
    }

    // MARK: - State

    private struct EyeState {
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1
    }

    private func resetEyes() {
        leftEye = EyeState()
        rightEye = EyeState()
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Animated — Large") {
    TarsyEyes(size: 120)
        .padding(40)
        .background(Color(hex: "0a0a0a"))
        .preferredColorScheme(.dark)
}

#Preview("Animated — Small") {
    TarsyEyes(size: 40)
        .padding(40)
        .background(Color(hex: "0a0a0a"))
        .preferredColorScheme(.dark)
}

#Preview("Static") {
    TarsyEyes(size: 100, animated: false)
        .padding(40)
        .background(Color(hex: "0a0a0a"))
        .preferredColorScheme(.dark)
}
#endif
