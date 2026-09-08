import Foundation

enum BootContinuationTranscript {
    static func encode(context: BootContinuityContext, publicKey: Data,
                       challenge: BootContinuationChallenge) -> Data {
        var result = Data("darkbloom/boot-continuation/v1\0".utf8)
        for value in [context.accountID, context.deviceID, context.coordinatorOrigin, context.releaseID] {
            append(Data(value.utf8), to: &result)
        }
        var generation = context.policyGeneration.bigEndian
        withUnsafeBytes(of: &generation) { result.append(contentsOf: $0) }
        append(publicKey, to: &result)
        append(challenge.nonce, to: &result)
        append(challenge.processPublicKey, to: &result)
        return result
    }

    private static func append(_ value: Data, to result: inout Data) {
        var size = UInt32(value.count).bigEndian
        withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
        result.append(value)
    }
}
