import Foundation
import DarkbloomClusterProtocol

/// The control leader's request that the provider's coordinator register this pair's model approval under the
/// account (`POST /v1/cluster/owner-approvals`), and its renewal (`DELETE /v1/cluster/owner-approvals/{id}`, then the
/// request again). The leader asks before it reads the approvals (`ClusterApprovalFetch`): after the guided setup's
/// Test stage, and at the cluster service's checks while the setup holds no approval or holds an owner approval
/// within `renewWithinSeconds` of its end (`need`). The request carries the provider's coordinator credential, the
/// installed app's version, the setup's model, its artifact and its prefill schedule; the coordinator answers with the
/// approval it holds for them (a new one, or the live one it already has, so asking again is safe). The answer
/// approves nothing by itself: the fetch reads the account's own approvals (`ClusterApprovalFetch.fetchOwned`), and
/// the existing match and save on both Macs (`ClusterApprovalSync`) take the entry as they take an operator's. Only a
/// DevNet coordinator takes the request; production and staging answer 403 or 404. Every outcome is one line, and
/// none stops a Mac from serving.
enum ClusterApprovalRequest {
    static let path = ClusterApprovalFetch.ownerPath
    static let timeoutSeconds: Double = 10
    /// An owner approval this close to its `not_after` is renewed.
    static let renewWithinSeconds: Double = 7 * 86_400
    /// How the coordinator names an approval its owner registered: `owner/<account>/<model>/s<schedule>/<nonce>`.
    static let ownerIDPrefix = "owner/"

    enum Outcome: Equatable, Sendable {
        /// 200 or 201: the coordinator holds this approval for the pair.
        case registered(String)
        /// 403 or 404: this coordinator does not register approvals for this pair (production, staging, a build
        /// without `-dev.`, the setting off).
        case notTaken(Int)
        /// Another 4xx: the coordinator refused this request (400 a body it does not read, 409 the account or the
        /// catalog is full).
        case refused(Int)
        /// Nothing was sent: this Mac lacks what the request needs (a credential, the installed version, an HTTPS
        /// coordinator).
        case notSent(String)
        /// No answer, a 5xx or a redirect, an answer that is not an owner approval, or a renewal whose delete failed.
        case failed(String)

        /// The one line for the screen and the service log (`ClusterOnboardingReady.approvalRequestNotice`).
        var line: String {
            let text: String
            switch self {
            case .registered(let id): text = "the coordinator holds approval \(id) for this pair"
            case .notTaken(let status): text = "not taken by this coordinator (HTTP \(status))"
            case .refused(let status): text = "refused by the coordinator (HTTP \(status))"
            case .notSent(let reason): text = "not sent (\(reason))"
            case .failed(let reason): text = "failed (\(reason))"
            }
            return ClusterOnboardingReady.approvalRequestNotice + ": " + text + "."
        }

        /// Whether the cluster service asks again at its next check: after a success (the next check still finds no
        /// approval only when saving it failed) and after a failure that may pass (no answer, a server error). An
        /// answer that refuses, or a Mac that cannot send, waits for the next service run or update.
        var retries: Bool {
            switch self {
            case .registered, .failed: return true
            case .notTaken, .refused, .notSent: return false
            }
        }
    }

    /// What the leader asks for its saved setup before it reads the approvals.
    enum Need: Equatable, Sendable {
        /// Nothing: the setup holds a pair approval saved by hand, an operator's cluster approval, or an owner approval
        /// with more than `renewWithinSeconds` left.
        case nothing
        /// The setup holds no approval: ask for one.
        case request
        /// The setup holds this owner approval, which ends within `renewWithinSeconds`: delete it, then ask again.
        case renew(String)
    }

    static func need(_ saved: ClusterConfigurationStore.Saved, now: Double) -> Need {
        let member = saved.configuration.nativeMember
        guard member?.approval == nil else { return .nothing }
        guard let held = member?.clusterApproval else { return .request }
        guard held.id.hasPrefix(ownerIDPrefix), let end = ClusterApprovalLifetime.expiry(held), end - now <= renewWithinSeconds else {
            return .nothing
        }
        return .renew(held.id)
    }

