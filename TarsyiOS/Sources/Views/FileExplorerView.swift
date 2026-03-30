import SwiftUI
import TarsyShared

struct FileExplorerView: View {
    let workspace: Workspace
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismiss) var dismiss

    @State private var files: [FileEntry] = []
    @State private var searchText = ""
    @State private var expandedDirs: Set<String> = []
    @State private var isLoading = true
    @State private var selectedFile: FilePreviewData?

    var filteredFiles: [FileEntry] {
        if searchText.isEmpty { return files }
        return files.filter { $0.type == "file" && $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundColor(TarsyTheme.textSecondary)
                    TextField("", text: $searchText, prompt: Text("search files...").foregroundColor(TarsyTheme.textSecondary.opacity(0.5)))
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(TarsyTheme.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .padding(10)
                .background(TarsyTheme.backgroundSecondary)
                .cornerRadius(8)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider().background(TarsyTheme.backgroundTertiary)

                if isLoading {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView().tint(TarsyTheme.accentAmber)
                        Text("scanning project...")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(TarsyTheme.textSecondary)
                    }
                    Spacer()
                } else if searchText.isEmpty {
                    treeView
                } else {
                    searchResultsView
                }
            }
            .background(TarsyTheme.backgroundPrimary)
            .navigationTitle("file explorer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done") { dismiss() }
                        .foregroundColor(TarsyTheme.accentAmber)
                }
            }
            .toolbarBackground(TarsyTheme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear { loadTree() }
        .onDisappear { connectionManager.removeListener("files-\(workspace.id)") }
        .sheet(item: $selectedFile) { file in
            FilePreviewView(file: file)
        }
    }

    // MARK: - Tree View

    private var treeView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visibleFiles) { entry in
                    if entry.type == "dir" {
                        dirRow(entry)
                    } else {
                        fileRow(entry)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var visibleFiles: [FileEntry] {
        files.filter { entry in
            if entry.depth == 0 { return true }
            // Check if all parent dirs are expanded
            let components = entry.path.components(separatedBy: "/")
            for i in 1..<components.count {
                let parentPath = components[0..<i].joined(separator: "/")
                if !expandedDirs.contains(parentPath) { return false }
            }
            return true
        }
    }

    private func dirRow(_ entry: FileEntry) -> some View {
        Button(action: { toggleDir(entry.path) }) {
            HStack(spacing: 6) {
                Image(systemName: expandedDirs.contains(entry.path) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(TarsyTheme.textSecondary)
                    .frame(width: 12)

                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundColor(TarsyTheme.accentAmber)

                Text(entry.name)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(TarsyTheme.textPrimary)

                Spacer()
            }
            .padding(.leading, CGFloat(entry.depth) * 16 + 12)
            .padding(.vertical, 6)
            .padding(.trailing, 12)
        }
    }

    private func fileRow(_ entry: FileEntry) -> some View {
        Button(action: { requestFileRead(entry.path) }) {
            HStack(spacing: 6) {
                Color.clear.frame(width: 12) // Align with folder chevron

                Image(systemName: fileIcon(entry.ext))
                    .font(.system(size: 12))
                    .foregroundColor(fileIconColor(entry.ext))

                Text(entry.name)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(TarsyTheme.textSecondary)

                Spacer()
            }
            .padding(.leading, CGFloat(entry.depth) * 16 + 12)
            .padding(.vertical, 5)
            .padding(.trailing, 12)
        }
    }

    // MARK: - Search Results

    private var searchResultsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(filteredFiles) { entry in
                    Button(action: { requestFileRead(entry.path) }) {
                        HStack(spacing: 8) {
                            Image(systemName: fileIcon(entry.ext))
                                .font(.system(size: 12))
                                .foregroundColor(fileIconColor(entry.ext))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(TarsyTheme.textPrimary)
                                Text(entry.path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(TarsyTheme.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(TarsyTheme.backgroundSecondary)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Actions

    private func loadTree() {
        connectionManager.addListener("files-\(workspace.id)") { [self] packet in
            Task { @MainActor in
                switch packet.action {
                case .fileTreeResult:
                    isLoading = false
                    if let json = packet.payload?["tree"],
                       let data = json.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                        files = parsed.map { FileEntry(from: $0) }
                    }
                case .fileReadResult:
                    if packet.payload?["success"] == "true",
                       let content = packet.payload?["content"],
                       let file = packet.payload?["file"],
                       let language = packet.payload?["language"] {
                        selectedFile = FilePreviewData(file: file, content: content, language: language)
                    }
                default: break
                }
            }
        }
        connectionManager.send(WSPacket(action: .fileTree, payload: ["path": workspace.localPath]))
    }

    private func toggleDir(_ path: String) {
        if expandedDirs.contains(path) {
            expandedDirs.remove(path)
        } else {
            expandedDirs.insert(path)
        }
    }

    private func requestFileRead(_ path: String) {
        connectionManager.send(WSPacket(action: .fileRead, payload: ["path": workspace.localPath, "file": path]))
    }

    // MARK: - File Icons

    private func fileIcon(_ ext: String) -> String {
        switch ext.lowercased() {
        case "swift": return "swift"
        case "js", "jsx", "ts", "tsx": return "curlybraces"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml": return "doc.text"
        case "md", "markdown": return "doc.richtext"
        case "html", "css", "scss": return "globe"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        default: return "doc"
        }
    }

    private func fileIconColor(_ ext: String) -> Color {
        switch ext.lowercased() {
        case "swift": return .orange
        case "js", "jsx": return .yellow
        case "ts", "tsx": return .blue
        case "py": return .green
        case "json": return .yellow
        case "md": return .gray
        default: return TarsyTheme.textSecondary
        }
    }
}

// MARK: - File Entry

struct FileEntry: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let type: String
    let ext: String
    let depth: Int

    init(from dict: [String: Any]) {
        self.name = dict["name"] as? String ?? ""
        self.path = dict["path"] as? String ?? ""
        self.type = dict["type"] as? String ?? "file"
        self.ext = dict["ext"] as? String ?? ""
        self.depth = dict["depth"] as? Int ?? 0
    }
}

// MARK: - File Preview

struct FilePreviewData: Identifiable {
    let id = UUID()
    let file: String
    let content: String
    let language: String
}

struct FilePreviewView: View {
    let file: FilePreviewData
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(file.content.components(separatedBy: "\n").enumerated()), id: \.offset) { idx, line in
                        HStack(spacing: 0) {
                            Text("\(idx + 1)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(TarsyTheme.textSecondary.opacity(0.3))
                                .frame(width: 36, alignment: .trailing)
                                .padding(.trailing, 8)

                            Text(colorizedLine(line))
                                .font(.system(size: 12, design: .monospaced))
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(TarsyTheme.backgroundPrimary)
            .navigationTitle(file.file)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done") { dismiss() }
                        .foregroundColor(TarsyTheme.accentAmber)
                }
            }
            .toolbarBackground(TarsyTheme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    // Basic syntax colorization
    private func colorizedLine(_ line: String) -> AttributedString {
        var result = AttributedString(line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Comments
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") || trimmed.hasPrefix("--") {
            result.foregroundColor = Color(red: 0.5, green: 0.6, blue: 0.5)
            return result
        }

        // Keywords
        let keywords = ["func ", "let ", "var ", "import ", "class ", "struct ", "enum ", "protocol ",
                        "if ", "else ", "for ", "while ", "return ", "guard ", "switch ", "case ",
                        "def ", "from ", "const ", "function ", "export ", "async ", "await ",
                        "public ", "private ", "static ", "override ", "self", "true", "false", "nil", "null"]

        for kw in keywords {
            if trimmed.hasPrefix(kw) || trimmed.contains(" \(kw)") {
                result.foregroundColor = Color(red: 0.8, green: 0.6, blue: 0.9)
                return result
            }
        }

        // Strings
        if trimmed.contains("\"") {
            result.foregroundColor = Color(red: 0.8, green: 0.7, blue: 0.5)
            return result
        }

        result.foregroundColor = TarsyTheme.textPrimary
        return result
    }
}

#if DEBUG
#Preview {
    FileExplorerView(workspace: PreviewData.workspace)
        .environmentObject(ConnectionManager())
        .preferredColorScheme(.dark)
}
#endif
