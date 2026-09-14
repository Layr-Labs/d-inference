package accountfleet

import "github.com/eigeninference/d-inference/coordinator/registry"

// Registry supplies current machines and the existing atomic online check /
// stale-entry cleanup used by removal. Provider reads keep their own locks.
type Registry interface {
	ForEachProvider(func(*registry.Provider))
	RemoveProviderBySerial(string, bool) bool
}
