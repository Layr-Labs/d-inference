import Foundation
import Darwin
import DarkbloomClusterRemote
import DarkbloomClusterProtocol

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

/// The receiving Mac's own installed cluster worker, asked to describe a staged copy exactly as it describes a model
/// before it loads it (`--describe-runtime` with this Mac's pinned worker hash: the registered configuration and
/// manifest bytes). The catalog's aggregate digest covers the file digests but not their names, so a paired peer
/// could otherwise send an approved model under renamed files; this check binds names, configuration and manifest
/// to what the worker loads, before the folder is put in place.
struct ClusterModelWorkerCheck: Sendable {
    var executable: URL
    var runtimeBinarySHA256: String

    /// Nil when the worker describes the staged folder as this artifact; otherwise why not, in words.
    func refusal(staged: URL, artifact: ClusterCatalogArtifact) -> String? {
        let arguments = ["--describe-runtime", "--config", staged.appendingPathComponent("config.json").path,
                         "--manifest", staged.appendingPathComponent("manifest.json").path,
                         "--expected-executable-sha256", runtimeBinarySHA256]
        let outcome: ClusterSetupChild.Outcome
        do {
            outcome = try ClusterSetupChild.run(executable: executable, arguments: arguments, seconds: 20,
                                                maximumOutputBytes: ClusterRuntimeCapabilityCodec.maximumBytes)
        } catch {
            return "its runtime description did not run (\(ClusterConsoleText.bounded(String(describing: error), maximum: 160)))"
        }
        guard outcome.status == 0 else {
            let line = outcome.errorText.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit status \(outcome.status)"
            return "its runtime description refused the files (\(ClusterConsoleText.bounded(line, maximum: 200)))"
        }
        guard let described = try? ClusterCapabilityRecord.decode(outcome.output, writtenBy: "this Mac's cluster worker") else {
            return "its runtime description could not be read"
        }
        guard described.runtimeBinarySHA256 == runtimeBinarySHA256 else { return "its runtime description names another worker build" }
        guard described.artifactSHA256 == artifact.aggregateSHA256 else {
            return "it registers these files as \(described.runtimeModelID) with another artifact digest"
        }
        return nil
    }
}

/// The receiving side, one copy at a time, driven by the sender's frames on the cluster service's link listener.
final class ClusterModelProvisionResponder: @unchecked Sendable {
    let store: @Sendable () -> URL
    let trust: @Sendable (ClusterCatalogArtifact) -> String?
    /// This Mac's installed worker for the staged-folder check; throws (the copy is refused before any byte) when
    /// this Mac has no worker set up to check with.
    let worker: @Sendable () throws -> ClusterModelWorkerCheck
    let say: @Sendable (String) -> Void
    private var receiver: ClusterModelReceiver?
    private var failure: String?
    private var received: Int64 = 0
    private var started = Date()

    init(store: @escaping @Sendable () -> URL, trust: @escaping @Sendable (ClusterCatalogArtifact) -> String?,
         worker: @escaping @Sendable () throws -> ClusterModelWorkerCheck, say: @escaping @Sendable (String) -> Void) {
        self.store = store; self.trust = trust; self.worker = worker; self.say = say
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
                // Fail closed: no worker to check the staged folder with, no copy.
                let check: ClusterModelWorkerCheck
                do { check = try worker() } catch {
                    throw ClusterSetupFailure("this Mac cannot check a copied model with its own cluster worker (\(ClusterConsoleText.bounded(String(describing: error), maximum: 200))); it was not accepted")
                }
                let created = try ClusterModelReceiver(artifact: artifact, store: store(), folder: begin.folder,
                    expectedAggregate: nil, trust: trust, stagedCheck: { check.refusal(staged: $0, artifact: artifact) })
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
                say("model copy stopped: \(error)")
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
                say("model copy refused: \(error)")
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
    /// `folder`; `progress(bytes sent so far, bytes to send)` about once a second; `begun` once the other Mac took the
    /// copy (before any byte flows), so a caller can answer as soon as it is under way or refused.
    func copy(artifact: ClusterCatalogArtifact, source: URL, folder: String, begun: (@Sendable (ClusterModelReceiveState) -> Void)? = nil,
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
        guard state.complete || state.offsets.count == artifact.files.count else { throw ClusterSetupFailure("the other Mac answered the copy with another file list") }
        begun?(state)
        if state.complete { return .init(sentBytes: 0, seconds: 0, alreadyThere: true) }
        let total = zip(artifact.files, state.offsets).reduce(Int64(0)) { $0 + $1.0.sizeBytes - $1.1 }
        let chunk = ClusterSetupLinkExchange.provisionChunkBytes
        let window = ClusterSetupLinkExchange.provisionWindowBytes / chunk
        let started = Date()
        var sent: Int64 = 0, chunks: Int64 = 0, lastReport = Date()
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
                          port: UInt16 = ClusterSetupLinkExchange.port, policy: ClusterLinkInterfacePolicy = .thunderboltOnly,
                          begun: (@Sendable (ClusterModelReceiveState) -> Void)? = nil,
                          progress: @escaping @Sendable (Int64, Int64) -> Void) throws -> ClusterModelCopyClient.Outcome {
        try oneAtATime(seconds: 60) {
            var address = peerAddress
            if address == nil { address = ClusterLinkPairingDiscovery.find(selection: selection, port: port, seconds: 8).first?.address }
            guard let address else { throw ClusterSetupFailure("the other Mac's cluster service did not answer on the cable") }
            return try ClusterModelCopyClient(pairing: pairing, selection: selection, peerAddress: address, port: port, policy: policy)
                .copy(artifact: artifact, source: source, folder: folder, begun: begun, progress: progress)
        }
    }
}

