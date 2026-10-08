import Foundation

struct Gemma4ExpertExchangeFrame: Equatable, Sendable {
    let sequence: Int, phase: String, offset: Int, count: Int, finalPrompt: Bool
}

/// Pure ordering for the first concrete native probe2/decode1 + P32/C16/O2.
/// It is not a token/state owner; the real CBv2 session commits its own state.
struct Gemma4ExpertExchangeSchedule {
    enum Failure: Error { case order }
    private enum Phase: Equatable { case created, probe, probeComplete, request, awaitingCommit, requestComplete, retired, released, failed }
    private var phase = Phase.created
    private var frameIndex = 0, layerIndex = 0
    private(set) var completedExchanges = 0
    var failed: Bool { phase == .failed }
    var released: Bool { phase == .released }
    static let probeFrames = [
        Gemma4ExpertExchangeFrame(sequence: 0, phase: "prefill", offset: 0, count: 2, finalPrompt: true),
        Gemma4ExpertExchangeFrame(sequence: 1, phase: "decode", offset: 2, count: 1, finalPrompt: false)]
    static let requestFrames = [
        Gemma4ExpertExchangeFrame(sequence: 0, phase: "prefill", offset: 0, count: 16, finalPrompt: false),
        Gemma4ExpertExchangeFrame(sequence: 1, phase: "prefill", offset: 16, count: 16, finalPrompt: true),
        Gemma4ExpertExchangeFrame(sequence: 2, phase: "decode", offset: 32, count: 1, finalPrompt: false)]

    mutating func begin() throws { try require(phase == .created); phase = .probe }
    mutating func ready() throws {
        try require(phase == .probeComplete && completedExchanges == 60)
        phase = .request; frameIndex = 0; layerIndex = 0
    }
    mutating func requireExchange(purpose: String, frame: Gemma4ExpertExchangeFrame, layer: Int) throws {
        let frames: [Gemma4ExpertExchangeFrame]
        if purpose == "probe", phase == .probe { frames = Self.probeFrames }
        else if purpose == "request", phase == .request { frames = Self.requestFrames }
        else { try require(false); return }
        try require(frames.indices.contains(frameIndex) && frames[frameIndex] == frame
            && layer == layerIndex && (0..<30).contains(layer) && completedExchanges < 150)
    }
    mutating func completeExchange(purpose: String, frame: Gemma4ExpertExchangeFrame, layer: Int) throws {
        try requireExchange(purpose: purpose, frame: frame, layer: layer)
        layerIndex += 1; completedExchanges += 1
        if layerIndex == 30 {
            layerIndex = 0
            if phase == .probe {
                frameIndex += 1
                if frameIndex == Self.probeFrames.count { phase = .probeComplete }
            } else { phase = .awaitingCommit }
        }
    }
    mutating func committed(_ frame: Gemma4ExpertExchangeFrame) throws {
        try require(phase == .awaitingCommit && Self.requestFrames.indices.contains(frameIndex)
            && Self.requestFrames[frameIndex] == frame)
        frameIndex += 1
        phase = frameIndex == Self.requestFrames.count ? .requestComplete : .request
    }
    mutating func retire() throws {
        try require(phase == .requestComplete && completedExchanges == 150); phase = .retired
    }
    mutating func releaseModel() throws { try require(phase == .retired); phase = .released }
    mutating func poison() { phase = .failed }
    private mutating func require(_ value: Bool) throws {
        guard value else { phase = .failed; throw Failure.order }
    }
}
