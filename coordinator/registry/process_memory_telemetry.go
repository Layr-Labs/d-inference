package registry

import "github.com/eigeninference/d-inference/coordinator/protocol"

// Discard impossible/oversized observations instead of clamping individual
// ownership terms into a false accounting identity. This never affects routing.
func validProcessMemoryTelemetry(s *protocol.ProcessMemoryTelemetry) *protocol.ProcessMemoryTelemetry {
	const exactInteger = uint64(1<<53) - 1
	if s == nil || s.Generation == 0 || s.SampleSeq == 0 ||
		s.Generation > exactInteger || s.SampleSeq > exactInteger || s.PolicyEpoch > exactInteger ||
		s.MaterializedBytes > s.ChargedBytes || s.ChargedBytes-s.MaterializedBytes != s.UnmaterializedBytes ||
		s.OwnerCount > 1<<32 || s.ClosingOwnerCount > s.OwnerCount ||
		(s.RemainingBytes > 0 && s.CommitmentDebtBytes > 0) {
		return nil
	}
	for _, value := range []uint64{s.CapBytes, s.ActivationReserveBytes, s.ActiveBytes, s.CacheBytes,
		s.ChargedBytes, s.MaterializedBytes, s.UnmaterializedBytes, s.RemainingBytes, s.CommitmentDebtBytes} {
		if value > maxCapacitySampleGaugeBytes {
			return nil
		}
	}
	if s.SystemAvailableBytes != nil && *s.SystemAvailableBytes > maxCapacitySampleGaugeBytes {
		return nil
	}
	// Byte bounds above make active+cache safe to add. Mirror the wire's
	// saturated headroom identity solely to reject inconsistent diagnostics.
	headroom := s.CapBytes - min(s.CapBytes, s.ActiveBytes+s.CacheBytes)
	if s.SystemAvailableBytes != nil {
		headroom = min(headroom, *s.SystemAvailableBytes)
	}
	headroom -= min(headroom, s.ActivationReserveBytes)
	covered := min(headroom, s.UnmaterializedBytes)
	if s.RemainingBytes != headroom-covered || s.CommitmentDebtBytes != s.UnmaterializedBytes-covered {
		return nil
	}
	s.SampleAgeMS = min(s.SampleAgeMS, exactInteger)
	return s
}
