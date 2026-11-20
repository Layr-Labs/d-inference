import Foundation
@_spi(QuantizedConstantCache) import MLX
import MLXNN

// Port of https://github.com/ml-explore/mlx-examples/blob/main/llms/mlx_lm/models/switch_layers.py

/// Compiled SiLU-gated product (`silu(gate) * up`) for the common MoE GLU path.
/// Fusing activation + product into one compiled, shapeless kernel cuts kernel
/// dispatches and intermediates on the hot decode path. Upstream ef85ed0.
///
/// Gated by `MLXHardwareInfo.isCompiledDecodeSupported` (env `MLX_COMPILED_DECODE`,
/// default on) like the sibling `compiledSwiGLU` / `safeGeluApproximate` fusions.
/// The default SiLU `SwitchGLU` path wires this in as `activationProduct` (the
/// highest-precedence branch in `callAsFunction`) and `LFM2MoE` calls it directly,
/// so without the gate both would keep hitting compiled kernels on the very M1/M2 +
/// macOS Tahoe machines the opt-out (MLX #3329) is meant to protect. Falls back to
/// the plain uncompiled closure when off; the default (env unset) stays compiled.
public let compiledSiluProduct: @Sendable (MLXArray, MLXArray) -> MLXArray = {
    let body: @Sendable (MLXArray, MLXArray) -> MLXArray = { gate, up in
        MLXNN.silu(gate) * up
    }
    if MLXHardwareInfo.isCompiledDecodeSupported {
        return cbv2ObservedCompiled(.siluProduct, compile(shapeless: true, body))
    }
    return body
}()

/// Compiled weighted expert-output combine (`(outputs * weights[..., None]).sum(-2)`).
/// Shared by MoE routers (e.g. Gemma 4) to fuse the scale + reduce. Upstream ef85ed0.
public let weightedExpertSum: @Sendable (MLXArray, MLXArray) -> MLXArray = cbv2ObservedCompiled(.weightedExpertSum, compile(
    shapeless: true
) { outputs, weights in
    (outputs * MLX.expandedDimensions(weights, axis: -1)).sum(axis: -2)
})
/// Effective-selection count for the direct sorted-expert reduction. Benchmark
/// callers arm this after warmup and snapshot it only after the engine is idle.
/// The unarmed hot path reads one plain Bool and performs no atomic operation,
/// locking, allocation, or clock access.
public struct WeightedExpertUnsortStats: Sendable, Equatable {
    public let effectiveCalls: Int
}

/// Benchmark-facing requested/effective contract for one measured scope.
public struct WeightedExpertUnsortProvenance: Sendable, Equatable {
    public let requested: Bool
    public let effectiveCalls: Int

    public var engaged: Bool { effectiveCalls > 0 }
    public var missingExpectedEngagement: Bool { requested && !engaged }
}

private final class WeightedExpertUnsortProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var effectiveCalls = 0
    // Benchmark boundaries guarantee no engine work is in flight while this
    // plain flag changes. Concurrent recorders only read it while armed.
    private var enabled = false

    @inline(__always)
    func recordEffective() {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        // Defensively close a recorder/snapshot lock handoff. The idle-boundary
        // contract prevents a concurrent unsynchronized flag mutation.
        guard enabled else { return }
        effectiveCalls += 1
    }

    func snapshot() -> WeightedExpertUnsortStats {
        lock.lock()
        enabled = false
        defer { lock.unlock() }
        return WeightedExpertUnsortStats(effectiveCalls: effectiveCalls)
    }

    func reset() {
        lock.lock()
        effectiveCalls = 0
        enabled = true
        lock.unlock()
    }
}

private let weightedExpertUnsortProbe = WeightedExpertUnsortProbe()

/// Process-wide provenance snapshot for the weighted expert unsort experiment.
public func weightedExpertUnsortStats() -> WeightedExpertUnsortStats {
    weightedExpertUnsortProbe.snapshot()
}

/// Disarm and snapshot one benchmark scope with its resolved request state.
public func weightedExpertUnsortProvenance(
    requested: Bool
) -> WeightedExpertUnsortProvenance {
    let stats = weightedExpertUnsortStats()
    return WeightedExpertUnsortProvenance(
        requested: requested,
        effectiveCalls: stats.effectiveCalls)
}

/// Reset the provenance counters before a benchmark cell.
public func resetWeightedExpertUnsortStats() {
    weightedExpertUnsortProbe.reset()
}

