import Foundation

func workerRequire(_ condition: Bool, _ message: String) throws {
    guard condition else { throw ClusterWorkerProtocolError.invalid(message) }
}

enum ClusterWorkerValidation {
    static func text(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    static func hash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func ready(_ value: ClusterWorkerReady) throws {
        let id = value.identity, p = value.profile
        try workerRequire(text(id.modelID, maximum: 512) && hash(id.artifactSHA256) && hash(id.configurationSHA256)
            && id.peers.count == 2 && id.peers[0].id != id.peers[1].id
            && id.peers.allSatisfy({ text($0.id, maximum: 128) && hash($0.buildSHA256) }), "Invalid worker membership")
        try workerRequire((0...1).contains(value.rank) && hash(value.executionPlanSHA256)
            && (1...ClusterWorkerLimits.capacityBytes).contains(value.requestCapacityBytes), "Invalid local readiness")
        try workerRequire(text(p.id, maximum: 128) && (1...ClusterWorkerLimits.vocabularySize).contains(p.vocabularySize)
            && (1...ClusterWorkerLimits.wirePromptTokens).contains(p.maximumPromptTokens)
            && (1...ClusterWorkerLimits.wireOutputTokens).contains(p.maximumOutputTokens)
            && (1...p.maximumPromptTokens).contains(p.maximumChunkTokens)
            && (p.maximumPromptTokens...ClusterWorkerLimits.wireContextTokens).contains(p.maximumContextTokens), "Invalid worker profile")
        if let d = value.dataPlane {
            try workerRequire(d.protection == ClusterWorkerDataPlane.encrypted && hash(d.transcriptSHA256)
                && d.edgeID.utf8.count == 32 && d.edgeID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                "Invalid worker data plane")
        }
        try workerRequire(value.servingContextTokens.map { (1...p.maximumContextTokens).contains($0) } ?? true,
            "Invalid serving context")
        try workerRequire(value.linkProbe?.valid ?? true, "Invalid link probe")
        try workerRequire(value.media.map { $0 == ClusterGLMMedia.contract } ?? true, "Unknown worker media contract")
    }
    static func reservation(_ value: ClusterWorkerReservation) throws {
        try workerRequire(text(value.profileID, maximum: 128)
            && (1...ClusterWorkerLimits.wirePromptTokens).contains(value.promptTokenIDs.count)
            && (1...ClusterWorkerLimits.wireOutputTokens).contains(value.outputCount)
            && (1...ClusterWorkerLimits.wirePromptTokens).contains(value.chunkSize)
            && value.promptTokenIDs.count <= ClusterWorkerLimits.wireContextTokens - value.outputCount
            && value.promptTokenIDs.allSatisfy({ (0..<ClusterWorkerLimits.vocabularySize).contains($0) })
            && value.stopTokenIDs.count <= ClusterWorkerLimits.stopTokens
            && value.stopTokenIDs == value.stopTokenIDs.sorted() && Set(value.stopTokenIDs).count == value.stopTokenIDs.count
            && value.stopTokenIDs.allSatisfy({ (0..<ClusterWorkerLimits.vocabularySize).contains($0) })
            && value.deadlineUptimeNanoseconds > 0 && value.deadlineUptimeNanoseconds <= UInt64(Int64.max)
            && (1...ClusterWorkerLimits.capacityBytes).contains(value.capacityLimitBytes), "Invalid worker reservation")
        if let media = value.stillImages {
            try workerRequire(value.mimoImages == nil && value.route == nil
                && value.profileID == ClusterStillImages.glmProfileID, "Still images require the GLM pipeline")
            try media.validateStructure(promptCount: value.promptTokenIDs.count)
        }
        if let media = value.glmMedia {
            // Bound to the prompt by both ranks, the GLM row's markers by the runtime.
            try workerRequire(value.stillImages == nil && value.mimoImages == nil && value.route == nil
                && value.profileID == ClusterGLMImageCandidate.textProfileID,
                "GLM media rides alone, on the GLM row's text profile, on the pair as placed")
            try media.validateStructure()
            try workerRequire(media.featureTokens < value.promptTokenIDs.count, "GLM media exceeds the prompt")
        }
        if let media = value.mimoImages {
            try workerRequire(value.profileID.hasSuffix(ClusterMiMoImages.profileSuffix) && value.route == nil,
                "MiMo images require the private image pipeline profile")
            try media.validate(prompt: value.promptTokenIDs)
        }
        if let sampling = value.sampling { try ClusterWorkerSamplingCodec.validate(sampling) }
    }
    static func command(_ frame: ClusterWorkerCommandFrame) throws {
        try workerRequire(frame.sequence < UInt64(Int64.max), "Invalid command sequence")
        switch frame.command {
        case .shutdown, .keepWarm: try workerRequire(frame.requestID == nil, "Shutdown and keep-warm have no request ID")
        default: try workerRequire(frame.requestID != nil, "Command requires request ID")
        }
        switch frame.command {
        case .reserve(let value): try reservation(value)
        case .tokenDecision(let ordinal, _):
            try workerRequire((0..<ClusterWorkerLimits.wireOutputTokens).contains(ordinal), "Invalid token decision ordinal")
        case .keepWarm(let ordinal):
            try workerRequire((1..<ClusterWorkerLimits.keepWarmOrdinals).contains(ordinal), "Invalid keep-warm ordinal")
        default: break
        }
    }
    static func event(_ frame: ClusterWorkerEventFrame) throws {
        try workerRequire(frame.sequence < UInt64(Int64.max), "Invalid event sequence")
        switch frame.event {
        case .ready, .unavailable, .shutdownComplete, .keptWarm:
            try workerRequire(frame.requestID == nil, "Worker event has no request ID")
        default: try workerRequire(frame.requestID != nil, "Event requires request ID")
        }
        switch frame.event {
        case .ready(let value):
            try ready(value)
            try workerRequire(value.identity.membershipEpoch == frame.membershipEpoch, "Ready epoch differs")
        case .admitted(let bytes):
            try workerRequire((1...ClusterWorkerLimits.capacityBytes).contains(bytes), "Invalid reserved bytes")
        case .keptWarm(let ordinal, let microseconds, let serving):
            try workerRequire((1..<ClusterWorkerLimits.keepWarmOrdinals).contains(ordinal) && microseconds >= 0
                && (serving.map { (1...ClusterWorkerLimits.wireContextTokens).contains($0) } ?? true),
                "Invalid keep-warm acknowledgment")
        case .committedToken(let ordinal, let token, let committed, let logprobs):
            try workerRequire((0..<ClusterWorkerLimits.wireOutputTokens).contains(ordinal)
                && (0..<ClusterWorkerLimits.vocabularySize).contains(token)
                && (1...ClusterWorkerLimits.wireContextTokens).contains(committed), "Invalid committed token")
            if let logprobs {
                // Raw log probabilities: finite or -infinity (a token the model
                // cannot emit), never above zero beyond rounding.
                let values = [logprobs.logprob] + logprobs.top.map(\.logprob)
                try workerRequire(logprobs.top.count <= ClusterWorkerSampling.maximumTopLogprobs
                    && values.allSatisfy({ !$0.isNaN && $0 <= 1e-3 })
                    && logprobs.top.allSatisfy({ (0..<ClusterWorkerLimits.vocabularySize).contains($0.tokenID) }),
                    "Invalid token logprobs")
            }
        case .promptCache(let reused, let stored):
            try workerRequire((0..<ClusterWorkerLimits.wirePromptTokens).contains(reused) && stored.count <= 32
                && (reused > 0 || !stored.isEmpty)
                && stored.allSatisfy({ (1..<ClusterWorkerLimits.wirePromptTokens).contains($0) })
                && zip(stored, stored.dropFirst()).allSatisfy({ $0 < $1 }), "Invalid prompt cache report")
        case .requestTelemetry(let t):
            let day: UInt64 = 86_400 * 1_000_000_000
            try workerRequire(!t.isEmpty
                && (t.handoffNanoseconds.map { $0 <= day } ?? true)
                && (t.prefillNanoseconds.map { $0 <= day } ?? true)
                && (t.handoffBytes.map { (0...ClusterWorkerLimits.capacityBytes).contains($0) } ?? true)
                && (t.mtpDrafted.map { (0...ClusterWorkerLimits.wireOutputTokens * 16).contains($0) } ?? true)
                && (t.mtpAccepted.map { accepted in accepted >= 0 && accepted <= (t.mtpDrafted ?? 0) } ?? true)
                && (t.mtpRounds.map { (0...ClusterWorkerLimits.wireOutputTokens).contains($0) } ?? true),
                "Invalid request telemetry")
        default: break
        }
    }
}
