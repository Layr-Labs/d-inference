import ProviderCore

/// Every direct benchmark runner in this process shares one native capacity
/// authority. Their KV grants already use this same default activation reserve.
/// Static initialization stays lazy; GlobalKVCacheBudget construction is MLX-free.
enum BenchmarkMemoryBudget {
    static let shared = GlobalKVCacheBudget()
}
