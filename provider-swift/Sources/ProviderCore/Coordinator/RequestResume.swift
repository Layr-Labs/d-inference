import CryptoKit
import Foundation

/// Request resume v1 (coordinator failover, phase 5;
/// `docs/reference/protocol-messages.md#request-resume-v1`).
///
/// A coordinator can put a resume id `r` in the sealed body of a request. When
/// the connection to that coordinator drops, this Mac keeps the request's
/// generation and its output for `window`, and lists `r` in its next
/// `register`. A surviving coordinator then dispatches the same request again,
/// through a normal hop 2 with a fresh session key. When every check of
/// `refusal(held:request:cacheReceiptNonce:signature:clusterRequest:)` passes,
/// that dispatch takes the held output: every chunk from the first, sealed to
/// its own session key, then its terminal. Anything else runs as new. The Mac
/// never derives `r`; it is an opaque value of the coordinator.
enum RequestResume {
    /// `register.request_resume_protocol`: this build keeps an interrupted
    /// request's work for a matching dispatch.
    static let protocolVersion = 1
    /// The wire names. Each is spelled once, in the coding key it reads.
    static let registerProtocolKey = ProviderMessage.CodingKeys.requestResumeProtocol.rawValue
    static let registerHeldKey = ProviderMessage.CodingKeys.resumableRequests.rawValue
    static let sealedBodyMember = BodyProbe.CodingKeys.member.rawValue
    /// The most requests held at once, and the most `register` lists. The
    /// held set is also never larger than the requests this Mac runs at once.
    static let maxHeldRequests = 64
    /// How long a held request waits for its dispatch: from the disconnect,
    /// or from the end of its generation when that is later.
    static let window: Duration = .seconds(15)
    /// The response bytes one resumable request keeps. A request whose output
    /// grows past it is no longer resumable: it is cancelled at a disconnect,
    /// as every request was before.
    static let maxBufferedOutputBytes = 4 << 20

    /// The `_darkbloom_resume_id` member of a decrypted request body: 64
    /// lowercase hexadecimal characters. Any other value reads as absent.
    struct BodyProbe: Decodable {
        let value: String?

        enum CodingKeys: String, CodingKey {
            case member = "_darkbloom_resume_id"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try? container.decodeIfPresent(String.self, forKey: .member)
            value = raw.flatMap { RequestResume.isResumeID($0) ? $0 : nil }
        }
    }

    static func isResumeID(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 64 && bytes.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// The request fields outside the box that change the output or its
    /// receipts (`CoordinatorClient+Inbound.swift`), and the model the body
    /// asks for. A dispatch attaches only when all of them are equal.
    struct OuterFields: Sendable, Equatable {
        var model: String
        var cacheScope: String?
        var prefixCacheProtocol: Int?
        var cacheReceiptBoundaryMode: String?
        var cacheRepeatedPrefixTokens: Int?
        var toolSchemaMetadataProtocol: Int?
        var gemmaPromptContract: Int?
    }

    /// What the Mac keeps of a resumable request to match a later dispatch.
    /// The body itself is not kept: only its SHA-256.
    struct Identity: Sendable {
        let resumeID: String
        /// SHA-256 of the exact decrypted body bytes.
        let bodyDigest: Data
        /// The hop-2 session public key the body was sealed with.
        let sessionKey: Data
        let outer: OuterFields

        init(resumeID: String, body: Data, sessionKey: Data, outer: OuterFields) {
            self.resumeID = resumeID
            self.bodyDigest = Data(SHA256.hash(data: body))
            self.sessionKey = sessionKey
            self.outer = outer
        }
    }

    /// Why a dispatch with a held request's resume id runs as new.
    enum Refusal: String, Sendable, Equatable {
        /// Its decrypted body is not the held request's.
        case body
        /// It is sealed with the held request's own session key: a copy of
        /// the dead coordinator's frame, whose answer nobody can read.
        case sameSessionKey = "same_session_key"
        case outerFields = "outer_fields"
        /// It carries a receipt nonce: the held output has no receipt that
        /// could be bound to it.
        case receiptNonce = "receipt_nonce"
        /// The build pins coordinator request-signing keys and the dispatch
        /// carries no verified signature.
        case unsigned
        /// Pair and cluster requests are never resumed.
        case clusterRequest = "cluster_request"
    }

    /// Nil when `request` may take the output of `held`, which carries the
    /// same resume id. The digests are compared in constant time.
    static func refusal(
        held: Identity, request: Identity, cacheReceiptNonce: String?,
        signature: CoordinatorSignatureCheck, clusterRequest: Bool
    ) -> Refusal? {
        let sameBody = constantTimeEqual(held.bodyDigest, request.bodyDigest)
        if clusterRequest { return .clusterRequest }
        if !sameBody { return .body }
        if held.sessionKey == request.sessionKey { return .sameSessionKey }
        if held.outer != request.outer { return .outerFields }
        if cacheReceiptNonce != nil { return .receiptNonce }
        if signature == .unsigned { return .unsigned }
        return nil
    }

    /// Length-checked constant-time comparison of two digests.
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}

/// One resumable request's response path. Its generation sends every chunk
/// here. While the request's connection lives, a chunk goes to its
/// coordinator at once; every chunk is also kept, in order, for a later
/// dispatch. While the request is held, chunks are only kept. An attached
/// dispatch gets every kept chunk from the first, then the live ones, all
/// sealed to its own session key with this Mac's static key as sender, and
/// then the terminal with the whole usage.
final class ResumableResponse: @unchecked Sendable {
    /// Where the response goes: one dispatch's request id, its sealer and its
    /// connection.
    struct Binding: Sendable {
        let requestId: String
        let sealer: ResponseFrameSealer
        let send: SendHandle
        /// This dispatch took the output of an earlier one.
        let resumed: Bool
    }

