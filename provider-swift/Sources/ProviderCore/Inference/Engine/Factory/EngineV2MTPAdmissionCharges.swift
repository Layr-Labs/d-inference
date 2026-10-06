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
        // Ordering above proves both nonnegative subtractions representable.
        let remainingAuxiliary = auxiliaryBytesPerToken - legacyMTPBytesPerToken
        return .init(kvBytesPerToken: kvBytesPerToken - legacyMTPBytesPerToken,
            auxiliaryBytesPerToken: remainingAuxiliary,
            auxiliaryTokenGranularity: remainingAuxiliary == 0 ? 1 : auxiliaryTokenGranularity,
            auxiliaryTokenAllocationPadding: remainingAuxiliary == 0 ? 0 : auxiliaryTokenAllocationPadding,
            // Already includes bounded MTP, target and caller fixed state.
            // In particular, do not add bounded.fixedBytesPerRequest twice.
            fixedRequestBytes: fixedRequestBytes)
    }
}
