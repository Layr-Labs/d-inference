import Foundation
import MLX

/// One-shot, diagnostic teacher timeline over exactly one loaded native rank.
/// Parent admission owns rank/world/flow and must fence both processes on throw.
/// No result retains a native array, model, context, transport or callback.
func runQwenLayerStageLookaheadRequest(context: QwenLayerStageLookaheadContext,
    transport: QwenLayerStageLookaheadTransport, request: QwenLayerStageRecordedRequest,
    check: () throws -> Void
) throws -> QwenLayerStageLookaheadRequestResult {
    var sender: QwenLayerStageLookaheadSenderDriver?
    var receiver: QwenLayerStageLookaheadReceiverDriver?
    do {
        let plan = try QwenLayerStageLookaheadDriverSupport.admit(
            context: context, transport: transport, request: request)
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            try checked()
            let result: QwenLayerStageLookaheadRequestResult
            if context.identity.stageIndex == 0 {
                let driver = try QwenLayerStageLookaheadSenderDriver(
                    context: context, transport: transport, request: request, plan: plan)
                sender = driver
                result = try driver.run(check: checked)
            } else {
                let driver = try QwenLayerStageLookaheadReceiverDriver(
                    context: context, transport: transport, request: request, plan: plan)
                receiver = driver
                result = try driver.run(check: checked)
            }
            try checked()
            guard context.isClosed, !context.isFailed, !transport.isFailed else {
                throw ProbeError("Lookahead request lost clean retirement before returning its CPU result")
            }
            return result
        }
    } catch {
        // Clear the native prepared slot before cancellation. This also handles
        // capture errors after a successful native commit and late close faults.
        sender?.retire(); receiver?.retire(); transport.retire()
        try QwenLayerStageLookaheadDriverSupport.cancel(context, primary: error)
    }
}
