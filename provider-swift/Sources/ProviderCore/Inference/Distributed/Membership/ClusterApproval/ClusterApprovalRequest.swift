import Foundation

/// The guided setup's request that the provider's coordinator register this pair's model approval
/// (`POST /v1/cluster/approvals`), sent by the control leader after the Test stage passed and before it fetches the
/// approvals (`ClusterApprovalFetch`). The request carries the provider's coordinator credential, the installed app's
/// version, the setup's model and its prefill schedule; the coordinator answers with the approval it holds for them
/// (a new one, or the live one it already has). Its answer approves nothing by itself: the existing fetch, match and
/// save on both Macs (`ClusterApprovalSync`) take the listed entry as for an operator's. Only a DevNet coordinator
/// takes the request; production and staging answer 403 or 404, and every outcome is one line that stops nothing.
enum ClusterApprovalRequest {
    static let timeoutSeconds: Double = 10

    enum Outcome: Equatable, Sendable {
        /// 200 or 201: the coordinator holds an approval for this pair (its id, when the answer names one).
        case registered(String?)
        /// 403 or 404: this coordinator does not register approvals for this pair (production, staging, setting off).
        case notTaken(Int)
        /// No request (no credential, no version, a URL this Mac does not ask), no answer, or another answer.
        case failed(String)

        /// The one line the setup screen shows (`ClusterOnboardingReady.approvalRequestNotice`).
        var line: String {
            let text: String
            switch self {
            case .registered(let id?): text = "the coordinator holds approval \(id) for this pair"
            case .registered(nil): text = "the coordinator took it"
            case .notTaken(let status): text = "not taken by this coordinator (HTTP \(status))"
            case .failed(let reason): text = "failed (\(reason))"
            }
            return ClusterOnboardingReady.approvalRequestNotice + ": " + text + "."
        }
    }

    /// The request body: the fields the coordinator's endpoint reads, and nothing else.
    static func body(providerVersion: String, model: String, schedule: UInt8) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["provider_version": providerVersion, "model": model, "schedule": Int(schedule)],
                                   options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// The version of the app whose helpers the setup runs (`Contents/Info.plist` beside `Contents/Helpers`): what
    /// this Mac has installed, which an update may have changed since this process started.
    static func installedVersion(_ configuration: ClusterConfiguration) -> String? {
        let contents = ClusterApprovalAttachment.installation(configuration).worker.deletingLastPathComponent().deletingLastPathComponent()
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty else { return nil }
        return version
    }

    /// One request to `coordinatorURL` (the provider configuration's WebSocket URL). The URL rules are the fetch's
    /// (HTTPS, or this Mac's loopback), so the credential never leaves the Mac in plain text, and no redirect is
    /// followed with it.
    static func request(coordinatorURL: String, token: String?, providerVersion: String, model: String,
                        schedule: UInt8) async -> Outcome {
        guard let url = ClusterApprovalFetch.url(coordinatorURL: coordinatorURL) else {
            return .failed("the coordinator URL is not HTTPS")
        }
        guard let token, !token.isEmpty else { return .failed("this Mac is not linked to an account") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutSeconds; configuration.timeoutIntervalForResource = timeoutSeconds
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: ClusterNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            request.httpBody = try body(providerVersion: providerVersion, model: model, schedule: schedule)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.url == url else { return .failed("no HTTP answer") }
            switch http.statusCode {
            case 200, 201:
                let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                return .registered((answer?["approval"] as? [String: Any])?["id"] as? String)
            case 403, 404:
                return .notTaken(http.statusCode)
            default:
                return .failed("HTTP \(http.statusCode)")
            }
        } catch let error as URLError {
            return .failed("no answer: \(error.localizedDescription)")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The request for a saved setup, to the provider configuration's coordinator with the saved account credential.
    static func request(for configuration: ClusterConfiguration, providerConfiguration: URL,
                        token: String? = AuthTokenStore.load()) async -> Outcome {
        guard let coordinator = try? ConfigManager.loadOrDefaults(from: providerConfiguration).coordinator.url else {
            return .failed("the provider configuration names no coordinator")
        }
        guard let version = installedVersion(configuration) else { return .failed("the installed app's version could not be read") }
        return await request(coordinatorURL: coordinator, token: token, providerVersion: version, model: configuration.publicModelID,
                             schedule: ClusterApprovalLifetime.schedule(configuration.selectedPrefillSchedule))
    }

    /// The same, from a thread outside the cooperative pool (the cluster service's and the onboarding's threads).
    static func requestBlocking(for configuration: ClusterConfiguration, providerConfiguration: URL,
                                token: String? = AuthTokenStore.load()) -> Outcome {
        blockingWizard { await request(for: configuration, providerConfiguration: providerConfiguration, token: token) }
    }
}
