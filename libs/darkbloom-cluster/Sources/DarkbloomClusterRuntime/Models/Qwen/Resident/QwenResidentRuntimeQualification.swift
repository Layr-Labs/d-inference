import Foundation

/// The two switches that exist for qualification only, and whether this
/// process may honour them.
///
/// `DARKBLOOM_CLUSTER_TRANSPORT=local-socket-test` replaces the RDMA link with
/// a loopback socket between two ranks on one Mac;
/// `DARKBLOOM_CLUSTER_QUALIFICATION_FAULT` asks a rank to commit a fault during
/// a hand-off. Neither may take effect in an installed worker. A caller that
/// does not explicitly permit them gets a refusal that names the switch when
/// its environment carries one: a switch is never silently ignored, and never
/// silently obeyed.
///
/// `DARKBLOOM_CLUSTER_GENERATION_MODE` was how a launcher declared the mode
/// before the worker had `--generation-mode`. It is refused always, so that a
/// launcher still using it cannot believe it declared a mode it did not.
///
/// This file needs nothing but Foundation and the runtime's error type, so a
/// check can compile it without MLX.
public struct QwenResidentQualificationSwitches: Equatable, Sendable {
    public static let transportEnvironmentName = "DARKBLOOM_CLUSTER_TRANSPORT"
    public static let faultEnvironmentName = "DARKBLOOM_CLUSTER_QUALIFICATION_FAULT"
    public static let retiredGenerationModeEnvironmentName = "DARKBLOOM_CLUSTER_GENERATION_MODE"
    /// `measure` records what the host memory gate would have refused for
    /// admissible memory alone instead of enforcing it; see
    /// `QwenDenseStageLoadMeasurement`. Spelled out here so this file still
    /// compiles without the rest of the runtime.
    public static let memoryGateEnvironmentName = "DARKBLOOM_CLUSTER_QUALIFICATION_MEMORY_GATE"
    /// The worker argument that permits the two switches, with the value `yes`.
    public static let permittingArgument = "--qualification-switches"

    public let permitted: Bool
    /// What every installed caller passes, and the default of `load`.
    public static let refused = Self(permitted: false)
    /// Only for a caller that was itself started with the explicit test flag.
    public static let permittedByExplicitFlag = Self(permitted: true)

    /// The caller passes the actual process environment, before anything is
    /// loaded. Throws naming the switch that is present and not permitted.
    public func admit(environment: [String: String]) throws {
        guard environment[Self.retiredGenerationModeEnvironmentName] == nil else {
            throw ProbeError("\(Self.retiredGenerationModeEnvironmentName) is no longer read; "
                + "declare the mode with the worker's --generation-mode argument")
        }
        guard !permitted else { return }
        for name in [Self.transportEnvironmentName, Self.faultEnvironmentName, Self.memoryGateEnvironmentName]
        where environment[name] != nil {
            throw ProbeError("\(name) is a qualification switch and this process was not started with "
                + "\(Self.permittingArgument) yes; it is refused, not ignored")
        }
    }
}