    /// The end of the generation, kept while the request is held. The
    /// terminal is built from it for the dispatch it goes to: the response
    /// hash covers that dispatch's request id.
    struct Completion {
        let usage: UsageInfo
        let stopSequence: String?
        let completionTokens: UInt64
        /// The output the response hash covers (zeroed when released).
        let response: ResponseTextBuffer
        let profile: RequestProfileBuilder
        let signer: (any AttestationSigner)?
    }

    enum EmitResult: Equatable {
        case sent
        /// The chunk could not be sealed to the bound session key.
        case sealFailed
        /// Nothing will take this output: the generation stops.
        case dropped
    }

    enum AttachResult: Equatable {
        /// The generation runs on; its next chunks go to the new dispatch.
        case running
        /// The whole answer, terminal included, went to the new dispatch.
        case finished
        case refused
    }

    private enum Phase {
        /// Connected; nil until the generation's own sealer exists.
        case live(Binding?)
        case held
        /// Its terminal went out.
        case done
        /// Dropped unanswered.
        case closed
    }

    /// The generation's own request id.
    let requestId: String
    private let originalSend: SendHandle
    private let maxBufferedBytes: Int
    private let lock = NSLock()
    private var phase = Phase.live(nil)
    /// Every chunk's plaintext, back to back; nil once the request can no
    /// longer be resumed.
    private var output: ResponseTextBuffer? = ResponseTextBuffer()
    private var chunkEnds: [Int] = []
    private var completion: Completion?
    private var generationEndedAt: ContinuousClock.Instant?

    init(requestId: String, send: SendHandle, maxBufferedBytes: Int = RequestResume.maxBufferedOutputBytes) {
        self.requestId = requestId
        self.originalSend = send
        self.maxBufferedBytes = maxBufferedBytes
    }

    /// The generation's sealer for its own session key.
    func start(sealer: ResponseFrameSealer) {
        lock.withLock {
            if case .live(.none) = phase {
                phase = .live(Binding(requestId: requestId, sealer: sealer, send: originalSend, resumed: false))
            }
        }
    }

    /// The send handle for the generation's control messages. An error
    /// terminal goes to the dispatch now bound, under its request id, and
    /// nowhere while the request is held: a held request that fails is
    /// dropped, and its dispatch runs as new.
    func controlHandle() -> SendHandle {
        SendHandle { [self] message in forward(message) }
    }

    /// Seals and sends one chunk to the bound dispatch, and keeps it.
    func emit(_ chunk: String) -> EmitResult {
        lock.withLock {
            switch phase {
            case .live(let binding):
                keep(chunk)
                guard let binding else { return .sent }
                do {
                    let payload = try binding.sealer.sealFrame(chunk.utf8)
                    binding.send.sendChunk(.inferenceChunk(
                        requestId: binding.requestId, data: "", encryptedData: payload))
                    return .sent
                } catch {
                    return .sealFailed
                }
            case .held:
                keep(chunk)
                if output == nil {
                    closeLocked()
                    return .dropped
                }
                return .sent
            case .done, .closed:
                return .dropped
            }
        }
    }

