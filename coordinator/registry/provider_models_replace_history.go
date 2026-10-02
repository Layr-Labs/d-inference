package registry

import "github.com/eigeninference/d-inference/coordinator/protocol"

// Bound session-local queue cleanup retained across unconfirmed replacements.
// Count bounds map/slice overhead; bytes bounds peer-controlled model ID storage.
const (
	maxDrainRemovedModels     = 1024
	maxDrainRemovedModelBytes = 64 * 1024
)

// replacementRemovedModels computes the next history before any mutation. IDs
// restored by the effective next inventory no longer need queue cleanup.
// Reject overflow rather than dropping cleanup owed to earlier replacements.
func replacementRemovedModels(previous []string, current []protocol.ModelInfo, nextIDs map[string]bool) ([]string, bool) {
	var removed []string
	seen := make(map[string]struct{})
	bytes := 0
	retain := func(id string) bool {
		if nextIDs[id] {
			return true
		}
		if _, duplicate := seen[id]; duplicate {
			return true
		}
		if len(removed) >= maxDrainRemovedModels || len(id) > maxDrainRemovedModelBytes-bytes {
			return false
		}
		seen[id] = struct{}{}
		removed = append(removed, id)
		bytes += len(id)
		return true
	}
	for _, id := range previous {
		if !retain(id) {
			return nil, false
		}
	}
	for _, model := range current {
		if !retain(model.ID) {
			return nil, false
		}
	}
	return removed, true
}
