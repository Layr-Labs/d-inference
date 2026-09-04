package registry

// pair_keys.go — struct keys for the per-(provider, model) maps that used to
// be "providerID:modelID" string concatenations. A struct key is built with
// no allocation on the routing hot path (the dispatch-load cooldown gate runs
// once per provider per scan) and cannot alias across ids that contain the
// delimiter — the same reasoning as capacityRejectKey and inferenceErrorKey.
// Iteration-time filtering by provider (Disconnect, pending-load sweeps, the
// fault-key migration) compares the field instead of parsing a prefix.

// dispatchLoadKey identifies a dispatch-load cooldown bucket
// (Registry.dispatchLoadCooldowns). FaultKey is the provider's STABLE fault
// key (faultKeyLocked: serial/SE-key when bound, the session id otherwise) so
// the cooldown survives a reconnect within its TTL.
type dispatchLoadKey struct {
	FaultKey string
	ModelID  string
}

// modelLoadKey identifies a pending load_model command
// (Registry.pendingModelLoads / pendingModelLoadStarted). ProviderID is the
// live SESSION id, deliberately NOT the fault key: pending loads are
// connection-scoped and dropped on Disconnect.
type modelLoadKey struct {
	ProviderID string
	ModelID    string
}
