import Foundation
import MLX
import MLXNN

struct Gemma4BenchmarkResourceReceipt: Encodable {
    let policy = "registered_gemma4_resident_benchmark_resources_v1"
    let planSHA256: String, requestSHA256: String
    let selectedTensorCount: Int, completedTensorCount: Int
    let constructorParameterCount: Int, constructorUnmaterializedQuantizedParameterCount: Int
    let constructorObservedActiveBytes: Int, constructorObservedNativePeakBytes: Int
    let namedNativeReserveBytes: Int, hostEvidenceReserveBytes: Int
    let guardMetricsHostReserveBytes = Gemma4BenchmarkGuardMetrics.hostAllowanceBytes
    let persistentCastLogicalBytes: Int, stateLogicalBytes: Int
    let selectedAllocationBounds: [Int]
    let namedArrays: [Gemma4BenchmarkResourceBudget.ArrayTerm]
    let namedAllocationBounds: [Int]
    let prefillAllowance: QwenGenerationPrefillAllowance?
    let observationCount: Int, minimumActualFreeBytes: Int
    let maximumObservedActiveBytes: Int, maximumObservedNativePeakBytes: Int
    let actualAllocatorBoundsUsed = true
    let operationalResourceChecksApplied = true
    let reclaimableUsedForAdmission = false
    let wholeProcessPeakBoundEstablished = false
    let reserveTermsAreOperationalPolicy = true
    let constructorGraphHeadroomRetainedThroughoutLoad = true
    let newServingActivationFloorEstablished = false
    let physicalProcessOrLeaseRetirementEstablished = false
}

/// Private operational qualification owner. Uses the existing direct native/OS
/// readers and 6/4/2-GiB policy, never a supplied observation/capacity receipt.
final class Gemma4BenchmarkResourceOwner {
    private enum Phase: Equatable { case source, constructing, loading, probing, ready, allocating, request, complete, failed }
    private var phase = Phase.source
    private var progress: Gemma4OrderedLoadProgress
    private let guardMetrics: Gemma4BenchmarkGuardMetrics
    private let deadline: UInt64
    private let requests: [QwenLayerStageGenerationRequest]
    private var completedRequests = 0
    let budget: Gemma4BenchmarkResourceBudget
    private var observations = 0, minimumFree = Int.max, maximumActive = 0, maximumPeak = 0
    private var constructorCount = 0, constructorLazyQuantizedCount = 0
    private var constructorActive = 0, constructorPeak = 0

