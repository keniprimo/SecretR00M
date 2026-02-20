import Foundation
import UIKit

/// Manages invite token creation and validation through the relay server
final class InviteManager {

    // MARK: - Singleton

    static let shared = InviteManager()

    private init() {}

    // MARK: - Types

    struct InviteToken {
        let token: String
        let roomID: String
        let expiresIn: TimeInterval
    }

    struct ValidationResult {
        let isValid: Bool
        let roomID: String?
        let error: String?
    }

    enum InviteError: LocalizedError {
        case networkError(Error)
        case serverError(String)
        case invalidResponse
        case roomNotFound
        case tokenExpired
        case tokenAlreadyUsed
        case rateLimited
        case torNotReady

        var errorDescription: String? {
            switch self {
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .serverError(let message):
                return "Server error: \(message)"
            case .invalidResponse:
                return "Invalid server response"
            case .roomNotFound:
                return "Room no longer exists"
            case .tokenExpired:
                return "Invite link has expired"
            case .tokenAlreadyUsed:
                return "Invite link has already been used"
            case .rateLimited:
                return "Too many requests. Please try again later."
            case .torNotReady:
                return "Secure connection not ready. Please wait a moment and try again."
            }
        }
    }

    // MARK: - API Response Types

    private struct CreateTokenResponse: Decodable {
        let token: String
        let roomId: String
        let expiresIn: Int64?  // Seconds until expiration (optional)
        let expiresAt: Int64?  // Timestamp in milliseconds (optional)

        /// Calculate expiration duration in seconds, handling both server response formats
        var expirationSeconds: TimeInterval {
            if let expiresIn = expiresIn {
                // Server returned duration in seconds
                return TimeInterval(expiresIn)
            } else if let expiresAt = expiresAt {
                // Server returned timestamp in milliseconds - convert to duration
                let expirationDate = Date(timeIntervalSince1970: TimeInterval(expiresAt) / 1000.0)
                return expirationDate.timeIntervalSinceNow
            }
            // Default to 24 hours if neither field present
            return 86400
        }
    }

    private struct ValidateTokenResponse: Decodable {
        let valid: Bool
        let roomId: String?
        let error: String?
    }

    private struct ErrorResponse: Decodable {
        let error: String
    }

    // MARK: - Public API

