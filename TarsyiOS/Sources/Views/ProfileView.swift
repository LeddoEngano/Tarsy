import SwiftUI
import TarsyShared
import StoreKit
import Security

struct ProfileView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var profileService: ProfileService
    @EnvironmentObject var connectionManager: ConnectionManager

    @State private var apiKeys: [APIKeyEntry] = []
    @State private var editingProvider: AIEngineType?
    @State private var showPaywall = false
    @State private var permissionConfig = AgentPermissionConfig.load()
    @State private var displayNameInput = ""
    @State private var isEditingName = false
    @State private var showDeleteConfirmation = false
    @State private var deleteConfirmText = ""
    @State private var isDeleting = false
    @State private var showVoiceLanguagePicker = false

    var body: some View {
        NavigationStack {
            ZStack {
                TarsyTheme.backgroundPrimary.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        profileHeader
                        subscriptionSection
                        agentPermissionsSection
                        voiceInputSection
                        legalSection
                        aboutSection
                        accountSection
                        deleteAccountSection
                    }
                    .padding(16)
                }
            }
            .navigationTitle("profile")
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
        .onAppear { loadKeys() }
        .sheet(item: $editingProvider) { provider in
            APIKeyEditorSheet(provider: provider, existingKey: getKeyForProvider(provider)) { newKey in
                saveKey(newKey, for: provider)
                editingProvider = nil
            } onDelete: {
                deleteKey(for: provider)
                editingProvider = nil
            }
        }
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView()
        }
        .alert("delete account", isPresented: $showDeleteConfirmation) {
            TextField("type DELETE to confirm", text: $deleteConfirmText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("delete", role: .destructive) {
                if deleteConfirmText == "DELETE" {
                    performDeleteAccount()
                }
            }
            Button("cancel", role: .cancel) {
                deleteConfirmText = ""
            }
        } message: {
            Text("This will permanently delete your account and all associated data. This action cannot be undone.\n\nIf you have an active subscription, please cancel it first in your App Store settings.")
        }
    }

    // MARK: - Profile Header

    private var profileHeader: some View {
        VStack(spacing: 1) {
            HStack(spacing: 14) {
                if let avatarUrlStr = profileService.profile?.avatarUrl, let url = URL(string: avatarUrlStr) {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(TarsyTheme.textSecondary)
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(Circle())
                } else {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .frame(width: 56, height: 56)
                }

                VStack(alignment: .leading, spacing: 4) {
                    if isEditingName {
                        TextField("display name", text: $displayNameInput)
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundColor(TarsyTheme.textPrimary)
                            .textFieldStyle(.plain)
                            .onSubmit {
                                isEditingName = false
                                Task {
                                    await profileService.updateDisplayName(displayNameInput)
                                }
                            }
                    } else {
                        if let name = profileService.profile?.displayName, !name.isEmpty {
                            Text("hello, \(name)!")
                                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .foregroundColor(TarsyTheme.textPrimary)
                        } else {
                            Text(profileService.profile?.email ?? "")
                                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .foregroundColor(TarsyTheme.textPrimary)
                        }
                    }

                    if let email = profileService.profile?.email {
                        Text(email)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(TarsyTheme.textSecondary)
                    }
                }

                Spacer()

                Button(action: {
                    displayNameInput = profileService.profile?.displayName ?? ""
                    isEditingName.toggle()
                }) {
                    Text(isEditingName ? "done" : "edit")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(TarsyTheme.accentAmber)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(TarsyTheme.accentAmber.opacity(0.15))
                        .cornerRadius(6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(TarsyTheme.backgroundSecondary)
        }
        .cornerRadius(10)
    }

    // MARK: - Subscription

    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Subscription")

            VStack(spacing: 1) {
                Button(action: {
                    if !subscriptionManager.isPro {
                        showPaywall = true
                    }
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: subscriptionManager.isPro ? "crown.fill" : "crown")
                            .font(.system(size: 16))
                            .foregroundColor(subscriptionManager.isPro ? TarsyTheme.accentAmber : TarsyTheme.textSecondary)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(subscriptionManager.isPro ? "Tarsy Pro" : "Free Plan")
                                .font(TarsyTheme.monoFontSmall)
                                .foregroundColor(TarsyTheme.textPrimary)

                            if subscriptionManager.isPro, let exp = subscriptionManager.expirationDate {
                                Text("renews \(exp.formatted(.dateTime.month().day()))")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(TarsyTheme.textSecondary)
                            } else {
                                Text("1 workspace limit")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(TarsyTheme.textSecondary)
                            }
                        }

                        Spacer()

                        if subscriptionManager.isPro {
                            Text("active")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(TarsyTheme.accentMoss)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(TarsyTheme.accentMoss.opacity(0.15))
                                .cornerRadius(4)
                        } else {
                            Text("upgrade")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(TarsyTheme.accentAmber)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(TarsyTheme.accentAmber.opacity(0.15))
                                .cornerRadius(4)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(TarsyTheme.backgroundSecondary)
                }

                if subscriptionManager.isPro {
                    Button(action: { openSubscriptionManagement() }) {
                        HStack(spacing: 12) {
                            Image(systemName: "gear")
                                .font(.system(size: 14))
                                .foregroundColor(TarsyTheme.textSecondary)
                                .frame(width: 28)

                            Text("Manage Subscription")
                                .font(TarsyTheme.monoFontSmall)
                                .foregroundColor(TarsyTheme.textPrimary)

                            Spacer()

                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10))
                                .foregroundColor(TarsyTheme.textSecondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(TarsyTheme.backgroundSecondary)
                    }
                }

                Button(action: { Task { try? await AppStore.sync() } }) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14))
                            .foregroundColor(TarsyTheme.textSecondary)
                            .frame(width: 28)

                        Text("Restore Purchases")
                            .font(TarsyTheme.monoFontSmall)
                            .foregroundColor(TarsyTheme.textPrimary)

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(TarsyTheme.backgroundSecondary)
                }
            }
            .cornerRadius(10)
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Settings")

            VStack(spacing: 1) {
                // AI Provider Keys
                ForEach(AIEngineType.allCases.filter { $0.envKeyName != nil }, id: \.self) { engine in
                    apiKeyRow(engine)
                }
            }
            .cornerRadius(10)

            Text("API keys are stored in the device Keychain.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(TarsyTheme.textSecondary)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Agent Permissions

    private var agentPermissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Agent Permissions")

            VStack(spacing: 1) {
                ForEach(connectionManager.detectedAgents.isEmpty ? [AIEngineType.claude] : connectionManager.detectedAgents, id: \.self) { engine in
                    HStack(spacing: 12) {
                        AgentIcon(engineType: engine, size: 18)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.displayName)
                                .font(TarsyTheme.monoFontSmall)
                                .foregroundColor(TarsyTheme.textPrimary)
                            Text(permissionConfig.mode(for: engine) == .dangerous ? "auto mode" : "safe mode")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(TarsyTheme.textSecondary)
                        }

                        Spacer()

                        Button {
                            let current = permissionConfig.mode(for: engine)
                            let newMode: AgentPermissionConfig.PermissionMode = current == .dangerous ? .safe : .dangerous
                            permissionConfig.setMode(newMode, for: engine)
                            permissionConfig.save()
                            Task {
                                let perms = [
                                    "claude": permissionConfig.claude.rawValue,
                                    "codex": permissionConfig.codex.rawValue,
                                    "gemini": permissionConfig.gemini.rawValue,
                                    "aider": permissionConfig.aider.rawValue
                                ]
                                await profileService.updateAgentPermissions(perms)
                            }
                        } label: {
                            Text(permissionConfig.mode(for: engine) == .dangerous ? "auto" : "safe")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(permissionConfig.mode(for: engine) == .dangerous ? TarsyTheme.accentTerracotta : TarsyTheme.accentMoss)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    (permissionConfig.mode(for: engine) == .dangerous ? TarsyTheme.accentTerracotta : TarsyTheme.accentMoss).opacity(0.15)
                                )
                                .cornerRadius(6)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(TarsyTheme.backgroundSecondary)
                }
            }
            .cornerRadius(10)
        }
    }

    // MARK: - Voice Input

    private var voiceInputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Voice Input")

            VStack(spacing: 1) {
                voiceLanguageRow
            }
            .cornerRadius(10)
        }
    }

    // MARK: - Legal

    private var legalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Legal")

            VStack(spacing: 1) {
                linkRow("Terms of Use", url: "https://www.tarsy.dev/terms")
                linkRow("Privacy Policy", url: "https://www.tarsy.dev/privacy")
            }
            .cornerRadius(10)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("About")

            VStack(spacing: 1) {
                infoRow("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            }
            .cornerRadius(10)
        }
    }

    // MARK: - Account (Sign Out + Delete)

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Account")

            VStack(spacing: 1) {
                Button(action: {
                    Task { await authManager.signOut() }
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 14))
                            .foregroundColor(TarsyTheme.textPrimary)
                            .frame(width: 28)

                        Text("Sign Out")
                            .font(TarsyTheme.monoFontSmall)
                            .foregroundColor(TarsyTheme.textPrimary)

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(TarsyTheme.backgroundSecondary)
                }
            }
            .cornerRadius(10)
        }
    }

    // MARK: - Delete Account (Danger Zone)

    private var deleteAccountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Danger Zone")

            Button(action: { showDeleteConfirmation = true }) {
                HStack(spacing: 12) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundColor(TarsyTheme.accentTerracotta)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delete Account")
                            .font(TarsyTheme.monoFontSmall)
                            .foregroundColor(TarsyTheme.accentTerracotta)
                        Text("permanently remove all data")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(TarsyTheme.textSecondary)
                    }

                    Spacer()

                    if isDeleting {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(TarsyTheme.accentTerracotta)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(TarsyTheme.backgroundSecondary)
            }
            .disabled(isDeleting)
            .cornerRadius(10)
        }
        .padding(.top, 16)
        .padding(.bottom, 32)
    }

    // MARK: - Components

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(TarsyTheme.textSecondary)
            .padding(.leading, 4)
    }

    private func apiKeyRow(_ engine: AIEngineType) -> some View {
        Button(action: { editingProvider = engine }) {
            HStack(spacing: 12) {
                AgentIcon(engineType: engine, size: 20)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.displayName)
                        .font(TarsyTheme.monoFontSmall)
                        .foregroundColor(TarsyTheme.textPrimary)

                    Text(engine.envKeyName ?? "")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary)
                }

                Spacer()

                if hasKey(for: engine) {
                    HStack(spacing: 4) {
                        Circle().fill(TarsyTheme.accentMoss).frame(width: 6, height: 6)
                        Text("configured")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(TarsyTheme.accentMoss)
                    }
                } else {
                    Text("not set")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(TarsyTheme.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(TarsyTheme.backgroundSecondary)
        }
    }

    private func linkRow(_ title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 14))
                    .foregroundColor(TarsyTheme.textSecondary)
                    .frame(width: 28)

                Text(title)
                    .font(TarsyTheme.monoFontSmall)
                    .foregroundColor(TarsyTheme.textPrimary)

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundColor(TarsyTheme.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(TarsyTheme.backgroundSecondary)
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(TarsyTheme.monoFontSmall)
                .foregroundColor(TarsyTheme.textPrimary)
            Spacer()
            Text(value)
                .font(TarsyTheme.monoFontSmall)
                .foregroundColor(TarsyTheme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(TarsyTheme.backgroundSecondary)
    }

    private var currentVoiceLanguageName: String {
        let code = UserDefaults.standard.string(forKey: VoiceInputManager.languageKey) ?? ""
        return VoiceInputManager.supportedLanguages.first(where: { $0.code == code })?.name ?? "Not set"
    }

    private var voiceLanguageRow: some View {
        Button(action: { showVoiceLanguagePicker = true }) {
            HStack(spacing: 12) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 16))
                    .foregroundColor(TarsyTheme.accentAmber)
                    .frame(width: 28)

                Text("Language")
                    .font(TarsyTheme.monoFontSmall)
                    .foregroundColor(TarsyTheme.textPrimary)

                Spacer()

                Text(currentVoiceLanguageName)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(TarsyTheme.textSecondary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(TarsyTheme.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(TarsyTheme.backgroundSecondary)
        }
        .confirmationDialog("Voice Language", isPresented: $showVoiceLanguagePicker, titleVisibility: .visible) {
            ForEach(VoiceInputManager.supportedLanguages, id: \.code) { lang in
                Button(lang.name) {
                    UserDefaults.standard.set(lang.code, forKey: VoiceInputManager.languageKey)
                    Task {
                        await profileService.updateVoiceLanguage(lang.code)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Actions

    private func openSubscriptionManagement() {
        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
            UIApplication.shared.open(url)
        }
    }

    private func performDeleteAccount() {
        isDeleting = true
        Task {
            do {
                try await profileService.deleteAccount()
                await authManager.signOut()
            } catch {
                print("[ProfileView] Delete account error: \(error)")
            }
            isDeleting = false
        }
    }

    // MARK: - Keychain

    private func loadKeys() {
        apiKeys = AIEngineType.allCases.compactMap { engine in
            guard let envKey = engine.envKeyName else { return nil }
            let key = KeychainHelper.load(key: envKey)
            return APIKeyEntry(provider: engine, key: key)
        }
    }

    private func hasKey(for engine: AIEngineType) -> Bool {
        guard let envKey = engine.envKeyName else { return false }
        return KeychainHelper.load(key: envKey) != nil
    }

    private func getKeyForProvider(_ engine: AIEngineType) -> String? {
        guard let envKey = engine.envKeyName else { return nil }
        return KeychainHelper.load(key: envKey)
    }

    private func saveKey(_ key: String, for engine: AIEngineType) {
        guard let envKey = engine.envKeyName else { return }
        KeychainHelper.save(key: envKey, value: key)
        loadKeys()
    }

    private func deleteKey(for engine: AIEngineType) {
        guard let envKey = engine.envKeyName else { return }
        KeychainHelper.delete(key: envKey)
        loadKeys()
    }
}
