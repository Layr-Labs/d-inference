package providerversion

import (
	"strconv"
	"strings"
)

// Compare compares two dotted numeric versions, returning -1 when
// a < b, 0 when equal, +1 when a > b. It is deliberately tolerant: a leading
// "v"/"V" is stripped, segments compare numerically ("0.6.10" > "0.6.3"),
// missing segments compare as 0 ("0.6" == "0.6.0"), and unparseable segments
// compare as 0 ("garbage" == "0", "0.6.3-rc1" == "0.6.0"). An empty string
// parses as no segments (all zeros), so it sits below any real floor;
// providerMeetsTraitFloorsLocked additionally special-cases empty so a
// non-reporting provider fails every floor even if one were ever set to 0.
func (p *Policy) Compare(a, b string) int {
	as := p.versionSegments(a)
	bs := p.versionSegments(b)
	n := len(as)
	if len(bs) > n {
		n = len(bs)
	}
	for i := 0; i < n; i++ {
		var av, bv int
		if i < len(as) {
			av = as[i]
		}
		if i < len(bs) {
			bv = bs[i]
		}
		switch {
		case av < bv:
			return -1
		case av > bv:
			return 1
		}
	}
	return 0
}

// versionSegments parses "v0.6.3" into [0 6 3]. Unparseable or negative
// segments parse as 0. Results are memoized per distinct input string
// (memo.go) — the fleet runs a handful of binary versions, and the
// routing scan compares every provider's version against the capability
// floors and the pooled-budget layout floor on every request — so the
// returned slice is SHARED and must be treated as read-only.
func (p *Policy) versionSegments(v string) []int {
	return p.versionSegmentsMemo.getBounded(v, parseVersionSegments, versionSegmentsMemoizable)
}

// versionSegmentsMemoizable bounds the parsed slice a memo entry may retain.
func versionSegmentsMemoizable(segs []int) bool {
	return len(segs) <= maxMemoizedVersionSegments
}

// parseVersionSegments is the uncached parser behind versionSegments.
func parseVersionSegments(v string) []int {
	v = strings.TrimSpace(v)
	if len(v) > 0 && (v[0] == 'v' || v[0] == 'V') {
		v = v[1:]
	}
	if v == "" {
		return nil
	}
	parts := strings.Split(v, ".")
	segs := make([]int, len(parts))
	for i, part := range parts {
		n, err := strconv.Atoi(strings.TrimSpace(part))
		if err != nil || n < 0 {
			n = 0
		}
		segs[i] = n
	}
	return segs
}
