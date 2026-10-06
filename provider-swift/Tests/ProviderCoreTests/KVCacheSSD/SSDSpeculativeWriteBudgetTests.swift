import Foundation
import Testing
@testable import ProviderCore

/// The speculative write class of `SSDWriteRateLimiter`.
///
/// Every limiter here has a cap of 86,400 bytes per day (the total refills one
/// byte per second) and a repeat reserve of one half (novel share 43,200
/// bytes, refilling half a byte per second), so every balance is exact in
/// floating point. Unless a test says otherwise the speculative headroom is
/// 1,800 seconds of refill = 1,800 bytes: a speculative write must leave the
/// total at or above 84,600 and the novel share at or above 41,400.
@Suite("Speculative write budget")
struct SSDSpeculativeWriteBudgetTests {
    private final class Clock: @unchecked Sendable {
        var now: Double = 0
    }

    private static let cap = 86_400
    private static let headroom = 1_800

    private func makeLimiter(headroomSeconds: Double = 1_800, clock: Clock = Clock()) -> SSDWriteRateLimiter {
        SSDWriteRateLimiter(capBytesPerDay: Self.cap, repeatReserveFraction: 0.5,
                            speculativeHeadroomSeconds: headroomSeconds, nowSeconds: { clock.now })
    }

    @Test("speculative writes spend only the headroom of a full budget, from both buckets")
    func spendsOnlyHeadroom() {
        let limiter = makeLimiter()
        #expect(limiter.admission(bytes: 1_801, writeClass: .speculative) == .speculativeLimited)
        #expect(limiter.consume(bytes: 1_000, writeClass: .speculative) == .accepted)
        #expect(limiter.consume(bytes: 801, writeClass: .speculative) == .speculativeLimited)
        #expect(limiter.consume(bytes: 800, writeClass: .speculative) == .accepted)
        #expect(limiter.consume(bytes: 1, writeClass: .speculative) == .speculativeLimited)
        // The 1,800 bytes were charged to the total and to the novel share.
        #expect(limiter.mightAccept(bytes: 84_600))
        #expect(!limiter.mightAccept(bytes: 84_601))
        #expect(limiter.mightAccept(bytes: 41_400, repeated: false))
        #expect(!limiter.mightAccept(bytes: 41_401, repeated: false))
    }

    @Test("speculative writes stop when other writes take either bucket below its floor and resume after refill")
    func yieldsToEitherBucket() {
        // A repeated write lowers only the total: the total alone refuses.
        let totalOnly = makeLimiter()
        #expect(totalOnly.tryConsume(bytes: 1_000))
        #expect(totalOnly.admission(bytes: 801, writeClass: .speculative) == .speculativeLimited)
        #expect(totalOnly.admission(bytes: 800, writeClass: .speculative) == .accepted)
        #expect(totalOnly.tryConsume(bytes: 800))
        #expect(totalOnly.admission(bytes: 1, writeClass: .speculative) == .speculativeLimited)

        // A novel write takes both buckets to their floors. After 1,000 s the
        // total is 1,000 bytes above its floor but the novel share only 500:
        // the novel share alone refuses.
        let clock = Clock()
        let both = makeLimiter(clock: clock)
        #expect(both.tryConsume(bytes: 1_800, repeated: false))
        #expect(both.admission(bytes: 1, writeClass: .speculative) == .speculativeLimited)
        clock.now = 1_000
        #expect(both.admission(bytes: 501, writeClass: .speculative) == .speculativeLimited)
        #expect(both.consume(bytes: 500, writeClass: .speculative) == .accepted)
        #expect(both.consume(bytes: 1, writeClass: .speculative) == .speculativeLimited)
        // Another 3,600 s refills both buckets completely.
        clock.now = 4_600
        #expect(both.admission(bytes: 1_800, writeClass: .speculative) == .accepted)
    }

