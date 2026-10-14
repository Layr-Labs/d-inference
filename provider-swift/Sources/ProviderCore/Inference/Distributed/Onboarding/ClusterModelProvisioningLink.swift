import Foundation
import Darwin
import DarkbloomClusterRemote

// The model copy on the paired link: the Mac that has the model sends it to a Mac that lacks it inside a link control
// session keyed by the pairing's edge secret (authenticated and encrypted records, rekeyed by the channel before its
// per-key caps; never plain TCP, never SSH). The receiving Mac's cluster service checks the manifest against the
// catalog identity, writes uncached into a hidden staging folder of its own model store, verifies every file's
// SHA-256 and renames the folder into place; the sender keeps a bounded window of bytes in flight, acknowledged
// only after the receiver wrote and hashed them, so neither Mac buffers a model in memory.

extension ClusterSetupLinkExchange {
    static let provisionBeginTag: UInt16 = 0x5E07
    static let provisionStateTag: UInt16 = 0x5E08
    static let provisionChunkTag: UInt16 = 0x5E09
    static let provisionAckTag: UInt16 = 0x5E0A
    static let provisionFileTag: UInt16 = 0x5E0B
    static let provisionFileReplyTag: UInt16 = 0x5E0C
    static let provisionCommitTag: UInt16 = 0x5E0D
    static let provisionCommitReplyTag: UInt16 = 0x5E0E

    /// Bytes in flight on one copy (chunks of `provisionChunkBytes`).
    static let provisionWindowBytes = 32 << 20
}

/// What the sending Mac asks first.
struct ClusterModelCopyBegin: Codable, Sendable {
    var manifest: Data
    var folder: String
}

/// Where the cluster's model folders live when no folder was given (`darkbloom cluster` needs no `--model-dir`):
/// beside the product's own model cache, so a model single-Mac Darkbloom downloaded is cloned in on the same volume
/// with no new blocks, and a copy lands on the disk the person chose for models.
public enum ClusterModelStoreLocation {
    public static func defaultDirectory() -> URL {
        ModelScanner.cacheDirectory().deletingLastPathComponent().appendingPathComponent("darkbloom-cluster-models", isDirectory: true)
    }
}

/// The receiving side, one copy at a time, driven by the sender's frames on the cluster service's link listener.
final class ClusterModelProvisionResponder: @unchecked Sendable {
    let store: @Sendable () -> URL
    let trust: @Sendable (ClusterCatalogArtifact) -> String?
    let say: @Sendable (String) -> Void
    private var receiver: ClusterModelReceiver?
    private var failure: String?
    private var received: Int64 = 0
    private var started = Date()

    init(store: @escaping @Sendable () -> URL, trust: @escaping @Sendable (ClusterCatalogArtifact) -> String?, say: @escaping @Sendable (String) -> Void) {
        self.store = store; self.trust = trust; self.say = say
    }

    static func error(_ text: String) -> Data { Data(("error:" + ClusterConsoleText.bounded(text, maximum: 300)).utf8) }

