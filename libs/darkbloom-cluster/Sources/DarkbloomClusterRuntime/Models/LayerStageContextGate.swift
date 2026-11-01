import Foundation

/// The largest context the host memory gate admits on this Mac now, for a
/// family whose request charge is its own function of the context: what
/// `QwenResidentRuntime.admittedContext` does for the layer-stage seam, for
/// the families with their own resident runtime (GPT-OSS, MiMo). One sample
/// of the host is judged for every candidate, so the search is consistent;
/// the caller then takes one live decision at the result. A load is refused
/// only when not even one frame and one output fit (oMLX U#3643: a ceiling
/// frozen at load refused what the settled host could hold).
enum LayerStageContextGate {
    struct Charge {
        let reservedBytes: Int
        let extraNativeBytes: Int
        let extraHostBytes: Int
    }

    /// `charge(context, prompt, chunk)` is the request charge at `context`
    /// tokens with the longest prompt it allows, prefilled in frames of
    /// `chunk`. It must grow with the context. Nil when the smallest useful
    /// request does not fit.
    static func admitted(profile: QwenLayerStageGenerationProfile,
                         charge: (_ context: Int, _ prompt: Int, _ chunk: Int) throws -> Charge) throws -> (context: Int, charge: Charge)? {
        let maximum = profile.maximumContextTokens
        let minimum = min(maximum, profile.maximumChunkTokens + 1)
        let sum = QwenLongPrefillCheckedBytes.sum
        func value(_ context: Int) throws -> Charge {
            let prompt = min(profile.maximumPromptTokens, context - 1)
            return try charge(context, prompt, min(profile.maximumChunkTokens, prompt))
        }
        let os = try QwenDenseStageLoadResources.observeOS()
        let native = QwenDenseStageLoadResources.observeNative()
        let now = DispatchTime.now().uptimeNanoseconds
        func admits(_ context: Int) throws -> Bool {
            let charge = try value(context)
            let free = max(QwenDenseStageLoadPolicy.minimumAdmissibleBytes, try sum([charge.reservedBytes,
                charge.extraNativeBytes, charge.extraHostBytes, QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
            let allocator = try sum([native.activeBytes, native.cacheBytes, charge.reservedBytes,
                charge.extraNativeBytes, QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
            let decision = try QwenDenseStageLoadPolicy.decide(os, requiredBytes: free,
                purpose: "Resident context of \(context) tokens", now: now)
            return decision.admitted && native.allocatorLimitBytes >= allocator
        }
        guard let largest = try QwenResidentContextAdmission.largest(minimum: minimum, maximum: maximum, admits: admits) else {
            return nil
        }
        return (largest, try value(largest))
    }

    /// The smallest context a loaded stage must serve: one frame and one output.
    static func minimumContextTokens(_ profile: QwenLayerStageGenerationProfile) -> Int {
        min(profile.maximumContextTokens, profile.maximumChunkTokens + 1)
    }
}
