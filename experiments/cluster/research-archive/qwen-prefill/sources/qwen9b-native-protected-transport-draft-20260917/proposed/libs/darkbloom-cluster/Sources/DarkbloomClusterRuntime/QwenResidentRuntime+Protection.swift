import Foundation

extension QwenResidentRuntime {
    var protectedReservedBytes: Int {
        protectedBudget == nil ? 0 : QwenResidentProtectedExperiment.reservedBytes
    }

    func requireProtectedLive(_ allowance: QwenResidentRequestAllowance,
                              prefill: QwenGenerationPrefillAllowance?, capture: QwenResidentRecordingCharge?) throws {
        guard protectedBudget != nil else { return }
        let sum = QwenLongPrefillCheckedBytes.sum
        try QwenProtectedResources.requireLive()
        try allowance.requireLive(additionalNativeBytes: sum([
            QwenResidentProtectedExperiment.nativeAllowanceBytes, prefill?.extraNativeBytes ?? 0,
            capture?.capture.extraNativeBytes ?? 0]), additionalHostBytes: sum([
                QwenResidentProtectedExperiment.hostAllowanceBytes, prefill?.extraHostBytes ?? 0,
                capture?.capture.extraHostBytes ?? 0]))
    }
}
