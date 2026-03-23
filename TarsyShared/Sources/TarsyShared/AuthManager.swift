import Foundation
import Supabase
import AuthenticationServices

@MainActor
public class AuthManager: ObservableObject {
    @Published public var isAuthenticated = false
    @Published public var isLoading = true
    @Published public var currentUser: User?
    @Published public var errorMessage: String?

    public init() {
        Task {
            await checkSession()
        }
    }

    public func checkSession() async {
        isLoading = true
        do {
            let session = try await supabase.auth.session
            currentUser = session.user
            isAuthenticated = true
        } catch {
            isAuthenticated = false
            currentUser = nil
        }
        isLoading = false
    }

    public func signIn(email: String, password: String) async {
        isLoading = true
        errorMessage = nil
        do {
            let session = try await supabase.auth.signIn(email: email, password: password)
            currentUser = session.user
            isAuthenticated = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    public func signUp(email: String, password: String) async {
        isLoading = true
        errorMessage = nil
        do {
            let response = try await supabase.auth.signUp(email: email, password: password)
            currentUser = response.user
            isAuthenticated = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    public func signOut() async {
        do {
            try await supabase.auth.signOut()
            isAuthenticated = false
            currentUser = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
