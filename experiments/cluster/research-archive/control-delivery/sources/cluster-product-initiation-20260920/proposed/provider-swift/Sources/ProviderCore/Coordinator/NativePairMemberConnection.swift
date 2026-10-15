import Foundation
import Network

/// Created only by CoordinatorClient after actual TLS/WebSocket readiness and
/// nonce-bound member ACK. It is never Codable or constructible from a grant.
final class NativePairMemberConnection: @unchecked Sendable {
    let nonce: String
    private let connection: NWConnection
    private let signer: any AttestationSigner
    private let onInvalidation: @Sendable (NativePairMemberConnection) -> Void
    private let lock = NSLock(), writer = NSLock()
    private var live = true, sequence: UInt64 = 0, waiting = 0
    init(nonce: String, connection: NWConnection, signer: any AttestationSigner,
         onInvalidation: @escaping @Sendable (NativePairMemberConnection) -> Void) {
        self.nonce = nonce; self.connection = connection; self.signer = signer; self.onInvalidation = onInvalidation
    }
    var isLive: Bool { lock.withLock { live } }
    func invalidate() {
        let changed = lock.withLock { if !live { return false }; live = false; return true }
        if changed { connection.cancel(); onInvalidation(self) }
    }

    /// One serialized write and at most two waiting callers. Worker request
    /// records may contain inference control on this authenticated TLS socket;
    /// native private/shared traffic keys never enter these frames.
    func send(type: String, epoch: String, generation: UInt64, payload: Data, until: UInt64) throws {
        try sendSigned(until: until) { next in
            let unsigned = try NativePairMessage(type: type, memberNonce: nonce, epoch: epoch,
                generation: generation, sequence: next, payload: payload)
            let signature = try signer.sign(unsigned.signingBytes())
            return try JSONEncoder().encode(NativePairMessage(type: type, memberNonce: nonce, epoch: epoch,
                generation: generation, sequence: next, payload: payload, signature: signature))
        }
    }
    func sendIntent(_ intent: NativePairIntent, until: UInt64) throws {
        try sendSigned(until: until) { next in
            try Task.checkCancellation()
            let unsigned = try NativePairIntentMessage(nonce: nonce, sequence: next, intent: intent)
            let signature = try signer.sign(unsigned.signingBytes())
            try Task.checkCancellation()
            let bytes = try JSONEncoder().encode(NativePairIntentMessage(nonce: nonce, sequence: next, intent: intent, signature: signature))
            guard bytes.count <= 4096 else { throw NativePairMemberError.binding }
            return bytes
        }
    }
    private func sendSigned(until: UInt64, build: (UInt64) throws -> Data) throws {
        try lock.withLock {
            guard live, waiting < 3 else { throw NativePairMemberError.queue }
            waiting += 1
        }
        defer { lock.withLock { waiting -= 1 } }
        // Queue capacity is a memory bound; acquisition also respects the
        // original deadline and cancellation instead of waiting on a signer.
        while !writer.try() {
            guard isLive, DispatchTime.now().uptimeNanoseconds < until else {
                invalidate(); throw NativePairMemberError.deadline
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        defer { writer.unlock() }
        do {
            let next = try lock.withLock { () throws -> UInt64 in
                guard live, sequence < UInt64.max, DispatchTime.now().uptimeNanoseconds < until else { throw NativePairMemberError.inactive }
                sequence += 1; return sequence
            }
            let bytes = try build(next)
            guard bytes.count <= NativePairMessage.maximumFrameBytes, isLive,
                  DispatchTime.now().uptimeNanoseconds < until else { throw NativePairMemberError.deadline }
            let completion = NativePairWriteCompletion()
            let context = NWConnection.ContentContext(identifier: "native-pair-control", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
            connection.send(content: bytes, contentContext: context, isComplete: true,
                completion: .contentProcessed { error in completion.finish(error == nil) })
            guard completion.wait(until: until), isLive else { throw NativePairMemberError.inactive }
        } catch { invalidate(); throw NativePairMemberError.inactive }
    }
}

private final class NativePairWriteCompletion: @unchecked Sendable {
    private let lock = NSLock(), done = DispatchSemaphore(value: 0)
    private var succeeded = false
    func finish(_ value: Bool) { lock.withLock { succeeded = value }; done.signal() }
    func wait(until deadline: UInt64) -> Bool {
        done.wait(timeout: .init(uptimeNanoseconds: deadline)) == .success && lock.withLock { succeeded }
    }
}