    /// Create a new invite token for a room
    /// - Parameters:
    ///   - roomID: The room ID to create an invite for
    ///   - relayURL: Base URL of the relay server (must be .onion for production)
    ///   - completion: Callback with result
    /// - Note: SECURITY - This method requires Tor to be ready. Use isTorReady() to check first.
    func createInviteToken(
        roomID: String,
        relayURL: URL,
        completion: @escaping (Result<InviteToken, InviteError>) -> Void
    ) {
        // SECURITY: Verify Tor is ready before any network operation
        guard let session = getTorSession() else {
            completion(.failure(.torNotReady))
            return
        }

        // Server expects: POST /invite/create/{roomId} (roomId in path, no body)
        let url = relayURL.appendingPathComponent("invite/create/\(roomID)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        // No body needed - roomId is in the path

        let task = session.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(.networkError(error)))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(.invalidResponse))
                    return
                }

                guard let data = data else {
                    completion(.failure(.invalidResponse))
                    return
                }

                switch httpResponse.statusCode {
                case 200, 201:
                    do {
                        let response = try JSONDecoder().decode(CreateTokenResponse.self, from: data)
                        // Handle both expiresIn (seconds) and expiresAt (timestamp) formats
                        let token = InviteToken(
                            token: response.token,
                            roomID: response.roomId,
                            expiresIn: response.expirationSeconds
                        )
                        completion(.success(token))
                    } catch {
                        #if DEBUG
                        // Log the actual response for debugging
                        if let responseString = String(data: data, encoding: .utf8) {
                            print("[InviteManager] Failed to decode response: \(responseString)")
                            print("[InviteManager] Decode error: \(error)")
                        }
                        #endif
                        completion(.failure(.invalidResponse))
                    }

                case 404:
                    completion(.failure(.roomNotFound))

                case 429:
                    completion(.failure(.rateLimited))

                default:
                    if let errorResp = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                        completion(.failure(.serverError(errorResp.error)))
                    } else {
                        completion(.failure(.serverError("HTTP \(httpResponse.statusCode)")))
                    }
                }
            }
        }

        task.resume()
    }

    /// Validate an invite token without consuming it
    /// - Parameters:
    ///   - token: The invite token to validate
    ///   - relayURL: Base URL of the relay server
    ///   - completion: Callback with validation result
    /// - Note: SECURITY - This method requires Tor to be ready. Use isTorReady() to check first.
    func validateToken(
        _ token: String,
        relayURL: URL,
        completion: @escaping (Result<ValidationResult, InviteError>) -> Void
    ) {
        // SECURITY: Verify Tor is ready before any network operation
        guard let session = getTorSession() else {
            completion(.failure(.torNotReady))
            return
        }

        // Server expects: GET /invite/validate/{token} (token in path, no body)
        let url = relayURL.appendingPathComponent("invite/validate/\(token)")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        // No body needed - token is in the path

        let task = session.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(.networkError(error)))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(.invalidResponse))
                    return
                }

                guard let data = data else {
                    completion(.failure(.invalidResponse))
                    return
                }

                switch httpResponse.statusCode {
                case 200:
                    do {
                        let response = try JSONDecoder().decode(ValidateTokenResponse.self, from: data)
                        let result = ValidationResult(
                            isValid: response.valid,
                            roomID: response.roomId,
                            error: response.error
                        )
                        completion(.success(result))
                    } catch {
                        completion(.failure(.invalidResponse))
                    }

                case 429:
                    completion(.failure(.rateLimited))

                default:
                    if let errorResp = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                        completion(.failure(.serverError(errorResp.error)))
                    } else {
                        completion(.failure(.serverError("HTTP \(httpResponse.statusCode)")))
                    }
                }
            }
        }

        task.resume()
    }

    // MARK: - Sharing

    /// Generate shareable content for an invite
    /// - Parameter token: The invite token
    /// - Returns: Tuple of (URL, text) for sharing
    func generateShareContent(token: String) -> (url: URL, text: String)? {
        guard let url = DeepLinkHandler.generateInviteURL(token: token) else {
            return nil
        }

        let text = """
        Join my secure room on SecretR00M:
        \(url.absoluteString)

        This link expires in 24 hours and can only be used once.
        """

        return (url, text)
    }

    /// Copy invite link to clipboard
    /// - Parameter token: The invite token
    /// - Returns: Whether the copy was successful
    @discardableResult
    func copyToClipboard(token: String) -> Bool {
        guard let url = DeepLinkHandler.generateInviteURL(token: token) else {
            return false
        }

        UIPasteboard.general.url = url
        return true
    }

    // MARK: - Private

    /// Get URLSession configured for Tor
    /// SECURITY: All traffic to .onion must go through Tor
    /// - Returns: URLSession configured for Tor, or nil if Tor is not ready
    private func getTorSession() -> URLSession? {
        #if targetEnvironment(simulator)
        // Simulator cannot use Tor - use default session for development only
        // WARNING: This should never be used with .onion addresses in production
        return URLSession.shared
        #else
        // SECURITY: Verify Tor is ready before creating session
        guard EphemeralTorManager.shared.verifyTorReady() else {
            return nil
        }
        // Use Tor-configured URLSession for .onion access
        return EphemeralTorManager.shared.createTorURLSession()
        #endif
    }

    /// Check if Tor is ready for network operations
    /// SECURITY: Call this before any network operation to ensure traffic goes through Tor
    func isTorReady() -> Bool {
        #if targetEnvironment(simulator)
        return true // Simulator doesn't use real Tor
        #else
        return EphemeralTorManager.shared.verifyTorReady()
        #endif
    }
}

// MARK: - Async/Await Support (iOS 15+)

@available(iOS 15.0, *)
extension InviteManager {

    /// Create invite token (async)
    func createInviteToken(roomID: String, relayURL: URL) async throws -> InviteToken {
        try await withCheckedThrowingContinuation { continuation in
            createInviteToken(roomID: roomID, relayURL: relayURL) { result in
                switch result {
                case .success(let token):
                    continuation.resume(returning: token)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Validate token (async)
    func validateToken(_ token: String, relayURL: URL) async throws -> ValidationResult {
        try await withCheckedThrowingContinuation { continuation in
            validateToken(token, relayURL: relayURL) { result in
                switch result {
                case .success(let validation):
                    continuation.resume(returning: validation)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
