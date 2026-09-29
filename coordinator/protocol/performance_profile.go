package protocol

// ServingPerformanceProfileReference names coordinator-owned reviewed release
// data. Provider telemetry cannot certify its own width or degradation curve.
type ServingPerformanceProfileReference struct {
	ID              string `json:"id"`
	RuntimeRevision string `json:"runtime_revision"`
	ContextTokens   int    `json:"context_tokens"`
}