/// Fused inverse-permutation + weighted reduction for the sorted MoE prefill path.
///
/// `SwitchGLU` sorts expert assignments before its gathered matrix multiplies.
/// The regular path restores `[tokens, topK, hidden]` and then reduces it with
/// ``weightedExpertSum``. This kernel reads those sorted rows through the inverse
/// permutation and writes `[tokens, hidden]` directly, avoiding that full
/// `[tokens, topK, hidden]` intermediate.
private let weightedExpertUnsortKernel: MLXFast.MLXFastKernel = MLXFast.metalKernel(
    name: "weighted_expert_unsort",
    inputNames: ["sorted_outputs", "inverse_order", "weights"],
    outputNames: ["output"],
    source: """
        uint feature = thread_position_in_grid.x;
        uint token = thread_position_in_grid.y;

        T accumulator = (T)0;
        const uint assignment_base = token * (uint)K;
        for (uint slot = 0; slot < (uint)K; ++slot) {
            const uint assignment = assignment_base + slot;
            const uint sorted_row = (uint)inverse_order[assignment];
            // Preserve the legacy bfloat16 multiply-then-reduce rounding.
            const T weighted = (T)(
                (float)sorted_outputs[sorted_row * threads_per_grid.x + feature]
                * (float)weights[assignment]);
            accumulator = accumulator + weighted;
        }
        output[token * threads_per_grid.x + feature] = accumulator;
    """,
    ensureRowContiguous: true
)

/// Consume production-shaped sorted Gemma 4 expert rows through their inverse
/// permutation and reduce original top-K slots into `[tokens, hidden]`.
///
/// This primitive deliberately accepts only the production logical layout:
/// bfloat16 `[tokens * 8, 2816]`, uint32 inverse order, and bfloat16
/// `[tokens, 8]`. Callers must use the legacy scatter + weighted sum for every
/// other dtype, shape, or layout.
public func weightedExpertUnsort(
    sortedOutputs: MLXArray,
    inverseOrder: MLXArray,
    weights: MLXArray
) -> MLXArray {
    let hidden = sortedOutputs.dim(1)
    precondition(
        sortedOutputs.ndim == 2 && (hidden % 64 == 0)
            && sortedOutputs.dtype == .bfloat16,
        "weightedExpertUnsort outputs must be bfloat16 [assignments, hidden] with hidden % 64 == 0")
    precondition(
        inverseOrder.ndim == 1 && inverseOrder.dtype == .uint32,
        "weightedExpertUnsort inverse order must be flat uint32")
    precondition(
        weights.ndim == 2 && weights.dim(1) == 8 && weights.size >= 64
            && weights.dtype == .bfloat16,
        "weightedExpertUnsort weights must be sorted-prefill bfloat16 [tokens, 8]")
    precondition(
        sortedOutputs.dim(0) == weights.size && inverseOrder.size == weights.size,
        "weightedExpertUnsort assignment counts must match")

    let tokens = weights.dim(0)
    weightedExpertUnsortProbe.recordEffective()
    return weightedExpertUnsortKernel(
        [sortedOutputs, inverseOrder, weights],
        template: [
            ("T", sortedOutputs.dtype),
            ("K", 8),
        ],
        grid: (hidden, tokens, 1),
        threadGroup: (64, 4, 1),
        outputShapes: [[tokens, hidden]],
        outputDTypes: [.bfloat16]
    )[0]
}


// MARK: - Compiled activation fusions (vMLX / osaurus-main port)

/// Approximate (tanh) GELU written with `x * x * x` instead of the Power
/// primitive (`x ** 3`). The Power primitive returns zero results under the
/// macOS Tahoe Metal JIT (MLX #3329), so the explicit multiplies keep it safe
/// under `compile(shapeless: true)`. Numerically identical to
/// `MLXNN.geluApproximate`.
///
/// Gated by `MLXHardwareInfo.isCompiledDecodeSupported` (env `MLX_COMPILED_DECODE`,
/// default on); falls back to the plain closure when compiled fusions are off.
public let safeGeluApproximate: @Sendable (MLXArray) -> MLXArray = {
    let body: @Sendable (MLXArray) -> MLXArray = { (x: MLXArray) -> MLXArray in
        0.5 * x * (1 + tanh(sqrt(2 / Float.pi) * (x + 0.044715 * x * x * x)))
    }
    if MLXHardwareInfo.isCompiledDecodeSupported {
        return cbv2ObservedCompiled(.gelu, compile(shapeless: true, body))
    }
    return body
}()

/// Drop-in replacement for `MLXNN.GELU(approximation: .tanh)` that avoids the
/// Power primitive crash. Use anywhere a tanh-approx GELU unary layer is needed.
public class SafeGELU: Module, UnaryLayer {
    public override init() { super.init() }
    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        safeGeluApproximate(x)
    }
}

/// Compiled SiLU-gated GLU product (`silu(gate) * up`). Same math as
/// `compiledSiluProduct` above, but gated by `MLXHardwareInfo` so M1/M2 + macOS
/// Tahoe can opt out. Used by `SwitchGLU` when a SiLU activation is supplied via
/// the custom-activation initializer (where `activationProduct` is nil).
private let compiledSwiGLU: @Sendable (MLXArray, MLXArray) -> MLXArray = {
    let body: @Sendable (MLXArray, MLXArray) -> MLXArray = {
        (gate: MLXArray, up: MLXArray) -> MLXArray in
        MLXNN.silu(gate) * up
    }
    if MLXHardwareInfo.isCompiledDecodeSupported {
        return cbv2ObservedCompiled(.swiGLU, compile(shapeless: true, body))
    }
    return body
}()

