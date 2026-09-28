import Foundation
import Darwin
import CryptoKit
import DarkbloomClusterProtocol
@testable import InstalledContract

private struct Failure: Error { let message: String }
private func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
private func reject(_ body: () throws -> Void) throws {
    do { try body() } catch is Failure { throw Failure(message: "Assertion in refusal") } catch { return }
    throw Failure(message: "Expected refusal")
}

@main enum ClusterDiagnosticsCheck {
    static func main() throws {
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(30); defer { alarm(0) }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("diagnostics-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try InstalledFixture.make(root: root, probe: URL(fileURLWithPath: CommandLine.arguments[1]),
            owner: URL(fileURLWithPath: CommandLine.arguments[2]), worker: URL(fileURLWithPath: CommandLine.arguments[3]))
        try validation(f)
        try status(f)
        try discovery(f)
        try journal(f)
        print("Cluster diagnostics: read-only leader/follower metadata, closed fresh status, local discovery and journal uncertainty passed")
    }

    static func tree(_ root: URL) throws -> [String: String] {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        var result = [String: String]()
        for url in files {
            var info = stat(); try require(lstat(url.path, &info) == 0, "stat")
            let digest = info.st_mode & S_IFMT == S_IFREG ? ClusterConfigurationCodec.sha256(try Data(contentsOf: url)) : "directory"
            result[String(url.path.dropFirst(root.path.count))] = "\(info.st_mode):\(digest)"
        }
        return result
    }

    static func validation(_ f: InstalledFixture) throws {
        let before = try tree(f.root)
        let value = try DistributedInstalledValidation.validate(reference: f.reference, paths: f.paths,
            deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
        try require(value.plan.configuration.role == .leader && value.model.publicModelID == f.configuration.publicModelID, "leader metadata")
        try require(try tree(f.root) == before, "metadata validation wrote files")
        try require(!FileManager.default.fileExists(atPath: f.paths.deviceDirectory.appendingPathComponent("configuration").path), "matrix published")

        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.configuration)) as! [String: Any]
        object["role"] = "follower"; object["memberID"] = "peer-1"
        let input = f.root.appendingPathComponent("follower.json")
        try JSONSerialization.data(withJSONObject: object).write(to: input)
        var reference: ClusterConfigurationReference?
        _ = try ClusterConfigurationStore(paths: f.paths).save(configurationInput: input,
            capabilityInput: f.root.appendingPathComponent("capability.json"), capabilitySHA256: f.configuration.capabilitySHA256) { reference = $0 }
        let followerBefore = try tree(f.root)
        let follower = try DistributedInstalledValidation.validate(reference: reference!, paths: f.paths,
            deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
        try require(follower.plan.configuration.role == .follower && follower.plan.localPeer.rank == 1, "follower local selection")
        try require(try tree(f.root) == followerBefore, "follower validation wrote files")
        try reject { _ = try DistributedInstalledValidation.validate(reference: reference!, paths: f.paths, deadline: 1) }
        let fallback = value.model.directory.appendingPathComponent("chat_template.json")
        try Data("{}".utf8).write(to: fallback)
        let refusalBefore = try tree(f.root)
        try reject { _ = try DistributedInstalledValidation.validate(reference: f.reference, paths: f.paths,
            deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000) }
        try require(try tree(f.root) == refusalBefore, "refused metadata wrote files")
        try FileManager.default.removeItem(at: fallback)
    }

