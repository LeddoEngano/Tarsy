import Foundation
import Supabase

@MainActor
public class ProfileService: ObservableObject {
    @Published public var profile: Profile?
    @Published public var isLoading = false

    public init() {}

    // MARK: - Load

    public func loadProfile() async {
        isLoading = true
        do {
            let userId = try await supabase.auth.session.user.id
            let result: Profile = try await supabase
                .from("profiles")
                .select()
                .eq("id", value: userId.uuidString)
                .single()
                .execute()
                .value
            profile = result
        } catch {
            print("[ProfileService] Load error: \(error)")
            // Profile might not exist yet (pre-trigger users) — try to create it
            await ensureProfileExists()
        }
        isLoading = false
    }

    // MARK: - Update

    public func updateDisplayName(_ name: String) async {
        guard let profileId = profile?.id else { return }
        do {
            try await supabase
                .from("profiles")
                .update(["display_name": name])
                .eq("id", value: profileId.uuidString)
                .execute()
            profile?.displayName = name
        } catch {
            print("[ProfileService] Update name error: \(error)")
        }
    }

    public func updateVoiceLanguage(_ language: String) async {
        guard let profileId = profile?.id else { return }
        do {
            try await supabase
                .from("profiles")
                .update(["voice_language": language])
                .eq("id", value: profileId.uuidString)
                .execute()
            profile?.voiceLanguage = language
        } catch {
            print("[ProfileService] Update voice language error: \(error)")
        }
    }

    public func updateAgentPermissions(_ permissions: [String: String]) async {
        guard let profileId = profile?.id else { return }
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: permissions)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            try await supabase
                .from("profiles")
                .update(["agent_permissions": jsonString])
                .eq("id", value: profileId.uuidString)
                .execute()
            profile?.agentPermissions = permissions
        } catch {
            print("[ProfileService] Update permissions error: \(error)")
        }
    }

    public func updateSubscription(isPro: Bool, status: String, endDate: Date?) async {
        guard let profileId = profile?.id else { return }
        do {
            var update: [String: String] = [
                "is_pro": isPro ? "true" : "false",
                "subscription_status": status
            ]
            if let end = endDate {
                update["subscription_end_date"] = ISO8601DateFormatter().string(from: end)
            }
            try await supabase
                .from("profiles")
                .update(update)
                .eq("id", value: profileId.uuidString)
                .execute()
            profile?.isPro = isPro
            profile?.subscriptionStatus = status
            profile?.subscriptionEndDate = endDate
        } catch {
            print("[ProfileService] Update subscription error: \(error)")
        }
    }

    public func markOnboarded() async {
        guard let profileId = profile?.id else { return }
        do {
            try await supabase
                .from("profiles")
                .update(["onboarded": "true"])
                .eq("id", value: profileId.uuidString)
                .execute()
            profile?.onboarded = true
        } catch {
            print("[ProfileService] Mark onboarded error: \(error)")
        }
    }

    // MARK: - Ensure profile exists

    private func ensureProfileExists() async {
        do {
            let user = try await supabase.auth.session.user
            let newProfile = [
                "id": user.id.uuidString,
                "email": user.email ?? "",
                "display_name": user.userMetadata["full_name"]?.value as? String ?? "",
                "avatar_url": user.userMetadata["avatar_url"]?.value as? String ?? ""
            ]
            let created: Profile = try await supabase
                .from("profiles")
                .upsert(newProfile)
                .select()
                .single()
                .execute()
                .value
            profile = created
        } catch {
            print("[ProfileService] Ensure profile error: \(error)")
        }
    }
}
