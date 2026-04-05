import SwiftUI

struct AutocompleteItem: Identifiable {
    let id = UUID()
    let icon: String
    let label: String
    let insertText: String
    let description: String
}

struct AutocompleteOverlay: View {
    let items: [AutocompleteItem]
    let onSelect: (AutocompleteItem) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(items.prefix(6).enumerated()), id: \.element.id) { index, item in
                    Button(action: { onSelect(item) }) {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon)
                                .font(TarsyTheme.font(size: 12))
                                .foregroundColor(TarsyTheme.textSecondary)
                                .frame(width: 18)
                            Text(item.label)
                                .font(TarsyTheme.font(size: 14, weight: .medium))
                                .foregroundColor(TarsyTheme.textPrimary)
                            Spacer()
                            Text(item.description)
                                .font(TarsyTheme.font(size: 11))
                                .foregroundColor(TarsyTheme.textSecondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < min(items.count, 6) - 1 {
                        Divider().background(TarsyTheme.textSecondary.opacity(0.15))
                    }
                }
            }
        }
        .frame(maxHeight: 264)
        .background(TarsyTheme.backgroundSecondary)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(TarsyTheme.textSecondary.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 8, y: -4)
    }

    // MARK: - Slash Commands

    static let slashCommands: [AutocompleteItem] = [
        AutocompleteItem(icon: "arrow.triangle.2.circlepath", label: "/compact", insertText: "/compact", description: "Compact context"),
        AutocompleteItem(icon: "questionmark.circle", label: "/help", insertText: "/help", description: "Show commands"),
        AutocompleteItem(icon: "xmark.circle", label: "/clear", insertText: "/clear", description: "Clear conversation"),
        AutocompleteItem(icon: "dollarsign.circle", label: "/cost", insertText: "/cost", description: "Token usage & cost"),
        AutocompleteItem(icon: "cpu", label: "/model", insertText: "/model ", description: "Switch model"),
        AutocompleteItem(icon: "gearshape", label: "/config", insertText: "/config", description: "Edit config"),
        AutocompleteItem(icon: "brain", label: "/memory", insertText: "/memory", description: "Edit memory files"),
        AutocompleteItem(icon: "doc.text.magnifyingglass", label: "/context", insertText: "/context", description: "View context usage"),
        AutocompleteItem(icon: "stethoscope", label: "/doctor", insertText: "/doctor", description: "Check health"),
        AutocompleteItem(icon: "square.and.arrow.up", label: "/export", insertText: "/export", description: "Export conversation"),
        AutocompleteItem(icon: "eye", label: "/review", insertText: "/review", description: "Review changes"),
    ]

    // MARK: - File Icon Helper

    static func iconForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "swift": return "swift"
        case "js", "ts", "jsx", "tsx": return "chevron.left.forwardslash.chevron.right"
        case "py": return "terminal"
        case "json", "yaml", "yml", "toml": return "doc.text"
        case "md", "txt": return "doc.plaintext"
        case "css", "scss": return "paintbrush"
        case "html": return "globe"
        default: return "doc"
        }
    }
}
