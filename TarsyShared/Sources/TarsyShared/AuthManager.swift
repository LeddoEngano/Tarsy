import Foundation
import Supabase
import AuthenticationServices
import CryptoKit

@MainActor
public class AuthManager: ObservableObject {
    @Published public var isAuthenticated = false
    @Published public var isLoading = true
    @Published public var currentUser: User?
    @Published public var errorMessage: String?

    private var currentNonce: String?

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

    // MARK: - Sign in with Apple

    public func generateNonce() -> String {
        let nonce = randomNonceString()
        currentNonce = nonce
        return nonce
    }

    public func handleAppleSignIn(result: Result<ASAuthorization, Error>) async {
        isLoading = true
        errorMessage = nil

        switch result {
        case .success(let authorization):
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityTokenData = appleIDCredential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8) else {
                errorMessage = "Failed to get Apple ID token."
                isLoading = false
                return
            }

            do {
                let session = try await supabase.auth.signInWithIdToken(
                    credentials: .init(
                        provider: .apple,
                        idToken: identityToken,
                        nonce: currentNonce
                    )
                )
                currentUser = session.user
                isAuthenticated = true
            } catch {
                errorMessage = error.localizedDescription
            }

        case .failure(let error):
            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
    }

    // MARK: - Sign in with GitHub

    public func signInWithGitHub() async {
        isLoading = true
        errorMessage = nil
        do {
            #if os(iOS)
            let scheme = "com.tarsy.ios"
            #elseif os(macOS)
            let scheme = "com.tarsy.macos"
            #endif
            try await supabase.auth.signInWithOAuth(
                provider: .github,
                redirectTo: URL(string: "\(scheme)://login-callback")
            )
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    public func handleOAuthCallback(url: URL) async {
        isLoading = true
        errorMessage = nil
        do {
            let session = try await supabase.auth.session(from: url)
            currentUser = session.user
            isAuthenticated = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Helpers

    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        guard errorCode == errSecSuccess else { return "" }
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }

    public func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}
