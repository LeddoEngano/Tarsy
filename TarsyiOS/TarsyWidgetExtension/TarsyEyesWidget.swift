import SwiftUI

/// Tiny animated Tarsy eyes for Live Activity / Dynamic Island.
/// Matches the real logo: two solid white circles on dark background.
/// A small dark pupil moves based on `pupilX` / `pupilY` from ContentState;
/// SwiftUI automatically animates the offset change between updates.
struct TarsyEyesWidget: View {
    let size: CGFloat
    /// Normalized pupil offset (-1…1)
    let pupilX: Double
    let pupilY: Double

    var body: some View {
        HStack(spacing: size * 0.12) {
            eye(diameter: size * 0.38)
            eye(diameter: size * 0.42)
        }
        .offset(y: -size * 0.04)
    }

    @ViewBuilder
    private func eye(diameter: CGFloat) -> some View {
        let maxOffset = diameter * 0.2
        ZStack {
            // White eye — solid, matching the logo
            Circle()
                .fill(.white)
                .frame(width: diameter, height: diameter)

            // Dark pupil — moves with state updates
            Circle()
                .fill(Color(red: 0.04, green: 0.04, blue: 0.04))
                .frame(width: diameter * 0.4, height: diameter * 0.4)
                .offset(
                    x: maxOffset * pupilX,
                    y: maxOffset * pupilY
                )
        }
    }
}
