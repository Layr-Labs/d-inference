import Foundation

/// The cluster approvals the provider's coordinator serves (`GET /v1/cluster/approvals`): every unexpired entry of
/// the coordinator operator's approval file, public build facts, so the request carries no credential. The answer
/// approves nothing by itself: the leader takes only an entry whose digests are this Mac's own cluster runtime facts
/// (or a model approval for its saved setup's model, schedule and artifact), and each Mac checks it against its own
/// installed files before it saves it (`ClusterApprovalAttachment`). A coordinator without pair control answers 404,
/// and every failure means "no approval": nothing here can stop a Mac from serving. With the account credential the
/// leader also reads the approvals its own account registered (`GET /v1/cluster/owner-approvals`,
/// `ClusterApprovalRequest`), which the public list does not hold, and takes them as listed entries too.
public enum ClusterApprovalFetch {
    public static let path = "/v1/cluster/approvals"
    /// The caller's own unexpired approvals (DevNet): `{"approvals":[{"approval":{…},"policy_sha256":"…"}]}`.
    public static let ownerPath = "/v1/cluster/owner-approvals"
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
        /// offered pair whose coordinator stays so for the absence grace serves locally (`ClusterApprovalCheck.step`).
        case unreachable(String)
    }

    /// The request URL for the provider's coordinator: HTTPS, or plain HTTP to this Mac's own loopback (a local test
    /// coordinator). Nil for any other URL, so a plain request never leaves the Mac.
    static func url(coordinatorURL: String, path: String = ClusterApprovalFetch.path) -> URL? {
        guard var components = URLComponents(string: coordinatorHTTPBase(coordinatorURL)),
              let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(),
              scheme == "https" || (scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)),
              components.query == nil, components.fragment == nil else { return nil }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + path
        return components.url
    }

    public static func fetch(coordinatorURL: String) async -> Outcome {
        await get(coordinatorURL: coordinatorURL, path: path, token: nil, notOffered: [404], decode: decode)
    }

    /// The approvals the credential's account registered. 404 (owner approvals off), 403 (not development, no
    /// account) and 401 (a credential the coordinator does not take) mean it holds none.
    static func fetchOwned(coordinatorURL: String, token: String) async -> Outcome {
        await get(coordinatorURL: coordinatorURL, path: ownerPath, token: token, notOffered: [401, 403, 404], decode: decodeOwned)
    }

    /// The public list and the account's own approvals as one answer. An account that holds none leaves the public
    /// answer as it is (production and staging byte for byte). When either request fails, the answer is that failure,
    /// so a partial answer never withdraws a saved approval that the other list holds.
    static func combined(_ listed: Outcome, owned: Outcome) -> Outcome {
        switch (listed, owned) {
        case (_, .notOffered): return listed
        case (.approvals(let listedEntries), .approvals(let own)): return .approvals(listedEntries + own)
        case (.notOffered, .approvals(let own)): return .approvals(own)
        case (.approvals, _), (.notOffered, _): return owned
        default: return listed
        }
    }

    private static func get(coordinatorURL: String, path: String, token: String?, notOffered: Set<Int>,
                            decode: (Data) throws -> [ClusterRuntimeApproval]) async -> Outcome {
        guard let url = url(coordinatorURL: coordinatorURL, path: path) else {
            return .unavailable("the coordinator URL is not HTTPS")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutSeconds; configuration.timeoutIntervalForResource = timeoutSeconds
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: ClusterNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.url == url else { return .unavailable("no HTTP answer") }
            if notOffered.contains(http.statusCode) { return .notOffered }
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

    /// What the provider configuration's coordinator serves, with the account's own approvals when this Mac holds
    /// the account credential (`combined`); nil when the provider configuration names no coordinator.
    static func fetch(providerConfiguration: URL, token: String? = AuthTokenStore.load()) async -> Outcome? {
        guard let coordinator = try? ConfigManager.loadOrDefaults(from: providerConfiguration).coordinator.url else { return nil }
        let listed = await fetch(coordinatorURL: coordinator)
        guard let token, !token.isEmpty else { return listed }
        return combined(listed, owned: await fetchOwned(coordinatorURL: coordinator, token: token))
    }

    /// The same, from a thread outside the cooperative pool (the cluster service's and the onboarding's threads).
    static func fetchBlocking(providerConfiguration: URL, token: String? = AuthTokenStore.load()) -> Outcome? {
        blockingWizard { await fetch(providerConfiguration: providerConfiguration, token: token) }
    }

    /// `{"schema":"darkbloom_cluster_catalog_v2","cluster_approvals":[…]}`, read as strictly as a saved setup reads
    /// one entry: the exact field names of one of the two shapes (build-pinned or a model approval, in any mix),
    /// nothing unknown or missing, and every entry must encode to coordinator policy bytes
    /// (`ClusterRuntimeApproval.canonicalPolicy`). One bad entry refuses the whole answer.
    static func decode(_ data: Data) throws -> [ClusterRuntimeApproval] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schema", "cluster_approvals"], object["schema"] as? String == schemaName,
              let entries = object["cluster_approvals"] as? [[String: Any]], entries.count <= maximumApprovals,
              entries.allSatisfy({ ClusterRuntimeApproval.isEntry($0.keys) }) else {
            throw ClusterConfigurationError.invalid("The cluster approvals answer is not a \(schemaName) list")
        }
        struct List: Decodable { let clusterApprovals: [ClusterRuntimeApproval]
            enum CodingKeys: String, CodingKey { case clusterApprovals = "cluster_approvals" } }
        let approvals = try JSONDecoder().decode(List.self, from: data).clusterApprovals
        for approval in approvals { _ = try approval.canonicalPolicy() }
        return approvals
    }

    /// `{"approvals":[{"approval":{…},"policy_sha256":"…"}]}`: each entry read as `decodeOwnedEntry` reads one. One
    /// bad entry refuses the whole answer.
    static func decodeOwned(_ data: Data) throws -> [ClusterRuntimeApproval] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == ["approvals"],
              let entries = object["approvals"] as? [[String: Any]], entries.count <= maximumApprovals,
              entries.allSatisfy(isOwnedEntry) else {
            throw ClusterConfigurationError.invalid("The owner approvals answer is not an approvals list")
        }
        struct List: Decodable { let approvals: [OwnedEntry] }
        return try JSONDecoder().decode(List.self, from: data).approvals.map { try $0.verified() }
    }

    /// `{"approval":{…},"policy_sha256":"…"}`, the answer of a registration: the `approval` read as strictly as a
    /// public entry (`decode`), and its `policy_sha256` must be the SHA-256 of the canonical policy bytes this Mac
    /// derives from it.
    static func decodeOwnedEntry(_ data: Data) throws -> ClusterRuntimeApproval {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], isOwnedEntry(object) else {
            throw ClusterConfigurationError.invalid("The answer is not an owner approval")
        }
        return try JSONDecoder().decode(OwnedEntry.self, from: data).verified()
    }

    private static func isOwnedEntry(_ entry: [String: Any]) -> Bool {
        Set(entry.keys) == ["approval", "policy_sha256"]
            && (entry["approval"] as? [String: Any]).map { ClusterRuntimeApproval.isEntry($0.keys) } == true
    }

    private struct OwnedEntry: Decodable {
        let approval: ClusterRuntimeApproval
        let policySHA256: String
        enum CodingKeys: String, CodingKey { case approval; case policySHA256 = "policy_sha256" }

        func verified() throws -> ClusterRuntimeApproval {
            guard ClusterConfigurationCodec.sha256(try approval.canonicalPolicy()) == policySHA256 else {
                throw ClusterConfigurationError.invalid("Owner approval \(approval.id) does not hash to its policy_sha256")
            }
            return approval
        }
    }
}