    /// The request body: exactly the fields the coordinator's endpoint reads, in the order of the shared vector
    /// (`Fixtures/coordinator-wire/owner_cluster_approval_vector.json`, the same bytes the coordinator's tests pin).
    static func body(providerVersion: String, model: String, artifact: String, schedule: UInt8) throws -> Data {
        func string(_ value: String) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
                   as: UTF8.self)
        }
        return Data(("{\"provider_version\":" + (try string(providerVersion)) + ",\"model\":" + (try string(model))
            + ",\"artifact_sha256\":" + (try string(artifact)) + ",\"schedule\":\(schedule)}").utf8)
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

    /// One exchange with the coordinator: the status and body of its answer, or the outcome that ends the request.
    /// The URL rules are the fetch's (HTTPS, or this Mac's loopback), so the credential never leaves the Mac in plain
    /// text, and no redirect is followed with it.
    private static func exchange(coordinatorURL: String, path: String, method: String, token: String?,
                                 body: Data?) async -> Result<(status: Int, data: Data), Stop> {
        guard let url = ClusterApprovalFetch.url(coordinatorURL: coordinatorURL, path: path) else {
            return .failure(.init(.notSent("the coordinator URL is not HTTPS")))
        }
        guard let token, !token.isEmpty else { return .failure(.init(.notSent("this Mac is not linked to an account"))) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutSeconds; configuration.timeoutIntervalForResource = timeoutSeconds
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: ClusterNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeoutSeconds)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.url == url else { return .failure(.init(.failed("no HTTP answer"))) }
            return .success((status: http.statusCode, data: data))
        } catch let error as URLError {
            return .failure(.init(.failed("no answer: \(error.localizedDescription)")))
        } catch {
            return .failure(.init(.failed(error.localizedDescription)))
        }
    }

    /// An outcome that ends an exchange before an answer to read.
    private struct Stop: Error { let outcome: Outcome; init(_ outcome: Outcome) { self.outcome = outcome } }

    /// `POST /v1/cluster/owner-approvals` to `coordinatorURL` (the provider configuration's WebSocket URL). A 200 or
    /// 201 must hold one owner approval whose `policy_sha256` this Mac derives (`ClusterApprovalFetch.decodeOwnedEntry`).
    static func request(coordinatorURL: String, token: String?, providerVersion: String, model: String, artifact: String,
                        schedule: UInt8) async -> Outcome {
        let body: Data
        do { body = try self.body(providerVersion: providerVersion, model: model, artifact: artifact, schedule: schedule) } catch {
            return .notSent(error.localizedDescription)
        }
        switch await exchange(coordinatorURL: coordinatorURL, path: path, method: "POST", token: token, body: body) {
        case .failure(let stop):
            return stop.outcome
        case .success(let answer):
            switch answer.status {
            case 200, 201:
                guard let approval = try? ClusterApprovalFetch.decodeOwnedEntry(answer.data) else {
                    return .failed("the answer is not an owner approval")
                }
                return .registered(approval.id)
            case 403, 404: return .notTaken(answer.status)
            case 400..<500: return .refused(answer.status)
            default: return .failed("HTTP \(answer.status)")
            }
        }
    }

    /// `DELETE /v1/cluster/owner-approvals/{id}`: nil when the coordinator no longer holds it (204, or 404: not, or no
    /// longer, this account's), else why the renewal stopped.
    static func delete(id: String, coordinatorURL: String, token: String?) async -> Outcome? {
        switch await exchange(coordinatorURL: coordinatorURL, path: path + "/" + id, method: "DELETE", token: token, body: nil) {
        case .failure(let stop): return stop.outcome
        case .success(let answer) where answer.status == 204 || answer.status == 404: return nil
        case .success(let answer): return .failed("the renewal could not delete approval \(id): HTTP \(answer.status)")
        }
    }

    /// What the saved setup needs (`need`), asked of the provider configuration's coordinator with the saved account
    /// credential: nil when it needs nothing, so nothing is sent and nothing is said.
    static func ensure(_ saved: ClusterConfigurationStore.Saved, providerConfiguration: URL, now: Double,
                       token: String? = AuthTokenStore.load()) async -> Outcome? {
        let needed = need(saved, now: now)
        if needed == .nothing { return nil }
        guard let coordinator = try? ConfigManager.loadOrDefaults(from: providerConfiguration).coordinator.url else {
            return .notSent("the provider configuration names no coordinator")
        }
        let configuration = saved.configuration
        guard let version = installedVersion(configuration) else { return .notSent("the installed app's version could not be read") }
        if case .renew(let id) = needed, let stopped = await delete(id: id, coordinatorURL: coordinator, token: token) { return stopped }
        return await request(coordinatorURL: coordinator, token: token, providerVersion: version, model: configuration.publicModelID,
                             artifact: saved.capability.artifactSHA256,
                             schedule: ClusterApprovalLifetime.schedule(configuration.selectedPrefillSchedule))
    }

    /// The same, from a thread outside the cooperative pool (the cluster service's and the onboarding's threads).
    static func ensureBlocking(_ saved: ClusterConfigurationStore.Saved, providerConfiguration: URL, now: Double,
                               token: String? = AuthTokenStore.load()) -> Outcome? {
        blockingWizard { await ensure(saved, providerConfiguration: providerConfiguration, now: now, token: token) }
    }
}
