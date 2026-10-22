import Foundation

/// The hand-off fault a qualification run asks a MiMo stage process to
/// commit (`DARKBLOOM_CLUSTER_QUALIFICATION_FAULT`, the dense adapter's own
/// switch and fault kinds): rank 0 corrupts one hand-off segment after its
/// digest was taken, or rank 1 stalls after receiving one. A switch is never
/// silently ignored and never silently obeyed: without the explicit
/// qualification flag `QwenResidentQualificationSwitches.admit` refuses it;
/// with the flag, a fault this process cannot commit is refused here, not
/// dropped (a mode with no hand-off, or the prompt-prefix disk tier, which a
/// MiMo stage does not keep).
enum MiMoQualificationFault {
    static func admit(environment: [String: String], qualification: QwenResidentQualificationSwitches,
                      mode: QwenResidentGenerationMode) throws -> QwenPhaseSplitFault? {
        try qualification.admit(environment: environment)
        guard qualification.permitted, let fault = try QwenPhaseSplitFault.admit(environment: environment) else { return nil }
        guard fault.prefixDisk == nil else {
            throw ProbeError("\(QwenPhaseSplitFault.environmentName) names the prompt-prefix disk tier, which a MiMo stage "
                + "does not keep; it is refused, not ignored")
        }
        guard mode.isPhaseSplit else {
            throw ProbeError("\(QwenPhaseSplitFault.environmentName) names a hand-off and generation mode \(mode.rawValue) "
                + "has none; it is refused, not ignored")
        }
        return fault
    }
}
