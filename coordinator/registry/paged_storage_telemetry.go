package registry

import "github.com/eigeninference/d-inference/coordinator/protocol"

func clampPagedStorageTelemetry(s *protocol.PagedStorageTelemetry) *protocol.PagedStorageTelemetry {
	if s == nil || s.Kind != "segmented" || s.Generation == 0 || s.SampleSeq == 0 {
		return nil
	}
	s.SampleAgeMS = min(s.SampleAgeMS, maxCapacitySampleValue)
	for _, value := range []*uint64{&s.GrantBytes, &s.CommittedBytes, &s.ReservedPageBytes,
		&s.LivePageBytes, &s.PoisonBytes, &s.SlackBytes, &s.OverGrantBytes, s.NominalKVBytes, s.PhysicalFloorOverheadBytes, s.AllocatorPaddingBytes, s.LastAllocationAllowanceBytes} {
		if value != nil {
			*value = min(*value, maxCapacitySampleGaugeBytes)
		}
	}
	s.SegmentCount = min(s.SegmentCount, uint64(1<<32))
	s.AddressPages = min(s.AddressPages, uint64(1<<32))
	for _, value := range []*uint64{s.AllocationFailuresTotal, s.AdmissionRefusalsTotal, s.GrantRefusalsTotal, s.GrantEpochRetriesTotal} {
		if value != nil {
			*value = min(*value, maxCapacitySampleValue)
		}
	}
	return s
}
