import MLX

/// Attach to the ORIGINAL target/service before creating any graph. This object
/// has no retry/reset/release method. On failure the original retirement path
/// retains it, the capture and group. Success still waits for install/seeded ACK.
final class Gemma4MTPPullSnapshotBatch {
    enum Direction { case send, receive }
    let direction: Direction
    let plan: Gemma4MTPPullTransferPlan
    let geometries: [CollectivePointToPointShape]
    private(set) var inputs: [MLXArray] = []
    private(set) var outputs: [MLXArray] = []
    private(set) var progress = Gemma4MTPPullSnapshotBatchProgress()
    // Set before ANY potentially throwing status/check after C construction.
    private var pendingOutput: MLXArray?
    var completed: Bool { progress.phase == .complete }

    init(plan: Gemma4MTPPullTransferPlan, direction: Direction) throws {
        self.plan = plan; self.direction = direction
        let hidden: DType = plan.hiddenDType == 1 ? .bfloat16 : (plan.hiddenDType == 2 ? .float16 : .float32)
        let shapes = [[1,1,2816]] + Array(repeating:[1,1,plan.frontier,512],count:4)
            + Array(repeating:[1,8,min(plan.frontier,1024),256],count:2)
        geometries = try shapes.enumerated().map { index, shape in
            try CollectivePointToPointShape(shape:shape,dtype:index == 0 ? hidden : .bfloat16,
                maximumBytes:plan.maximumSingleTransferBytes)
        }
        guard geometries.count == 7, plan.senderAdditional.count == 8, plan.receiverRoots.count == 9 else {
            throw ProbeError("Owned snapshot batch has no exact seven-transfer allocation plan")
        }
    }
    func begin() throws { try progress.begin() }
    func prepare(_ capture: Gemma4OwnedMTPConditioning, check: () throws -> Void) throws {
        guard direction == .send, progress.phase == .preparing, inputs.isEmpty else {
            throw ProbeError("Owned snapshot producer preparation is out of turn")
        }
        // Retain each lazy slice before checking the native error box. The pinned
        // Slice GPU implementation shares storage; CPU compact packs remain the
        // original seven individually rounded senderAdditional terms.
        inputs.append(capture.hidden); try check()
        for tensor in [capture.fullKeys,capture.fullValues] {
            for head in 0..<2 {
                inputs.append(tensor[0...,head..<(head+1),0...,0...]); try check()
            }
        }
        inputs.append(capture.slidingKeys); try check()
        inputs.append(capture.slidingValues); try check()
        guard inputs.count == geometries.count else { throw ProbeError("Snapshot producer count differs") }
        for (shape,array) in zip(geometries,inputs) { try shape.validateMetadata(array) }
    }
    func preparedAfterFence() throws { try progress.preparedAfterFence() }
    func requireNext(_ index: Int) throws { try progress.requireNext(index) }
    func retainOutput(_ array: MLXArray, index: Int) throws {
        pendingOutput = array
        try progress.outputRetained(index)
        outputs.append(array); pendingOutput = nil
    }
    func transferCompleted(_ index: Int) throws { try progress.transferCompleted(index) }
    func finishAfterFence() throws { try progress.finishAfterFence() }
    func poison() { progress.poison() }
}
