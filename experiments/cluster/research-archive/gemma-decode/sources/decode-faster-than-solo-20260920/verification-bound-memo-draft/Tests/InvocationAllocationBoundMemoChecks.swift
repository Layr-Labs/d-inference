import Foundation

private enum Failure: Error { case check(String), injected }
private func require(_ value: Bool, _ label: String) throws {
    if !value { throw Failure.check(label) }
}

@main
private enum InvocationAllocationBoundMemoChecks {
    static func main() throws {
        var groups = 0
        do {
            var memo = InvocationAllocationBoundMemo(), calls: [Int] = []
            let sizes = [4096, 8192, 4096, 8192, 4096]
            let values = sizes.map { size in memo.value(for:size) { calls.append($0); return $0 + 16384 } }
            try require(values == sizes.map { $0 + 16384 } && calls == [4096,8192], "duplicate exact sizes")
            groups += 1
        }
        do {
            var memo = InvocationAllocationBoundMemo(), calls: [Int] = []
            for size in [1,2,1,2] { _ = memo.value(for:size) { calls.append($0); return 16384 } }
            try require(calls == [1,2], "equal rounded bounds must not merge different inputs")
            groups += 1
        }
        do {
            var calls = 0, first = InvocationAllocationBoundMemo(), second = InvocationAllocationBoundMemo()
            let a = first.value(for:123) { _ in calls += 1; return 16384 }
            let b = second.value(for:123) { _ in calls += 1; return 32768 }
            try require(calls == 2 && a == 16384 && b == 32768, "fresh admission must resolve again")
            groups += 1
        }
        do {
            var memo = InvocationAllocationBoundMemo(), calls = 0
            do {
                _ = try memo.value(for:4096) { _ -> Int in calls += 1; throw Failure.injected }
                throw Failure.check("resolver failure accepted")
            } catch Failure.injected { }
            let result = memo.value(for:4096) { _ in calls += 1; return 32768 }
            try require(calls == 2 && result == 32768, "failure must propagate and not be cached")
            groups += 1
        }
        do {
            var memo = InvocationAllocationBoundMemo(), calls: [Int] = []
            let a = memo.value(for:0) { calls.append($0); return 0 }
            let b = memo.value(for:0) { calls.append($0); return 1 }
            let c = memo.value(for:Int.max) { calls.append($0); return Int.max }
            try require(a == 0 && b == 0 && c == Int.max && calls == [0,Int.max], "memo does not round, overflow or invent validation")
            groups += 1
        }
        do {
            // 158 distinct live arrays, four sizes: all allocations remain charged.
            let terms = (0..<158).map { ("array\($0)", [4096,8192,12288,16384][$0 % 4]) }
            let initial = ["array0":65536, "previous":32768]
            var direct = initial, memoized = initial, memo = InvocationAllocationBoundMemo(), calls = 0
            for (name,size) in terms {
                direct[name] = max(direct[name] ?? 0,size + 16384)
                let bound = memo.value(for:size) { calls += 1; return $0 + 16384 }
                memoized[name] = max(memoized[name] ?? 0,bound)
            }
            try require(direct == memoized && direct.count == 159 && calls == 4,
                        "per-name persistent maximum or multiplicity changed")
            try require(direct.values.reduce(0,+) == memoized.values.reduce(0,+), "sum changed")
            groups += 1
        }
        do {
            // Owner-style all-before-publication transaction: failed resolution
            // leaves the previously admitted map and revision untouched.
            var committed = ["existing":65536], revision = 7
            do {
                var next = committed, memo = InvocationAllocationBoundMemo()
                for (name,size) in [("newA",4096),("newB",8192),("newC",4096)] {
                    let value = try memo.value(for:size) { bytes -> Int in
                        if bytes == 8192 { throw Failure.injected }
                        return bytes + 16384
                    }
                    next[name] = max(next[name] ?? 0,value)
                }
                committed = next; revision += 1
                throw Failure.check("transaction resolver failure accepted")
            } catch Failure.injected { }
            try require(committed == ["existing":65536] && revision == 7, "failed plan published")
            groups += 1
        }
        print("PASS \(groups) invocation allocation-bound memo groups")
    }
}
