package api

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Server) recordPagedStorageTelemetry(provider *registry.Provider, prev, capacity *protocol.BackendCapacity) {
	if s.dd == nil || capacity == nil {
		return
	}
	tags := mlxTelemetryTags(provider)
	for _, slot := range capacity.Slots {
		cur := slot.PagedStorage
		if cur == nil {
			continue
		}
		s.dd.HistogramOrGauge("provider.paged_storage.sample_age_ms", float64(cur.SampleAgeMS), tags)
		fresh := cur.SampleAgeMS <= capacitySampleFreshMS
		s.dd.HistogramOrGauge("provider.paged_storage.sample_fresh", boolGauge(fresh), tags)
		var old *protocol.PagedStorageTelemetry
		if prev != nil {
			for _, previousSlot := range prev.Slots {
				if previousSlot.Model == slot.Model {
					old = previousSlot.PagedStorage
					break
				}
			}
		}
		same := old != nil && old.Generation == cur.Generation && old.Kind == cur.Kind
		if !fresh || (same && cur.SampleSeq <= old.SampleSeq) {
			continue
		}
		for _, metric := range []struct {
			name  string
			value uint64
		}{
			{"grant_bytes", cur.GrantBytes}, {"committed_bytes", cur.CommittedBytes},
			{"reserved_page_bytes", cur.ReservedPageBytes}, {"live_page_bytes", cur.LivePageBytes},
			{"poison_bytes", cur.PoisonBytes}, {"slack_bytes", cur.SlackBytes},
			{"over_grant_bytes", cur.OverGrantBytes}, {"segment_count", cur.SegmentCount},
			{"address_pages", cur.AddressPages},
		} {
			s.dd.HistogramOrGauge("provider.paged_storage."+metric.name, float64(metric.value), tags)
		}
		for _, metric := range []struct {
			name  string
			value *uint64
		}{
			{"allocator_padding_bytes", cur.AllocatorPaddingBytes},
			{"last_allocation_allowance_bytes", cur.LastAllocationAllowanceBytes},
			{"nominal_kv_bytes", cur.NominalKVBytes},
			{"physical_floor_overhead_bytes", cur.PhysicalFloorOverheadBytes},
		} {
			if metric.value != nil {
				s.dd.HistogramOrGauge("provider.paged_storage."+metric.name, float64(*metric.value), tags)
			}
		}
		if !same {
			continue
		}
		for _, metric := range []struct {
			name              string
			previous, current *uint64
		}{
			{"allocation_failures", old.AllocationFailuresTotal, cur.AllocationFailuresTotal},
			{"admission_refusals", old.AdmissionRefusalsTotal, cur.AdmissionRefusalsTotal},
			{"grant_refusals", old.GrantRefusalsTotal, cur.GrantRefusalsTotal},
			{"grant_epoch_retries", old.GrantEpochRetriesTotal, cur.GrantEpochRetriesTotal},
		} {
			if metric.previous != nil && metric.current != nil {
				s.ddCountDelta("provider.paged_storage."+metric.name, *metric.previous, *metric.current, tags)
			}
		}
	}
}
