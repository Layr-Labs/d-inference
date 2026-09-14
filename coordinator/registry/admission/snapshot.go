package admission

import "github.com/eigeninference/d-inference/coordinator/registry/providerversion"

// Policy evaluates version-dependent memory limits using the registry's shared
// version interpreter. It owns no provider state or reservation lifecycle.
type Policy struct{ versions *providerversion.Policy }

// NewPolicy binds the non-nil version interpreter used by the other routing
// gates, so cold estimates and slot layouts share one bounded cache owner.
func NewPolicy(versions *providerversion.Policy) Policy { return Policy{versions: versions} }

// Snapshot is the consistent, read-only capacity view needed by admission.
// Callers capture it under their state locks and retain ownership of reservation
// changes. FreeForLoadGB is optional (nil means unreported); Pool is immutable
// after reconstruction, including any overflow storage in its KV-rate table.
type Snapshot struct {
	Model                     string
	BinaryVersion             string
	TotalPending              int
	PendingMaxTokens          int
	PendingMaxTokensAllModels int
	PendingMaxBytesAllModels  int64
	PendingBytesKnown         bool
	MaxTokensPotential        int64
	GPUMemoryActiveGB         float64
	TotalMemoryGB             float64
	FreeForLoadGB             *float64
	ModelSizeGB               float64
	ModelLoaded               bool
	AvailableOnDisk           bool
	ActiveTokenBudgetUsed     int64
	ActiveTokenBudgetMax      int64
	QueuedTokenBudget         int64
	Pool                      Pool
	BudgetClamped             bool
	KVBytesPerToken           int64
}
