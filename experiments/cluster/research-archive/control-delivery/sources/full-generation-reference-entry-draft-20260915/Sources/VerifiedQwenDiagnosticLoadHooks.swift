/// Optional private observation seams around the existing verified full loader.
/// Existing callers retain nil hooks and the same storage/conversion policy.
struct VerifiedQwenDiagnosticLoadHooks {
    let expectedManifestSHA256: String
    let prepared: (PreparedQwenCheckpoint, QwenDenseSourceReadPlan) throws -> Void
    let beforeTensor: (String, QwenCheckpointTensor) throws -> Void
    let check: () throws -> Void
}
