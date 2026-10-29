import Foundation

/// The coordinator's cluster approvals for this Mac's release (`GET /v1/cluster/approvals`): public build facts, so
/// the request carries no credential. The answer approves nothing by itself: each Mac checks an entry against its own
/// installed files before it saves it (`ClusterApprovalAttachment`). A coordinator without pairing answers 404, and
/// every failure means "no approval": nothing here can stop a Mac from serving.
public enum ClusterApprovalFetch {
    public static let path = "/v1/cluster/approvals"
    public static let platform = "macos-arm64"
    public static let schemaName = "darkbloom_cluster_catalog_v2"
    /// A release lists at most 64 models (contract A), each approved for two schedules.
    static let maximumApprovals = 128
    static let maximumBytes = 512 * 1024
    static let timeoutSeconds: Double = 10

    public enum Outcome: Equatable, Sendable {
        case approvals([ClusterRuntimeApproval])
        /// 404: pairing is off on this coordinator, or the release has no cluster runtime.
        case notOffered
        /// Any other answer, or a URL this Mac does not ask: the reason, for one log line.
        case unavailable(String)
        /// No answer at all (the request failed before an HTTP answer: no route, refused, timed out): the reason. An
        /// offered pair whose coordinator stays so for the absence grace serves locally (`ClusterApprovalSync.step`).
        case unreachable(String)
    }

    /// The request URL for the provider's coordinator: HTTPS, or plain HTTP to this Mac's own loopback (a local test
    /// coordinator). Nil for any other URL, so a plain request never leaves the Mac.
    static func url(coordinatorURL: String, version: String) -> URL? {
        guard var components = URLComponents(string: coordinatorHTTPBase(coordinatorURL)),
              let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(),
              scheme == "https" || (scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)),
              components.query == nil, components.fragment == nil else { return nil }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + path
        components.queryItems = [URLQueryItem(name: "version", value: version), URLQueryItem(name: "platform", value: platform)]
        return components.url
    }

    public static func fetch(coordinatorURL: String, version: String = ProviderCore.version) async -> Outcome {
        guard let url = url(coordinatorURL: coordinatorURL, version: version) else {
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
            var bytes = Data()
            for try await byte in stream {
                guard bytes.count < maximumBytes else { return .unavailable("the answer exceeds its bound") }
                bytes.append(byte)
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

    /// What the provider configuration's coordinator offers for the Darkbloom app installed beside `configuration`'s
    /// worker (`installedVersion`); nil when the provider configuration names no coordinator.
    static func fetch(for configuration: ClusterConfiguration, providerConfiguration: URL) async -> Outcome? {
        guard let coordinator = try? ConfigManager.loadOrDefaults(from: providerConfiguration).coordinator.url else { return nil }
        return await fetch(coordinatorURL: coordinator, version: installedVersion(configuration))
    }

    /// The same, from a thread outside the cooperative pool (the cluster service's and the onboarding's threads).
    static func fetchBlocking(for configuration: ClusterConfiguration, providerConfiguration: URL) -> Outcome? {
        blockingWizard { await fetch(for: configuration, providerConfiguration: providerConfiguration) }
    }

    /// Largest `Info.plist` read for `installedVersion`.
    static let maximumInfoBytes = 64 * 1024

    /// The version of the Darkbloom app whose helpers `configuration` names: `CFBundleShortVersionString` of the
    /// `Contents/Info.plist` above the worker's `Contents/Helpers`. That is the app whose files each Mac checks the
    /// approval against (`ClusterApprovalAttachment.installation`) and whose worker the update re-adoption detects
    /// (`ClusterService.checkForUpdate`). After an update, a cluster service that has not restarted still runs the
    /// earlier build, so this process's own version would ask for the earlier release's approval. This process's
    /// version only when the worker is not inside an app, or the app names no valid version. The file is read
    /// directly, not through `Bundle`, which keeps a bundle's first `Info.plist` for the life of the process.
    static func installedVersion(_ configuration: ClusterConfiguration) -> String {
        let helpers = ClusterApprovalAttachment.installation(configuration).worker.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        guard helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents",
              let handle = try? FileHandle(forReadingFrom: contents.appendingPathComponent("Info.plist")) else {
            return ProviderCore.version
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumInfoBytes + 1), data.count <= maximumInfoBytes,
              let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String, SemanticVersion(version) != nil else {
            return ProviderCore.version
        }
        return version
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