    static func status(_ f: InstalledFixture) throws {
        let binding = try ClusterStatusBinding(configuration: f.configuration, capability: f.capability)
        let nonce = UUID().uuidString.lowercased(), epoch = UUID().uuidString.lowercased()
        let sample = ClusterLiveStatus(schema: ClusterLiveStatus.schemaName, nonce: nonce, binding: binding,
            authenticationConfigured: true, hostPhase: "serving", session: .init(binding: binding, phase: "ready",
                observedMembershipEpoch: epoch, observedPrefillSchedule: .serial, ready: true,
                admission: .init(remainingLifetimeNanoseconds: 8_000_000_000, remainingRequests: 16, activeRequest: false, draining: false, valid: true),
                members: (0..<2).map { .init(peerID: "peer-\($0)", rank: $0, transport: $0 == 0 ? .localPipes : .authenticatedSSH,
                    nativeReady: true, requestCapacityBytes: 1024, nativeCleanupObserved: false, ownerReleaseAcknowledged: false, ownerTermination: nil) },
                mtpEnabled: false, mtpOffReason: "runtimeCapabilityDisablesSpeculation"),
            boundPort: 8000, acquisitions: 0, failed: false, ready: true, admissionAvailable: true, quarantined: false)
        func decode(_ bytes: Data, auth: Bool = true) throws -> ClusterLiveStatus {
            try ClusterStatusCodec.decode(bytes, nonce: nonce, binding: binding, authenticationConfigured: auth, port: 8000)
        }
        let encoded = try ClusterStatusCodec.encode(sample)
        try require(try decode(encoded) == sample, "round trip")
        func changed(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]; change(&object)
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]); data.append(10); return data
        }
        let noAuth = try changed { $0["authenticationConfigured"] = false }
        try require(try !decode(noAuth, auth: false).authenticationConfigured, "explicit no-auth rejected")
        try reject { _ = try decode(noAuth) }
        for field in ["nonce", "schema", "hostPhase"] {
            try reject { _ = try decode(changed { $0[field] = "wrong" }) }
        }
        try reject { _ = try decode(changed { $0["unknown"] = true }) }
        try reject { _ = try decode(changed { $0["acquisitions"] = true }) }
        try reject { _ = try decode(changed { $0["boundPort"] = 8001 }) }
        try reject { _ = try decode(changed { $0["ready"] = false }) }
        try reject { _ = try decode(changed { var b = $0["binding"] as! [String: Any]; b["planSHA256"] = String(repeating: "0", count: 64); $0["binding"] = b }) }
        for (key, value) in [("remainingRequests", 17), ("remainingLifetimeNanoseconds", 11_000_000_000)] {
            try reject { _ = try decode(changed { var s = $0["session"] as! [String: Any]; var a = s["admission"] as! [String: Any]; a[key] = value; s["admission"] = a; $0["session"] = s }) }
        }
        try reject { _ = try decode(changed { var s = $0["session"] as! [String: Any]; s["observedPrefillSchedule"] = "one_chunk_lookahead_v1"; $0["session"] = s }) }
        try reject { _ = try decode(changed { var s = $0["session"] as! [String: Any]; s["mtpEnabled"] = true; $0["session"] = s }) }
        try reject { _ = try decode(changed { var s = $0["session"] as! [String: Any]; var m = s["members"] as! [[String: Any]]; m[1]["ownerReleaseAcknowledged"] = true; s["members"] = m; $0["session"] = s }) }
        let text = String(decoding: encoded, as: UTF8.self)
        try reject { _ = try decode(Data(text.replacingOccurrences(of: "\"acquisitions\":0", with: "\"acquisitions\":0,\"acquisitions\":0").utf8)) }
        try reject { _ = try decode(Data(text.replacingOccurrences(of: "\"acquisitions\":0", with: "\"acquisitions\":0.0").utf8)) }
        try reject { _ = try decode(Data(repeating: 32, count: ClusterStatusCodec.maximumBytes + 1)) }
    }

    static func discovery(_ f: InstalledFixture) throws {
        func record(host: String, base: String? = nil, key: String = "fixture-bearer") throws -> ClusterStatusDiscovery {
            let advertised = host == "0.0.0.0" || host.isEmpty ? "127.0.0.1" : host
            return try JSONDecoder().decode(ClusterStatusDiscovery.self, from: JSONSerialization.data(withJSONObject:
                ["host": host, "port": 8000, "base_url": base ?? "http://\(advertised):8000/v1", "api_key": key]))
        }
        let assigned: Set<String> = ["127.0.0.1", "::1", "192.0.2.24"]
        for host in ["127.0.0.1", "0.0.0.0", "::", "::1", "localhost", "192.0.2.24"] {
            let url = try record(host: host).endpoint(localAddresses: assigned)
            try require(url.path == "/v1/cluster/status" && url.port == 8000, "local address refused")
        }
        try reject { _ = try record(host: "192.0.2.25").endpoint(localAddresses: assigned) }
        try reject { _ = try record(host: "other.example").endpoint(localAddresses: assigned) }
        try reject { _ = try record(host: "127.0.0.1", base: "http://remote.example:8000/v1").endpoint(localAddresses: assigned) }
        try reject { _ = try record(host: "127.0.0.1", base: "http://127.0.0.1:8000/v1?redirect=1").endpoint(localAddresses: assigned) }
        try reject { _ = try record(host: "127.0.0.1", key: "bad\nkey").endpoint(localAddresses: assigned) }
        try require(try record(host: "127.0.0.1", key: "").endpoint(localAddresses: assigned).port == 8000, "no-auth discovery")
        let link = f.root.appendingPathComponent("discovery-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: f.root.appendingPathComponent("input.json").path)
        try reject { _ = try ClusterStatusDiscovery.read(link) }
    }

    static func journal(_ f: InstalledFixture) throws {
        let file = f.paths.deviceLeaseFile
        let fd = open(file.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try require(fd >= 0, "fixture gate missing"); defer { Darwin.close(fd) }
        try require(flock(fd, LOCK_EX | LOCK_NB) == 0, "fixture gate busy"); defer { _ = flock(fd, LOCK_UN) }
        let before = try tree(f.root)
        try require(ClusterDeviceJournalObservation.read(paths: f.paths) == .emptyJournal, "empty locked journal not distinguished")
        try require(try tree(f.root) == before, "journal read wrote files")
        let payload = Data("unresolved ownership".utf8)
        let written = payload.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        try require(written == payload.count, "journal fixture write")
        let unresolved = try tree(f.root)
        try require(ClusterDeviceJournalObservation.read(paths: f.paths) == .ownershipUnproven, "nonempty journal inferred orphan/ready")
        try require(try tree(f.root) == unresolved, "journal observation changed ownership")
    }
}
