import Foundation

/// One worker epoch owns an ordered, finite sequence and never reuses request IDs.
/// The caller must terminate the cohort on rejection; this type never resyncs it.
struct WorkerSequence {
    let epoch: String
    private(set) var nextSequence = 1
    private(set) var inferenceCount = 0
    private(set) var isShutdown = false
    private var requestIDs = Set<String>()

    init(epoch: String) throws {
        try validateWorkerEnvelope(epoch: epoch, sequence: 1)
        self.epoch = epoch
    }

    mutating func accept(command: WorkerCommand, vocabularySize: Int, maxContextTokens: Int) throws {
        guard vocabularySize > 0, maxContextTokens > 0 else { throw ProbeError("Invalid worker model bounds") }
        try validateWorkerEnvelope(epoch: command.epoch, sequence: command.sequence)
        guard !isShutdown, command.epoch == epoch, command.sequence == nextSequence else {
            throw ProbeError("Worker command has a stale epoch, replayed/out-of-order sequence, or closed session")
        }
        switch command {
        case .infer(let request):
            try validateWorkerInference(request)
            guard inferenceCount < 4096, !requestIDs.contains(request.requestID),
                request.outputTokens <= maxContextTokens,
                request.prompt.count <= maxContextTokens - request.outputTokens,
                request.prompt.allSatisfy({ $0 < vocabularySize }),
                request.teacherTokens?.allSatisfy({ $0 < vocabularySize }) ?? true else {
                throw ProbeError("Worker request repeats an ID or exceeds model/session bounds")
            }
            if request.captureLogits {
                let count = vocabularySize.multipliedReportingOverflow(by: request.outputTokens)
                guard !count.overflow, count.partialValue <= 1_048_576 else {
                    throw ProbeError("Worker captured logits exceed 1048576 values")
                }
            }
            // No externally visible state changes precede the final validation.
            requestIDs.insert(request.requestID)
            inferenceCount += 1
        case .shutdown:
            isShutdown = true
        }
        nextSequence += 1
    }
}
