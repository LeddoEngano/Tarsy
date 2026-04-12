import SwiftUI
import TarsyShared

/// Displays an agent's icon from the Asset Catalog, falling back to SF Symbol.
struct AgentIcon: View {
    let engineType: AIEngineType
    var size: CGFloat = 16

    var body: some View {
        if let asset = engineType.iconAsset {
            Image(asset)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: engineType.iconName)
                .font(TarsyTheme.font(size: size * 0.75))
                .frame(width: size, height: size)
        }
    }
}

#if DEBUG
#Preview("Agent Icons") {
    HStack(spacing: 16) {
        ForEach(AIEngineType.allCases, id: \.self) { engine in
            AgentIcon(engineType: engine, size: 32)
        }
    }
    .padding()
    .background(TarsyTheme.backgroundPrimary)
}
#endif
