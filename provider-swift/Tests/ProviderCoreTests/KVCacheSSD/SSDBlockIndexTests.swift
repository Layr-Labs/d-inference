import Foundation
import Testing
@testable import ProviderCore

@Suite("SSD block index eviction order")
struct SSDBlockIndexTests {
    enum Recency: CaseIterable {
        case allTied
        case fewValues
        case distinct
    }

    @Test("Oldest probe keeps deterministic order after touches and removals")
    func oldestProbe() {
        let index = SSDBlockIndex()
        #expect(index.oldest() == nil)
        let tags = [Data([3]), Data([1]), Data([2])]
        for tag in tags { index.insert(tag16: tag, fileBytes: 10, lastAccess: 5) }
        #expect(index.oldest()?.tag16 == Data([1]))
        #expect(Array(index.oldestFirstSnapshot()).map(\.tag16) == [Data([1]), Data([2]), Data([3])])
        index.touch(tags16: [Data([1])], now: 6)
        #expect(index.oldest()?.tag16 == Data([2]))
        #expect(index.remove(tag16: Data([2])) == 10)
        #expect(index.oldest()?.tag16 == Data([3]))
        #expect(index.oldest()?.fileBytes == 10)
        #expect(index.oldest()?.lastAccess == 5)
        index.removeAll()
        #expect(index.oldest() == nil)
    }

    @Test("Lazy oldest-first snapshot yields exactly the sorted eviction order",
          arguments: [0, 1, 2, 3, 4, 7, 64, 255, 256, 4_097, 20_000], Recency.allCases)
    func oldestFirstSnapshotOrder(count: Int, recency: Recency) {
        var random = SplitMix64(seed: 0x55D_1DE7 ^ UInt64(count))
        let index = SSDBlockIndex()
        var inserted: [Data: (lastAccess: Int64, fileBytes: Int)] = [:]
        let ranks = Array(0..<count).shuffled(using: &random)
        for position in 0..<count {
            // Mostly production-shaped tags. Short and empty tags exercise the
            // shorter-prefix-first rule; bytes above 0x7F check unsigned order.
            let length = random.next() % 8 == 0 ? Int(random.next() % 3) : 16
            let tag = Data((0..<length).map { _ in UInt8(truncatingIfNeeded: random.next()) })
            let lastAccess: Int64 = switch recency {
            case .allTied: 1_700_000_000
            case .fewValues: Int64(random.next() % 3)
            case .distinct: Int64(ranks[position])
            }
            index.insert(tag16: tag, fileBytes: position, lastAccess: lastAccess)
            inserted[tag] = (lastAccess, position)
        }
        // Independent oracle: fully sort what was inserted (a repeated tag
        // replaces its entry) by last hit, then `Data` lexicographic order.
        let expected = inserted
            .map { (tag16: $0.key, lastAccess: $0.value.lastAccess, fileBytes: $0.value.fileBytes) }
            .sorted {
                if $0.lastAccess != $1.lastAccess { return $0.lastAccess < $1.lastAccess }
                return $0.tag16.lexicographicallyPrecedes($1.tag16)
            }
        let actual = Array(index.oldestFirstSnapshot())
        #expect(expected.count == index.count)
        #expect(actual.map(\.tag16) == expected.map(\.tag16))
        #expect(actual.map(\.lastAccess) == expected.map(\.lastAccess))
        #expect(actual.map(\.fileBytes) == expected.map(\.fileBytes))
        // The first-attempt probe and the fallback snapshot agree on the head.
        #expect(index.oldest()?.tag16 == expected.first?.tag16)
    }

    @Test("Tag tie-break compares unsigned bytes and puts a shorter prefix first")
    func tieBreakOrder() {
        let index = SSDBlockIndex()
        let ordered = [Data(), Data([0x00]), Data([0x7F]), Data([0x7F, 0x00]), Data([0x7F, 0xFF]), Data([0x80])]
        for tag in ordered.reversed() { index.insert(tag16: tag, fileBytes: 1, lastAccess: 7) }
        #expect(index.oldest()?.tag16 == Data())
        #expect(Array(index.oldestFirstSnapshot()).map(\.tag16) == ordered)
    }

    @Test("Snapshot ignores later index changes and resumes where a walk stopped")
    func oldestFirstSnapshotIsolation() {
        let index = SSDBlockIndex()
        for byte: UInt8 in [3, 1, 2] { index.insert(tag16: Data([byte]), fileBytes: 10, lastAccess: 5) }
        var snapshot = index.oldestFirstSnapshot()
        #expect(snapshot.next()?.tag16 == Data([1]))
        index.insert(tag16: Data([0]), fileBytes: 10, lastAccess: 0)
        #expect(index.remove(tag16: Data([2])) == 10)
        index.touch(tags16: [Data([3])], now: 4)
        #expect(Array(snapshot).map(\.tag16) == [Data([2]), Data([3])])
        #expect(Array(snapshot).map(\.lastAccess) == [5, 5])
    }
}

/// Deterministic PRNG so randomized index contents reproduce across runs.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
