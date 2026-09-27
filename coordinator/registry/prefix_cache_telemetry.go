package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func clampPrefixCacheTelemetry(s *protocol.PrefixCacheTelemetry) *protocol.PrefixCacheTelemetry {
	if s == nil || s.Generation == 0 || s.SampleSeq == 0 ||
		(s.Kind != "attention_blocks" && s.Kind != "complete_checkpoint") {
		return nil
	}
	for _, value := range []*uint64{&s.SampleAgeMS, &s.StagesTotal, &s.FilesWrittenTotal,
		&s.WrittenBytesTotal, &s.DonationDropsTotal, &s.CorruptDropsTotal, &s.EvictionsTotal} {
		*value = min(*value, maxCapacitySampleValue)
	}
	s.Entries = min(s.Entries, uint64(1<<32))
	s.DiskBytes = min(s.DiskBytes, maxCapacitySampleGaugeBytes)
	s.StagingBytes = min(s.StagingBytes, maxCapacitySampleGaugeBytes)
	if s.TTLExpiredTotal != nil {
		*s.TTLExpiredTotal = min(*s.TTLExpiredTotal, maxCapacitySampleValue)
	}
	if s.Kind != "complete_checkpoint" {
		s.IO = nil
	}
	if s.IO != nil {
		s.IO.StagingPeakBytes = min(s.IO.StagingPeakBytes, maxCapacitySampleGaugeBytes)
		for _, value := range []*uint64{&s.IO.FilesReadTotal, &s.IO.ReadBytesTotal, &s.IO.StageReadBytesTotal,
			&s.IO.DonationReadBytesTotal, &s.IO.StageUSTotal, &s.IO.WriteUSTotal} {
			*value = min(*value, maxCapacitySampleValue)
		}
	}
	return s
}