    /// One frame; the reply to send (tag, bytes), nil when the frame is not a copy frame. Runs on the listener's
    /// serial work queue, so frames are handled in the order they were sent.
    func handle(tag: UInt16, _ data: Data) -> (UInt16, Data)? {
        typealias X = ClusterSetupLinkExchange
        switch tag {
        case X.provisionBeginTag:
            receiver = nil; failure = nil; received = 0; started = Date()
            do {
                let begin = try JSONDecoder().decode(ClusterModelCopyBegin.self, from: data)
                let artifact = try ClusterCatalogArtifact.parse(manifest: begin.manifest)
                let created = try ClusterModelReceiver(artifact: artifact, store: store(), folder: begin.folder,
                    expectedAggregate: nil, trust: trust)
                let state = try created.begin()
                receiver = state.complete ? nil : created
                say("model copy: \(artifact.modelID) \(artifact.version) into \(begin.folder): " + (state.complete ? "already here"
                    : "\(ClusterModelProvisioning.gigabytes(zip(artifact.files, state.offsets).reduce(Int64(0)) { $0 + $1.0.sizeBytes - $1.1 })) to receive"))
                return (X.provisionStateTag, try JSONEncoder().encode(state))
            } catch {
                say("model copy refused: \(error)")
                return (X.provisionStateTag, Self.error("\(error)"))
            }
        case X.provisionChunkTag:
            if let failure { return (X.provisionAckTag, Self.error(failure)) }
            guard let receiver, let chunk = ClusterModelTransferWire.parseChunk(data) else {
                failure = "a copy frame arrived with no copy under way"
                return (X.provisionAckTag, Self.error(failure!))
            }
            do {
                try receiver.write(index: chunk.index, offset: chunk.offset, chunk.bytes)
                received += Int64(chunk.bytes.count)
                return (X.provisionAckTag, ClusterModelTransferWire.chunk(index: chunk.index, offset: chunk.offset + Int64(chunk.bytes.count), Data()))
            } catch {
                failure = "\(error)"
                return (X.provisionAckTag, Self.error(failure!))
            }
        case X.provisionFileTag:
            if let failure { return (X.provisionFileReplyTag, Self.error(failure)) }
            guard let receiver, data.count == 4 else { return (X.provisionFileReplyTag, Self.error("no copy under way")) }
            let index = Int(data.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            do { try receiver.finish(index: index); return (X.provisionFileReplyTag, Data("ok".utf8)) } catch {
                failure = "\(error)"
                say("model copy: \(error)")
                return (X.provisionFileReplyTag, Self.error(failure!))
            }
        case X.provisionCommitTag:
            if let failure { return (X.provisionCommitReplyTag, Self.error(failure)) }
            guard let receiver else { return (X.provisionCommitReplyTag, Self.error("no copy under way")) }
            do {
                let placed = try receiver.commit()
                self.receiver = nil
                let seconds = Date().timeIntervalSince(started)
                say("model copy: \(placed.lastPathComponent) in place, every file verified (\(ClusterModelProvisioning.gigabytes(received)) in \(String(format: "%.1f", seconds)) s)")
                return (X.provisionCommitReplyTag, Data(("ok:" + placed.lastPathComponent).utf8))
            } catch {
                failure = "\(error)"
                return (X.provisionCommitReplyTag, Self.error(failure!))
            }
        default:
            return nil
        }
    }
}

/// The sending side: one session to the receiving Mac's cluster service, the bounded window, the replies.
final class ClusterModelCopyClient: @unchecked Sendable {
    struct Outcome: Sendable { var sentBytes: Int64; var seconds: Double; var alreadyThere: Bool }

    private let client: ClusterLinkControlClient
    private let condition = NSCondition()
    private var replies: [UInt16: Data] = [:]
    private var acknowledged: Int64 = 0
    private var ackError: String?

    init(pairing: ClusterSetupLinkExchange.Pairing, selection: ClusterLinkInterfaceSelection, peerAddress: ClusterLinkIPv4Address,
         port: UInt16 = ClusterSetupLinkExchange.port, policy: ClusterLinkInterfacePolicy = .thunderboltOnly) throws {
        let edge = try ClusterSetupLinkExchange.edge(pairing, peerAddress: peerAddress)
        let box = Box()
        client = try ClusterLinkControlClient(configuration: .init(interface: selection.interface, localAddress: selection.local.address,
            port: port, policy: policy, edge: edge)) { event, _ in
            guard case .opaque(_, _, let tag, let data) = event else { return }
            box.target?.deliver(tag: tag, data)
        }
        box.target = self
    }

    private final class Box: @unchecked Sendable { weak var target: ClusterModelCopyClient? }

    private func deliver(tag: UInt16, _ data: Data) {
        condition.lock(); defer { condition.unlock() }
        if tag == ClusterSetupLinkExchange.provisionAckTag {
            if data.starts(with: Data("error:".utf8)) { ackError = String(decoding: data.dropFirst(6), as: UTF8.self) }
            else if let ack = ClusterModelTransferWire.parseChunk(data) { _ = ack; acknowledged += 1 }
        } else {
            replies[tag] = data
        }
        condition.broadcast()
    }

