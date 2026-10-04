package registry

// Query-local grouping avoids copying every compatible boundary for the same
// provider. The caller visits deepest endpoints first. Compatibility includes
// every holder field that can make the later capability snapshot reject one
// endpoint but accept a shorter one; it does not select a cheaper endpoint.
func cacheMatchCompatibilityEqual(a, b cacheRoutingMatch) bool {
	x, y := a.Holder, b.Holder
	if x.ProviderID != y.ProviderID || x.Provider != y.Provider || x.ModelID != y.ModelID ||
		x.CacheEpoch != y.CacheEpoch || a.Tier != b.Tier {
		return false
	}
	if (x.stageMeasurement == nil) != (y.stageMeasurement == nil) {
		return false
	}
	if x.stageMeasurement != nil && x.stageMeasurement.capability != y.stageMeasurement.capability {
		return false
	}
	// Keep an uncreditable representative for MatchingHolders, while allowing a
	// shorter positive-stage SSD record to remain a usable fallback. Memory
	// endpoints accept zero stage cost, so they do not need this partition.
	return (a.Tier != "memory" && x.stageCostAt(a.queriedAt) <= 0) ==
		(b.Tier != "memory" && y.stageCostAt(b.queriedAt) <= 0)
}

// These budgets bound optimization scratch and compatibility comparisons.
// They never limit admitted requests, retained tracker evidence or the result:
// overflow restores ordinary append-all materialization for the remaining query.
const (
	cacheMatchMaxGroupsPerProvider = 8
	cacheMatchMaxTrackedProviders  = 256
)

type cacheProviderMatchGroups struct {
	indices []int
}

type cacheMatchGroups struct {
	byProvider map[string]cacheProviderMatchGroups
	exhausted  bool
}

// retain compares at most eight previously retained records. Indices refer to
// the caller's append-only result, so a retained record remains its class's
// first/deepest representative. The zero value allocates nothing for cold queries.
func (groups *cacheMatchGroups) retain(match cacheRoutingMatch, out []cacheRoutingMatch) bool {
	if groups.exhausted {
		return true
	}
	group, known := groups.byProvider[match.Holder.ProviderID]
	if !known && len(groups.byProvider) >= cacheMatchMaxTrackedProviders {
		groups.exhausted = true
		return true
	}
	for _, index := range group.indices {
		if cacheMatchCompatibilityEqual(out[index], match) {
			return false
		}
	}
	if groups.byProvider == nil {
		groups.byProvider = make(map[string]cacheProviderMatchGroups)
	}
	if len(group.indices) == cacheMatchMaxGroupsPerProvider {
		groups.exhausted = true
		return true
	}
	group.indices = append(group.indices, len(out))
	groups.byProvider[match.Holder.ProviderID] = group
	return true
}
