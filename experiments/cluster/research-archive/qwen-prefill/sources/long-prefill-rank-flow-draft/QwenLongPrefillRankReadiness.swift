import Foundation
import MLX

/// Both callers have already independently admitted their verified local stage.
/// This v4-only exchange owns no request state and completes before rank zero's
/// clock. Its distinct domain cannot be satisfied by a v3 readiness message.
func requireQwenLongPrefillRankReadiness(_ agreement: QwenLayerStageProfiledPrefillStartAgreement,
    collective: Collective, check: () throws -> Void
) throws -> QwenLongPrefillRankReadiness {
    guard collective.size == 2, (0..<2).contains(collective.rank) else {
        throw ProbeError("Long prefill readiness requires exactly two admitted ranks")
    }
    return try MLX.withError { error in
        func checked() throws { try error.check(); try check(); try error.check() }
        let digest = sha256(Data(("qwen-profiled-prefill-readiness-v1|" + agreement.fingerprint).utf8))
        let values = digest.utf8.map(Int32.init)
        func send() throws {
            let array = MLXArray(values)
            try checked()
            _ = try collective.sendCompleted(array, to: 1 - collective.rank,
                maximumBytes: 256, check: checked)
        }
        func receive() throws {
            let actual = try collective.receiveCompleted(shape: [64], dtype: .int32,
                from: 1 - collective.rank, maximumBytes: 256, check: checked).asArray(Int32.self)
            try checked()
            guard actual == values else {
                throw ProbeError("Long ranks disagree on admitted source, input, arithmetic or scheduling before clock start")
            }
        }
        if collective.rank == 0 { try send(); try receive() }
        else { try receive(); try send() }
        try checked()
        return .init(agreementFingerprint: agreement.fingerprint, readinessMaterialSHA256: digest)
    }
}
