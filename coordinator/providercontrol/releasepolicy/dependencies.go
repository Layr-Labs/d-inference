package releasepolicy

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Store reads the full release inventory, including inactive rows.
type Store interface {
	ListReleasesWithError() ([]store.Release, error)
}

// Registry keeps live provider identity and routing publication authoritative.
type Registry interface {
	SetReleasePolicyGeneration(uint64, bool, func(registry.ApplicationEvidence) bool) []string
	GetProvider(string) *registry.Provider
	ProviderIDs() []string
	ReconcileAttestedRuntimeCapabilities(string) error
	ClearIneligiblePendingModelLoads(string) int
}

// Dependencies retain current inventory, fleet, logger and version-floor reads.
// Registry returns a true nil when no fleet is attached.
type Dependencies struct {
	Store          func() Store
	Registry       func() Registry
	Logger         func() *slog.Logger
	MinimumVersion func() string
	Incr           func(string, []string)
}
