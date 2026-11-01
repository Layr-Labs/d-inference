/// Trusted local provenance for engine timing observations. This value is
/// supplied by the serving adapter, never decoded from an inference request.
public enum EngineMeasurementPurpose: Sendable, Equatable {
    case serving
    /// Exercises first-use kernels and templates, not representative throughput.
    case startupWarmup
}
