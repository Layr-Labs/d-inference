import Testing
@testable import ProviderCore

@Test func reserveMarksModelInFlight() {
    var c = LocalReservationCounter()
    #expect(!c.isReserved("m"))
    c.reserve("m")
    #expect(c.isReserved("m"))
    #expect(c.count("m") == 1)
}

@Test func reserveAndReleaseAreBalanced() {
    var c = LocalReservationCounter()
    c.reserve("m")
    c.reserve("m") // two concurrent local requests
    #expect(c.count("m") == 2)
    c.release("m")
    #expect(c.isReserved("m")) // still one in flight
    #expect(c.count("m") == 1)
    c.release("m")
    #expect(!c.isReserved("m")) // last one done → key removed
    #expect(c.count("m") == 0)
}

@Test func releaseNeverGoesNegative() {
    var c = LocalReservationCounter()
    c.release("never-reserved") // no-op
    #expect(!c.isReserved("never-reserved"))
    #expect(c.count("never-reserved") == 0)
    c.reserve("m")
    c.release("m")
    c.release("m") // extra release is a no-op, must not underflow
    #expect(c.count("m") == 0)
    #expect(!c.isReserved("m"))
}

@Test func countersAreIndependentPerModel() {
    var c = LocalReservationCounter()
    c.reserve("a")
    c.reserve("b")
    c.reserve("b")
    #expect(c.count("a") == 1)
    #expect(c.count("b") == 2)
    c.release("a")
    #expect(!c.isReserved("a"))
    #expect(c.isReserved("b")) // releasing a must not affect b
}
