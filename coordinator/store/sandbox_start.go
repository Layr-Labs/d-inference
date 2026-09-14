package store

const SandboxRuntimeCleanupFailed = "runtime_cleanup_failed"

func sandboxStartResultState(operation *SandboxOperation, update SandboxOperationUpdate) string {
	if update.State == SandboxOperationFailed && update.ErrorCode == SandboxRuntimeCleanupFailed {
		// The runtime could not prove that the VM stopped. Keep capacity and
		// forbid resume until deletion proves cleanup; stopped would be false.
		return SandboxStateFailed
	}
	return sandboxStateForOperationUpdate(operation, update.State)
}

// The request's reserved fence survives reconnect and uncertain runtime starts.
// A post-rotation failure must retain the new token for safe stop/delete; no
// response can roll it back, extend expiry or change the reserved resources.
func applySandboxStartAuthority(sandbox *SandboxRecord, operation *SandboxOperation, update SandboxOperationUpdate) error {
	if operation.RequestedFencingToken <= operation.FencingToken ||
		!operation.RequestedLeaseExpiresAt.Equal(sandbox.LeaseExpiresAt) ||
		(update.LeaseExpiresAt != nil && !update.LeaseExpiresAt.Equal(sandbox.LeaseExpiresAt)) {
		return ErrSandboxConflict
	}
	if update.FencingToken == operation.RequestedFencingToken {
		sandbox.FencingToken = operation.RequestedFencingToken
		return nil
	}
	if update.FencingToken == operation.FencingToken && sandbox.FencingToken == operation.FencingToken &&
		(update.State == SandboxOperationFailed || update.State == SandboxOperationPreparing || update.State == SandboxOperationBooting) {
		return nil
	}
	return ErrSandboxConflict
}

func sandboxStartMatchesLease(sandbox *SandboxRecord, operation *SandboxOperation) bool {
	return operation.Kind != SandboxOperationKindStart ||
		(sandbox.State == SandboxStateStopped && operation.CreatedAt.Before(sandbox.LeaseExpiresAt) &&
			operation.RequestedLeaseExpiresAt.Equal(sandbox.LeaseExpiresAt))
}
