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
            try await supabase.auth.signOut(scope: .local)
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

            // Extract full name from Apple credential (only provided on first sign-in)
            let fullName: String? = {
                guard let nameComponents = appleIDCredential.fullName else { return nil }
                let formatter = PersonNameComponentsFormatter()
                let formatted = formatter.string(from: nameComponents).trimmingCharacters(in: .whitespaces)
                return formatted.isEmpty ? nil : formatted
            }()

            do {
                let session = try await supabase.auth.signInWithIdToken(
                    credentials: .init(
                        provider: .apple,
                        idToken: identityToken,
                        nonce: currentNonce
                    )
                )

                // Save Apple-provided name to user metadata so the profile picks it up
                if let fullName {
                    let updatedUser = try? await supabase.auth.update(user: UserAttributes(data: ["full_name": .string(fullName)]))
                    currentUser = updatedUser ?? session.user
                } else {
                    currentUser = session.user
                }
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
            let redirectURL = URL(string: "\(scheme)://login-callback")!

            // Get the OAuth URL from Supabase without opening it
            let oauthURL = try supabase.auth.getOAuthSignInURL(
                provider: .github,
                redirectTo: redirectURL
            )

            // Use ASWebAuthenticationSession — auto-dismisses on callback
            let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let session = ASWebAuthenticationSession(
                    url: oauthURL,
                    callbackURLScheme: scheme
                ) { url, error in
                    if let url {
                        continuation.resume(returning: url)
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: NSError(domain: "AuthManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "OAuth cancelled"]))
                    }
                }
                #if os(macOS)
                session.presentationContextProvider = MacAuthPresenter.shared
                #elseif os(iOS)
                session.presentationContextProvider = IOSAuthPresenter.shared
                #endif
                session.prefersEphemeralWebBrowserSession = false
                session.start()
            }

            // Exchange callback URL for session
            let session = try await supabase.auth.session(from: callbackURL)
            currentUser = session.user
            isAuthenticated = true
        } catch {
            // Check if user cancelled
            let nsError = error as NSError
            if nsError.domain == ASWebAuthenticationSessionErrorDomain,
               nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                // User cancelled — not an error
            } else if let session = try? await supabase.auth.session {
                currentUser = session.user
                isAuthenticated = true
            } else {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    public func handleOAuthCallback(url: URL) async {
        isLoading = true
        errorMessage = nil
        do {
            let session = try await supabase.auth.session(from: url)
            currentUser = session.user
            isAuthenticated = true
        } catch {
            errorMessage = "Login failed: \(error.localizedDescription). If you already have an account with this email via another provider, try logging in with that provider instead."
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

#if os(macOS)
import AppKit

class MacAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = MacAuthPresenter()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? ASPresentationAnchor()
    }
}
#elseif os(iOS)
import UIKit

class IOSAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = IOSAuthPresenter()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }) else {
            return ASPresentationAnchor()
        }
        return window
    }
}
#endif
