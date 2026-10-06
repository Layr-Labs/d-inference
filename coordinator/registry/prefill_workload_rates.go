package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type prefillWorkloadRate = measurements.WorkloadRate

func snapshotPrefillWorkloadRates(m *protocol.PerformanceMeasurements, acceptedAt time.Time) []prefillWorkloadRate {
	return measurements.SnapshotWorkloadRates(m, acceptedAt, time.Duration(firstContentConservativeHandoffMs)*time.Millisecond)
}
