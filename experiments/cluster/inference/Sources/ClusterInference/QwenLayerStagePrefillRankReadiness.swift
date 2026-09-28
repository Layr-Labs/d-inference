import Foundation
import MLX

/// Both verified model loads finish before this exact agreement exchange. It
/// owns no request context. Unlike a log-file ready record, receipt of the peer's
/// digest actually gates rank zero's subsequent first-token clock.
func requireQwenLayerStagePrefillRankReadiness(_ agreement: QwenLayerStagePrefillStartAgreement,
    collective: Collective, check: () throws -> Void) throws {
    try MLX.withError { error in
        func checked() throws { try error.check(); try check(); try error.check() }
        let values = sha256(Data(("qwen-prefill-readiness-v1|" + agreement.fingerprint).utf8)).utf8.map(Int32.init)
        func send() throws {
            let array = MLXArray(values)
            try checked()
            _ = try collective.sendCompleted(array, to: 1 - collective.rank, maximumBytes: 256, check: checked)
        }
        func receive() throws {
            let actual = try collective.receiveCompleted(shape: [64], dtype: .int32,
                from: 1 - collective.rank, maximumBytes: 256, check: checked).asArray(Int32.self)
            try checked()
            guard actual == values else { throw ProbeError("Prefill ranks disagree on loaded source or prepared request before clock start") }
        }
        if collective.rank == 0 { try send(); try receive() }
        else { try receive(); try send() }
        try checked()
    }
}
