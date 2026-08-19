import AppKit
import AuthenticationServices
import Foundation

/// Errors surfaced by the account sign-in handoff.
enum AccountSessionError: Error, Equatable, LocalizedError {
    /// The user dismissed the auth browser without completing sign-in. This
    /// is a normal outcome (like touching "Cancel"), not a failure — callers
    /// stay on the signed-out state without surfacing an error.
    case cancelled
    /// A sign-in is already presented; the ephemeral browser cannot stack.
    case alreadyInProgress
    /// The session completed without a callback URL, or the callback did not
    /// parse as a `darkbloom://auth/callback` token handoff.
    case malformedCallback
    /// ASWebAuthenticationSession refused to start (no usable anchor window).
    case presentationUnavailable
    /// The auth browser itself failed (network, TLS, Privy outage).
    case browserFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "Sign-in was cancelled."
        case .alreadyInProgress:
            "Sign-in is already in progress."
        case .malformedCallback:
            "The sign-in completed without a usable session token."
        case .presentationUnavailable:
            "Darkbloom could not open the sign-in window."
        case .browserFailed(let reason):
            "The sign-in page failed to load. \(reason)"
        }
    }
}

/// The app's `darkbloom://auth/callback#token=<jwt>` handoff URL.
///
/// Token transport is the URL *fragment*, not a query parameter: fragments
/// are never transmitted in HTTP requests, so the token cannot land in
/// console/edge server logs, Referer headers, or analytics beacons — only in
/// the browser's own navigation, which ASWebAuthenticationSession intercepts
/// before any fetch. The console page uses `location.replace` so the URL
/// also stays out of the auth browser's back-stack.
struct AccountLinkCallback: Equatable, Sendable {
    static let scheme = "darkbloom"
    static let host = "auth"
    static let path = "/callback"
    static let callbackURL = "darkbloom://auth/callback"

    let token: String

    static func parse(url: URL) -> AccountLinkCallback? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host,
              url.path == path
        else {
            return nil
        }
        // URLComponents strips the leading '#'. The fragment is `token=<jwt>`
        // (encodeURIComponent'd by the console page); the JWT alphabet needs
        // no encoding, but decode defensively anyway. Note: Substring.split
        // drops empty subsequences, so a `token=` with an empty value must be
        // detected by prefix removal, not by splitting on '='.
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment else {
            return nil
        }
        for parameter in fragment.split(separator: "&") {
            guard parameter.hasPrefix("token=") else { continue }
            let rawToken = parameter.dropFirst("token=".count)
            let token = String(rawToken).removingPercentEncoding ?? String(rawToken)
            guard !token.isEmpty else { return nil }
            return AccountLinkCallback(token: token)
        }
        return nil
    }
}

/// Where the app keeps the user's interactive (Privy) session.
///
/// Implemented by `KeychainSessionStore` in production and by in-memory
/// fakes in tests. Error handling is deliberately failable-not-throwing:
/// a keychain miss reads as signed-out, and a failed save loses the session
/// (the next launch signs out once) rather than blocking sign-in.
protocol AccountSessionStoring: Sendable {
    func loadToken() -> String?
    @discardableResult func saveToken(_ token: String) -> Bool
    func clearToken()
}

/// The user's interactive account session for account-scoped views
/// (My Macs). Distinct from the provider's machine link: `darkbloom login`
/// uses the RFC 8628 device-code flow and never holds a Privy token — so
/// there is no CLI path to share for this data.
protocol AccountSessionManaging: AnyObject, Sendable {
    /// A persisted token exists. Says nothing about expiry — the coordinator
    /// decides that (401), and the store reacts to it.
    var isSignedIn: Bool { get }

    /// The persisted Privy access token, if any.
    func accessToken() -> String?

    /// Runs the console sign-in handoff and returns the freshly issued
    /// Privy access token. Throws `AccountSessionError.cancelled` when the
    /// user dismisses the auth browser.
    @MainActor func signIn() async throws -> String

    /// Drops the persisted token (user sign-out AND coordinator-rejected
    /// 401 alike — from the app's side both are "no usable session").
    func signOut()
}

