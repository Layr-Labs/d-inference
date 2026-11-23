// Test-only adapter: the test hooks the new wiring tests call, with the behaviour of the code before the change
// (no rows reference is passed, and the fleet budgets read only the process environment).
import MLXLMCommon
@testable import ProviderCore

extension GLM5NextGPULimitKVBudget {
    @TaskLocal static var environmentForTesting: [String: String]?
}

extension ProviderLoop.EngineV2SlotHooks {
    init(
        physicalMemoryBytes: UInt64?, retainedResidentBytes: UInt64?, gpuLimit: GLM5NextGPULimitKVBudget.GPULimit?,
        onGLMRowsReference: @escaping @Sendable (String, Int?) -> Void,
        makeEngine: @escaping @Sendable (String, Int) throws -> any CBv2Engine
    ) {
        self.init(physicalMemoryBytes: physicalMemoryBytes, retainedResidentBytes: retainedResidentBytes,
            gpuLimit: gpuLimit, makeEngine: makeEngine)
    }
}

extension StandaloneServer.V2TestHooks {
    init(
        physicalMemoryBytes: UInt64?, retainedResidentBytes: UInt64?, gpuLimit: GLM5NextGPULimitKVBudget.GPULimit?,
        onGLMRowsReference: @escaping @Sendable (String, Int?) -> Void,
        makeEngine: @escaping @Sendable (String, Int) throws -> any CBv2Engine
    ) {
        self.init(physicalMemoryBytes: physicalMemoryBytes, retainedResidentBytes: retainedResidentBytes,
            gpuLimit: gpuLimit, makeEngine: makeEngine)
    }
}
