import Foundation
import UIKit
#if DEBUG
import os.log
#endif

/// Handles deep links from Universal Links and custom URL schemes
/// Supports: secretr00m://join/{token}, https://secretr00m.app/join/{token}
final class DeepLinkHandler {

    // MARK: - Singleton

    static let shared = DeepLinkHandler()

    #if DEBUG
    private let logger = Logger(subsystem: "com.ephemeral.rooms", category: "DeepLink")
    #endif

    private init() {}

    // MARK: - Types

    enum DeepLinkType {
        case joinRoom(token: String)
        case unknown
    }

    struct ParsedDeepLink {
        let type: DeepLinkType
        let originalURL: URL
    }

    // MARK: - Constants

    private static let customScheme = "secretr00m"
    private static let universalLinkHost = "secretr00m.app"
    private static let tokenRegex = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{32}$")

    // MARK: - Pending Link Storage

    /// Stores pending deep link when app is not ready to handle it
    private var pendingDeepLink: ParsedDeepLink?

    /// Callback to invoke when a deep link is ready to process
    var onDeepLinkReceived: ((ParsedDeepLink) -> Void)?

    // MARK: - Public API

    /// Parse and handle a URL from any source (Universal Link, custom scheme, or clipboard)
    /// - Parameter url: The URL to parse
    /// - Returns: Parsed deep link result, or nil if invalid
    func handleURL(_ url: URL) -> ParsedDeepLink? {
        #if DEBUG
        logger.info("Deep link received: \(url.scheme ?? "nil", privacy: .public)://\(url.host ?? "", privacy: .public)/...")
        #endif

        guard let parsed = parseURL(url) else {
            #if DEBUG
            logger.error("Failed to parse deep link URL")
            #endif
            return nil
        }

        switch parsed.type {
        case .joinRoom(let token):
            #if DEBUG
            logger.info("Parsed invite link with token length: \(token.count)")
            #endif
        case .unknown:
            #if DEBUG
            logger.warning("Parsed as unknown deep link type")
            #endif
        }

        // If we have a handler, invoke immediately
        if let handler = onDeepLinkReceived {
            #if DEBUG
            logger.info("Handler registered - invoking immediately")
            #endif
            handler(parsed)
        } else {
            // Store for later processing
            #if DEBUG
            logger.warning("Handler NOT registered - storing as pending deep link")
            #endif
            pendingDeepLink = parsed
        }

        return parsed
    }

    /// Check and process any pending deep link
    /// Call this when the app is ready to handle navigation
    func processPendingDeepLink() {
        guard let pending = pendingDeepLink else {
            #if DEBUG
            logger.debug("processPendingDeepLink called but no pending link")
            #endif
            return
        }

        #if DEBUG
        logger.info("Processing pending deep link")
        #endif
        pendingDeepLink = nil

        if let handler = onDeepLinkReceived {
            #if DEBUG
            logger.info("Invoking handler for pending deep link")
            #endif
            handler(pending)
        } else {
            #if DEBUG
            logger.error("CRITICAL: processPendingDeepLink called but handler is nil - link will be lost!")
            #endif
        }
    }

    /// Check if there's a pending deep link
    var hasPendingDeepLink: Bool {
        return pendingDeepLink != nil
    }

    /// Clear any pending deep link (e.g., after user cancels)
    func clearPendingDeepLink() {
        pendingDeepLink = nil
    }

    // MARK: - Clipboard Check (Deferred Deep Linking)

    /// Check clipboard for invite link on app launch
    /// Only checks once per app session to avoid annoyance
    private var hasCheckedClipboardThisSession = false

    func checkClipboardForInvite() -> ParsedDeepLink? {
        guard !hasCheckedClipboardThisSession else { return nil }
        hasCheckedClipboardThisSession = true

        // Check if clipboard has a URL
        guard UIPasteboard.general.hasURLs,
              let url = UIPasteboard.general.url else {
            return nil
        }

        // Parse and validate
        guard let parsed = parseURL(url) else {
            return nil
        }

        // Clear clipboard after reading (security)
        // Only clear if it was a valid invite link
        UIPasteboard.general.urls = []

        return parsed
    }

    // MARK: - URL Parsing

    private func parseURL(_ url: URL) -> ParsedDeepLink? {
        // Handle custom scheme: secretr00m://join/{token}
        if url.scheme?.lowercased() == Self.customScheme {
            return parseCustomSchemeURL(url)
        }

        // Handle Universal Link: https://secretr00m.app/join/{token}
        if url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" {
            if url.host?.lowercased() == Self.universalLinkHost {
                return parseUniversalLinkURL(url)
            }
        }

        return nil
    }

    private func parseCustomSchemeURL(_ url: URL) -> ParsedDeepLink? {
        // secretr00m://join/{token}
        guard url.host?.lowercased() == "join" else {
            return ParsedDeepLink(type: .unknown, originalURL: url)
        }

        // Token is the first path component
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard let token = pathComponents.first, isValidToken(token) else {
            return ParsedDeepLink(type: .unknown, originalURL: url)
        }

        return ParsedDeepLink(type: .joinRoom(token: token), originalURL: url)
    }

    private func parseUniversalLinkURL(_ url: URL) -> ParsedDeepLink? {
        // https://secretr00m.app/join/{token}
        let pathComponents = url.pathComponents.filter { $0 != "/" }

        guard pathComponents.count >= 2,
              pathComponents[0].lowercased() == "join" else {
            return ParsedDeepLink(type: .unknown, originalURL: url)
        }

        let token = pathComponents[1]
        guard isValidToken(token) else {
            return ParsedDeepLink(type: .unknown, originalURL: url)
        }

        return ParsedDeepLink(type: .joinRoom(token: token), originalURL: url)
    }

    private func isValidToken(_ token: String) -> Bool {
        let range = NSRange(token.startIndex..., in: token)
        return Self.tokenRegex.firstMatch(in: token, range: range) != nil
    }

    // MARK: - URL Generation

    /// Generate a shareable invite URL for a token
    /// Uses custom URL scheme since we don't have a registered domain
    /// - Parameter token: The invite token
    /// - Returns: Custom scheme URL that opens the app directly
    static func generateInviteURL(token: String) -> URL? {
        return URL(string: "\(customScheme)://join/\(token)")
    }

    /// Generate a custom scheme URL (same as generateInviteURL)
    /// - Parameter token: The invite token
    /// - Returns: Custom scheme URL
    static func generateCustomSchemeURL(token: String) -> URL? {
        return URL(string: "\(customScheme)://join/\(token)")
    }
}