    private func request(tag: UInt16, _ body: Data, reply: UInt16, seconds: Double) throws -> Data {
        condition.lock(); replies[reply] = nil; condition.unlock()
        _ = try client.peer.sendOpaque(tag: tag, body, timeout: .seconds(30))
        let deadline = Date(timeIntervalSinceNow: seconds)
        condition.lock(); defer { condition.unlock() }
        while replies[reply] == nil {
            if let ackError { throw ClusterSetupFailure("the other Mac stopped the copy: \(ackError)") }
            guard condition.wait(until: deadline) else { throw ClusterSetupFailure("the other Mac did not answer the copy within \(Int(seconds)) s") }
        }
        let data = replies[reply]!
        if data.starts(with: Data("error:".utf8)) { throw ClusterSetupFailure("the other Mac refused the copy: " + String(decoding: data.dropFirst(6), as: UTF8.self)) }
        return data
    }

    /// Sends the model in `source` (verified against `artifact` file by file on the other side) into its store as
    /// `folder`; `progress(bytes sent so far, bytes to send)` about once a second.
    func copy(artifact: ClusterCatalogArtifact, source: URL, folder: String,
              progress: @escaping @Sendable (Int64, Int64) -> Void) throws -> Outcome {
        client.start()
        defer { client.stop() }
        guard client.peer.waitUntilConnected(timeout: .seconds(10)) else {
            let reason = client.lastRefusal.map { "refused (\($0))" } ?? client.lastConnectFailure ?? "no answer"
            throw ClusterSetupFailure("the other Mac's cluster service did not take the paired connection: \(reason)")
        }
        let sender = try ClusterModelSender(artifact: artifact, directory: source)
        let begin = try JSONEncoder().encode(ClusterModelCopyBegin(manifest: artifact.manifest, folder: folder))
        let stateData = try request(tag: ClusterSetupLinkExchange.provisionBeginTag, begin, reply: ClusterSetupLinkExchange.provisionStateTag, seconds: 600)
        let state = try JSONDecoder().decode(ClusterModelReceiveState.self, from: stateData)
        if state.complete { return .init(sentBytes: 0, seconds: 0, alreadyThere: true) }
        guard state.offsets.count == artifact.files.count else { throw ClusterSetupFailure("the other Mac answered the copy with another file list") }
        let total = zip(artifact.files, state.offsets).reduce(Int64(0)) { $0 + $1.0.sizeBytes - $1.1 }
        let chunk = ClusterSetupLinkExchange.provisionChunkBytes
        let window = ClusterSetupLinkExchange.provisionWindowBytes / chunk
        let started = Date()
        var sent: Int64 = 0, chunks: Int64 = 0, lastReport = Date.distantPast
        for (index, file) in artifact.files.enumerated() where state.offsets[index] < file.sizeBytes {
            var offset = state.offsets[index]
            while offset < file.sizeBytes {
                let bytes = try sender.read(index: index, offset: offset, count: chunk)
                // At most `window` chunks written but not yet acknowledged (written and hashed) by the other Mac.
                condition.lock()
                let deadline = Date(timeIntervalSinceNow: 120)
                while chunks - acknowledged >= Int64(window) && ackError == nil {
                    guard condition.wait(until: deadline) else {
                        condition.unlock(); throw ClusterSetupFailure("the other Mac stopped acknowledging the copy for 2 minutes")
                    }
                }
                let failed = ackError
                condition.unlock()
                if let failed { throw ClusterSetupFailure("the other Mac stopped the copy: \(failed)") }
                _ = try client.peer.sendOpaque(tag: ClusterSetupLinkExchange.provisionChunkTag,
                    ClusterModelTransferWire.chunk(index: index, offset: offset, bytes), timeout: .seconds(60))
                chunks += 1; offset += Int64(bytes.count); sent += Int64(bytes.count)
                if Date().timeIntervalSince(lastReport) >= 1 { progress(sent, total); lastReport = Date() }
            }
            var name = Data(count: 4)
            name.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(index).bigEndian, as: UInt32.self) }
            _ = try request(tag: ClusterSetupLinkExchange.provisionFileTag, name, reply: ClusterSetupLinkExchange.provisionFileReplyTag, seconds: 600)
        }
        _ = try request(tag: ClusterSetupLinkExchange.provisionCommitTag, Data(), reply: ClusterSetupLinkExchange.provisionCommitReplyTag, seconds: 600)
        progress(sent, total)
        return .init(sentBytes: sent, seconds: Date().timeIntervalSince(started), alreadyThere: false)
    }
}

