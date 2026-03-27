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

    private struct PermissionsUpdate: Encodable {
        let agent_permissions: [String: String]
    }

    public func updateAgentPermissions(_ permissions: [String: String]) async {
        guard let profileId = profile?.id else { return }
        do {
            try await supabase
                .from("profiles")
                .update(PermissionsUpdate(agent_permissions: permissions))
                .eq("id", value: profileId.uuidString)
                .execute()
            profile?.agentPermissions = permissions
        } catch {
            print("[ProfileService] Update permissions error: \(error)")
        }
    }

    private struct SubscriptionUpdate: Encodable {
        let is_pro: Bool
        let subscription_status: String
        let subscription_end_date: String?
    }

    public func updateSubscription(isPro: Bool, status: String, endDate: Date?) async {
        guard let profileId = profile?.id else { return }
        do {
            let update = SubscriptionUpdate(
                is_pro: isPro,
                subscription_status: status,
                subscription_end_date: endDate.map { ISO8601DateFormatter().string(from: $0) }
            )
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

    // MARK: - Email notifications

    public func sendBillingEmail(type: String, endDate: Date? = nil) async {
        guard let profile = profile, !profile.email.isEmpty else { return }

        for attempt in 1...2 {
            do {
                let session = try await supabase.auth.session
                var body: [String: String] = [
                    "email_type": type,
                    "email": profile.email,
                    "display_name": profile.displayName ?? ""
                ]
                if let end = endDate {
                    body["subscription_end_date"] = ISO8601DateFormatter().string(from: end)
                }
                let url = TarsyConfig.supabaseURL.appendingPathComponent("functions/v1/send-email")
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (_, response) = try await URLSession.shared.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200...299).contains(statusCode) {
                    print("[ProfileService] Billing email '\(type)' sent OK (attempt \(attempt))")
                    return
                }
                print("[ProfileService] Billing email '\(type)' failed with status \(statusCode) (attempt \(attempt))")
            } catch {
                print("[ProfileService] Billing email '\(type)' error: \(error) (attempt \(attempt))")
            }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    public func markOnboarded() async {
        guard let profileId = profile?.id else { return }
        do {
            try await supabase
                .from("profiles")
                .update(["onboarded": true])
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