/// Compiled GELU-gated GLU product (`geluApprox(gate) * up`), fusing the tanh
/// GELU and the element-wise multiply into one shapeless kernel. Uses the
/// Power-free `x * x * x` GELU so it is safe under `compile(shapeless: true)`.
private let compiledGeGLU: @Sendable (MLXArray, MLXArray) -> MLXArray = {
    let body: @Sendable (MLXArray, MLXArray) -> MLXArray = {
        (gate: MLXArray, up: MLXArray) -> MLXArray in
        (0.5 * gate * (1 + tanh(sqrt(2 / Float.pi) * (gate + 0.044715 * gate * gate * gate)))) * up
    }
    if MLXHardwareInfo.isCompiledDecodeSupported {
        return cbv2ObservedCompiled(.geGLU, compile(shapeless: true, body))
    }
    return body
}()

public func gatherSort(x: MLXArray, indices: MLXArray) -> (MLXArray, MLXArray, MLXArray) {
    let m = indices.dim(-1)
    let indices = indices.flattened()
    let order = argSort(indices)
    let inverseOrder = argSort(order)

    return (
        x.flattened(start: 0, end: -3)[order.floorDivide(m)],
        indices[order],
        inverseOrder
    )
}

public func scatterUnsort(x: MLXArray, invOrder: MLXArray, shape: [Int]? = nil) -> MLXArray {
    var x = x[invOrder]
    if let shape {
        x = unflatten(x, axis: 0, shape: shape)
    }
    return x
}

private let qwenDirectExpertReductionEnabled: Bool = {
    let raw = ProcessInfo.processInfo.environment["MLX_QWEN_DIRECT_EXPERT_REDUCTION"]?
        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return raw == "1" || raw == "true" || raw == "on"
}()

// MARK: - SwitchGLU

/// Semantic profile required by the exact Gemma direct-reduction experiment.
/// Generic SwitchGLU instances never infer production eligibility from a
/// one-point activation probe.
public enum SwitchGLUWeightedReductionProfile: Sendable {
    case generic
    case gemma4ProductionGeGLU
    case qwen35ProductionSwiGLU
}


