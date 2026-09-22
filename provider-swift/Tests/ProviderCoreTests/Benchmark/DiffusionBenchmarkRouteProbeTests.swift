import Testing

@testable import ProviderCore

@Suite("Diffusion benchmark route observation")
struct DiffusionBenchmarkRouteProbeTests {
  private func sample(
    hits: UInt64 = 120, armed: Bool = false, softCalls: UInt64 = 151,
    samplerCalls: Int = 159
  ) -> DiffusionBenchmarkRouteSnapshot {
    .init(
      requested: true, aotAvailable: true, naxAvailable: false, armedAfter: armed,
      attempts: 120, hits: hits, fallbacks: 0, assignmentFallback: 0,
      metallibFallback: 0, sortednessRetracted: 0, weightedUnsortCalls: 60,
      softEmbeddingCalls: softCalls, compiledSamplerCalls: samplerCalls)
  }

  @Test func activationIsExplicit() {
    #expect(!DiffusionBenchmarkRouteProbe.isEnabled([:]))
    #expect(
      DiffusionBenchmarkRouteProbe.isEnabled([DiffusionBenchmarkRouteProbe.environmentKey: "1"]))
    #expect(
      !DiffusionBenchmarkRouteProbe.isEnabled([DiffusionBenchmarkRouteProbe.environmentKey: "true"])
    )
  }

  @Test func warmupAndUnchangedTimedSnapshots() throws {
    var state = DiffusionBenchmarkRouteState()
    try state.record(iteration: 0, snapshot: sample())
    try state.requireIdle(sample())
    try state.record(iteration: 1, snapshot: sample())
    try state.record(iteration: 2, snapshot: sample())
  }

  @Test func changedCountersOrInvalidOrderAreRejected() throws {
    var state = DiffusionBenchmarkRouteState()
    #expect(throws: (any Error).self) { try state.requireIdle(sample()) }
    #expect(throws: (any Error).self) { try state.record(iteration: 1, snapshot: sample()) }
    #expect(throws: (any Error).self) {
      try state.record(iteration: 0, snapshot: sample(armed: true))
    }
    try state.record(iteration: 0, snapshot: sample())
    #expect(throws: (any Error).self) {
      try state.record(iteration: 1, snapshot: sample(hits: 121))
    }
    #expect(throws: (any Error).self) {
      try state.record(iteration: 1, snapshot: sample(softCalls: 152))
    }
    #expect(throws: (any Error).self) {
      try state.record(iteration: 1, snapshot: sample(samplerCalls: 160))
    }
    #expect(throws: (any Error).self) { try state.record(iteration: 0, snapshot: sample()) }
  }
}