    @Test("a refused speculative write is speculative-limited even when the total is empty, and charges nothing")
    func refusalChargesNothing() {
        let limiter = makeLimiter()
        #expect(limiter.consume(bytes: 1_801, writeClass: .speculative) == .speculativeLimited)
        #expect(limiter.admission(bytes: 86_400, writeClass: .repeated) == .accepted)
        #expect(limiter.admission(bytes: 43_200, writeClass: .novel) == .accepted)
        #expect(limiter.admission(bytes: 1_800, writeClass: .speculative) == .accepted)

        #expect(limiter.tryConsume(bytes: 86_400))
        #expect(limiter.consume(bytes: 1, writeClass: .repeated) == .rateLimited)
        #expect(limiter.consume(bytes: 1, writeClass: .novel) == .rateLimited)
        #expect(limiter.consume(bytes: 1, writeClass: .speculative) == .speculativeLimited)
        #expect(limiter.admission(bytes: 1, writeClass: .speculative) == .speculativeLimited)
    }

    @Test("proven writes are judged exactly as before once speculation has used all of its headroom")
    func provenDecisionsUnchanged() {
        let speculated = makeLimiter()
        #expect(speculated.consume(bytes: 1_800, writeClass: .speculative) == .accepted)
        // The same bytes charged as one novel write to a limiter that accepts
        // no speculative write at all.
        let reference = makeLimiter(headroomSeconds: 0)
        #expect(reference.tryConsume(bytes: 1_800, repeated: false))
        for bytes in [0, 1, 41_399, 41_400, 41_401, 84_599, 84_600, 84_601, 86_400] {
            for writeClass in [SSDWriteClass.repeated, .novel] {
                #expect(speculated.admission(bytes: bytes, writeClass: writeClass)
                    == reference.admission(bytes: bytes, writeClass: writeClass))
            }
        }
        // Everything below the two floors is still theirs.
        #expect(speculated.admission(bytes: 84_601, writeClass: .repeated) == .rateLimited)
        #expect(speculated.admission(bytes: 41_401, writeClass: .novel) == .priorityLimited)
        #expect(speculated.consume(bytes: 41_400, writeClass: .novel) == .accepted)
        #expect(speculated.consume(bytes: 43_200, writeClass: .repeated) == .accepted)
    }

    /// The balance bound: at every instant each bucket holds at least what it
    /// would hold had the same proven writes been accepted and no speculative
    /// write ever charged, minus the headroom (1,800 bytes). So a proven write
    /// that this reference admits with 1,800 bytes to spare is always admitted
    /// here, and all speculative writes together spend at most the headroom
    /// plus what refilled meanwhile.
    ///
    /// The reference is charged only with what the limiter under test
    /// accepts, so this says nothing about a limiter that was never offered
    /// speculation and so accepts a different set of writes. The two tests
    /// after this one compare against that.
    @Test("with the same proven writes accepted, a sustained stream of speculative offers never leaves a bucket more than the headroom short")
    func speculationCostIsBounded() {
        let clock = Clock()
        let limiter = makeLimiter(clock: clock)
        // Charged with exactly the proven writes `limiter` accepts.
        let speculationFree = makeLimiter(headroomSeconds: 0, clock: clock)
        var seed: UInt64 = 0x5EED
        func next(below bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        var speculativeBytes = 0, speculativeRefusals = 0
        var provenWithHeadroomToSpare = 0, provenRefusedDespiteHeadroom = 0, provenRefusals = 0
        var provenAcceptedOnlyWithSpeculation = 0
        for step in 0 ..< 25_200 {
            clock.now += Double(next(below: 120))
            for _ in 0 ..< 3 {
                let bytes = 1 + next(below: 900)
                if limiter.consume(bytes: bytes, writeClass: .speculative) == .accepted {
                    speculativeBytes += bytes
                } else {
                    speculativeRefusals += 1
                }
            }
            // 6,000 quiet steps let the buckets refill from empty and then
            // speculation flow; 300 busy steps of proven writes drain both
            // buckets far below the floors.
            let busy = step % 6_300 >= 6_000
            guard busy || next(below: 8) == 0 else { continue }
            let writeClass: SSDWriteClass = next(below: 4) == 0 ? .repeated : .novel
            let bytes = 1 + next(below: busy ? 600 : 200)
            let hasHeadroomToSpare = speculationFree.admission(
                bytes: bytes + Self.headroom, writeClass: writeClass) == .accepted
            let accepted = limiter.consume(bytes: bytes, writeClass: writeClass) == .accepted
            if hasHeadroomToSpare {
                provenWithHeadroomToSpare += 1
                if !accepted { provenRefusedDespiteHeadroom += 1 }
            }
            if accepted {
                if speculationFree.consume(bytes: bytes, writeClass: writeClass) != .accepted {
                    provenAcceptedOnlyWithSpeculation += 1
                }
            } else {
                provenRefusals += 1
            }
        }
        #expect(provenRefusedDespiteHeadroom == 0)
        #expect(provenAcceptedOnlyWithSpeculation == 0)
        #expect(Double(speculativeBytes) <= Double(Self.headroom) + clock.now)
        // The run reached every regime: speculation flowing long after the
        // first headroom was spent, speculation shut out, proven writes with
        // room to spare and proven writes refused.
        #expect(speculativeBytes > 100 * Self.headroom)
        #expect(speculativeRefusals > 0)
        #expect(provenWithHeadroomToSpare > 0)
        #expect(provenRefusals > 0)
    }

    /// The balance bound is not a bound on refused bytes. A proven write is
    /// refused whole, so a shortfall smaller than the headroom refuses a file
    /// larger than the headroom. Novel share 43,200, headroom 1,800, proven
    /// files of 2,100 bytes: a full share holds 20 of them, a share that is
    /// 1,700 bytes short holds 19.
    @Test("against an independent first-sight-off limiter one speculative file costs one whole proven file, more than the headroom, in every refill cycle")
    func speculationCostsOneProvenFilePerRefillCycle() {
        let clock = Clock()
        let limiter = makeLimiter(clock: clock)
        // Offered every proven write `limiter` is offered and no speculative
        // one. What it accepts is its own decision.
        let firstSightOff = makeLimiter(headroomSeconds: 0, clock: clock)
        let provenFile = 2_100
        var accepted = 0, acceptedWithoutSpeculation = 0
        for _ in 0 ..< 10 {
            // A day refills both buckets of both limiters completely.
            clock.now += 86_400
            #expect(limiter.consume(bytes: 1_700, writeClass: .speculative) == .accepted)
            var inCycle = 0, inCycleWithoutSpeculation = 0
            for _ in 0 ..< 25 {
                if limiter.consume(bytes: provenFile, writeClass: .novel) == .accepted { inCycle += 1 }
                if firstSightOff.consume(bytes: provenFile, writeClass: .novel) == .accepted {
                    inCycleWithoutSpeculation += 1
                }
            }
            #expect(inCycleWithoutSpeculation == 20)
            #expect(inCycle == 19)
            // Once drained below the floor, speculation takes nothing more
            // until the next refill.
            #expect(limiter.consume(bytes: 1, writeClass: .speculative) == .speculativeLimited)
            accepted += inCycle
            acceptedWithoutSpeculation += inCycleWithoutSpeculation
        }
        // One 2,100-byte file per cycle for 1,700 speculative bytes: more
        // than the headroom, less than the headroom plus one file, and it
        // recurs with every refill. Ten cycles cost ten files.
        let costPerCycle = (acceptedWithoutSpeculation - accepted) * provenFile / 10
        #expect(costPerCycle == provenFile)
        #expect(costPerCycle > Self.headroom)
        #expect(costPerCycle < Self.headroom + provenFile)
        // Which offer is refused differs between the two histories, so the
        // cost is a net figure: the limiter that refused the larger file has
        // 1,600 bytes left and takes a 1,300-byte file the other, with 1,200
        // left, refuses.
        #expect(limiter.consume(bytes: 1_300, writeClass: .novel) == .accepted)
        #expect(firstSightOff.consume(bytes: 1_300, writeClass: .novel) == .priorityLimited)
    }

    /// The bound that does hold against an independent limiter. Start from
    /// full buckets and let no time pass. If speculation accepts S bytes
    /// (S is at most the headroom) and the proven offers are then of one
    /// class, the limiter that speculated accepts S fewer proven bytes than
    /// the other, give or take what each has left when the offers end. It
    /// never has a whole file more left than the other (it refuses a file the
    /// other accepts only while it holds less), so the extra refused bytes
    /// are less than S plus one file. A refill starts the next cycle, and
    /// the cost can recur there.
    @Test("against an independent first-sight-off limiter speculation costs proven writes less than the headroom plus one file per refill cycle")
    func independentHistoryCostIsBoundedPerRefillCycle() {
        let clock = Clock()
        let limiter = makeLimiter(clock: clock)
        let firstSightOff = makeLimiter(headroomSeconds: 0, clock: clock)
        var seed: UInt64 = 0xF1857
        func next(below bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        // Proven files of 1,201 to 2,400 bytes: none is small enough to use
        // up whatever a refusal leaves, as a deep checkpoint is not.
        let smallestProvenFile = 1_201, largestProvenFile = 2_400
        var cyclesCostingMoreThanHeadroom = 0, cyclesCostingNothing = 0
        for cycle in 0 ..< 400 {
            clock.now += 86_400
            #expect(limiter.mightAccept(bytes: Self.cap) && firstSightOff.mightAccept(bytes: Self.cap))
            #expect(limiter.mightAccept(bytes: Self.cap / 2, repeated: false)
                && firstSightOff.mightAccept(bytes: Self.cap / 2, repeated: false))
            let writeClass: SSDWriteClass = cycle.isMultiple(of: 4) ? .repeated : .novel
            var speculated = 0, refused = 0, refusedWithoutSpeculation = 0
            func offerSpeculative() {
                let bytes = 1 + next(below: 900)
                if limiter.consume(bytes: bytes, writeClass: .speculative) == .accepted { speculated += bytes }
            }
            for _ in 0 ..< 4 { offerSpeculative() }
            // 120 offers of at least 1,201 bytes exceed either bucket.
            for _ in 0 ..< 120 {
                let bytes = smallestProvenFile + next(below: largestProvenFile - smallestProvenFile + 1)
                if limiter.consume(bytes: bytes, writeClass: writeClass) != .accepted { refused += bytes }
                if firstSightOff.consume(bytes: bytes, writeClass: writeClass) != .accepted {
                    refusedWithoutSpeculation += bytes
                }
                offerSpeculative()
            }
            let cost = refused - refusedWithoutSpeculation
            #expect(speculated <= Self.headroom)
            #expect(cost < speculated + largestProvenFile)
            #expect(refusedWithoutSpeculation > 0)
            if cost > Self.headroom { cyclesCostingMoreThanHeadroom += 1 }
            if cost == 0 { cyclesCostingNothing += 1 }
        }
        // Both regimes occur: cycles in which speculation cost no proven
        // byte, and cycles in which it cost more than the headroom.
        #expect(cyclesCostingMoreThanHeadroom > 0)
        #expect(cyclesCostingNothing > 0)
    }

    @Test("a limiter built without speculative headroom accepts no speculative write")
    func noHeadroomNoSpeculation() {
        // The attention-block store builds its limiter this way.
        let singleBudget = SSDWriteRateLimiter(capBytesPerDay: Self.cap)
        #expect(singleBudget.consume(bytes: 1, writeClass: .speculative) == .speculativeLimited)
        #expect(singleBudget.tryConsume(bytes: Self.cap))
        for seconds in [0, -1_800, Double.nan, .infinity] {
            #expect(makeLimiter(headroomSeconds: seconds).admission(bytes: 1, writeClass: .speculative)
                == .speculativeLimited)
        }
    }

    @Test("speculative headroom larger than the cap never overdraws either bucket")
    func headroomIsClampedToTheNovelShare() {
        let limiter = makeLimiter(headroomSeconds: 10 * 86_400)
        #expect(limiter.admission(bytes: 43_201, writeClass: .speculative) == .speculativeLimited)
        #expect(limiter.consume(bytes: 43_200, writeClass: .speculative) == .accepted)
        #expect(limiter.consume(bytes: 1, writeClass: .speculative) == .speculativeLimited)
        // The repeat reserve is untouched and the novel share is exactly empty.
        #expect(limiter.mightAccept(bytes: 43_200))
        #expect(!limiter.mightAccept(bytes: 43_201))
        #expect(!limiter.mightAccept(bytes: 1, repeated: false))
    }

    /// A simulation on a synthetic trace, not a measurement: the production
    /// write cap, repeat reserve and cache lifetime, a synthetic 64 MB
    /// first-sight file offered once a second, and a synthetic 256 MB proven
    /// write once a minute.
    @Test("at the default cap a sustained one-off flood drains one TTL of refill, then admits about one file per refill interval, and interleaved proven writes are never refused")
    func defaultCapFlood() {
        let clock = Clock()
        let cap = SSDPrefixCachePolicy.defaultMaxWriteBytesPerDay
        let lifetime = Int(SSDPrefixCachePolicy.defaultTTLSeconds)
        let limiter = SSDWriteRateLimiter(
            capBytesPerDay: cap, repeatReserveFraction: SSDCheckpointDemand.repeatReserveFraction,
            speculativeHeadroomSeconds: Double(lifetime), nowSeconds: { clock.now })
        let headroom = cap * lifetime / 86_400
        let novelRefillPerSecond = Double(cap) * (1 - SSDCheckpointDemand.repeatReserveFraction) / 86_400
        let floodFile = 64_000_000, provenFile = 256_000_000

        // With no time passing the flood gets the headroom and nothing more.
        var drained = 0
        while limiter.consume(bytes: floodFile, writeClass: .speculative) == .accepted { drained += 1 }
        #expect(drained == headroom / floodFile)

        // Ten minutes of flood alone: one file each time the novel share has
        // refilled one file's worth.
        var admitted = 0
        for _ in 0 ..< 600 {
            clock.now += 1
            if limiter.consume(bytes: floodFile, writeClass: .speculative) == .accepted { admitted += 1 }
        }
        let filesPerTenMinutes = Int(600 * novelRefillPerSecond) / floodFile
        #expect((filesPerTenMinutes - 1 ... filesPerTenMinutes + 1).contains(admitted))

        // An hour of flood with proven writes interleaved: every proven write
        // is admitted, and the flood gets only the refill they leave.
        var provenRefusals = 0
        admitted = 0
        for second in 1 ... 3_600 {
            clock.now += 1
            if second.isMultiple(of: 60), limiter.consume(bytes: provenFile, writeClass: .novel) != .accepted {
                provenRefusals += 1
            }
            if limiter.consume(bytes: floodFile, writeClass: .speculative) == .accepted { admitted += 1 }
        }
        #expect(provenRefusals == 0)
        let leftForFlood = (Int(3_600 * novelRefillPerSecond) - 60 * provenFile) / floodFile
        // The last proven write lands in the final second, so up to its whole
        // size is not yet repaid when the hour ends.
        #expect((leftForFlood - 1 ... leftForFlood + 1 + provenFile / floodFile).contains(admitted))
    }

    @Test("an unlimited cap admits every write class")
    func unlimitedCap() {
        let unlimited = SSDWriteRateLimiter(capBytesPerDay: 0)
        for writeClass in [SSDWriteClass.repeated, .novel, .speculative] {
            #expect(unlimited.admission(bytes: 1 << 40, writeClass: writeClass) == .accepted)
            #expect(unlimited.consume(bytes: 1 << 40, writeClass: writeClass) == .accepted)
        }
    }
}
