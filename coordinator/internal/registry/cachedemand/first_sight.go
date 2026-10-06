package cachedemand

// FirstSight reads a novel prompt from its own boundaries: the deepest stride
// boundary is the prefix worth keeping for a follow-up, and the affinity key
// is the deepest ladder rung, which is the key Tracker.Observe gives a
// follow-up that extends the prompt, so both rank equivalent providers alike.
// That equality relies on every plan with a stride boundary containing the
// 1,024 rung. Without a rung the key falls back to the deepest stride
// boundary, whereas the tracker falls back to the deepest matched boundary of
// any kind, so the two keys can differ. Zero tokens means the prompt has no
// stride boundary.
func FirstSight(boundaries []Boundary) (tokens int, affinity string) {
	deepest, rung := "", 0
	for _, boundary := range boundaries {
		if boundary.Key == "" || boundary.Tokens < StrideTokens || boundary.Tokens%StrideTokens != 0 {
			continue
		}
		if boundary.Tokens > tokens {
			tokens, deepest = boundary.Tokens, boundary.Key
		}
		if boundary.Tokens > rung && AffinityRung(boundary.Tokens) {
			rung, affinity = boundary.Tokens, boundary.Key
		}
	}
	if affinity == "" {
		affinity = deepest
	}
	return tokens, affinity
}
