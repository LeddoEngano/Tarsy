import SwiftUI
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
                    .font(.system(size: 48))
                    .foregroundColor(TarsyTheme.accentAmber)

                VStack(spacing: 8) {
                    Text("how should we call you?")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(TarsyTheme.textPrimary)

                    Text("we'll use it to personalize your experience")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }

                TextField("your name or nickname", text: $name)
                    .font(.system(size: 16, design: .monospaced))
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
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
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