/// Safely row-concatenates split SwitchGLU gate/up checkpoint tensors.
///
/// This is the model-neutral core of the Qwen3.5 gate/up load-time fusion:
/// every tensor suffix must match in shape and dtype, and both module paths
/// must resolve to one quantization policy. An incompatible pair is left
/// byte-for-byte split and reported through `setFused`, allowing the caller to
/// install a split ``SwitchGLU`` before strict parameter verification.
public func fuseSwitchGLUGateUpWeights(
    weights: [String: MLXArray],
    perLayerQuantization: BaseConfiguration.PerLayerQuantization? = nil,
    moduleName: String = "switch_mlp",
    quantizationAliases: (String) -> [String] = { _ in [] },
    shouldProcess: (String) -> Bool = { _ in true },
    setFused: ((String, Bool) -> Void)? = nil
) -> [String: MLXArray] {
    var weights = weights
    let splitMarker = ".\(moduleName).gate_proj."
    var bases = Set<String>()
    for key in weights.keys where key.contains(splitMarker) {
        let range = key.range(of: splitMarker)!
        let base = String(key[..<range.lowerBound]) + ".\(moduleName)."
        if shouldProcess(String(base.dropLast())) {
            bases.insert(base)
        }
    }

    func resolvedQuantization(
        for path: String,
        in table: BaseConfiguration.PerLayerQuantization
    ) -> BaseConfiguration.Quantization? {
        var candidates = [path]
        for alias in quantizationAliases(path) where !candidates.contains(alias) {
            candidates.append(alias)
        }
        for candidate in candidates {
            guard let option = table.perLayerQuantization[candidate] else { continue }
            switch option {
            case .skip:
                return nil
            case .quantize(let quantization):
                return quantization
            }
        }
        return table.quantization
    }

    func suffixes(_ half: String, base: String) -> Set<String> {
        let prefix = "\(base)\(half)."
        return Set(
            weights.keys.compactMap {
                $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil
            })
    }

    for base in bases.sorted() {
        let modulePath = String(base.dropLast())
        let gateSuffixes = suffixes("gate_proj", base: base)
        let upSuffixes = suffixes("up_proj", base: base)
        guard !upSuffixes.isEmpty else {
            // Leave malformed half-pairs untouched so strict update reports a
            // catchable missing/unhandled-parameter error.
            continue
        }

        var blocker: String?
        if let table = perLayerQuantization {
            let gate = resolvedQuantization(for: "\(base)gate_proj", in: table)
            let up = resolvedQuantization(for: "\(base)up_proj", in: table)
            let sameEffectivePolicy: Bool
            switch (gate, up) {
            case (nil, nil):
                sameEffectivePolicy = true
            case (let gate?, let up?):
                sameEffectivePolicy =
                    gate.groupSize == up.groupSize && gate.bits == up.bits
                    && gate.mode == up.mode
            default:
                sameEffectivePolicy = false
            }
            if !sameEffectivePolicy {
                blocker = "gate and up resolve to different quantization policies"
            }
            // The loader gives an explicit fused-path policy precedence
            // over aliases. Do not concatenate halves under a policy that
            // the replacement projection will not actually use. Absence of
            // a fused entry must still resolve through the split aliases.
            if sameEffectivePolicy,
                table.perLayerQuantization["\(base)gate_up_proj"] != nil
            {
                let fused = resolvedQuantization(for: "\(base)gate_up_proj", in: table)
                let fusedMatches: Bool
                switch (gate, fused) {
                case (nil, nil):
                    fusedMatches = true
                case (let gate?, let fused?):
                    fusedMatches = gate.groupSize == fused.groupSize
                        && gate.bits == fused.bits && gate.mode == fused.mode
                default:
                    fusedMatches = false
                }
                if !fusedMatches {
                    blocker = "fused projection resolves to a different quantization policy"
                }
            }
        }
        if blocker == nil, gateSuffixes != upSuffixes {
            blocker = "gate and up carry different tensor sets"
        }
        if blocker == nil {
            for suffix in gateSuffixes.sorted() {
                guard let gate = weights["\(base)gate_proj.\(suffix)"],
                    let up = weights["\(base)up_proj.\(suffix)"]
                else { continue }
                if gate.shape != up.shape || gate.dtype != up.dtype {
                    blocker = "\(suffix) tensors differ in shape or dtype"
                    break
                }
            }
        }

        if let blocker {
            print("[INFO] fuseSwitchGLUGateUpWeights: keeping \(modulePath) split — \(blocker)")
            setFused?(modulePath, false)
            continue
        }

        for suffix in gateSuffixes.sorted() {
            guard let gate = weights.removeValue(forKey: "\(base)gate_proj.\(suffix)"),
                let up = weights.removeValue(forKey: "\(base)up_proj.\(suffix)")
            else { continue }
            let axis = suffix == "bias" ? -1 : -2
            weights["\(base)gate_up_proj.\(suffix)"] = concatenated([gate, up], axis: axis)
        }
    }

    if let setFused {
        let fusedMarker = ".\(moduleName).gate_up_proj."
        var fusedPaths = Set<String>()
        for key in weights.keys where key.contains(fusedMarker) {
            let range = key.range(of: fusedMarker)!
            let path = String(key[..<range.lowerBound]) + ".\(moduleName)"
            if shouldProcess(path) {
                fusedPaths.insert(path)
            }
        }
        for path in fusedPaths.sorted() {
            setFused(path, true)
        }
    }
    return weights
}

/// Replaces the SwitchGLU at a checkpoint path with its fused or split twin.
/// Aliases bridge checkpoint and module-tree namespaces.
public func setSwitchGLUGateUpFused(
    _ fused: Bool,
    at path: String,
    aliases: [String] = [],
    in root: Module
) {
    let candidates = [path] + aliases.filter { $0 != path }
    for (modulePath, module) in root.namedModules() {
        guard candidates.contains(modulePath), let glu = module as? SwitchGLU else {
            continue
        }
        if glu.hasFusedGateUp != fused {
            let twin = fused ? glu.fusingGateUp() : glu.splittingGateUp()
            root.update(modules: ModuleChildren.unflattened([(modulePath, twin)]))
        }
        return
    }
}

public class SwitchGLU: Module {
    @ModuleInfo(key: "gate_proj") var gateProj: SwitchLinear?
    @ModuleInfo(key: "up_proj") var upProj: SwitchLinear?
    @ModuleInfo(key: "gate_up_proj") var gateUpProj: SwitchLinear?
    @ModuleInfo(key: "down_proj") var downProj: SwitchLinear

    let inputDims: Int
    let hiddenDims: Int
    let numExperts: Int
    let activation: (MLXArray) -> MLXArray
    /// Optional fused (activation * up) kernel. Set for the default SiLU path so
    /// the GLU product runs as one compiled op; nil when a custom activation is
    /// supplied (we then fall back to `activation(gate) * up`). Upstream ef85ed0.
    let activationProduct: (@Sendable (MLXArray, MLXArray) -> MLXArray)?
    let weightedReductionProfile: SwitchGLUWeightedReductionProfile

    /// Activation-type flags detected once at init from a tiny test input (vMLX
    /// approach — no per-token check). Only consulted when `activationProduct` is
    /// nil (the custom-activation path): they let SiLU/GELU custom activations use
    /// the compiled `compiledSwiGLU` / `compiledGeGLU` fusions instead of the
    /// uncompiled `activation(gate) * up`. On any mismatch we fall back to that
    /// exact uncompiled path, so detection only ever enables a numerically
    /// equivalent fast path — it can never change results.
    let isSiluActivation: Bool
    let isGeluActivation: Bool

