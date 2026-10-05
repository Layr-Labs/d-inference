package registry

import "github.com/eigeninference/d-inference/coordinator/internal/registry/versionmemo"

// Standalone comparisons share a bounded memo. Routing uses the registry's
// retained memo so unrelated comparison callers cannot populate its entries.
var versionSegmentsMemo versionmemo.Memo[[]int]

// CompareVersions compares two dotted numeric versions, returning -1 when
// a < b, 0 when equal, +1 when a > b. It is deliberately tolerant: a leading
// "v"/"V" is stripped, segments compare numerically ("0.6.10" > "0.6.3"),
// missing segments compare as 0 ("0.6" == "0.6.0"), and unparseable segments
// compare as 0 ("garbage" == "0", "0.6.3-rc1" == "0.6.0"). An empty string
// parses as no segments (all zeros), so it sits below any real floor;
// version-floor callers additionally reject empty versions.
func CompareVersions(a, b string) int {
	return versionmemo.Compare(&versionSegmentsMemo, a, b)
}
