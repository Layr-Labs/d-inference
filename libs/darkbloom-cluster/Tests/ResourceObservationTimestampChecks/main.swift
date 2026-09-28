import Foundation

let dates: [Date] = [
    -62_135_596_800, -2_208_988_800, -1, -0.001, 0, 0.999,
    951_782_399, 951_782_400, 1_704_067_199.999, 1_704_067_200,
    1_790_000_000.123, 2_147_483_647, 4_102_444_800,
].map { Date(timeIntervalSince1970: $0) }
let expected = dates.map { ISO8601DateFormatter().string(from: $0) }
for _ in 0..<10 {
    for (date, value) in zip(dates, expected) {
        precondition(ResourceObservationTimestamp.utc(date) == value)
    }
}
DispatchQueue.concurrentPerform(iterations: 4096) { index in
    let i = index % dates.count
    precondition(ResourceObservationTimestamp.utc(dates[i]) == expected[i])
}
precondition(ResourceObservationTimestamp.utc(Date(timeIntervalSince1970: 0))
    != ResourceObservationTimestamp.utc(Date(timeIntervalSince1970: 1)))

func measure(_ body: (Date) -> String) -> UInt64 {
    var bytes = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for index in 0..<10_000 {
        autoreleasepool { bytes += body(dates[index % dates.count]).utf8.count }
    }
    precondition(bytes > 0)
    return DispatchTime.now().uptimeNanoseconds - start
}
var rows: [[String: UInt64]] = []
for ordinal in 0..<5 {
    let old: UInt64, reused: UInt64
    if ordinal % 2 == 0 {
        old = measure { ISO8601DateFormatter().string(from: $0) }
        reused = measure { ResourceObservationTimestamp.utc($0) }
    } else {
        reused = measure { ResourceObservationTimestamp.utc($0) }
        old = measure { ISO8601DateFormatter().string(from: $0) }
    }
    rows.append(["freshFormatterNanoseconds": old, "reusedFormatterNanoseconds": reused])
}
let result: [String: Any] = ["status": "passed", "dateCases": dates.count,
    "concurrentComparisons": 4096, "iterationsPerArm": 10000,
    "measurements": rows, "gpuExecuted": false,
    "scope": "formatting only; no inference speed claim"]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
