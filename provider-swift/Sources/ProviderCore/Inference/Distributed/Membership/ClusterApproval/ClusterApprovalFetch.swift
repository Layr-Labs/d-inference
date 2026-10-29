import Foundation

/// The cluster approvals the provider's coordinator serves (`GET /v1/cluster/approvals`): every unexpired entry of
/// the coordinator operator's approval file, public build facts, so the request carries no credential. The answer
/// approves nothing by itself: the leader takes only an entry whose digests are this Mac's own cluster runtime facts,
/// and each Mac checks it against its own installed files before it saves it (`ClusterApprovalAttachment`). A
/// coordinator without pair control answers 404, and every failure means "no approval": nothing here can stop a Mac
/// from serving.
public enum ClusterApprovalFetch {
    public static let path = "/v1/cluster/approvals"
    public static let schemaName = "darkbloom_cluster_catalog_v2"
    /// More entries than any operator file holds are never read.
    static let maximumApprovals = 128
    static let maximumBytes = 512 * 1024
    static let timeoutSeconds: Double = 10

    public enum Outcome: Equatable, Sendable {
        case approvals([ClusterRuntimeApproval])
        /// 404: pair control is off on this coordinator (production, staging).
        case notOffered
        /// Any other answer, or a URL this Mac does not ask: the reason, for one log line.
        case unavailable(String)
        /// No answer at all (the request failed before an HTTP answer: no route, refused, timed out): the reason. An
        /// offered pair whose coordinator stays so for the absence grace serves locally (`ClusterApprovalSync.step`).
        case unreachable(String)
    }

    /// The request URL for the provider's coordinator: HTTPS, or plain HTTP to this Mac's own loopback (a local test
    /// coordinator). Nil for any other URL, so a plain request never leaves the Mac.
    static func url(coordinatorURL: String) -> URL? {
        guard var components = URLComponents(string: coordinatorHTTPBase(coordinatorURL)),
              let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(),
              scheme == "https" || (scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)),
              components.query == nil, components.fragment == nil else { return nil }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + path
        return components.url
    }

    public static func fetch(coordinatorURL: String) async -> Outcome {
        guard let url = url(coordinatorURL: coordinatorURL) else {
            return .unavailable("the coordinator URL is not HTTPS")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutSeconds; configuration.timeoutIntervalForResource = timeoutSeconds
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: ClusterNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.url == url else { return .unavailable("no HTTP answer") }
            if http.statusCode == 404 { return .notOffered }
            guard http.statusCode == 200 else { return .unavailable("HTTP \(http.statusCode)") }
            guard response.expectedContentLength <= Int64(maximumBytes) else { return .unavailable("the answer exceeds its bound") }
            // An answer came: a failure from here on is an unusable answer, never "unreachable".
            var bytes = Data()
            do {
                for try await byte in stream {
                    guard bytes.count < maximumBytes else { return .unavailable("the answer exceeds its bound") }
                    bytes.append(byte)
                }
            } catch {
                return .unavailable("the answer could not be read: \(error.localizedDescription)")
            }
            return .approvals(try decode(bytes))
        } catch let error as ClusterConfigurationError {
            return .unavailable("\(error)")
        } catch let error as URLError {
            return .unreachable(error.localizedDescription)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    /// What the provider configuration's coordinator serves; nil when the provider configuration names no coordinator.
    static func fetch(providerConfiguration: URL) async -> Outcome? {
        guard let coordinator = try? ConfigManager.loadOrDefaults(from: providerConfiguration).coordinator.url else { return nil }
        return await fetch(coordinatorURL: coordinator)
    }

    /// The same, from a thread outside the cooperative pool (the cluster service's and the onboarding's threads).
    static func fetchBlocking(providerConfiguration: URL) -> Outcome? {
        blockingWizard { await fetch(providerConfiguration: providerConfiguration) }
    }

    /// `{"schema":"darkbloom_cluster_catalog_v2","cluster_approvals":[…]}`, read as strictly as a saved setup reads
    /// one entry: exact field names, nothing unknown or missing, and every entry must encode to coordinator policy
    /// bytes (`ClusterRuntimeApproval.canonicalPolicy`). One bad entry refuses the whole answer.
    static func decode(_ data: Data) throws -> [ClusterRuntimeApproval] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schema", "cluster_approvals"], object["schema"] as? String == schemaName,
              let entries = object["cluster_approvals"] as? [[String: Any]], entries.count <= maximumApprovals,
              entries.allSatisfy({ Set($0.keys) == ClusterRuntimeApproval.fields }) else {
            throw ClusterConfigurationError.invalid("The cluster approvals answer is not a \(schemaName) list")
        }
        struct List: Decodable { let clusterApprovals: [ClusterRuntimeApproval]
            enum CodingKeys: String, CodingKey { case clusterApprovals = "cluster_approvals" } }
        let approvals = try JSONDecoder().decode(List.self, from: data).clusterApprovals
        for approval in approvals { _ = try approval.canonicalPolicy() }
        return approvals
    }
}
