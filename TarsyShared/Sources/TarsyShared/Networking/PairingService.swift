import Foundation
import Supabase

/// Handles QR code-based machine pairing.
/// macOS uses `generatePairingToken()` to create tokens and display QR codes.
/// iOS uses `claimMachine()` to claim a machine via token or connection code.
@MainActor
public class PairingService: ObservableObject {
    @Published public var currentToken: String?
    @Published public var currentConnectionCode: String?
    @Published public var expiresAt: Date?
    @Published public var isPairing = false
    @Published public var pairingError: String?

    public init() {}

    // MARK: - macOS: Generate Pairing Token

    /// Response from the create_machine_pairing RPC. Dates come back as
    /// ISO8601 strings (Postgres jsonb_build_object format) and are parsed
    /// manually — Supabase's default decoder doesn't handle them as Date.
    private struct PairingResponse: Decodable {
        let pairing_token: String
        let connection_code: String
        let expires_at: String
    }

    /// Generates a new pairing token and connection code for the given machine.
    /// The token/code are generated server-side by the create_machine_pairing
    /// RPC; only HMACs are persisted in machine_pairings (plaintext values are
    /// returned once to the caller and never stored). Returns the QR payload URL.
    public func generatePairingToken(machineId: UUID) async throws -> String {
        print("[PairingService] Requesting pairing token for machine \(machineId)")

        let response: PairingResponse = try await supabase
            .rpc("create_machine_pairing", params: ["p_machine_id": machineId.uuidString])
            .execute()
            .value

        let isoWithFraction = ISO8601DateFormatter()
        isoWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        let parsedExpiry = isoWithFraction.date(from: response.expires_at)
            ?? isoPlain.date(from: response.expires_at)
            ?? Date().addingTimeInterval(300)

        currentToken = response.pairing_token
        currentConnectionCode = response.connection_code
        expiresAt = parsedExpiry

        let qrURL = "tarsy://pair?m=\(machineId.uuidString)&t=\(response.pairing_token)"
        print("[PairingService] QR URL generated for machine \(machineId), expires \(parsedExpiry)")
        return qrURL
    }

    /// Generates a fresh pairing token, replacing any previous one for the machine.
    /// The create_machine_pairing RPC already deletes prior rows for the machine,
    /// so this is equivalent to calling `generatePairingToken` directly.
    public func refreshPairingToken(machineId: UUID) async throws -> String {
        return try await generatePairingToken(machineId: machineId)
    }

    // MARK: - iOS: Claim Machine

    /// Claims a machine via QR code (machine_id + pairing_token).
    public func claimMachine(machineId: String, pairingToken: String) async throws -> Machine {
        try await invokeClaimFunction(body: [
            "machine_id": machineId,
            "pairing_token": pairingToken
        ])
    }

    /// Claims a machine via manual connection code (XXXX-XXXX-XXXX).
    public func claimMachineWithCode(_ code: String) async throws -> Machine {
        let cleanCode = code.replacingOccurrences(of: "-", with: "").uppercased()
        return try await invokeClaimFunction(body: [
            "connection_code": cleanCode
        ])
    }

    private func invokeClaimFunction(body: [String: String]) async throws -> Machine {
        isPairing = true
        pairingError = nil
        defer { isPairing = false }

        print("[PairingService] Claiming machine with \(body.count) fields")

        let session = try await supabase.auth.session
        let jsonData = try JSONSerialization.data(withJSONObject: body)

        let url = TarsyConfig.supabaseURL.appendingPathComponent("functions/v1/claim-machine")
        print("[PairingService] POST \(url.absoluteString)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Bearer \(TarsyConfig.supabaseAnonKey)", forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let responseBody = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        print("[PairingService] Response \(httpResponse?.statusCode ?? -1): \(responseBody)")

        guard let httpResponse, httpResponse.statusCode == 200 else {
            let errorResult = try? JSONDecoder().decode(ClaimResponse.self, from: data)
            let errorMsg = errorResult?.error ?? "Failed to claim machine"
            print("[PairingService] Claim failed: \(errorMsg)")
            pairingError = errorMsg
            throw PairingError.claimFailed(errorMsg)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            // Try ISO8601 with fractional seconds, then without
            let formatters: [ISO8601DateFormatter] = {
                let f1 = ISO8601DateFormatter()
                f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let f2 = ISO8601DateFormatter()
                f2.formatOptions = [.withInternetDateTime]
                return [f1, f2]
            }()
            for f in formatters {
                if let date = f.date(from: str) { return date }
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(str)")
        }
        let result = try decoder.decode(ClaimResponse.self, from: data)

        guard result.success, let machine = result.machine else {
            let errorMsg = result.error ?? "Failed to claim machine"
            print("[PairingService] Claim response not successful: \(errorMsg)")
            pairingError = errorMsg
            throw PairingError.claimFailed(errorMsg)
        }

        print("[PairingService] Machine claimed successfully: \(machine.id)")
        return machine
    }

    // MARK: - QR Payload Parsing

    /// Parses a `tarsy://pair?m=...&t=...` URL into machine_id and pairing_token.
    public static func parsePairingURL(_ url: URL) -> (machineId: String, token: String)? {
        guard url.scheme == "tarsy", url.host == "pair" else { return nil }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let machineId = components?.queryItems?.first(where: { $0.name == "m" })?.value,
              let token = components?.queryItems?.first(where: { $0.name == "t" })?.value else {
            return nil
        }

        return (machineId, token)
    }

    // MARK: - Connection Code Formatting

    /// Formats a 12-char hex string as XXXX-XXXX-XXXX for display.
    public static func formatConnectionCode(_ code: String) -> String {
        let clean = code.uppercased().replacingOccurrences(of: "-", with: "")
        guard clean.count == 12 else { return code }
        let idx1 = clean.index(clean.startIndex, offsetBy: 4)
        let idx2 = clean.index(clean.startIndex, offsetBy: 8)
        return "\(clean[clean.startIndex..<idx1])-\(clean[idx1..<idx2])-\(clean[idx2...])"
    }

    // Token + connection code generation moved to the create_machine_pairing
    // RPC (Postgres gen_random_bytes) so all secret material originates in the
    // server and the client never sees a plaintext that hasn't been HMACed.
}

// MARK: - Models

private struct ClaimResponse: Codable {
    let success: Bool
    let machine: Machine?
    let error: String?
}

public enum PairingError: LocalizedError {
    case claimFailed(String)
    case invalidQRCode
    case expired

    public var errorDescription: String? {
        switch self {
        case .claimFailed(let msg): return msg
        case .invalidQRCode: return "Invalid QR code"
        case .expired: return "Pairing code has expired"
        }
    }
}

