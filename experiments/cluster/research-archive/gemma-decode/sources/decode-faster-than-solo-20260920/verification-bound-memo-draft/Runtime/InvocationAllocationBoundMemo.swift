/// A scalar lookup memo for ONE synchronous admission only. Callers create a
/// fresh local value; no OS/native observation or array ownership is cached.
/// Equal sizes share a bound calculation, never a named allocation charge.
struct InvocationAllocationBoundMemo {
    private var values: [Int:Int] = [:]

    mutating func value(for bytes: Int, resolve: (Int) throws -> Int) rethrows -> Int {
        if let value = values[bytes] { return value }
        let value = try resolve(bytes)
        values[bytes] = value
        return value
    }
}
