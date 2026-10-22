import MLXLMCommon

/// Translate the actual engine's MTP reservation into the bridge's shared and
/// process-ledger inputs. This is arithmetic only, never materialization credit.
struct EngineV2MTPAdmissionCharges: Equatable {
    let kvBytesPerToken: Int
    let auxiliaryBytesPerToken: Int
    let auxiliaryTokenGranularity: Int
    let auxiliaryTokenAllocationPadding: Int
    let fixedRequestBytes: Int

    static func resolve(
        resolution: CBv2MTPAdmissionResolution?, legacyMTPBytesPerToken: Int,
        kvBytesPerToken: Int, auxiliaryBytesPerToken: Int,
        auxiliaryTokenGranularity: Int, auxiliaryTokenAllocationPadding: Int,
        fixedRequestBytes: Int
    ) throws -> Self {
        guard let resolution else {
            // Do not retune or reinterpret existing families/defaults.
            return .init(kvBytesPerToken: kvBytesPerToken,
                auxiliaryBytesPerToken: auxiliaryBytesPerToken,
                auxiliaryTokenGranularity: auxiliaryTokenGranularity,
                auxiliaryTokenAllocationPadding: auxiliaryTokenAllocationPadding,
                fixedRequestBytes: fixedRequestBytes)
        }
        guard case .bounded(let bounded) = resolution else {
            if case .unavailable(let reason) = resolution { throw reason }
            throw CBv2MTPAdmissionRefusal.invalidDeclaration
        }
        guard legacyMTPBytesPerToken >= 0,
              kvBytesPerToken >= auxiliaryBytesPerToken,
              auxiliaryBytesPerToken >= legacyMTPBytesPerToken,
              auxiliaryTokenGranularity > 0, auxiliaryTokenAllocationPadding >= 0,
              bounded.fixedBytesPerRequest > 0,
              fixedRequestBytes >= bounded.fixedBytesPerRequest,
              fixedRequestBytes < Int.max else {
            throw CBv2MTPAdmissionRefusal.invalidExistingCharge
        }
        if bounded.auxiliaryBytesPerToken > 0 {
            // A sequence-scaled declaration: the engine charges the drafter's
            // growing state per reserved token through its exact projection.
            // The shared reservation prices it linearly, with the projection's
            // slack added to the fixed bytes so it bounds the engine's charge.
            guard legacyMTPBytesPerToken == 0, auxiliaryBytesPerToken == 0,
                  bounded.auxiliaryLinearSlackBytes >= 0 else {
                throw CBv2MTPAdmissionRefusal.invalidExistingCharge
            }
            let (perToken, rateOverflow) = kvBytesPerToken.addingReportingOverflow(
                bounded.auxiliaryBytesPerToken)
            let (fixed, fixedOverflow) = fixedRequestBytes.addingReportingOverflow(
                bounded.auxiliaryLinearSlackBytes)
            guard !rateOverflow, !fixedOverflow, fixed < Int.max else {
                throw CBv2MTPAdmissionRefusal.chargeOverflow
            }
            return .init(kvBytesPerToken: perToken, auxiliaryBytesPerToken: bounded.auxiliaryBytesPerToken,
                auxiliaryTokenGranularity: 1, auxiliaryTokenAllocationPadding: 0, fixedRequestBytes: fixed)
        }
        // Ordering above proves both nonnegative subtractions representable.
        let remainingAuxiliary = auxiliaryBytesPerToken - legacyMTPBytesPerToken
        // The engine charges bounded MTP growth per reserved token; mirror it.
        let (rate, rateOverflow) = (kvBytesPerToken - legacyMTPBytesPerToken)
            .addingReportingOverflow(bounded.auxiliaryBytesPerToken)
        let (auxiliary, auxiliaryOverflow) = remainingAuxiliary
            .addingReportingOverflow(bounded.auxiliaryBytesPerToken)
        guard bounded.auxiliaryBytesPerToken >= 0, !rateOverflow, !auxiliaryOverflow else {
            throw CBv2MTPAdmissionRefusal.chargeOverflow
        }
        return .init(kvBytesPerToken: rate,
            auxiliaryBytesPerToken: auxiliary,
            auxiliaryTokenGranularity: remainingAuxiliary == 0 ? 1 : auxiliaryTokenGranularity,
            auxiliaryTokenAllocationPadding: remainingAuxiliary == 0 ? 0 : auxiliaryTokenAllocationPadding,
            // Already includes bounded MTP, target and caller fixed state.
            // In particular, do not add bounded.fixedBytesPerRequest twice.
            fixedRequestBytes: fixedRequestBytes)
    }
}
