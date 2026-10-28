/// Read-only configured dispatch policy; this is not an actual kernel counter.
@_spi(ClusterBenchmark)
public func cbv2BenchmarkConfiguredQueryBlockSize() -> Int {
    CBv2AttentionV1.queryBlockSize
}
