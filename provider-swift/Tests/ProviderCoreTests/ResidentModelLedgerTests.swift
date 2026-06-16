import Testing
@testable import ProviderCore

private let gib: UInt64 = 1024 * 1024 * 1024

@Test func ledgerSumsResidentWeightsAcrossModels() async {
    let ledger = ResidentModelLedger()
    await ledger.record(modelKey: "gemma-4-26b-qat-4bit", weightBytes: UInt64(13.8 * Double(gib)))
    await ledger.record(modelKey: "gpt-oss-20b", weightBytes: UInt64(11.25 * Double(gib)))
    #expect(await ledger.count() == 2)
    #expect(await ledger.totalResidentWeightBytes() == UInt64(13.8 * Double(gib)) + UInt64(11.25 * Double(gib)))
}

@Test func ledgerTotalDropsWhenAModelIsRemoved() async {
    let ledger = ResidentModelLedger()
    await ledger.record(modelKey: "a", weightBytes: 10 * gib)
    await ledger.record(modelKey: "b", weightBytes: 5 * gib)
    await ledger.remove(modelKey: "b")
    #expect(await ledger.totalResidentWeightBytes() == 10 * gib)
    #expect(await ledger.count() == 1)
    // Removing an unknown key is a no-op.
    await ledger.remove(modelKey: "ghost")
    #expect(await ledger.totalResidentWeightBytes() == 10 * gib)
}

@Test func ledgerRecordOverwritesRatherThanDoubleCounts() async {
    // A reload re-measures the same model; the total must not double.
    let ledger = ResidentModelLedger()
    await ledger.record(modelKey: "a", weightBytes: 10 * gib)
    await ledger.record(modelKey: "a", weightBytes: 12 * gib)
    #expect(await ledger.totalResidentWeightBytes() == 12 * gib)
    #expect(await ledger.count() == 1)
}

@Test func ledgerExcludingGivesReplacementHeadroom() async {
    // `excluding:` reports Σweights as if one model weren't loaded — a
    // replacement-sizing convenience (NOT used by the current load gate, which
    // reads live MLX counters; see the ResidentModelLedger type note).
    let ledger = ResidentModelLedger()
    await ledger.record(modelKey: "victim", weightBytes: 26 * gib)
    await ledger.record(modelKey: "keep", weightBytes: 11 * gib)
    #expect(await ledger.totalResidentWeightBytes(excluding: "victim") == 11 * gib)
    #expect(await ledger.totalResidentWeightBytes(excluding: "absent") == 37 * gib)
}

@Test func ledgerReportsPerModelBytesAndSnapshot() async {
    let ledger = ResidentModelLedger()
    await ledger.record(modelKey: "a", weightBytes: 10 * gib)
    #expect(await ledger.weightBytes(modelKey: "a") == 10 * gib)
    #expect(await ledger.weightBytes(modelKey: "missing") == nil)
    let snap = await ledger.snapshot()
    #expect(snap == ["a": 10 * gib])
}

@Test func ledgerSaturatesOnOverflowInsteadOfTrapping() async {
    let ledger = ResidentModelLedger()
    await ledger.record(modelKey: "a", weightBytes: .max)
    await ledger.record(modelKey: "b", weightBytes: .max)
    #expect(await ledger.totalResidentWeightBytes() == .max)
}