    /// Default SiLU GLU path -- uses the compiled fused (silu * up) kernel.
    public init(
        inputDims: Int,
        hiddenDims: Int,
        numExperts: Int,
        bias: Bool = false,
        fuseGateUp: Bool = false,
        weightedReductionProfile: SwitchGLUWeightedReductionProfile = .generic
    ) {
        self.inputDims = inputDims
        self.hiddenDims = hiddenDims
        self.numExperts = numExperts
        self.activation = MLXNN.silu
        self.activationProduct = compiledSiluProduct
        self.weightedReductionProfile = weightedReductionProfile
        // Default path is SiLU and `activationProduct` is non-nil, so these are
        // not consulted on the hot path; set them accurately for completeness
        // (and to avoid a needless probe eval at load for every MoE layer).
        self.isSiluActivation = true
        self.isGeluActivation = false

        if fuseGateUp {
            self._gateUpProj.wrappedValue = SwitchLinear(
                inputDims: inputDims, outputDims: hiddenDims * 2,
                numExperts: numExperts, bias: bias)
        } else {
            self._gateProj.wrappedValue = SwitchLinear(
                inputDims: inputDims, outputDims: hiddenDims,
                numExperts: numExperts, bias: bias)
            self._upProj.wrappedValue = SwitchLinear(
                inputDims: inputDims, outputDims: hiddenDims,
                numExperts: numExperts, bias: bias)
        }
        self._downProj.wrappedValue = SwitchLinear(
            inputDims: hiddenDims, outputDims: inputDims, numExperts: numExperts, bias: bias)

        super.init()
    }

    /// Custom-activation GLU path -- runs `activation(gate) * up` uncompiled.
    public init(
        inputDims: Int,
        hiddenDims: Int,
        numExperts: Int,
        activation: @escaping (MLXArray) -> MLXArray,
        bias: Bool = false,
        fuseGateUp: Bool = false,
        weightedReductionProfile: SwitchGLUWeightedReductionProfile = .generic
    ) {
        self.inputDims = inputDims
        self.hiddenDims = hiddenDims
        self.numExperts = numExperts
        self.activation = activation
        self.activationProduct = nil
        self.weightedReductionProfile = weightedReductionProfile
        // Detect SiLU/GELU once via a tiny test input (vMLX approach) so the hot
        // path can select the compiled fusion without a per-token check. Exact
        // equality is intentional: a match means the supplied closure computes
        // that exact function; any non-match falls back to `activation(gate) * up`
        // in callAsFunction, so this can only ever enable an equivalent fast path.
        let probe = MLXArray([Float(1.0)])
        let probeOut = activation(probe)
        let detectedSilu = (probeOut .== MLXNN.silu(probe)).all().item(Bool.self)
        self.isSiluActivation = detectedSilu
        self.isGeluActivation =
            !detectedSilu && (probeOut .== safeGeluApproximate(probe)).all().item(Bool.self)

        if fuseGateUp {
            self._gateUpProj.wrappedValue = SwitchLinear(
                inputDims: inputDims, outputDims: hiddenDims * 2,
                numExperts: numExperts, bias: bias)
        } else {
            self._gateProj.wrappedValue = SwitchLinear(
                inputDims: inputDims, outputDims: hiddenDims,
                numExperts: numExperts, bias: bias)
            self._upProj.wrappedValue = SwitchLinear(
                inputDims: inputDims, outputDims: hiddenDims,
                numExperts: numExperts, bias: bias)
        }
        self._downProj.wrappedValue = SwitchLinear(
            inputDims: hiddenDims, outputDims: inputDims, numExperts: numExperts, bias: bias)

        super.init()
    }

    /// True while the routed gate/up projection uses the fused
    /// `gate_up_proj` layout built by `fuseGateUp: true`.
    public var hasFusedGateUp: Bool { gateUpProj != nil }

    /// Structural twin with the requested gate/up topology: same
    /// dims/bias/activation/profile, freshly initialized gate/up
    /// projection(s) (the caller's subsequent quantize + strict update
    /// supplies their tensors), `down_proj` carried over.
    ///
    /// Used because the gate/up fusion is a per-load, per-layer decision: a
    /// heterogeneous checkpoint (different gate vs up quantization policies)
    /// must load through split modules, and a later homogeneous load on the
    /// same model instance must be able to restore the fused layout.
    private init(copying other: SwitchGLU, fusedGateUp: Bool) {
        self.inputDims = other.inputDims
        self.hiddenDims = other.hiddenDims
        self.numExperts = other.numExperts
        self.activation = other.activation
        self.activationProduct = other.activationProduct
        self.weightedReductionProfile = other.weightedReductionProfile
        self.isSiluActivation = other.isSiluActivation
        self.isGeluActivation = other.isGeluActivation

        let bias = (other.gateUpProj ?? other.gateProj)?.bias != nil
        if fusedGateUp {
            self._gateUpProj.wrappedValue = SwitchLinear(
                inputDims: other.inputDims, outputDims: other.hiddenDims * 2,
                numExperts: other.numExperts, bias: bias)
        } else {
            self._gateProj.wrappedValue = SwitchLinear(
                inputDims: other.inputDims, outputDims: other.hiddenDims,
                numExperts: other.numExperts, bias: bias)
            self._upProj.wrappedValue = SwitchLinear(
                inputDims: other.inputDims, outputDims: other.hiddenDims,
                numExperts: other.numExperts, bias: bias)
        }
        self._downProj.wrappedValue = other.downProj

        super.init()
    }

