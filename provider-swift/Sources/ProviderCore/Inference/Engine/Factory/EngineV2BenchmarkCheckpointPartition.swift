/// Candidate partitioning is available only through the benchmark SPI. It
/// never activates a new serving architecture; native parity and cost must
/// qualify an explicit serving gate separately.
@_spi(Benchmarking)
public enum EngineV2BenchmarkCheckpointPartition: Sendable, Equatable {
    case production
    case demandedRecurrentQualification
}
