import Foundation
import MLX

/// What this process's Metal device reports about the routed experts' sorted
/// expert-tile gather: whether the environment requested it, whether the
/// metallib beside the binary carries its kernels and, between `arm` and
/// `finish`, how many routed gathers took the route or fell back to the
/// legacy gather. The counters are the backend's own; arming them changes no
/// arithmetic. A count is an observation of one run, not a qualification.
public struct QwenRoutedExpertRouteObservation: Encodable, Equatable, Sendable {
    public let requested: Bool
    public let kernelsAvailable: Bool
    /// Zero unless the run was armed.
    public let attempts: UInt64, hits: UInt64, fallbacks: UInt64
    public let fallbackMetallibUnavailable: UInt64, fallbackSortednessRetracted: UInt64

    private init(_ value: GPU.Gemma4ExpertQMMDiagnostics) {
        requested = value.requested; kernelsAvailable = value.aotAvailable
        attempts = value.attempts; hits = value.hits; fallbacks = value.fallbacks
        fallbackMetallibUnavailable = value.fallbackMetallibUnavailable
        fallbackSortednessRetracted = value.fallbackSortednessRetracted
    }

    /// The request and the kernels, without touching the counters.
    public static var current: Self { .init(GPU.gemma4ExpertQMMDiagnostics()) }

    /// Clears the counters and starts counting. Call with nothing in flight.
    public static func arm() { GPU.clearAndArmGemma4ExpertQMMDiagnostics() }

    /// The counts since `arm`, and stops counting. Call with nothing in flight.
    public static func finish() -> Self { .init(GPU.snapshotAndDisarmGemma4ExpertQMMDiagnostics()) }

    public var summary: String {
        "expert-tile route: requested \(requested), kernels in the metallib \(kernelsAvailable), "
            + "\(hits) of \(attempts) routed gathers took it, \(fallbacks) fell back"
            + (fallbacks == 0 ? "" : " (\(fallbackMetallibUnavailable) for missing kernels, \(fallbackSortednessRetracted) retracted, "
                + "\(fallbacks - fallbackMetallibUnavailable - fallbackSortednessRetracted) outside the route's shapes)")
    }
}

extension QwenResidentArithmeticPolicy {
    /// The environment check admits what a rank was started with; this holds
    /// the process itself to it before a stage is read. A routed-expert model
    /// is loaded only where the Metal device took the route's request and the
    /// metallib beside the binary carries its kernels. Without them every
    /// routed gather would silently take the legacy path: different
    /// arithmetic from the product's and from a rank that has them.
    func requireNativeRoute() throws {
        guard self == .routedExperts else { return }
        let route = QwenRoutedExpertRouteObservation.current
        guard route.requested, route.kernelsAvailable else {
            throw ProbeError("Routed-expert arithmetic requires the expert-tile route: requested \(route.requested), "
                + "kernels in the metallib beside this binary \(route.kernelsAvailable)")
        }
    }
}
