package cachedirectory

type RemovalReason string

const (
	RemovalTTL              RemovalReason = "ttl"
	RemovalDisconnect       RemovalReason = "disconnect"
	RemovalEpochChange      RemovalReason = "epoch_change"
	RemovalCapabilityChange RemovalReason = "capability_change"
	RemovalProofMismatch    RemovalReason = "proof_mismatch"
	RemovalMissInvalidation RemovalReason = "miss_invalidation"
	RemovalCapacityEviction RemovalReason = "capacity_eviction"
)

func HolderRemovalReasons() []string {
	return []string{
		string(RemovalTTL),
		string(RemovalDisconnect),
		string(RemovalEpochChange),
		string(RemovalCapabilityChange),
		string(RemovalProofMismatch),
		string(RemovalMissInvalidation),
		string(RemovalCapacityEviction),
	}
}
