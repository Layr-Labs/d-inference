import Foundation
import os

/// Seals one request's response frames, then its usage, in order.
///
/// Frame `i` (from 0) is sealed under the nonce `prefix || i`, where `prefix`
/// is 16 random bytes fixed for the request and `i` is a big-endian `UInt64`.
/// The usage that ends the request is sealed under the next number, with the
/// frame count inside it. The box authenticates its nonce, so the coordinator
/// can tell from the frames it opens whether any is missing, repeated or out of
/// place, and from the usage how many frames there were. The output is an
/// ordinary NaCl box, so a coordinator that ignores the order still opens it.
final class ResponseFrameSealer: Sendable {
    static let prefixLength = 16

    private let keyPair: NodeKeyPair
    private let sharedKey: Data
    let prefix: [UInt8]
    /// Frames sealed so far, which is also the next frame's number. Held
    /// across each seal so that a number goes to exactly one box.
    private let sealedFrames = os.OSAllocatedUnfairLock<UInt64>(initialState: 0)

    init(keyPair: NodeKeyPair, sharedKey: Data, prefix: [UInt8] = ResponseFrameSealer.randomPrefix()) {
        precondition(prefix.count == Self.prefixLength)
        self.keyPair = keyPair
        self.sharedKey = sharedKey
        self.prefix = prefix
    }

    /// Seals the next frame of the response.
    func sealFrame(_ plaintext: some Collection<UInt8>) throws -> EncryptedPayload {
        try sealedFrames.withLockUnchecked { count in
            let payload = try keyPair.encryptPayloadFast(
                sharedKey: sharedKey, plaintext: plaintext, nonce: nonce(count))
            count += 1
            return payload
        }
    }

    /// Seals the request's usage and frame count under the number after the
    /// last frame. Sealing it ends the sequence: call it once, after the last
    /// frame.
    func sealUsage(_ usage: UsageInfo) throws -> EncryptedPayload {
        try sealedFrames.withLockUnchecked { count in
            let body = try Self.usageEncoder.encode(SealedResponseUsage(frameCount: count, usage: usage))
            let payload = try keyPair.encryptPayloadFast(sharedKey: sharedKey, plaintext: body, nonce: nonce(count))
            count += 1
            return payload
        }
    }

    /// Sorted keys keep the sealed bytes of one usage the same on every build.
    private static let usageEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private func nonce(_ number: UInt64) -> [UInt8] {
        prefix + withUnsafeBytes(of: number.bigEndian, Array.init)
    }

    /// The prefix only has to differ between requests: the system generator
    /// (arc4random on Darwin) cannot fail.
    static func randomPrefix() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<prefixLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}

/// The plaintext of `inference_complete.encrypted_usage`.
struct SealedResponseUsage: Codable, Equatable {
    /// Response frames sealed before the usage.
    var frameCount: UInt64
    var usage: UsageInfo

    enum CodingKeys: String, CodingKey {
        case frameCount = "chunk_count"
        case usage
    }
}
