import Foundation
import MLX
import ProviderCore

extension ProviderRuntimeCapabilityDetector {
    /// Binds the approved colocated metallib before the first live MLX
    /// diagnostic. Capability evidence is therefore authored inside the worker.
    public static func detectLive(
        hardware: HardwareInfo,
        metallibURL: URL? = nil
    ) -> Set<ProviderRuntimeCapability> {
        let boundHash = bindRuntimeMetallibForMLX(from: metallibURL)
        return detect(
            chipFamily: hardware.chipFamily,
            naxAvailable: { GPU.gemma4ExpertQMMDiagnostics().naxAvailable },
            liveMetallibHash: { boundHash })
    }
}
