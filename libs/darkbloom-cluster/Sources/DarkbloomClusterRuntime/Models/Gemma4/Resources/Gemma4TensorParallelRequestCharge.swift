import Foundation

/// What one request costs a Gemma 4 tensor-parallel rank at its own context,
/// so the pair serves the model's native context (`Gemma4ResidentAdapterDefinition.contextLimits`)
/// with no service-level cap: LOAD and the planner quote the memory plan's
/// request (`Gemma4ResidentAdapterDefinition.memoryProfile`, the standard
/// 32,768 + 32,768 tokens), and each rank's live gate admits a longer request
/// when its whole charge fits now and refuses it alone otherwise (`reserve`,
/// `reserveLane`). READY carries the longest context that gate admits now
/// (`servingContextTokens`), so the pair refuses a longer request before
/// either rank is asked.
///
/// The one place this rank's charges are derived (`budget`): LOAD's quote, a
/// reservation or lane at its own context, prompt and chunk, the share probe,
/// READY's capacity and the serving context all take the same terms
/// (`Gemma4TensorParallelRequestBudget`): this rank's own KV heads, its query
/// heads' attention transient, the FP32 partials, the vocabulary rows and the
/// prompt-prefix capture.
struct Gemma4TensorParallelRequestCharge {
    /// What the pair advertises and holds a request to.
    let profile: QwenLayerStageGenerationProfile
    /// What LOAD quotes every lane at.
    let memory: QwenLayerStageGenerationProfile
    /// Whether this rank keeps prompt prefixes: a request is then charged its capture.
    let keepsPrefixes: Bool
    let allocationBound: (Int) throws -> Int

    init(profile: QwenLayerStageGenerationProfile, memory: QwenLayerStageGenerationProfile, keepsPrefixes: Bool,
         allocationBound: @escaping (Int) throws -> Int) throws {
        guard memory.identifier == profile.identifier, memory.maximumContextTokens <= profile.maximumContextTokens,
              memory.maximumChunkTokens == profile.maximumChunkTokens else {
            throw ProbeError("Gemma tensor-parallel memory plan differs from its profile")
        }
        self.profile = profile; self.memory = memory; self.keepsPrefixes = keepsPrefixes
        self.allocationBound = allocationBound
    }

    /// One request of `contextTokens` (its prompt and output) prefilled in
    /// chunks of `chunkTokens`, with the capture of a prompt of `promptTokens`
    /// (nil: the context's longest) when `keepsPrefixes` (nil: this rank's
    /// setting; a request whose cache is off, or the share probe, captures
    /// none), every array at the allocator's bound.
    func budget(contextTokens: Int, chunkTokens: Int, promptTokens: Int? = nil,
                keepsPrefixes: Bool? = nil) throws -> Gemma4TensorParallelRequestBudget {
        try .derive(contextTokens: contextTokens, chunkTokens: chunkTokens, promptTokens: promptTokens,
            keepsPrefixes: keepsPrefixes ?? self.keepsPrefixes, allocationBound: allocationBound)
    }

    /// LOAD's quote: one request at the memory plan's longest context, with
    /// the memory plan's longest prompt's capture.
    var memoryPlan: Gemma4TensorParallelRequestBudget {
        get throws {
            try budget(contextTokens: memory.maximumContextTokens, chunkTokens: memory.maximumChunkTokens,
                promptTokens: memory.maximumPromptTokens)
        }
    }

    /// One request of `contextTokens` at its longest prompt, in the profile's chunks.
    func requestBytes(contextTokens: Int) throws -> Int {
        guard (2...profile.maximumContextTokens).contains(contextTokens) else {
            throw ProbeError("Gemma tensor-parallel charge needs a context within the profile")
        }
        return try budget(contextTokens: contextTokens, chunkTokens: profile.maximumChunkTokens,
            promptTokens: min(profile.maximumPromptTokens, contextTokens - 1)).requestBytes
    }

    /// The longest request this rank's paged KV host is bounded by, a ceiling
    /// and not an allocation (each request's pages grow with it): the
    /// profile's, which READY's capacity covers.
    var hostBound: (maximumTokens: Int, chunkTokens: Int) {
        (profile.maximumContextTokens, profile.maximumChunkTokens)
    }

    /// READY's request capacity: LOAD's quote, or one request at the
    /// profile's longest context when that is more.
    var capacityBytes: Int {
        get throws {
            let load = try memoryPlan.requestBytes
            guard profile.maximumContextTokens > memory.maximumContextTokens else { return load }
            return max(load, try requestBytes(contextTokens: profile.maximumContextTokens))
        }
    }

    /// Whether the reservation gate admits one request of `contextTokens` on
    /// an idle rank (no lane held), with that gate's arithmetic
    /// (`Gemma4TensorParallelResidentRuntime.requireLiveMemory`): the request
    /// and the rank's reserve beside it, and the loading headroom.
    /// `reclaimableBytes` (kept prefix entries) give way before the gate refuses.
    func admits(contextTokens: Int, reclaimableBytes: Int, on os: QwenDenseStageLoadOSObservation,
                now: UInt64) throws -> Bool {
        let sum = QwenLongPrefillCheckedBytes.sum
        let held = try sum([requestBytes(contextTokens: contextTokens), memoryPlan.rankBytes,
            QwenDenseStageLoadPolicy.loadingHeadroomBytes(physicalMemoryBytes: os.physicalMemoryBytes)])
        let floor = QwenDenseStageLoadPolicy.minimumAdmissibleBytes(physicalMemoryBytes: os.physicalMemoryBytes)
        return try QwenDenseStageLoadPolicy.decide(os, requiredBytes: max(floor, held - max(0, reclaimableBytes)),
            purpose: "Gemma tensor-parallel context of \(contextTokens) tokens", now: now).admitted
    }

    /// The longest context the gate admits on one observation (`admits`), for
    /// a profile longer than the memory plan; nil for one within it, whose
    /// every request LOAD charged. Not even the smallest useful request (one
    /// chunk and one output token) fitting reports that smallest one, so a
    /// longer request is refused up front and a shorter one is still gated
    /// when it is reserved.
    func servingContextTokens(reclaimableBytes: Int, on os: QwenDenseStageLoadOSObservation, now: UInt64) throws -> Int? {
        guard profile.maximumContextTokens > memory.maximumContextTokens else { return nil }
        let minimum = LayerStageContextGate.minimumContextTokens(profile)
        // Charges grow with the context: the search is over a monotone gate.
        return try QwenResidentContextAdmission.largest(minimum: minimum, maximum: profile.maximumContextTokens) {
            try admits(contextTokens: $0, reclaimableBytes: reclaimableBytes, on: os, now: now)
        } ?? minimum
    }
}