    /// Returns the split twin described by `init(copying:fusedGateUp:)`.
    /// Swap it in with `Module.update(modules:)`; direct property assignment
    /// would not refresh the module cache.
    public func splittingGateUp() -> SwitchGLU {
        SwitchGLU(copying: self, fusedGateUp: false)
    }

    /// Returns the fused twin described by `init(copying:fusedGateUp:)` —
    /// the inverse of ``splittingGateUp()``, restoring the fused layout when
    /// a homogeneous checkpoint is loaded onto a previously split instance.
    public func fusingGateUp() -> SwitchGLU {
        SwitchGLU(copying: self, fusedGateUp: true)
    }

    private func projectExperts(
        _ x: MLXArray, _ indices: MLXArray,
        sortAssignments: Bool? = nil, sortedProjection: Bool? = nil
    ) -> (output: MLXArray, inverseOrder: MLXArray?, sorted: Bool) {
        var x = MLX.expandedDimensions(x, axes: [-2, -3])
        let doSort = sortAssignments ?? (indices.size >= 64)
        let projectionHint = sortedProjection ?? doSort

        var idx = indices
        var inverseOrder = MLXArray()
        if doSort {
            (x, idx, inverseOrder) = gatherSort(x: x, indices: indices)
        }

        let xGate: MLXArray
        let xUp: MLXArray
        if let gateUpProj {
            let xGateUp = gateUpProj(x, idx, sortedIndices: projectionHint)
            xGate = xGateUp[.ellipsis, ..<hiddenDims]
            xUp = xGateUp[.ellipsis, hiddenDims...]
        } else {
            guard let gateProj, let upProj else {
                preconditionFailure("SwitchGLU requires gate_up_proj or gate_proj/up_proj")
            }
            xUp = upProj(x, idx, sortedIndices: projectionHint)
            xGate = gateProj(x, idx, sortedIndices: projectionHint)
        }

        let activated: MLXArray
        if let activationProduct {
            activated = activationProduct(xGate, xUp)
        } else if isSiluActivation {
            activated = compiledSwiGLU(xGate, xUp)
        } else if isGeluActivation {
            activated = compiledGeGLU(xGate, xUp)
        } else {
            activated = activation(xGate) * xUp
        }

        x = downProj(activated, idx, sortedIndices: projectionHint)
        return (x, doSort ? inverseOrder : nil, doSort)
    }

    private func legacyWeightedReduction(
        _ projected: (output: MLXArray, inverseOrder: MLXArray?, sorted: Bool),
        indices: MLXArray,
        weights: MLXArray
    ) -> MLXArray {
        var output = projected.output
        if let inverseOrder = projected.inverseOrder {
            output = scatterUnsort(x: output, invOrder: inverseOrder, shape: indices.shape)
        }
        return weightedExpertSum(MLX.squeezed(output, axis: -2), weights)
    }

    private func supportsWeightedExpertUnsort(
        _ x: MLXArray, _ indices: MLXArray, weights: MLXArray
    ) -> Bool {
        switch weightedReductionProfile {
        case .generic:
            return false
        case .gemma4ProductionGeGLU:
            return inputDims == 2816
                && hiddenDims == 704
                && numExperts == 128
                && gateUpProj == nil
                && activationProduct == nil
                && isGeluActivation
                && x.ndim == 2
                && x.dim(1) == 2816
                && x.dtype == .bfloat16
                && indices.ndim == 2
                && indices.dim(0) == x.dim(0)
                && indices.dim(1) == 8
                && indices.dtype == .uint32
                && weights.ndim == 2
                && weights.shape == indices.shape
                && weights.dtype == .bfloat16
                && indices.size >= 64
        case .qwen35ProductionSwiGLU:
            return qwenDirectExpertReductionEnabled
                && inputDims == 2048
                && hiddenDims == 512
                && numExperts == 256
                && isSiluActivation
                && x.ndim == 2
                && x.dim(1) == 2048
                && x.dtype == .bfloat16
                && indices.ndim == 2
                && indices.dim(0) == x.dim(0)
                && indices.dim(1) == 8
                && indices.dtype == .uint32
                && weights.ndim == 2
                && weights.shape == indices.shape
                && weights.dtype == .bfloat16
                && indices.size >= 64
        }
    }