    /// The generation ended with its answer: the terminal goes to the bound
    /// dispatch, or is kept while the request is held.
    func complete(_ end: Completion) {
        lock.withLock {
            switch phase {
            case .live(let binding?):
                binding.send.send(Self.terminal(end, for: binding))
                phase = .done
            case .live(.none):
                phase = .done
            case .held:
                completion = end
                generationEndedAt = .now
            case .done, .closed:
                break
            }
        }
    }

    /// The connection dropped: keep the output for a matching dispatch.
    /// False when this request cannot be resumed: its output passed the cap,
    /// its terminal already went out, or it already took another dispatch's
    /// place.
    func hold() -> Bool {
        lock.withLock {
            guard output != nil else { return false }
            switch phase {
            case .live(let binding):
                if binding?.resumed == true { return false }
                phase = .held
                return true
            case .held:
                return true
            case .done, .closed:
                return false
            }
        }
    }

    var isHeld: Bool {
        lock.withLock {
            if case .held = phase { return true }
            return false
        }
    }

    /// When the generation of a held request ended; nil while it runs.
    var endedAt: ContinuousClock.Instant? { lock.withLock { generationEndedAt } }

    /// Gives this held request's output to `binding`: every kept chunk from
    /// the first, then its terminal when the generation has ended, or the live
    /// chunks from now on. `accepted` runs first, and only when it attaches.
    func attach(_ binding: Binding, accepted: () -> Void) -> AttachResult {
        lock.withLock {
            guard case .held = phase, let output else { return .refused }
            accepted()
            var start = 0
            for end in chunkEnds {
                let payload: EncryptedPayload
                do {
                    payload = try output.withBytes(in: start..<end) { try binding.sealer.sealFrame($0) }
                } catch {
                    binding.send.send(.inferenceError(
                        requestId: binding.requestId,
                        failure: InferenceFailure(code: .encryptionFailure, statusCode: 502)))
                    closeLocked()
                    return .finished
                }
                binding.send.sendChunk(.inferenceChunk(
                    requestId: binding.requestId, data: "", encryptedData: payload))
                start = end
            }
            // Never resumed twice: nothing more is kept.
            self.output = nil
            chunkEnds = []
            if let end = completion {
                completion = nil
                binding.send.send(Self.terminal(end, for: binding))
                phase = .done
                return .finished
            }
            phase = .live(binding)
            return .running
        }
    }

    /// Drops the request unanswered and releases its kept output.
    func close() {
        lock.withLock { closeLocked() }
    }

    // MARK: - Private (lock held)

    private func closeLocked() {
        phase = .closed
        output = nil
        chunkEnds = []
        completion = nil
    }

    private func keep(_ chunk: String) {
        guard let output else { return }
        guard output.count + chunk.utf8.count <= maxBufferedBytes else {
            self.output = nil
            chunkEnds = []
            return
        }
        output.append(chunk)
        chunkEnds.append(output.count)
    }

    private func forward(_ message: OutboundMessage) {
        switch message {
        case .inferenceError(_, let failure, let profile):
            lock.withLock {
                switch phase {
                case .live(let binding):
                    let send = binding?.send ?? originalSend
                    send.send(.inferenceError(
                        requestId: binding?.requestId ?? requestId, failure: failure, profile: profile))
                    phase = .done
                case .held:
                    closeLocked()
                case .done, .closed:
                    break
                }
            }
        case .inferenceComplete:
            // The generation's answer goes through `complete`; a terminal
            // built for its own request id is only valid there.
            lock.withLock {
                if case .live(let binding) = phase, binding?.resumed != true {
                    originalSend.send(message)
                    phase = .done
                }
            }
        default:
            originalSend.send(message)
        }
    }

    private static func terminal(_ end: Completion, for binding: Binding) -> OutboundMessage {
        var usage = end.usage
        usage.resumed = binding.resumed
        let attestation = computeResponseAttestation(
            identity: end.signer, requestId: binding.requestId,
            completionTokens: end.completionTokens, response: end.response)
        return .inferenceComplete(
            requestId: binding.requestId,
            usage: usage,
            stopSequence: end.stopSequence,
            seSignature: attestation.signature,
            responseHash: attestation.hash,
            profile: end.profile,
            encryptedUsage: try? binding.sealer.sealUsage(usage))
    }
}