/// Drives the Privy sign-in handoff through an ephemeral
/// ASWebAuthenticationSession pointed at the console's `/auth/app-link`
/// page. `prefersEphemeralWebBrowserSession` keeps the auth cookies out of
/// the user's Safari, so account-link sign-in never touches the browser the
/// console dashboard normally runs in. The ephemeral browser intercepts the
/// `darkbloom://` callback scheme directly; the dev `.app` bundle also
/// registers the scheme via CFBundleURLTypes in
/// Resources/DarkbloomApp/Info.plist so the callback is always resolvable.
///
/// The Privy application id is console-side configuration
/// (`NEXT_PUBLIC_PRIVY_APP_ID`); the app never sees it — it only receives
/// the resulting JWT through the callback fragment.
@MainActor
final class AccountSessionManager: NSObject, AccountSessionManaging {
    /// Production console (deploy/environments/prod.env `CONSOLE_URL`).
    static let defaultConsoleBaseURL = URL(string: "https://console.darkbloom.dev")!

    /// Environment override for pointing the handoff at a dev console, e.g.
    /// `DARKBLOOM_CONSOLE_URL=https://console.dev.darkbloom.xyz`.
    static let consoleURLEnvironmentKey = "DARKBLOOM_CONSOLE_URL"

    /// Sendable and immutable after init, so safe to read off-actor.
    nonisolated let sessionStore: any AccountSessionStoring
    private let consoleBaseURL: URL
    private var activeSession: ASWebAuthenticationSession?

    init(
        sessionStore: any AccountSessionStoring = KeychainSessionStore(),
        consoleBaseURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.sessionStore = sessionStore
        if let consoleBaseURL {
            self.consoleBaseURL = consoleBaseURL
        } else if let rawValue = environment[Self.consoleURLEnvironmentKey],
                  let url = URL(string: rawValue),
                  url.scheme?.hasPrefix("http") == true {
            self.consoleBaseURL = url
        } else {
            self.consoleBaseURL = Self.defaultConsoleBaseURL
        }
        super.init()
    }

    nonisolated var isSignedIn: Bool {
        sessionStore.loadToken() != nil
    }

    nonisolated func accessToken() -> String? {
        sessionStore.loadToken()
    }

    nonisolated func signOut() {
        sessionStore.clearToken()
    }

    func signIn() async throws -> String {
        guard activeSession == nil else {
            throw AccountSessionError.alreadyInProgress
        }
        let appLinkURL = consoleBaseURL
            .appending(path: "auth")
            .appending(path: "app-link")
            .appending(queryItems: [URLQueryItem(name: "source", value: "app")])

        return try await withCheckedThrowingContinuation { continuation in
            let webSession = ASWebAuthenticationSession(
                url: appLinkURL,
                callbackURLScheme: AccountLinkCallback.scheme
            ) { [weak self] callbackURL, error in
                // ASWebAuthenticationSession invokes its completion on the
                // main thread (documented); hop to the manager's actor for
                // the session bookkeeping.
                MainActor.assumeIsolated {
                    self?.activeSession = nil
                }
                if let error {
                    if let authError = error as? ASWebAuthenticationSessionError,
                       authError.code == .canceledLogin {
                        continuation.resume(throwing: AccountSessionError.cancelled)
                    } else {
                        continuation.resume(
                            throwing: AccountSessionError.browserFailed(error.localizedDescription)
                        )
                    }
                    return
                }
                guard let callbackURL,
                      let callback = AccountLinkCallback.parse(url: callbackURL) else {
                    continuation.resume(throwing: AccountSessionError.malformedCallback)
                    return
                }
                // Token is a Privy JWT. The coordinator is the authority on
                // expiry; the app persists it and reacts to 401s.
                self?.sessionStore.saveToken(callback.token)
                continuation.resume(returning: callback.token)
            }
            webSession.prefersEphemeralWebBrowserSession = true
            webSession.presentationContextProvider = self
            activeSession = webSession
            if !webSession.start() {
                activeSession = nil
                continuation.resume(throwing: AccountSessionError.presentationUnavailable)
            }
        }
    }
}

extension AccountSessionManager: ASWebAuthenticationPresentationContextProviding {
    // The presentation-context callback is invoked by the system on the main
    // thread, so reading NSApp state directly is safe despite the method
    // being nonisolated.
    nonisolated func presentationAnchor(
        for _: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApplication.shared.keyWindow ?? NSWindow()
        }
    }
}
