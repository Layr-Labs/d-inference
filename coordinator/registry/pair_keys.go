package registry

// pair_keys.go — struct keys for the per-(provider, model) maps that used to
// be "providerID:modelID" string concatenations. A struct key is built with
// no allocation and cannot alias across ids that contain the delimiter.
// Iteration-time filtering by provider (Disconnect, pending-load sweeps)
// compares the field instead of parsing a prefix. The fault trackers' pair
// keys are gone: their state is per identity (gate_state.go), keyed inside
// the gate by model (or modelShapeKey for the inference-error breaker).

// modelLoadKey identifies a pending load_model command
// (Registry.pendingModelLoads / pendingModelLoadStarted). ProviderID is the
// live SESSION id, deliberately NOT the fault key: pending loads are
// connection-scoped and dropped on Disconnect.
type modelLoadKey struct {
	ProviderID string
	ModelID    string
}
