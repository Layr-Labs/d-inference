package forecast

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/connectiontime"
)

// EvidenceExplorationAfter is a policy threshold, not a service guarantee.
const EvidenceExplorationAfter = 5 * time.Minute

// EvidenceGapAgeMS uses the older paired measurement's age, or connection age
// when either measurement is undated. It is not time spent idle.
func EvidenceGapAgeMS(performanceAge int32, origin *connectiontime.Origin, now time.Time) int32 {
	if performanceAge >= 0 {
		return performanceAge
	}
	age, known := origin.Age(now)
	if !known {
		return -1
	}
	return capacityvalue.ClampMsInt32(age.Milliseconds())
}

// EvidenceExplorable allows idle providers to compete to renew measurements.
func EvidenceExplorable(estimate Estimate, loaded bool, work Workload, pending int, gapAge int32) bool {
	if estimate.Status != Unknown {
		return false
	}
	switch estimate.Reason {
	case "performance_age_unknown_or_stale", "performance_missing":
	default:
		return false
	}
	return loaded && work.WholeMacKnown && !work.WholeMacBusy && work.PartialPrefillRows == 0 &&
		pending == 0 && gapAge >= 0 && time.Duration(gapAge)*time.Millisecond >= EvidenceExplorationAfter
}
