import DarkbloomClusterRuntime
import Foundation

/// The worker's own refusal of qualification switches, before any native
/// initialization, model read or pipe use.
///
/// `DARKBLOOM_CLUSTER_TRANSPORT` and `DARKBLOOM_CLUSTER_QUALIFICATION_FAULT`
/// exist for qualification runs. A worker that was not started with
/// `--qualification-switches yes` and finds either in its environment stops
/// here and names it; it neither obeys nor ignores it. The retired
/// `DARKBLOOM_CLUSTER_GENERATION_MODE` is refused whatever the flag says. The
/// runtime repeats the same check at load, so no other caller of it can be
/// switched by its environment either.
enum WorkerQualificationGate {
    static func admit(permitted: Bool, environment: [String: String]) throws -> QwenResidentQualificationSwitches {
        let switches: QwenResidentQualificationSwitches = permitted ? .permittedByExplicitFlag : .refused
        // The runtime's own error, unchanged: its text names the switch.
        try switches.admit(environment: environment)
        return switches
    }
}
