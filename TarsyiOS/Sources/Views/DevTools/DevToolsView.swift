import SwiftUI
import TarsyShared

struct DevToolsView: View {
    let workspace: Workspace
    @EnvironmentObject var connectionManager: ConnectionManager

    @State private var selectedTool: DevTool = .processAndPorts

    enum DevTool: String, CaseIterable {
        case processAndPorts = "processes"
        case apiClient = "api client"
        case textTools = "text tools"
        case resources = "resources"

        var icon: String {
            switch self {
            case .processAndPorts: return "list.bullet.rectangle"
            case .apiClient: return "arrow.up.right.square"
            case .textTools: return "textformat"
            case .resources: return "gauge.with.dots.needle.33percent"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tool picker
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(DevTool.allCases, id: \.self) { tool in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedTool = tool
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: tool.icon)
                                        .font(TarsyTheme.font(size: 11))
                                    Text(tool.rawValue)
                                        .font(TarsyTheme.font(size: 12, weight: .medium))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(selectedTool == tool ? TarsyTheme.backgroundTertiary : Color.clear)
                                .foregroundColor(selectedTool == tool ? TarsyTheme.textPrimary : TarsyTheme.textSecondary)
                                .cornerRadius(8)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .background(TarsyTheme.backgroundSecondary)

                Divider().background(TarsyTheme.backgroundTertiary)

                // Content
                switch selectedTool {
                case .processAndPorts:
                    ProcessPortsView(workspace: workspace)
                        .environmentObject(connectionManager)
                case .apiClient:
                    APIClientView(workspace: workspace)
                        .environmentObject(connectionManager)
                case .textTools:
                    TextToolsView()
                case .resources:
                    ResourceMonitorView(workspace: workspace)
                        .environmentObject(connectionManager)
                }
            }
            .background(TarsyTheme.backgroundPrimary)
            .navigationTitle("devtools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("devtools")
                        .font(TarsyTheme.monoFont)
                        .foregroundColor(TarsyTheme.textPrimary)
                }
            }
        }
    }
}
