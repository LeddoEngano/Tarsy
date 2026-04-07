import SwiftUI
import CryptoKit

struct TextToolsView: View {
    @State private var selectedTool: Tool = .base64

    enum Tool: String, CaseIterable {
        case base64 = "Base64"
        case jwt = "JWT"
        case sha256 = "SHA256"
        case json = "JSON"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tool picker
            HStack(spacing: 0) {
                ForEach(Tool.allCases, id: \.self) { tool in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { selectedTool = tool }
                    } label: {
                        Text(tool.rawValue)
                            .font(TarsyTheme.font(size: 11, weight: .medium))
                            .foregroundColor(selectedTool == tool ? TarsyTheme.textPrimary : TarsyTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(selectedTool == tool ? TarsyTheme.backgroundTertiary : Color.clear)
                            .cornerRadius(6)
                    }
                }
            }
            .padding(4)
            .background(TarsyTheme.backgroundSecondary)
            .cornerRadius(8)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            switch selectedTool {
            case .base64: Base64ToolView()
            case .jwt: JWTToolView()
            case .sha256: SHA256ToolView()
            case .json: JSONToolView()
            }
        }
        .background(TarsyTheme.backgroundPrimary)
    }
}

// MARK: - Base64

private struct Base64ToolView: View {
    @State private var input = ""
    @State private var isEncoding = true

    private var output: String {
        guard !input.isEmpty else { return "" }
        if isEncoding {
            return Data(input.utf8).base64EncodedString()
        } else {
            guard let data = Data(base64Encoded: input),
                  let str = String(data: data, encoding: .utf8) else {
                return "(invalid base64)"
            }
            return str
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(isEncoding ? "Encode" : "Decode")
                        .font(TarsyTheme.font(size: 12, weight: .semibold))
                        .foregroundColor(TarsyTheme.textPrimary)
                    Spacer()
                    Toggle("", isOn: $isEncoding)
                        .labelsHidden()
                        .tint(TarsyTheme.accentMoss)
                    Text(isEncoding ? "encode" : "decode")
                        .font(TarsyTheme.font(size: 11))
                        .foregroundColor(TarsyTheme.textSecondary)
                }

                textInput("Input", text: $input)
                outputBox("Output", text: output)
            }
            .padding(16)
        }
    }
}

// MARK: - JWT

private struct JWTToolView: View {
    @State private var input = ""

    private var decoded: (header: String, payload: String, expiration: String?)? {
        let parts = input.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        func decodeBase64URL(_ str: String) -> String? {
            var base64 = str.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let remainder = base64.count % 4
            if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
            guard let data = Data(base64Encoded: base64) else { return nil }
            // Pretty-print JSON
            if let json = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
               let str = String(data: pretty, encoding: .utf8) {
                return str
            }
            return String(data: data, encoding: .utf8)
        }

        let header = decodeBase64URL(String(parts[0])) ?? "(invalid)"
        let payload = decodeBase64URL(String(parts[1])) ?? "(invalid)"

        // Check exp claim
        var expiration: String? = nil
        if let payloadData = decodeBase64URL(String(parts[1]))?.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
           let exp = json["exp"] as? Double {
            let date = Date(timeIntervalSince1970: exp)
            if date > Date() {
                let diff = date.timeIntervalSince(Date())
                let hours = Int(diff / 3600)
                expiration = "valid for \(hours)h"
            } else {
                expiration = "expired"
            }
        }

        return (header, payload, expiration)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                textInput("JWT Token", text: $input)

                if let decoded = decoded {
                    sectionHeader("Header")
                    outputBox("", text: decoded.header)

                    sectionHeader("Payload")
                    outputBox("", text: decoded.payload)

                    if let exp = decoded.expiration {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(exp.contains("valid") ? TarsyTheme.accentMoss : TarsyTheme.accentTerracotta)
                                .frame(width: 6, height: 6)
                            Text(exp)
                                .font(TarsyTheme.font(size: 11))
                                .foregroundColor(exp.contains("valid") ? TarsyTheme.accentMoss : TarsyTheme.accentTerracotta)
                        }
                    }
                } else if !input.isEmpty {
                    Text("invalid JWT format")
                        .font(TarsyTheme.font(size: 11))
                        .foregroundColor(TarsyTheme.accentTerracotta)
                }
            }
            .padding(16)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(TarsyTheme.font(size: 11, weight: .semibold))
            .foregroundColor(TarsyTheme.textSecondary)
            .padding(.top, 4)
    }
}

// MARK: - SHA256

private struct SHA256ToolView: View {
    @State private var input = ""

    private var hash: String {
        guard !input.isEmpty else { return "" }
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                textInput("Input", text: $input)
                outputBox("SHA256 Hash", text: hash)
            }
            .padding(16)
        }
    }
}

// MARK: - JSON

private struct JSONToolView: View {
    @State private var input = ""
    @State private var isPretty = true

    private var output: (text: String, isError: Bool) {
        guard !input.isEmpty else { return ("", false) }
        guard let data = input.data(using: .utf8) else { return ("invalid input", true) }
        do {
            let json = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            let options: JSONSerialization.WritingOptions = isPretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
            let output = try JSONSerialization.data(withJSONObject: json, options: options)
            return (String(data: output, encoding: .utf8) ?? "", false)
        } catch {
            return ("invalid JSON: \(error.localizedDescription)", true)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Format / Minify")
                        .font(TarsyTheme.font(size: 12, weight: .semibold))
                        .foregroundColor(TarsyTheme.textPrimary)
                    Spacer()
                    Toggle("", isOn: $isPretty)
                        .labelsHidden()
                        .tint(TarsyTheme.accentMoss)
                    Text(isPretty ? "pretty" : "minified")
                        .font(TarsyTheme.font(size: 11))
                        .foregroundColor(TarsyTheme.textSecondary)
                }

                textInput("JSON Input", text: $input)

                if output.isError {
                    Text(output.text)
                        .font(TarsyTheme.font(size: 11))
                        .foregroundColor(TarsyTheme.accentTerracotta)
                } else {
                    outputBox("Output", text: output.text)
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Shared Components

private func textInput(_ placeholder: String, text: Binding<String>) -> some View {
    TextEditor(text: text)
        .font(TarsyTheme.font(size: 12))
        .foregroundColor(TarsyTheme.textPrimary)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 80, maxHeight: 120)
        .padding(10)
        .background(TarsyTheme.backgroundSecondary)
        .cornerRadius(8)
        .overlay(
            Group {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(TarsyTheme.font(size: 12))
                        .foregroundColor(TarsyTheme.textSecondary.opacity(0.5))
                        .padding(14)
                }
            },
            alignment: .topLeading
        )
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
}

private func outputBox(_ label: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        if !label.isEmpty {
            Text(label)
                .font(TarsyTheme.font(size: 10, weight: .semibold))
                .foregroundColor(TarsyTheme.textSecondary)
        }

        HStack {
            Text(text.isEmpty ? " " : text)
                .font(TarsyTheme.font(size: 12))
                .foregroundColor(TarsyTheme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !text.isEmpty {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundColor(TarsyTheme.textSecondary)
                }
            }
        }
        .padding(10)
        .background(TarsyTheme.backgroundTertiary)
        .cornerRadius(8)
    }
}