    init(plan: Gemma4LayerStagePlan, target: Gemma4ForwardTarget,
         requests: [QwenLayerStageGenerationRequest], residualDType: DType, captureEvidence: Bool,
         prefillPolicy: QwenResidentPrefillPolicy = .serial, deadline: UInt64,
         guardMetrics: Gemma4BenchmarkGuardMetrics) throws {
        guard requests.count == 4, Set(requests.map(\.requestID)).count == 4, let request = requests.first,
              requests.allSatisfy({ $0.promptTokenIDs == request.promptTokenIDs && $0.chunkSize == request.chunkSize
                && $0.outputCount == request.outputCount && $0.profile == request.profile && $0.stopTokenIDs.isEmpty }) else {
            throw ProbeError("Gemma benchmark needs four unique fresh-state requests with identical workload")
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now, deadline - now <= 300_000_000_000 else {
            throw ProbeError("Gemma correctness needs a fresh existing 300-second-or-shorter native lifetime")
        }
        try Gemma4BenchmarkResourceBudget.requireCandidateCut(plan)
        try Gemma4ForwardRequest.validate(request, dtype: residualDType)
        try guardMetrics.measure(.environmentGuard) { try QwenResidentResourceEnvironment.require(observationTiming: guardMetrics.observeOS) }
        let budget = try Gemma4BenchmarkResourceBudget.derive(plan: plan, target: target, request: request,
            captureEvidence: captureEvidence, prefillPolicy: prefillPolicy, bound: QwenResidentResourceEnvironment.allocationBound)
        self.budget = budget; self.deadline = deadline; self.requests = requests
        self.guardMetrics = guardMetrics
        progress = .init(expected: budget.selected)
        try check()
    }

    func check(observation supplied: Gemma4BenchmarkGuardObservation? = nil) throws {
        let owned = supplied == nil ? Gemma4BenchmarkGuardObservation(mode: .owner, deadline: deadline) : nil
        defer { owned?.close() }
        let observation = supplied ?? owned!
        try guardMetrics.measure(.ownerGuard) {
            try checkObservedResources(observation: observation, finishObservation: owned != nil)
        }
    }

    private func checkObservedResources(observation: Gemma4BenchmarkGuardObservation, finishObservation: Bool) throws {
        do {
            guard phase != .failed, !progress.failed,
                  DispatchTime.now().uptimeNanoseconds < deadline else {
                throw ProbeError("Gemma resource owner failed or expired")
            }
            let os = try guardMetrics.measure(.environmentGuard) {
                try observation.read(for: .owner, deadline: deadline, observationTiming: guardMetrics.observeOS)
            }
            try QwenDenseStageLoadPolicy.requireInitial(os, now: DispatchTime.now().uptimeNanoseconds)
            guard os.pressureLevel == 1 else { throw ProbeError("Gemma benchmark requires exact pressure level1") }
            let native = guardMetrics.measure(.nativeSnapshot) { QwenDenseStageLoadResources.observeNative() }
            guard native.activeBytes >= 0, native.cacheBytes == 0,
                  native.peakBytes >= native.activeBytes, native.allocatorLimitBytes > 0 else {
                throw ProbeError("Gemma dedicated owner requires valid native observations and zero freed-buffer cache")
            }
            let sum = QwenLongPrefillCheckedBytes.sum
            let loading = phase == .source || phase == .constructing || phase == .loading
            let remaining = loading ? try sum(Array(budget.selectedBounds.dropFirst(progress.completed))) : 0
            let hasRead = loading && progress.completed < budget.selected.count
            // Ordered completion occurs only after the tensor's read/convert/
            // update autorelease scope ends. Keep pending and every unread
            // tensor, but do not reserve a future reread of completed storage.
            let staging = try Gemma4BenchmarkUnreadStaging.bounds(
                logicalBytes: budget.selected.lazy.map { $0.source.layout.byteCount },
                allocationBounds: budget.selectedBounds, completed: progress.completed,
                pending: progress.pending, loading: loading)
            let host = staging.hostBytes
            let copy = staging.nativeCopyBytes
            let scratch = hasRead ? CheckpointAlignedReadPlan.maximumScratchAllocationBytes : 0
            let free = max(QwenDenseStageLoadPolicy.minimumActualFreeBytes,
                try sum([remaining, host, copy, scratch, budget.namedNativeBytes,
                    budget.hostEvidenceBytes, QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
            let allocator = try sum([native.activeBytes, native.cacheBytes, remaining, copy,
                budget.namedNativeBytes, QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
            guard os.actualFreeBytes >= free, os.physicalMemoryBytes >= free,
                  native.allocatorLimitBytes >= allocator else {
                throw ProbeError("Gemma resources refused: completed=\(progress.completed)/\(budget.selected.count), pending=\(progress.pending.map(String.init) ?? "none"), actualFree=\(os.actualFreeBytes), requiredFree=\(free), active=\(native.activeBytes), cache=\(native.cacheBytes), requiredAllocator=\(allocator), allocatorLimit=\(native.allocatorLimitBytes)")
            }
            observations = try sum([observations, 1]); minimumFree = min(minimumFree, os.actualFreeBytes)
            maximumActive = max(maximumActive, native.activeBytes); maximumPeak = max(maximumPeak, native.peakBytes)
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ProbeError("Gemma deadline expired during observation") }
            if finishObservation { try observation.finish(deadline: deadline) }
        } catch { phase = .failed; progress.poison(); throw error }
    }

    func construction(_ selected: [Gemma4SelectedTensor]) throws {
        do {
            guard phase == .source, selected.count == budget.selected.count,
                  zip(selected, budget.selected).allSatisfy({ $0.0.localName == $0.1.localName && $0.0.source == $0.1.source }) else {
                throw ProbeError("Gemma construction changed its closed selected inventory")
            }
            try check(); phase = .constructing
        } catch { phase = .failed; progress.poison(); throw error }
    }
    func prepared(_ value: Gemma4PreparedForwardModel) throws {
        do {
            guard phase == .constructing, value.source.plan.fingerprint == budget.planSHA256 else {
                throw ProbeError("Gemma constructor observation has no matching owner")
            }
            // Synchronize only already scheduled work. Buffer metadata never
            // evaluates an unscheduled parameter or traverses its input graph.
            Stream.gpu.synchronize(); Stream.cpu.synchronize(); try check()
            let parameters = Dictionary(uniqueKeysWithValues: value.model.module.parameters().flattened())
            guard parameters.count == budget.selected.count else { throw ProbeError("Gemma constructor coverage changed") }
            let quantizedPaths = Set(budget.selected.filter { $0.localName.hasSuffix(".scales") }
                .map { String($0.localName.dropLast(".scales".count)) })
            var lazy = 0
            for selected in budget.selected {
                guard let parameter = parameters[selected.localName] else { throw ProbeError("Gemma constructor parameter missing") }
                let parent = selected.localName.split(separator: ".").dropLast().joined(separator: ".")
                if quantizedPaths.contains(parent) {
                    guard case nil = try parameter.evaluatedBufferInfo() else {
                        throw ProbeError("Gemma initialized quantization graph materialized before source replacement")
                    }
                    lazy += 1
                }
            }
            constructorCount = parameters.count; constructorLazyQuantizedCount = lazy
            constructorActive = Memory.activeMemory; constructorPeak = Memory.peakMemory
            guard lazy > 0 else { throw ProbeError("Gemma constructor has no quantized placeholders") }
            phase = .loading; try check()
        } catch { phase = .failed; progress.poison(); throw error }
    }
    func beforeTensor(_ tensor: Gemma4SelectedTensor) throws {
        do {
            guard phase == .loading else { throw ProbeError("Gemma read outside loading phase") }
            try progress.begin(tensor); try check()
        } catch { phase = .failed; progress.poison(); throw error }
    }
    func afterTensor(_ tensor: Gemma4SelectedTensor) throws {
        do {
            guard phase == .loading else { throw ProbeError("Gemma completion outside loading phase") }
            try progress.finish(tensor); try check()
        } catch { phase = .failed; progress.poison(); throw error }
    }
    func loaded(_ receipt: Gemma4ForwardLoadReceipt) throws {
        do {
            guard phase == .loading, receipt.planSHA256 == budget.planSHA256,
                  receipt.artifactSHA256 == Gemma4ArtifactMetadata.artifactAggregateSHA256,
                  receipt.configurationSHA256 == Gemma4ArtifactMetadata.configurationSHA256,
                  receipt.sourceTensorCount == 1697, receipt.selectedTensorCount == budget.selected.count,
                  receipt.loadedTensorBytes == (try QwenLongPrefillCheckedBytes.sum(budget.selected.map { $0.source.layout.byteCount })),
                  receipt.readAccounting.selectedBytes == receipt.loadedTensorBytes else {
                throw ProbeError("Gemma actual load receipt differs from resource inventory")
            }
            try progress.requireFinished(); phase = .probing; try check()
        } catch { phase = .failed; progress.poison(); throw error }
    }
    func request(_ geometry: CBv2RequestGeometry) throws {
        do {
            guard phase == .allocating, let layout = geometry.attentionLayout,
                  layout.maximumTokens == requests[completedRequests].maximumTokens,
                  layout.maximumChunkTokens == requests[completedRequests].chunkSize,
                  geometry.recurrent.layers.isEmpty,
                  layout.layers.count == budget.stateLayers.count,
                  zip(layout.layers, budget.stateLayers).allSatisfy({
                      $0.0.globalIndex == $0.1.globalIndex && $0.0.kvHeads == $0.1.kvHeads
                        && $0.0.headDimension == $0.1.headDimension && $0.0.window == $0.1.window
                        && $0.0.element.bytes <= $0.1.element.bytes
                  }),
                  geometry.kvCapacityBytes <= budget.stateLogicalBytes else {
                throw ProbeError("Gemma observed request exceeds the closed resident state ledger")
            }
            phase = .request; try check()
        } catch { phase = .failed; progress.poison(); throw error }
    }
    func probeCompleted() throws {
        guard phase == .probing else { throw ProbeError("Gemma probe completion has no loaded owner") }
        try check(); phase = .ready
    }
    func beginRequest(_ request: QwenLayerStageGenerationRequest) throws {
        guard phase == .ready, completedRequests < requests.count,
              request == requests[completedRequests] else { throw ProbeError("Gemma resident request order/identity differs") }
        try check(); phase = .allocating
    }
    func retiredRequest(_ session: Gemma4OwnedForwardSession) throws {
        guard phase == .request, completedRequests < requests.count, session.request == requests[completedRequests],
              session.isClosed, !session.isFailed,
              session.committedTokens == session.request.promptCount + session.request.outputCount - 1 else {
            throw ProbeError("Gemma resident state did not retire at its original request frontier")
        }
        try check(); completedRequests += 1; phase = .ready
    }
    func completed() throws -> Gemma4BenchmarkResourceReceipt {
        guard phase == .ready, completedRequests == requests.count else { throw ProbeError("Gemma resource owner did not complete every resident request") }
        try check(); phase = .complete
        return .init(planSHA256: budget.planSHA256, requestSHA256: budget.requestSHA256,
            selectedTensorCount: budget.selected.count, completedTensorCount: progress.completed,
            constructorParameterCount: constructorCount, constructorUnmaterializedQuantizedParameterCount: constructorLazyQuantizedCount,
            constructorObservedActiveBytes: constructorActive, constructorObservedNativePeakBytes: constructorPeak,
            namedNativeReserveBytes: budget.namedNativeBytes, hostEvidenceReserveBytes: budget.hostEvidenceBytes,
            persistentCastLogicalBytes: budget.persistentCastLogicalBytes, stateLogicalBytes: budget.stateLogicalBytes,
            selectedAllocationBounds: budget.selectedBounds,
            namedArrays: budget.namedArrays, namedAllocationBounds: budget.namedAllocationBounds,
            prefillAllowance: budget.prefillAllowance,
            observationCount: observations, minimumActualFreeBytes: minimumFree,
            maximumObservedActiveBytes: maximumActive, maximumObservedNativePeakBytes: maximumPeak)
    }
}
