import SwiftUI
import WebKit
import TarsyShared

struct NameOnboardingView: View {
    @EnvironmentObject var profileService: ProfileService
    @State private var name = ""
    @State private var isSaving = false
    var onComplete: () -> Void

    var body: some View {
        ZStack {
            TarsyTheme.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                Image(systemName: "person.text.rectangle")
                    .font(TarsyTheme.font(size: 48))
                    .foregroundColor(TarsyTheme.accentAmber)

                VStack(spacing: 8) {
                    Text("how should we call you?")
                        .font(TarsyTheme.font(size: 22, weight: .bold))
                        .foregroundColor(TarsyTheme.textPrimary)

                    Text("we'll use it to personalize your experience")
                        .font(TarsyTheme.font(size: 12))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }

                TextField("your name or nickname", text: $name)
                    .font(TarsyTheme.font(size: 16))
                    .foregroundColor(TarsyTheme.textPrimary)
                    .padding(14)
                    .background(TarsyTheme.backgroundSecondary)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(TarsyTheme.accentAmber.opacity(0.3), lineWidth: 1)
                    )
                    .padding(.horizontal, 32)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)

                Button {
                    guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    isSaving = true
                    Task {
                        await profileService.updateDisplayName(name.trimmingCharacters(in: .whitespaces))
                        isSaving = false
                        onComplete()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                                .tint(TarsyTheme.backgroundPrimary)
                        }
                        Text("continue")
                            .font(TarsyTheme.font(size: 14, weight: .semibold))
                    }
                    .foregroundColor(TarsyTheme.backgroundPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(name.trimmingCharacters(in: .whitespaces).isEmpty ? TarsyTheme.textSecondary.opacity(0.3) : TarsyTheme.accentAmber)
                    .cornerRadius(10)
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                .padding(.horizontal, 32)

                Spacer()
                Spacer()
            }
        }
    }
}

// MARK: - Legal Web View

struct LegalWebView: View {
    let title: String
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebViewRepresentable(url: url)
                .ignoresSafeArea(edges: .bottom)
                .background(TarsyTheme.backgroundPrimary)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                            .font(TarsyTheme.font(size: 14, weight: .semibold))
                            .foregroundColor(TarsyTheme.accentAmber)
                    }
                }
                .toolbarBackground(TarsyTheme.backgroundSecondary, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

#if DEBUG
#Preview {
    NameOnboardingView {}
        .environmentObject(ProfileService())
}
#endif

struct WebViewRepresentable: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(TarsyTheme.backgroundPrimary)
        webView.scrollView.backgroundColor = UIColor(TarsyTheme.backgroundPrimary)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
