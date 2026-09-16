package catalog

import (
	"github.com/eigeninference/d-inference/coordinator/store"
)

// maxRetiredBuilds bounds the per-alias lineage list; the oldest retirements
// are dropped first once a (pathologically) churned alias exceeds it.
const maxRetiredBuilds = 16

// retiredBuildsAfterUpsert computes the alias's lineage after an upsert: prior
// retired builds, plus any prior desired/previous member rotated out by the new
// pointers, minus any build the new pointers re-promote to membership. Bounded
// to maxRetiredBuilds (oldest dropped first). The lineage lets the registration
// gate recognize a provider that was offline through a retirement as part of
// the alias's fleet.
func retiredBuildsAfterUpsert(prior *store.ModelAlias, newDesired, newPrevious string) []string {
	if prior == nil {
		return nil
	}
	isMember := func(b string) bool { return b == newDesired || b == newPrevious }
	var retired []string
	seen := make(map[string]struct{})
	add := func(b string) {
		if b == "" || isMember(b) {
			return
		}
		if _, dup := seen[b]; dup {
			return
		}
		seen[b] = struct{}{}
		retired = append(retired, b)
	}
	for _, b := range prior.RetiredBuilds {
		add(b)
	}
	add(prior.DesiredBuild)
	add(prior.PreviousBuild)
	if len(retired) > maxRetiredBuilds {
		retired = retired[len(retired)-maxRetiredBuilds:]
	}
	return retired
}
