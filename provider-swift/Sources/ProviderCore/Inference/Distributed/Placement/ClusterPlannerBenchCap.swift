import Foundation
import DarkbloomClusterPlacement

/// TEST ONLY, never offered to a user: the developer bench override that caps
/// what the planner believes each member can give a model
/// (`ClusterDeviceProfile.cappedForBench`), so a bench pair of large Macs is
/// placed the way a pair of smaller Macs would be and a real split can be
/// served and measured through the product's own planning (`darkbloom
/// cluster`, `darkbloom cluster plan`).
///
/// Set `DARKBLOOM_DEV_BENCH_PLANNER_CAP_GIB` to a whole number of GiB in the
/// environment of the process that plans. Only a debug build reads it; a
/// release build refuses to plan while it is set, so a signed install can
/// never be planned from it by accident. It changes the plan and the plan's
/// words only: every load is still admitted or refused by the load gate on
/// the Mac that loads, on that Mac's real memory.
public enum ClusterPlannerBenchCap {
    public static let environmentName = "DARKBLOOM_DEV_BENCH_PLANNER_CAP_GIB"
    static let largestGiB = 65_536

    /// Whether this binary was built for development (SwiftPM's debug configuration).
    public static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// The cap in bytes, nil when the variable is not set.
    public static func capBytes(environment: [String: String], debugBuild: Bool = isDebugBuild) throws -> Int? {
        guard let text = environment[environmentName] else { return nil }
        guard debugBuild else {
            throw ClusterConfigurationError.invalid("\(environmentName) is a developer bench override and is not available in a release build; "
                + "unset it to plan this pair on its real memory")
        }
        guard !text.isEmpty, text.utf8.count <= 6, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(text), (1...largestGiB).contains(value) else {
            throw ClusterConfigurationError.invalid("\(environmentName) must be a whole number of GiB from 1 to \(largestGiB)")
        }
        return value * 1_073_741_824
    }

    /// The words a capped plan starts with.
    static func lines(capBytes: Int) -> [String] {
        let gib = capBytes / 1_073_741_824
        return ["Developer bench cap (\(environmentName)=\(gib))",
                "  This plan is test only: the planner was told each Mac can give a model at most \(gib) GiB, "
                    + "so the pair is placed as two Macs of that size would be. The memory figures below are capped; "
                    + "physical memory is as detected.",
                "  Each Mac's load gate is unchanged: it admits or refuses every load on that Mac's real memory."]
    }
}