    public func callAsFunction(_ x: MLXArray, _ indices: MLXArray) -> MLXArray {
        var projected = projectExperts(x, indices)
        if let inverseOrder = projected.inverseOrder {
            projected.output = scatterUnsort(
                x: projected.output, invOrder: inverseOrder, shape: indices.shape)
        }
        return MLX.squeezed(projected.output, axis: -2)
    }

    /// Explicit private whole-expert partition entry. The caller derives the
    /// policy from the authoritative unpartitioned route and preserves local
    /// assignment order. A sorted projection hint requires the actual sort.
    /// Ordinary callAsFunction and weighted-reduction policies are unchanged.
    @_spi(ExpertParallel) public func callAsPartition(
        _ x: MLXArray, _ indices: MLXArray,
        sortAssignments: Bool, sortedProjection: Bool
    ) -> MLXArray {
        precondition(sortAssignments || !sortedProjection,
                     "A sorted expert projection must have sorted assignments")
        var projected = projectExperts(x, indices, sortAssignments: sortAssignments,
                                       sortedProjection: sortedProjection)
        if let inverseOrder = projected.inverseOrder {
            projected.output = scatterUnsort(
                x: projected.output, invOrder: inverseOrder, shape: indices.shape)
        }
        return MLX.squeezed(projected.output, axis: -2)
    }

    /// Always-called expert projection + weighted reduction entry point.
    ///
    /// When the experiment is enabled, only the exact sorted production Gemma
    /// prefill contract reduces directly to `[tokens, hidden]`. Disabled,
    /// decode/small-assignment, generic, custom-activation, dtype/layout, and
    /// near-geometry calls retain scatter/unsort followed by
    /// ``weightedExpertSum``.
    public func callAndWeightedReduce(
        _ x: MLXArray,
        _ indices: MLXArray,
        weights: MLXArray,
        fuseSortedReduction: Bool,
        isProductionPrefill: Bool = true
    ) -> MLXArray {
        guard fuseSortedReduction && isProductionPrefill,
            supportsWeightedExpertUnsort(x, indices, weights: weights)
        else {
            return weightedExpertSum(callAsFunction(x, indices), weights)
        }

        let projected = projectExperts(x, indices)
        guard projected.sorted,
            let inverseOrder = projected.inverseOrder,
            projected.output.ndim == 3,
            projected.output.dim(-2) == 1,
            (projected.output.dim(-1) == 2816 || projected.output.dim(-1) == inputDims),
            projected.output.dtype == .bfloat16
        else {
            return legacyWeightedReduction(projected, indices: indices, weights: weights)
        }

        return weightedExpertUnsort(
            sortedOutputs: MLX.squeezed(projected.output, axis: -2),
            inverseOrder: inverseOrder,
            weights: weights)
    }
}

public class SwitchLinear: Module, Quantizable {
    @ModuleInfo(key: "weight") var weight: MLXArray
    @ModuleInfo(key: "bias") var bias: MLXArray?

    let inputDims: Int
    let outputDims: Int
    let numExperts: Int

    public init(inputDims: Int, outputDims: Int, numExperts: Int, bias: Bool = true) {
        self.inputDims = inputDims
        self.outputDims = outputDims
        self.numExperts = numExperts

        let scale = sqrt(1.0 / Float(inputDims))
        self._weight.wrappedValue = MLXRandom.uniform(
            low: -scale,
            high: scale,
            [numExperts, outputDims, inputDims]
        )

        if bias {
            self._bias.wrappedValue = MLXArray.zeros([numExperts, outputDims])
        }

        super.init()
    }

    /// Initializer meant for subclasses to provide weight and bias arrays directly.
    ///
    /// This is used e.g. by ``QuantizedSwitchLinear`` to provide quantized weights and biases
    /// rather than have ``SwitchLinear`` compute them.
    public init(
        inputDims: Int, outputDims: Int, numExperts: Int,
        weight: MLXArray, bias: MLXArray? = nil
    ) {
        self.inputDims = inputDims
        self.outputDims = outputDims
        self.numExperts = numExperts

        self._weight.wrappedValue = weight
        self._bias.wrappedValue = bias
    }

    public func callAsFunction(
        _ x: MLXArray, _ indices: MLXArray, sortedIndices: Bool = false
    ) -> MLXArray {
        let weightT = self.weight.swappedAxes(-1, -2)
        var result = MLX.gatherMM(x, weightT, rhsIndices: indices, sortedIndices: sortedIndices)

        if let bias = self.bias {
            result = result + MLX.expandedDimensions(bias[indices], axis: -2)
        }

        return result
    }

    public func toQuantized(groupSize: Int = 64, bits: Int = 4, mode: QuantizationMode) -> Module {
        QuantizedSwitchLinear(self, groupSize: groupSize, bits: bits, mode: mode)
    }
}

