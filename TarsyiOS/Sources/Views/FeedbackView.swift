import SwiftUI
import PhotosUI
import TarsyShared

struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var feedbackType: FeedbackType = .feature
    @State private var title = ""
    @State private var details = ""
    @State private var isSubmitting = false
    @State private var showSuccess = false
    @State private var errorMessage: String?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var attachedImage: UIImage?

    enum FeedbackType: String, CaseIterable {
        case bug
        case feature
        case general

        var label: String {
            switch self {
            case .bug: return "bug report"
            case .feature: return "feature request"
            case .general: return "general feedback"
            }
        }

        var icon: String {
            switch self {
            case .bug: return "ladybug"
            case .feature: return "lightbulb"
            case .general: return "text.bubble"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TarsyTheme.backgroundPrimary.ignoresSafeArea()
                    .onTapGesture {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }

                if showSuccess {
                    successView
                } else {
                    formView
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("cancel") { dismiss() }
                        .font(TarsyTheme.font(size: 14))
                        .foregroundColor(TarsyTheme.textSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text("feedback")
                        .font(TarsyTheme.font(size: 16, weight: .semibold))
                        .foregroundColor(TarsyTheme.textPrimary)
                }
            }
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    attachedImage = image
                }
                selectedPhotoItem = nil
            }
        }
    }

    // MARK: - Form

    private var formView: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Type selector
                VStack(alignment: .leading, spacing: 8) {
                    Text("type")
                        .font(TarsyTheme.font(size: 11, weight: .semibold))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .textCase(.uppercase)

                    HStack(spacing: 8) {
                        ForEach(FeedbackType.allCases, id: \.self) { type in
                            let selected = feedbackType == type
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    feedbackType = type
                                }
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: type.icon)
                                        .font(TarsyTheme.font(size: 16))
                                    Text(type.label)
                                        .font(TarsyTheme.font(size: 10))
                                        .multilineTextAlignment(.center)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                }
                                .foregroundColor(selected ? TarsyTheme.textPrimary : TarsyTheme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(selected ? TarsyTheme.backgroundTertiary : TarsyTheme.backgroundSecondary)
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(selected ? TarsyTheme.textSecondary.opacity(0.4) : TarsyTheme.backgroundTertiary, lineWidth: 1)
                                )
                            }
                        }
                    }
                }

                // Title
                VStack(alignment: .leading, spacing: 8) {
                    Text("title")
                        .font(TarsyTheme.font(size: 11, weight: .semibold))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .textCase(.uppercase)

                    TextField("", text: $title, prompt: Text("brief summary").foregroundColor(TarsyTheme.statusIdle))
                        .font(TarsyTheme.font(size: 14))
                        .foregroundColor(TarsyTheme.textPrimary)
                        .padding(12)
                        .background(TarsyTheme.backgroundSecondary)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(TarsyTheme.backgroundTertiary, lineWidth: 1)
                        )
                }

                // Description
                VStack(alignment: .leading, spacing: 8) {
                    Text("description")
                        .font(TarsyTheme.font(size: 11, weight: .semibold))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .textCase(.uppercase)

                    TextEditor(text: $details)
                        .font(TarsyTheme.font(size: 14))
                        .foregroundColor(TarsyTheme.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 120)
                        .padding(12)
                        .background(TarsyTheme.backgroundSecondary)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(TarsyTheme.backgroundTertiary, lineWidth: 1)
                        )
                        .overlay(alignment: .topLeading) {
                            if details.isEmpty {
                                Text("provide as much detail as possible...")
                                    .font(TarsyTheme.font(size: 14))
                                    .foregroundColor(TarsyTheme.statusIdle)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 20)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                // Screenshot attachment
                VStack(alignment: .leading, spacing: 8) {
                    Text("screenshot")
                        .font(TarsyTheme.font(size: 11, weight: .semibold))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .textCase(.uppercase)

                    if let image = attachedImage {
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 200)
                                .cornerRadius(8)

                            Button {
                                withAnimation { attachedImage = nil }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(TarsyTheme.font(size: 20))
                                    .foregroundColor(TarsyTheme.textPrimary)
                                    .background(TarsyTheme.backgroundPrimary.clipShape(Circle()))
                            }
                            .offset(x: -6, y: 6)
                        }
                    } else {
                        PhotosPicker(selection: $selectedPhotoItem, matching: .screenshots) {
                            HStack(spacing: 8) {
                                Image(systemName: "camera")
                                    .font(TarsyTheme.font(size: 14))
                                Text("attach screenshot")
                                    .font(TarsyTheme.font(size: 12))
                            }
                            .foregroundColor(TarsyTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(TarsyTheme.backgroundSecondary)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [6]))
                                    .foregroundColor(TarsyTheme.backgroundTertiary)
                            )
                        }
                    }
                }

                // Error
                if let errorMessage {
                    Text(errorMessage)
                        .font(TarsyTheme.font(size: 12))
                        .foregroundColor(TarsyTheme.statusError)
                }

                // Submit
                Button {
                    Task { await submit() }
                } label: {
                    HStack(spacing: 8) {
                        if isSubmitting {
                            ProgressView()
                                .tint(TarsyTheme.backgroundPrimary)
                                .scaleEffect(0.8)
                        }
                        Text(isSubmitting ? "sending..." : "send feedback")
                            .font(TarsyTheme.font(size: 14, weight: .semibold))
                    }
                    .foregroundColor(TarsyTheme.backgroundPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(canSubmit ? TarsyTheme.textPrimary : TarsyTheme.statusIdle)
                    .cornerRadius(10)
                }
                .disabled(!canSubmit || isSubmitting)
            }
            .padding(16)
        }
    }

    // MARK: - Success

    private var successView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(TarsyTheme.font(size: 48))
                .foregroundColor(TarsyTheme.statusRunning)

            Text("thank you!")
                .font(TarsyTheme.font(size: 20, weight: .bold))
                .foregroundColor(TarsyTheme.textPrimary)

            Text("your feedback has been submitted.\nwe'll review it shortly.")
                .font(TarsyTheme.font(size: 13))
                .foregroundColor(TarsyTheme.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                dismiss()
            } label: {
                Text("done")
                    .font(TarsyTheme.font(size: 14, weight: .semibold))
                    .foregroundColor(TarsyTheme.backgroundPrimary)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(TarsyTheme.textPrimary)
                    .cornerRadius(8)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Logic

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            guard supabase.auth.currentUser != nil else {
                errorMessage = "not authenticated"
                return
            }

            var body: [String: String] = [
                "email_type": "feedback",
                "feedback_type": feedbackType.rawValue,
                "feedback_title": title.trimmingCharacters(in: .whitespacesAndNewlines),
                "feedback_description": details.trimmingCharacters(in: .whitespacesAndNewlines),
                "feedback_platform": "ios",
                "feedback_app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            ]

            // Attach image as base64 JPEG (max ~500KB after compression)
            if let image = attachedImage,
               let jpegData = image.jpegData(compressionQuality: 0.5) {
                let base64 = jpegData.base64EncodedString()
                body["feedback_image_base64"] = base64
            }

            try await supabase.functions.invoke(
                "send-email",
                options: .init(body: body)
            )

            withAnimation {
                showSuccess = true
            }
        } catch {
            errorMessage = "failed to submit: \(error.localizedDescription)"
        }
    }
}
