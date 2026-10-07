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
	return IdleEvidenceGap(loaded, work, pending, gapAge)
}

// IdleEvidenceGap is the provider-state half of EvidenceExplorable: the model
// is loaded, the Mac is idle, and the evidence gap has reached the bound.
func IdleEvidenceGap(loaded bool, work Workload, pending int, gapAge int32) bool {
	return loaded && work.WholeMacKnown && !work.WholeMacBusy && work.PartialPrefillRows == 0 &&
		pending == 0 && gapAge >= 0 && time.Duration(gapAge)*time.Millisecond >= EvidenceExplorationAfter
}

// ExplorationReplacesRate reports whether an explored provider's own rate
// gives way to the fleet median. The rate gives way when it is missing, or when
// it is dated and at least EvidenceExplorationAfter old. An undated rate is the
// first value after the provider connected, for example the legacy EWMA from
// its first served request, so it counts as the provider's own evidence. A
// negative age means undated.
func ExplorationReplacesRate(present bool, ageMs int32) bool {
	return !present || (ageMs >= 0 && time.Duration(ageMs)*time.Millisecond >= EvidenceExplorationAfter)
}
