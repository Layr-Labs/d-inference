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
            && (1...ClusterWorkerLimits.promptTokens).contains(p.maximumPromptTokens)
            && (1...ClusterWorkerLimits.outputTokens).contains(p.maximumOutputTokens)
            && (1...p.maximumPromptTokens).contains(p.maximumChunkTokens)
            && (p.maximumPromptTokens...ClusterWorkerLimits.contextTokens).contains(p.maximumContextTokens), "Invalid worker profile")
    }
    static func reservation(_ value: ClusterWorkerReservation) throws {
        try workerRequire(text(value.profileID, maximum: 128)
            && (1...ClusterWorkerLimits.promptTokens).contains(value.promptTokenIDs.count)
            && (1...ClusterWorkerLimits.outputTokens).contains(value.outputCount)
            && (1...ClusterWorkerLimits.promptTokens).contains(value.chunkSize)
            && value.promptTokenIDs.count <= ClusterWorkerLimits.contextTokens - value.outputCount
            && value.promptTokenIDs.allSatisfy({ (0..<ClusterWorkerLimits.vocabularySize).contains($0) })
            && value.stopTokenIDs.count <= ClusterWorkerLimits.stopTokens
            && value.stopTokenIDs == value.stopTokenIDs.sorted() && Set(value.stopTokenIDs).count == value.stopTokenIDs.count
            && value.stopTokenIDs.allSatisfy({ (0..<ClusterWorkerLimits.vocabularySize).contains($0) })
            && value.deadlineUptimeNanoseconds > 0 && value.deadlineUptimeNanoseconds <= UInt64(Int64.max)
            && (1...ClusterWorkerLimits.capacityBytes).contains(value.capacityLimitBytes), "Invalid worker reservation")
    }
    static func command(_ frame: ClusterWorkerCommandFrame) throws {
        try workerRequire(frame.sequence < UInt64(Int64.max), "Invalid command sequence")
        switch frame.command {
        case .shutdown: try workerRequire(frame.requestID == nil, "Shutdown has no request ID")
        default: try workerRequire(frame.requestID != nil, "Command requires request ID")
        }
        switch frame.command {
        case .reserve(let value): try reservation(value)
        case .tokenDecision(let ordinal, _):
            try workerRequire((0..<ClusterWorkerLimits.outputTokens).contains(ordinal), "Invalid token decision ordinal")
        default: break
        }
    }
    static func event(_ frame: ClusterWorkerEventFrame) throws {
        try workerRequire(frame.sequence < UInt64(Int64.max), "Invalid event sequence")
        switch frame.event {
        case .ready, .unavailable, .shutdownComplete:
            try workerRequire(frame.requestID == nil, "Worker event has no request ID")
        default: try workerRequire(frame.requestID != nil, "Event requires request ID")
        }
        switch frame.event {
        case .ready(let value):
            try ready(value)
            try workerRequire(value.identity.membershipEpoch == frame.membershipEpoch, "Ready epoch differs")
        case .admitted(let bytes):
            try workerRequire((1...ClusterWorkerLimits.capacityBytes).contains(bytes), "Invalid reserved bytes")
        case .committedToken(let ordinal, let token, let committed):
            try workerRequire((0..<ClusterWorkerLimits.outputTokens).contains(ordinal)
                && (0..<ClusterWorkerLimits.vocabularySize).contains(token)
                && (1...ClusterWorkerLimits.contextTokens).contains(committed), "Invalid committed token")
        default: break
        }
    }
}
