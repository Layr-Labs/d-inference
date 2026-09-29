package registry

import "time"

// Idle ranking deliberately outlives the two-minute deadline-evidence window.
// Thirty minutes retains ordinary idle/busy ranking while bounding how long a
// dated slow observation can exclude an otherwise idle provider from work.
const idleDecodeMeasurementMaxAge = 30 * time.Minute

func staleIdleDecodeMeasurement(s *routingSnapshot) bool {
	return s.modelLoaded && !s.wholeMacBusy && s.totalPending == 0 &&
		s.decodePerformanceAgeMs >= 0 &&
		time.Duration(s.decodePerformanceAgeMs)*time.Millisecond > idleDecodeMeasurementMaxAge
}
