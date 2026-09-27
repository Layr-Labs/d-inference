import Testing
@testable import ProviderCore

@Test func hostBufferReservationCompetesWithNativeCommitmentsAndRetiresExplicitly() throws {
    let ledger = ProcessMemoryLedger(
        policy: .init(epoch: 1, capBytes: 100, reserveBytes: 0),
        readUsage: { .init(activeBytes: 0, cacheBytes: 0, systemAvailableBytes: .max) })
    let engine = EngineProcessMemoryOwner(ledger: ledger)
    try engine.replaceCharge(60)
    let host = try #require(ProcessHostBufferReservation(ledger: ledger, bytes: 40))
    #expect(ProcessHostBufferReservation(ledger: ledger, bytes: 1) == nil)
    #expect(ledger.snapshot().chargedBytes == 100)
    #expect(ledger.updatePolicy(.init(epoch: 2, capBytes: 0, reserveBytes: 100)))
    host.closeAfterDroppingBuffers()
    host.closeAfterDroppingBuffers()
    #expect(ledger.snapshot().chargedBytes == 60)
    try engine.replaceCharge(0)
    engine.retire()
    #expect(ledger.snapshot().ownerCount == 0)
}

@Test func hostBufferHandleDeinitIsNotAProofOfBufferRetirement() throws {
    let ledger = ProcessMemoryLedger(
        policy: .init(epoch: 1, capBytes: 100, reserveBytes: 0),
        readUsage: { .init(activeBytes: 0, cacheBytes: 0, systemAvailableBytes: .max) })
    var host: ProcessHostBufferReservation? = try #require(ProcessHostBufferReservation(ledger: ledger, bytes: 40))
    #expect(host?.bytes == 40)
    host = nil
    #expect(ledger.snapshot().chargedBytes == 40)
    #expect(ledger.snapshot().ownerCount == 1)
}