extension ClusterSetupLinkExchange {
    /// Copies one model to the paired Mac's cluster service over the cable (one request at a time per user, so the
    /// leader's service does not take the session away mid-copy).
    static func copyModel(pairing: Pairing, selection: ClusterLinkInterfaceSelection, peerAddress: ClusterLinkIPv4Address?,
                          artifact: ClusterCatalogArtifact, source: URL, folder: String,
                          progress: @escaping @Sendable (Int64, Int64) -> Void) throws -> ClusterModelCopyClient.Outcome {
        try oneAtATime(seconds: 60) {
            var address = peerAddress
            if address == nil { address = ClusterLinkPairingDiscovery.find(selection: selection, port: port, seconds: 8).first?.address }
            guard let address else { throw ClusterSetupFailure("the other Mac's cluster service did not answer on the cable") }
            return try ClusterModelCopyClient(pairing: pairing, selection: selection, peerAddress: address)
                .copy(artifact: artifact, source: source, folder: folder, progress: progress)
        }
    }
}

/// The product's single-Mac model store (the models `darkbloom` downloaded, discovered as single-Mac Darkbloom
/// discovers them) seen from the cluster: each active revision's verified receipt is the catalog manifest, and its
/// files are cloned into the cluster's store (APFS clones: no new blocks, each file single-linked) so the cluster
/// worker loads it from a flat folder with its manifest.
enum ClusterProductModelStore {
    struct Installed: Sendable { var artifact: ClusterCatalogArtifact; var directory: URL }

    /// Every model the product store has an active, receipted revision of.
    static func installed(cache: URL = ModelScanner.cacheDirectory()) -> [Installed] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []).sorted().filter { $0.hasPrefix("models--") }
        return names.prefix(256).compactMap { name in
            let model = cache.appendingPathComponent(name)
            guard let ref = ClusterModelStore.readSmall(model.appendingPathComponent("refs/main")),
                  let revision = String(data: ref, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !revision.isEmpty, !revision.contains("/") else { return nil }
            let directory = model.appendingPathComponent("snapshots").appendingPathComponent(revision)
            guard let receipt = ClusterModelStore.readSmall(directory.appendingPathComponent(".darkbloom-manifest.json")),
                  let artifact = try? ClusterCatalogArtifact.parse(manifest: receipt) else { return nil }
            return .init(artifact: artifact, directory: directory)
        }
    }

    /// Clones a product-store model into the cluster's store under its folder name; nil when it is there already.
    static func cloneIntoClusterStore(_ installed: Installed, store: URL) throws -> String? {
        let artifact = installed.artifact
        if case .complete = ClusterModelStore.holding(store: store, artifact: artifact) { return nil }
        let folder = artifact.folderName
        let destination = store.appendingPathComponent(folder)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return nil }
        let staging = store.appendingPathComponent(".darkbloom-clone-" + String(artifact.aggregateSHA256.prefix(32)))
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for file in artifact.files {
                let target = staging.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                var info = stat()
                let source = installed.directory.appendingPathComponent(file.path)
                guard lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int64(info.st_size) == file.sizeBytes else {
                    throw ClusterSetupFailure("the product store's \(file.path) is missing or not its manifest size")
                }
                guard clonefile(source.path, target.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
                    throw ClusterSetupFailure("\(file.path) could not be cloned into the cluster's model store (errno \(errno)); the cluster store must be on the same disk as the product's models")
                }
            }
            try artifact.manifest.write(to: staging.appendingPathComponent("manifest.json"))
            guard rename(staging.path, destination.path) == 0 else { throw ClusterSetupFailure("the cloned folder could not be put in place") }
            return folder
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }
}

/// The protected-build trust check for a copied model: a build the catalog marks with required runtime capabilities
/// (the Qwen3.8 27B builds) is accepted from another Mac only when this build's own qualification records pin its
/// exact artifact digest; every other model is accepted on its manifest (each file then verified by digest).
enum ClusterModelCopyTrust {
    static func refusal(_ artifact: ClusterCatalogArtifact) -> String? {
        guard !ModelRuntimeRequirements.requiredCapabilities(for: artifact.modelID).isEmpty else { return nil }
        if ClusterPairQualificationRecordsBundled.jsonLines.contains("\"artifactSHA256\":\"\(artifact.aggregateSHA256)\"") { return nil }
        return "\(artifact.modelID) is a protected build, and this build's qualification records do not pin the offered digest \(artifact.aggregateSHA256.prefix(12))…; it was not accepted"
    }
}
