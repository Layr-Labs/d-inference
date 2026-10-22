import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

/// Refusal-only test hooks. They cannot replace an evaluation or fabricate a
/// successful fence. Production always uses nil.
struct GLM5NextLoadHooks: Sendable {
    var beforeEvaluation: (@Sendable ([MLXArray]) throws -> Void)?
    var beforeCleanupFence: (@Sendable () throws -> Void)?
    init(
        beforeEvaluation: (@Sendable ([MLXArray]) throws -> Void)? = nil,
        beforeCleanupFence: (@Sendable () throws -> Void)? = nil
    ) {
        self.beforeEvaluation = beforeEvaluation
        self.beforeCleanupFence = beforeCleanupFence
    }
}

/// Installed before native construction starts, and retained by the actual load
/// operation on failure. All mutation is confined to its construction lane.
final class GLM5NextConstructionOwner: @unchecked Sendable {
    let roots: GLM5NextArtifactLoadRoots
    private let hooks: GLM5NextLoadHooks?
    private var stream: MLX.Stream?
    private var artifact: GLM5NextArtifactLoader?
    private var model: GLM5NextModel?
    private var container: ModelContainer?
    private var cleanupProven = false

    init(hooks: GLM5NextLoadHooks? = nil) {
        self.hooks = hooks
        roots = GLM5NextArtifactLoadRoots(beforeEvaluation: hooks?.beforeEvaluation)
    }
    func capture(stream: MLX.Stream) { self.stream = stream }
    func retain(_ artifact: GLM5NextArtifactLoader) { self.artifact = artifact }
    func retain(_ model: GLM5NextModel) {
        self.model = model
        roots.retainOwner(model)
    }
    func retain(_ container: ModelContainer) { self.container = container }
    func finishTransferred() {
        roots.releaseAfterConfirmedFence()
        model = nil
        artifact = nil
        container = nil
        stream = nil
        cleanupProven = true
    }
    func cleanupAfterFailure() throws {
        if cleanupProven { return }
        try hooks?.beforeCleanupFence?()
        try MLX.withError { errors in
            stream?.synchronize()
            Stream.cpu.synchronize()
            try errors.check()
        }
        finishTransferred()
    }
    var retainedArrayCount: Int { roots.retainedArrayCount }
    var retainedOwnerCount: Int { roots.retainedOwnerCount }
}
