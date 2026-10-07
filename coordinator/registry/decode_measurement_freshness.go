package registry

import "time"

// idleDecodeMeasurementAge is the age of the dated decode observation for
// the snapshot model while the provider is idle: the model is loaded, the Mac
// has no service work, and no request is reserved. Busy and cold providers and
// undated observations return 0, so they keep their observed decode rate.
// Unchanged heartbeats and new prefill measurements do not renew the age.
func idleDecodeMeasurementAge(s *routingSnapshot) time.Duration {
	if !s.modelLoaded || s.wholeMacBusy || s.totalPending != 0 || s.decodePerformanceAgeMs < 0 {
		return 0
	}
	return time.Duration(s.decodePerformanceAgeMs) * time.Millisecond
}
