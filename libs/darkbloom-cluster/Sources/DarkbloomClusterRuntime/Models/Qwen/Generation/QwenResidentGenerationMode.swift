import DarkbloomClusterProtocol
import Foundation

/// How the two ranks divide one request: the protocol's own closed list, so
/// the worker's flag, the capability record and the runtime name one thing.
/// It is given to `QwenResidentRuntime.load` by the worker, which takes it from
/// its `--generation-mode` argument. The runtime reads no environment for it,
/// and a mode outside the registered model's resident row is refused at load.
public typealias QwenResidentGenerationMode = ClusterGenerationMode

extension ClusterGenerationMode {
    /// Extra load-agreement fields. The pipeline's agreement bytes are unchanged;
    /// a tensor-parallel mode binds its terms too (partials dtype, shard rule,
    /// reduction, ranks), so ranks started with different terms never agree.
    var loadAgreementFields: [String] {
        self == .pipeline ? [] : ["qwen-resident-generation-mode-v1", rawValue] + (tensorParallelTerms?.loadAgreementFields ?? [])
    }
}