public class QuantizedSwitchLinear: SwitchLinear, Quantized {
    private let scaleCastCache = ConstantArrayCastCache()
    private let offsetCastCache = ConstantArrayCastCache()
    private let linearBiasCastCache = ConstantArrayCastCache()

    @discardableResult
    public override func update(
        parameters: ModuleParameters, verify: VerifyUpdate, path: [String] = [],
        modulePath: [String] = []
    ) throws -> Self {
        defer {
            scaleCastCache.clear()
            offsetCastCache.clear()
            linearBiasCastCache.clear()
        }
        return try super.update(
            parameters: parameters, verify: verify, path: path, modulePath: modulePath)
    }

    @ModuleInfo(key: "scales") var scales: MLXArray
    @ModuleInfo(key: "biases") var biases: MLXArray?

    public let groupSize: Int
    public let bits: Int
    public let mode: QuantizationMode

    public init(
        _ other: SwitchLinear, groupSize: Int = 64, bits: Int = 4, mode: QuantizationMode = .affine
    ) {
        self.groupSize = groupSize
        self.bits = bits
        self.mode = mode

        let (quantizedWeight, scales, biases) = MLX.quantized(
            other.weight, groupSize: groupSize, bits: bits, mode: mode)

        self._scales.wrappedValue = scales
        self._biases.wrappedValue = biases

        super.init(
            inputDims: other.inputDims, outputDims: other.outputDims, numExperts: other.numExperts,
            weight: quantizedWeight, bias: other.bias)

        self.freeze()
    }

    /// The `sortedIndices` hint is forwarded only when `x` is index-aligned:
    /// when it already carries one row per gathered index. Otherwise it is
    /// withheld. That is a correctness constraint, not a tuning choice.
    ///
    /// THE CAUSE, in the MLX this package pins. `GatherQMM::eval_gpu` computes
    /// `M = x.size() / K` from the array it was HANDED, then passes that `M`
    /// into `gather_qmm_rhs`. `gather_qmm_rhs` broadcasts `x` up to one row per
    /// index when it is not already that shape, and never recomputes `M`; the
    /// dispatch grid and the kernel's row bound both keep using the stale
    /// value. Only the first `x.size() / K` rows of the output are written and
    /// the rest keeps whatever was in the pool. That memory is wrong from the
    /// first call, carries no NaN, and repeats exactly on reuse, so the fault
    /// reads as a stable wrong answer rather than as noise.
    ///
    /// So the fault needs a broadcast, and a broadcast is exactly what the
    /// condition below excludes. It mirrors the vendor's own test for whether
    /// the broadcast is needed.
    ///
    /// The non-quantized `gather_mm` is not exposed to any of this, and the
    /// reason is structural: `GatherMM::eval_gpu` derives its own shapes
    /// inside `gather_mm_rhs`, while only `GatherQMM::eval_gpu` carries a
    /// precomputed row count across the broadcast.
    ///
    /// WHAT IS AT STAKE EITHER WAY. The hint only reaches a different kernel
    /// when `M == 1 && B >= 16 && B / E >= 4`, and on that route it is worth
    /// worth 2.6x to 4.1x on the gather across runs, measured at the
    /// production geometry.
    /// Every caller in this package sorts through
    /// `gatherSort` before it hints, which produces one row per index, so the
    /// aligned branch is the one production takes and the fault is out of
    /// reach. Withholding the hint from that branch as well would surrender
    /// the speed, and the opt-in Gemma 4 expert-QMM tile route inside
    /// `gather_qmm_rhs` with it, for nothing.
    ///
    /// `QuantizedSwitchLinearSortedHintTests` holds both legs and the
    /// reproducer.
    override public func callAsFunction(
        _ x: MLXArray, _ indices: MLXArray, sortedIndices: Bool = false
    ) -> MLXArray {
        let indexAligned = x.size == indices.size * x.dim(-2) * x.dim(-1)
        let scales = mode == .affine
            ? (scaleCastCache.cachedCast(self.scales, to: x.dtype) ?? self.scales)
            : self.scales
        let biases = self.biases.map { offsets in
            mode == .affine
                ? (offsetCastCache.cachedCast(offsets, to: x.dtype) ?? offsets)
                : offsets
        }
        var result = MLX.gatherQuantizedMM(
            x,
            self.weight,
            scales: scales,
            biases: biases,
            rhsIndices: indices,
            transpose: true,
            groupSize: self.groupSize,
            bits: self.bits,
            mode: mode,
            sortedIndices: sortedIndices && indexAligned
        )

        if let bias = self.bias {
            // During transforms cachedCast returns nil, preserving the old
            // gather-then-promote ordering (including bias gradients).
            let bias = linearBiasCastCache.cachedCast(bias, to: result.dtype) ?? bias
            result = result + MLX.expandedDimensions(bias[indices], axis: -2)
        }

        return result
    }
}
