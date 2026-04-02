import SwiftUI

/// Animated Tarsy eyes — two solid white circles (no pupils).
/// Left eye is smaller, right eye is bigger. Aligned vertically.
/// Expressive like a little robot: random behaviors with personality.
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
            HStack(spacing: size * 0.1) {
                Circle()
                    .fill(.white)
                    .frame(width: size * 0.36, height: size * 0.36)
                    .scaleEffect(x: leftEye.scaleX, y: leftEye.scaleY)
                    .offset(x: leftEye.offsetX, y: leftEye.offsetY)

                Circle()
                    .fill(.white)
                    .frame(width: size * 0.414, height: size * 0.414)
                    .scaleEffect(x: rightEye.scaleX, y: rightEye.scaleY)
                    .offset(x: rightEye.offsetX, y: rightEye.offsetY)
            }
            .opacity(eyesOpacity)

            // Morph overlay — two shapes replacing each eye
            if morphShape != .none {
                HStack(spacing: size * 0.1) {
                    morphIcon
                        .font(TarsyTheme.font(size: size * 0.30))
                        .foregroundStyle(.white)

                    morphIcon
                        .font(TarsyTheme.font(size: size * 0.345))
                        .foregroundStyle(.white)
                }
                .opacity(morphOpacity)
            }
        }
        .frame(width: size, height: size * 0.5)
        .task(id: shouldAnimate) {
            guard shouldAnimate else { return }
            await runLoop()
        }
    }

    // MARK: - Animation Loop

    private func runLoop() async {
        try? await Task.sleep(for: .milliseconds(800))
        while !Task.isCancelled {
            await perform(pickBehavior())
            // Breathe between animations — chill, not hyperactive
            try? await Task.sleep(for: .milliseconds(Int.random(in: 1500...4000)))
        }
    }

    // MARK: - Behavior Selection

    private enum Behavior {
        case blink, doubleBlink, winkLeft, winkRight
        case dartRight, dartLeft
        case lookUp, lookDown
        case wave
        case widen
        case suspiciousSquint
        case morphHeart, morphStar
        case bounce
        case sleepy
        case shy
        case crossEyed
        case eyeRoll
        case peek
        case headShake
        case excited
    }

    private func pickBehavior() -> Behavior {
        let table: [(Behavior, Int)] = [
            (.blink, 5),
            (.doubleBlink, 2),
            (.winkLeft, 2),
            (.winkRight, 2),
            (.dartRight, 3),
            (.dartLeft, 3),
            (.lookUp, 2),
            (.lookDown, 2),
            (.wave, 2),
            (.widen, 2),
            (.suspiciousSquint, 2),
            (.morphHeart, 1),
            (.morphStar, 1),
            (.bounce, 2),
            (.sleepy, 1),
            (.shy, 2),
            (.crossEyed, 1),
            (.eyeRoll, 2),
            (.peek, 1),
            (.headShake, 2),
            (.excited, 2),
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
        case .winkLeft:         await doWink(left: true)
        case .winkRight:        await doWink(left: false)
        case .dartRight:        await doDart(direction: 1)
        case .dartLeft:         await doDart(direction: -1)
        case .lookUp:           await doLook(dy: -1)
        case .lookDown:         await doLook(dy: 1)
        case .wave:             await doWave()
        case .widen:            await doWiden()
        case .suspiciousSquint: await doSuspiciousSquint()
        case .morphHeart:       await doMorph(.heart)
        case .morphStar:        await doMorph(.star)
        case .bounce:           await doBounce()
        case .sleepy:           await doSleepy()
        case .shy:              await doShy()
        case .crossEyed:        await doCrossEyed()
        case .eyeRoll:          await doEyeRoll()
        case .peek:             await doPeek()
        case .headShake:        await doHeadShake()
        case .excited:          await doExcited()
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

    // MARK: - Wink

    private func doWink(left: Bool) async {
        withAnimation(.easeIn(duration: 0.07)) {
            if left { leftEye.scaleY = 0.08 } else { rightEye.scaleY = 0.08 }
        }
        try? await Task.sleep(for: .milliseconds(Int.random(in: 250...500)))
        withAnimation(.spring(duration: 0.14, bounce: 0.25)) {
            if left { leftEye.scaleY = 1 } else { rightEye.scaleY = 1 }
        }
        try? await Task.sleep(for: .milliseconds(150))
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
        try? await Task.sleep(for: .milliseconds(Int.random(in: 500...1200)))
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
        try? await Task.sleep(for: .milliseconds(Int.random(in: 600...1200)))
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
            withAnimation(.easeInOut(duration: 0.18)) {
                leftEye.offsetY = -amp
            }
            try? await Task.sleep(for: .milliseconds(100))

            withAnimation(.easeInOut(duration: 0.18)) {
                rightEye.offsetY = -amp
                leftEye.offsetY = 0
            }
            try? await Task.sleep(for: .milliseconds(100))

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

    // MARK: - Widen (surprise)

    private func doWiden() async {
        withAnimation(.spring(duration: 0.2, bounce: 0.35)) {
            leftEye.scaleX = 1.25
            leftEye.scaleY = 1.25
            rightEye.scaleX = 1.25
            rightEye.scaleY = 1.25
        }
        try? await Task.sleep(for: .milliseconds(Int.random(in: 500...1000)))
        withAnimation(.easeInOut(duration: 0.3)) {
            resetEyes()
        }
        try? await Task.sleep(for: .milliseconds(300))
    }

    // MARK: - Suspicious squint

    private func doSuspiciousSquint() async {
        withAnimation(.easeInOut(duration: 0.8)) {
            leftEye.scaleX = 0.75
            leftEye.scaleY = 0.4
            rightEye.scaleX = 0.75
            rightEye.scaleY = 0.4
        }
        try? await Task.sleep(for: .milliseconds(900))
        try? await Task.sleep(for: .milliseconds(Int.random(in: 800...1800)))
        withAnimation(.easeInOut(duration: 0.6)) {
            resetEyes()
        }
        try? await Task.sleep(for: .milliseconds(700))
    }

    // MARK: - Bounce (happy)

    private func doBounce() async {
        let bounceHeight = step * 1.8
        let bounces = Int.random(in: 2...4)

        for i in 0..<bounces {
            let factor = 1.0 - (Double(i) * 0.2) // each bounce smaller
            withAnimation(.spring(duration: 0.15, bounce: 0.4)) {
                leftEye.offsetY = -bounceHeight * factor
                rightEye.offsetY = -bounceHeight * factor
                leftEye.scaleY = 1.1
                rightEye.scaleY = 1.1
            }
            try? await Task.sleep(for: .milliseconds(160))

            withAnimation(.spring(duration: 0.12, bounce: 0.1)) {
                leftEye.offsetY = 0
                rightEye.offsetY = 0
                // Squish on landing
                leftEye.scaleX = 1.08
                leftEye.scaleY = 0.88
                rightEye.scaleX = 1.08
                rightEye.scaleY = 0.88
            }
            try? await Task.sleep(for: .milliseconds(100))

            withAnimation(.spring(duration: 0.1)) {
                leftEye.scaleX = 1
                leftEye.scaleY = 1
                rightEye.scaleX = 1
                rightEye.scaleY = 1
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        resetEyes()
    }

    // MARK: - Sleepy

    private func doSleepy() async {
        // Eyelids droop slowly
        withAnimation(.easeInOut(duration: 1.0)) {
            leftEye.scaleY = 0.3
            rightEye.scaleY = 0.3
            leftEye.offsetY = step * 0.5
            rightEye.offsetY = step * 0.5
        }
        try? await Task.sleep(for: .milliseconds(1200))

        // Almost closed...
        withAnimation(.easeInOut(duration: 0.8)) {
            leftEye.scaleY = 0.1
            rightEye.scaleY = 0.1
        }
        try? await Task.sleep(for: .milliseconds(Int.random(in: 800...1500)))

        // Snap awake!
        withAnimation(.spring(duration: 0.18, bounce: 0.4)) {
            leftEye.scaleX = 1.3
            leftEye.scaleY = 1.3
            rightEye.scaleX = 1.3
            rightEye.scaleY = 1.3
            leftEye.offsetY = 0
            rightEye.offsetY = 0
        }
        try? await Task.sleep(for: .milliseconds(300))

        withAnimation(.easeOut(duration: 0.25)) {
            resetEyes()
        }
        try? await Task.sleep(for: .milliseconds(250))
    }

    // MARK: - Shy (hide to one side)

    private func doShy() async {
        let dir: CGFloat = Bool.random() ? 1 : -1

        withAnimation(.easeInOut(duration: 0.4)) {
            leftEye.offsetX = step * 3 * dir
            rightEye.offsetX = step * 3 * dir
            leftEye.scaleX = 0.7
            leftEye.scaleY = 0.7
            rightEye.scaleX = 0.7
            rightEye.scaleY = 0.7
        }
        try? await Task.sleep(for: .milliseconds(Int.random(in: 800...1500)))

        // Peek back a little
        withAnimation(.easeInOut(duration: 0.3)) {
            leftEye.offsetX = step * 1.5 * dir
            rightEye.offsetX = step * 1.5 * dir
            leftEye.scaleX = 0.85
            leftEye.scaleY = 0.85
            rightEye.scaleX = 0.85
            rightEye.scaleY = 0.85
        }
        try? await Task.sleep(for: .milliseconds(500))

        withAnimation(.spring(duration: 0.25, bounce: 0.15)) {
            resetEyes()
        }
        try? await Task.sleep(for: .milliseconds(300))
    }

    // MARK: - Cross-eyed

    private func doCrossEyed() async {
        withAnimation(.spring(duration: 0.2, bounce: 0.2)) {
            leftEye.offsetX = step * 1.5
            rightEye.offsetX = -step * 1.5
        }
        try? await Task.sleep(for: .milliseconds(Int.random(in: 600...1200)))

        // Shake it off
        withAnimation(.spring(duration: 0.15, bounce: 0.3)) {
            leftEye.offsetX = -step * 0.5
            rightEye.offsetX = step * 0.5
        }
        try? await Task.sleep(for: .milliseconds(120))

        withAnimation(.spring(duration: 0.2, bounce: 0.1)) {
            resetEyes()
        }
        try? await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - Eye roll (dramatic)

    private func doEyeRoll() async {
        // Look down first
        withAnimation(.easeInOut(duration: 0.2)) {
            leftEye.offsetY = step * 1.2
            rightEye.offsetY = step * 1.2
        }
        try? await Task.sleep(for: .milliseconds(200))

        // Roll up slowly (the classic eye roll)
        withAnimation(.easeInOut(duration: 0.5)) {
            leftEye.offsetY = -step * 2
            rightEye.offsetY = -step * 2
            leftEye.scaleY = 0.85
            rightEye.scaleY = 0.85
        }
        try? await Task.sleep(for: .milliseconds(Int.random(in: 600...1000)))

        // Come back with a half-close (unimpressed)
        withAnimation(.easeInOut(duration: 0.3)) {
            leftEye.offsetY = 0
            rightEye.offsetY = 0
            leftEye.scaleY = 0.6
            rightEye.scaleY = 0.6
        }
        try? await Task.sleep(for: .milliseconds(500))

        withAnimation(.easeOut(duration: 0.3)) {
            resetEyes()
        }
        try? await Task.sleep(for: .milliseconds(300))
    }

    // MARK: - Peek (hide and seek)

    private func doPeek() async {
        // Both eyes shrink away
        withAnimation(.easeIn(duration: 0.3)) {
            leftEye.scaleX = 0
            leftEye.scaleY = 0
            rightEye.scaleX = 0
            rightEye.scaleY = 0
        }
        try? await Task.sleep(for: .milliseconds(Int.random(in: 500...900)))

        // One eye peeks out
        withAnimation(.spring(duration: 0.2, bounce: 0.3)) {
            rightEye.scaleX = 0.8
            rightEye.scaleY = 0.8
        }
        try? await Task.sleep(for: .milliseconds(400))

        // Other eye joins
        withAnimation(.spring(duration: 0.2, bounce: 0.3)) {
            leftEye.scaleX = 0.8
            leftEye.scaleY = 0.8
        }
        try? await Task.sleep(for: .milliseconds(300))

        // Both back to full
        withAnimation(.spring(duration: 0.2, bounce: 0.25)) {
            resetEyes()
        }
        try? await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - Head shake (nope)

    private func doHeadShake() async {
        let shakes = Int.random(in: 2...3)
        let dist = step * 1.5

        for _ in 0..<shakes {
            withAnimation(.easeInOut(duration: 0.1)) {
                leftEye.offsetX = -dist
                rightEye.offsetX = -dist
            }
            try? await Task.sleep(for: .milliseconds(110))

            withAnimation(.easeInOut(duration: 0.1)) {
                leftEye.offsetX = dist
                rightEye.offsetX = dist
            }
            try? await Task.sleep(for: .milliseconds(110))
        }

        withAnimation(.spring(duration: 0.15, bounce: 0.1)) {
            resetEyes()
        }
        try? await Task.sleep(for: .milliseconds(150))
    }

    // MARK: - Excited (vibrate + grow)

    private func doExcited() async {
        // Grow with excitement
        withAnimation(.spring(duration: 0.15, bounce: 0.3)) {
            leftEye.scaleX = 1.15
            leftEye.scaleY = 1.15
            rightEye.scaleX = 1.15
            rightEye.scaleY = 1.15
        }
        try? await Task.sleep(for: .milliseconds(150))

        // Rapid tiny vibrations
        for _ in 0..<6 {
            let jx = CGFloat.random(in: -step * 0.5...step * 0.5)
            let jy = CGFloat.random(in: -step * 0.4...step * 0.4)
            withAnimation(.linear(duration: 0.04)) {
                leftEye.offsetX = jx
                leftEye.offsetY = jy
                rightEye.offsetX = jx + CGFloat.random(in: -step * 0.2...step * 0.2)
                rightEye.offsetY = jy + CGFloat.random(in: -step * 0.2...step * 0.2)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        // Settle back down
        withAnimation(.spring(duration: 0.25, bounce: 0.15)) {
            resetEyes()
        }
        try? await Task.sleep(for: .milliseconds(250))
    }

    // MARK: - Shape morph (heart / star)

    private enum MorphShape {
        case none, heart, star
    }

    @ViewBuilder
    private var morphIcon: some View {
        switch morphShape {
        case .heart: Image(systemName: "heart.fill")
        case .star:  Image(systemName: "star.fill")
        case .none:  EmptyView()
        }
    }

    private func doMorph(_ shape: MorphShape) async {
        morphShape = shape

        // Eyes shrink in place, shapes fade in on top
        withAnimation(.easeInOut(duration: 0.3)) {
            leftEye.scaleX = 0.3
            leftEye.scaleY = 0.3
            rightEye.scaleX = 0.3
            rightEye.scaleY = 0.3
            eyesOpacity = 0
            morphOpacity = 1
        }
        try? await Task.sleep(for: .milliseconds(Int.random(in: 1200...2200)))

        // Shapes fade out, eyes grow back
        withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
            resetEyes()
            eyesOpacity = 1
            morphOpacity = 0
        }
        try? await Task.sleep(for: .milliseconds(350))
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
