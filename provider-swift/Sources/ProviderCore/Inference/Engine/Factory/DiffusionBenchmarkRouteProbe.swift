import Foundation
import MLX
@_spi(DiffusionGemmaDiagnostics) import MLXLLM
@_spi(DiffusionGemmaDiagnostics) import MLXLMCommon

struct DiffusionBenchmarkRouteSnapshot: Equatable {
  let requested: Bool
  let aotAvailable: Bool
  let naxAvailable: Bool
  let armedAfter: Bool
  let attempts: UInt64
  let hits: UInt64
  let fallbacks: UInt64
  let assignmentFallback: UInt64
  let metallibFallback: UInt64
  let sortednessRetracted: UInt64
  let weightedUnsortCalls: Int
  let softEmbeddingCalls: UInt64
  let compiledSamplerCalls: Int
}

struct DiffusionBenchmarkRouteState {
  enum Failure: Error { case invalidBoundary, counterChanged }
  private(set) var warmup: DiffusionBenchmarkRouteSnapshot?
  private var nextIteration = 0

  func requireIdle(_ snapshot: DiffusionBenchmarkRouteSnapshot) throws {
    guard let warmup, !snapshot.armedAfter, snapshot == warmup else {
      throw Failure.counterChanged
    }
  }

  mutating func record(iteration: Int, snapshot: DiffusionBenchmarkRouteSnapshot) throws {
    guard iteration == nextIteration, !snapshot.armedAfter else {
      throw Failure.invalidBoundary
    }
    if iteration == 0 { warmup = snapshot } else { try requireIdle(snapshot) }
    nextIteration += 1
  }
}

/// Opt-in benchmark observation; never used by request-serving paths.
final class DiffusionBenchmarkRouteProbe {
  static let environmentKey = "DARKBLOOM_DIFFUSION_DESCRIPTOR_PROBE"
  static func isEnabled(_ environment: [String: String]) -> Bool {
    environment[environmentKey] == "1"
  }

  private let enabled = DiffusionBenchmarkRouteProbe.isEnabled(ProcessInfo.processInfo.environment)
  private var state = DiffusionBenchmarkRouteState()

  func begin(iteration: Int) throws {
    guard enabled else { return }
    if iteration == 0 {
      GPU.clearAndArmGemma4ExpertQMMDiagnostics()
      resetWeightedExpertUnsortStats()
      DiffusionGemmaSoftEmbeddingDiagnostics.clearAndArm()
      DiffusionGemmaCompiledSamplerDiagnostics.clearAndArm()
    } else {
      try state.requireIdle(snapshot(disarm: false))
    }
  }

  func end(iteration: Int) throws {
    guard enabled else { return }
    let sample = snapshot(disarm: iteration == 0)
    try state.record(iteration: iteration, snapshot: sample)
    let environment = ProcessInfo.processInfo.environment
    let record: [String: Any] = [
      "iteration": iteration + 1, "warmup": iteration == 0,
      "requested": sample.requested, "aotAvailable": sample.aotAvailable,
      "naxAvailable": sample.naxAvailable, "counterArmedAfter": sample.armedAfter,
      "attempts": sample.attempts, "hits": sample.hits, "fallbacks": sample.fallbacks,
      "assignmentFallback": sample.assignmentFallback,
      "metallibFallback": sample.metallibFallback,
      "sortednessRetracted": sample.sortednessRetracted,
      "weightedUnsortCalls": sample.weightedUnsortCalls,
      "softEmbeddingCalls": sample.softEmbeddingCalls,
      "compiledSamplerCalls": sample.compiledSamplerCalls,
      "coreEnvironment": environment["MLX_GATHER_QMM_EXPERT_SLICES"] ?? "unset",
      "gemmaUnsortEnvironment": environment["MLX_GEMMA4_FUSED_WEIGHTED_UNSORT"] ?? "unset",
      "diffusionUnsortEnvironment": environment["DARKBLOOM_DIFFUSION_EXPERT_UNSORT"] ?? "unset",
      "softEmbeddingEnvironment": environment["DARKBLOOM_DIFFUSION_SOFT_EMBEDDING"] ?? "unset",
      "compiledSamplerEnvironment": environment["DARKBLOOM_DIFFUSION_COMPILED_SAMPLER"] ?? "unset",
    ]
    print(
      "DIFFUSION_PROVIDER_ROUTE "
        + String(
          decoding:
            try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
          as: UTF8.self))
  }

  func finish() {
    guard enabled else { return }
    _ = GPU.snapshotAndDisarmGemma4ExpertQMMDiagnostics()
    _ = weightedExpertUnsortStats()
    _ = DiffusionGemmaSoftEmbeddingDiagnostics.snapshotAndDisarm()
    _ = DiffusionGemmaCompiledSamplerDiagnostics.snapshotAndDisarm()
  }

  private func snapshot(disarm: Bool) -> DiffusionBenchmarkRouteSnapshot {
    let route =
      disarm
      ? GPU.snapshotAndDisarmGemma4ExpertQMMDiagnostics()
      : GPU.gemma4ExpertQMMDiagnostics()
    let weighted = weightedExpertUnsortStats()
    let soft = disarm ? DiffusionGemmaSoftEmbeddingDiagnostics.snapshotAndDisarm()
      : DiffusionGemmaSoftEmbeddingDiagnostics.snapshot()
    if disarm { _ = DiffusionGemmaCompiledSamplerDiagnostics.snapshotAndDisarm() }
    let sampler = DiffusionGemmaCompiledSamplerDiagnostics.snapshot()
    return .init(
      requested: route.requested, aotAvailable: route.aotAvailable,
      naxAvailable: route.naxAvailable,
      armedAfter: GPU.gemma4ExpertQMMDiagnostics().armed || soft.armed || sampler.armed,
      attempts: route.attempts, hits: route.hits, fallbacks: route.fallbacks,
      assignmentFallback: route.fallbackAssignmentCount,
      metallibFallback: route.fallbackMetallibUnavailable,
      sortednessRetracted: route.fallbackSortednessRetracted,
      weightedUnsortCalls: weighted.effectiveCalls, softEmbeddingCalls: soft.calls,
      compiledSamplerCalls: sampler.calls)
  }
}
