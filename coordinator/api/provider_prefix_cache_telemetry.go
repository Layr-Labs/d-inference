package api

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Server) recordPrefixCacheTelemetry(provider *registry.Provider, prev, capacity *protocol.BackendCapacity) {
	if s.dd == nil || capacity == nil {
		return
	}
	baseTags := mlxTelemetryTags(provider)
	for _, slot := range capacity.Slots {
		cur := slot.PrefixCache
		if cur == nil {
			continue
		}
		tags := append(append([]string(nil), baseTags...), "cache_kind:"+cur.Kind)
		s.dd.HistogramOrGauge("provider.prefix_cache.sample_age_ms", float64(cur.SampleAgeMS), tags)
		fresh := cur.SampleAgeMS <= capacitySampleFreshMS
		s.dd.HistogramOrGauge("provider.prefix_cache.sample_fresh", boolGauge(fresh), tags)
		var old *protocol.PrefixCacheTelemetry
		if prev != nil {
			for _, previousSlot := range prev.Slots {
				if previousSlot.Model == slot.Model {
					old = previousSlot.PrefixCache
					break
				}
			}
		}
		same := old != nil && old.Generation == cur.Generation && old.Kind == cur.Kind
		if !fresh || (same && cur.SampleSeq <= old.SampleSeq) {
			continue
		}
		for name, value := range map[string]uint64{
			"entries": cur.Entries, "disk_bytes": cur.DiskBytes, "staging_bytes": cur.StagingBytes,
		} {
			s.dd.HistogramOrGauge("provider.prefix_cache."+name, float64(value), tags)
		}
		if cur.IO != nil {
			s.dd.HistogramOrGauge("provider.prefix_cache.staging_peak_bytes", float64(cur.IO.StagingPeakBytes), tags)
		}
		if !same {
			continue
		}
		for _, metric := range []struct {
			name              string
			previous, current uint64
		}{
			{"stages", old.StagesTotal, cur.StagesTotal},
			{"files_written", old.FilesWrittenTotal, cur.FilesWrittenTotal},
			{"written_bytes", old.WrittenBytesTotal, cur.WrittenBytesTotal},
			{"donation_drops", old.DonationDropsTotal, cur.DonationDropsTotal},
			{"corrupt_drops", old.CorruptDropsTotal, cur.CorruptDropsTotal},
			{"evictions", old.EvictionsTotal, cur.EvictionsTotal},
		} {
			s.ddCountDelta("provider.prefix_cache."+metric.name, metric.previous, metric.current, tags)
		}
		if cur.TTLExpiredTotal != nil && old.TTLExpiredTotal != nil {
			s.ddCountDelta("provider.prefix_cache.ttl_expired", *old.TTLExpiredTotal, *cur.TTLExpiredTotal, tags)
		}
		if cur.IO != nil && old.IO != nil {
			for _, metric := range []struct {
				name              string
				previous, current uint64
			}{
				{"files_read", old.IO.FilesReadTotal, cur.IO.FilesReadTotal},
				{"read_bytes", old.IO.ReadBytesTotal, cur.IO.ReadBytesTotal},
				{"stage_read_bytes", old.IO.StageReadBytesTotal, cur.IO.StageReadBytesTotal},
				{"donation_read_bytes", old.IO.DonationReadBytesTotal, cur.IO.DonationReadBytesTotal},
				// Cumulative wall-time deltas are counts of microseconds, never request
				// latency histograms (stage totals also include refused stage attempts).
				{"stage_duration_us", old.IO.StageUSTotal, cur.IO.StageUSTotal},
				{"write_duration_us", old.IO.WriteUSTotal, cur.IO.WriteUSTotal},
			} {
				s.ddCountDelta("provider.prefix_cache."+metric.name, metric.previous, metric.current, tags)
			}
		}
	}
	cur := capacity.PrefixCacheMaintenance
	if cur == nil || prev == nil || prev.PrefixCacheMaintenance == nil {
		return
	}
	old := prev.PrefixCacheMaintenance
	for _, metric := range []struct {
		name              string
		previous, current uint64
	}{
		{"ttl_expired", old.TTLExpiredTotal, cur.TTLExpiredTotal},
		{"budget_evicted", old.BudgetEvictedTotal, cur.BudgetEvictedTotal},
		{"temp_removed", old.TempRemovedTotal, cur.TempRemovedTotal},
	} {
		s.ddCountDelta("provider.prefix_cache.sweep."+metric.name, metric.previous, metric.current, baseTags)
	}
}
