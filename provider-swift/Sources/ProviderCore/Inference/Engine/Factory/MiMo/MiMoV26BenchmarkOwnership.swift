import Foundation

/// The lifecycle opened by the actual benchmark loader and transferred only
/// into its published session. It is not a fresh authorization for each row.
/// The process registry retains faulted native resources after either caller
/// has unwound; this value carries the same transaction, not a second model.
struct MiMoV26BenchmarkOwnership: Sendable {
    let registry: MiMoV26NativeLoadRegistry
    let lifecycle: MiMoV26NativeLifecycle
    let transaction: MiMoV26NativeLoadTransaction
}
