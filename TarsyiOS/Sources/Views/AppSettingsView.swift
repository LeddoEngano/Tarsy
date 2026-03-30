import SwiftUI
import TarsyShared
import Security

struct AppSettingsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var connectionManager: ConnectionManager
    @EnvironmentObject var profileService: ProfileService
    @State private var apiKeys: [APIKeyEntry] = []
    @State private var editingProvider: AIEngineType?
    @State private var keyInput = ""
    @State private var showPaywall = false
    @State private var showMCPStore = false
    @State private var permissionConfig = AgentPermissionConfig.load()
    @State private var displayNameInput = ""
    @State private var isEditingName = false


    var body: some View {
        NavigationStack {
            ZStack {
                TarsyTheme.backgroundPrimary.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // Subscription Section
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
                        }
                        .cornerRadius(10)

                        // Profile Section
                        sectionHeader("Profile")

                        VStack(spacing: 1) {
                            HStack(spacing: 12) {
                                if let avatarUrlStr = profileService.profile?.avatarUrl, let url = URL(string: avatarUrlStr) {
                                    AsyncImage(url: url) { image in
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    } placeholder: {
                                        Image(systemName: "person.circle.fill")
                                            .foregroundColor(TarsyTheme.textSecondary)
                                    }
                                    .frame(width: 32, height: 32)
                                    .clipShape(Circle())
                                } else {
                                    Image(systemName: "person.circle.fill")
                                        .font(.system(size: 28))
                                        .foregroundColor(TarsyTheme.textSecondary)
                                        .frame(width: 32, height: 32)
                                }

                                if isEditingName {
                                    TextField("display name", text: $displayNameInput)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(TarsyTheme.textPrimary)
                                        .textFieldStyle(.plain)
                                        .onSubmit {
                                            isEditingName = false
                                            Task {
                                                await profileService.updateDisplayName(displayNameInput)
                                            }
                                        }
                                } else {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profileService.profile?.nameOrEmail ?? "")
                                            .font(.system(size: 13, design: .monospaced))
                                            .foregroundColor(TarsyTheme.textPrimary)
                                        if let email = profileService.profile?.email,
                                           profileService.profile?.displayName != nil {
                                            Text(email)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(TarsyTheme.textSecondary)
                                        }
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
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(TarsyTheme.backgroundSecondary)
                        }
                        .cornerRadius(10)

                        // API Keys Section
                        sectionHeader("AI Provider Keys")

                        VStack(spacing: 1) {
                            ForEach(AIEngineType.allCases.filter { $0.envKeyName != nil }, id: \.self) { engine in
                                apiKeyRow(engine)
                            }
                        }
                        .cornerRadius(10)

                        Text("Your API keys are stored securely in the device Keychain and sent to your Mac only when needed.")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(TarsyTheme.textSecondary)
                            .padding(.horizontal, 4)

                        // Agent Permissions
                        sectionHeader("Agent Permissions")

                        VStack(spacing: 1) {
                            ForEach(AIEngineType.allCases.filter { $0 != .custom }, id: \.self) { engine in
                                HStack(spacing: 12) {
                                    AgentIcon(engineType: engine, size: 18)
                                        .frame(width: 28)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(engine.displayName)
                                            .font(TarsyTheme.monoFontSmall)
                                            .foregroundColor(TarsyTheme.textPrimary)
                                        Text(permissionConfig.mode(for: engine) == .dangerous ? "auto mode — runs without asking" : "safe mode — asks before actions")
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

                        Text("Auto mode lets agents execute without permission prompts. Safe mode requires approval for each action.")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(TarsyTheme.textSecondary)
                            .padding(.horizontal, 4)

                        // Voice Language
                        sectionHeader("Voice Input")

                        VStack(spacing: 1) {
                            voiceLanguageRow
                        }
                        .cornerRadius(10)

                        // About Section
                        sectionHeader("About")

                        VStack(spacing: 1) {
                            infoRow("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            infoRow("Model", value: "BYOK (Bring Your Own Key)")
                        }
                        .cornerRadius(10)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("settings")
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
        .sheet(isPresented: $showMCPStore) {
            MCPStoreView(workspacePath: nil)
                .environmentObject(connectionManager)
        }
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

    @State private var showVoiceLanguagePicker = false

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

// MARK: - API Key Editor Sheet

struct APIKeyEditorSheet: View {
    let provider: AIEngineType
    let existingKey: String?
    let onSave: (String) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) var dismiss
    @State private var keyText = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                TarsyTheme.backgroundPrimary.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 20) {
                    // Provider info
                    HStack(spacing: 12) {
                        AgentIcon(engineType: provider, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName)
                                .font(TarsyTheme.monoFont)
                                .foregroundColor(TarsyTheme.textPrimary)
                            Text(provider.envKeyName ?? "")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(TarsyTheme.textSecondary)
                        }
                    }
                    .padding(.top, 8)

                    // Key input
                    VStack(alignment: .leading, spacing: 6) {
                        Text("API Key")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(TarsyTheme.textSecondary)

                        TextField("sk-...", text: $keyText)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(TarsyTheme.textPrimary)
                            .padding(12)
                            .background(TarsyTheme.backgroundSecondary)
                            .cornerRadius(8)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($isFocused)
                    }

                    // Get key link
                    if let url = getKeyURL(for: provider) {
                        Link(destination: url) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 11))
                                Text("Get your \(provider.displayName) API key")
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .foregroundColor(TarsyTheme.accentAmber)
                        }
                    }

                    // Save button
                    Button(action: {
                        guard !keyText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        onSave(keyText.trimmingCharacters(in: .whitespaces))
                    }) {
                        Text("Save Key")
                            .font(TarsyTheme.monoFont)
                            .foregroundColor(TarsyTheme.backgroundPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(keyText.isEmpty ? TarsyTheme.textSecondary : TarsyTheme.accentAmber)
                            .cornerRadius(10)
                    }
                    .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)

                    // Delete button (if key exists)
                    if existingKey != nil {
                        Button(action: { onDelete() }) {
                            Text("Remove Key")
                                .font(TarsyTheme.monoFontSmall)
                                .foregroundColor(TarsyTheme.accentTerracotta)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                    }

                    Spacer()
                }
                .padding(16)
            }
            .navigationTitle(provider.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("cancel") { dismiss() }
                        .foregroundColor(TarsyTheme.textSecondary)
                }
            }
            .toolbarBackground(TarsyTheme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            keyText = existingKey ?? ""
            isFocused = true
        }
    }

    private func getKeyURL(for provider: AIEngineType) -> URL? {
        switch provider {
        case .claude: return URL(string: "https://console.anthropic.com/settings/keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .codex: return URL(string: "https://platform.openai.com/api-keys")
        default: return nil
        }
    }
}

// MARK: - Supporting Types

struct APIKeyEntry: Identifiable {
    let id = UUID()
    let provider: AIEngineType
    let key: String?
}

extension AIEngineType: @retroactive Identifiable {
    public var id: String { rawValue }
}

// MARK: - Keychain Helper

enum KeychainHelper {
    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.tarsy.apikeys"
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.tarsy.apikeys",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.tarsy.apikeys",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
    }
}

#if DEBUG
#Preview {
    PreviewWrapper {
        AppSettingsView()
    }
}
#endif
