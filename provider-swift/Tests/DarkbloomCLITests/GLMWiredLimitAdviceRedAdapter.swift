// Test-only adapter: the interfaces the new tests call, with the behaviour of the code before the change.
import Foundation
import ProviderCore
@testable import darkbloom

enum GLM5NextGPULimitKVBudget {
    static let environmentName = "DARKBLOOM_GLM_GPU_LIMIT_KV"
}

extension GLMWiredLimitAdvice {
    static func doctorCheck(
        hardware: HardwareInfo?, glmInUse: Bool, limits: GLM5NextWiredLimit.Limits, cliName: String,
        environment: [String: String]
    ) -> DoctorResult? {
        doctorCheck(hardware: hardware, glmInUse: glmInUse, limits: limits, cliName: cliName)
    }

    static func startNotice(
        hardware: HardwareInfo, servedModels: [ModelInfo], limits: GLM5NextWiredLimit.Limits, cliName: String,
        environment: [String: String]
    ) -> String? {
        startNotice(hardware: hardware, servedModels: servedModels, limits: limits, cliName: cliName)
    }
}
