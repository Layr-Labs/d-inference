package api

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Server) recordProcessMemoryTelemetry(provider *registry.Provider, prev, capacity *protocol.BackendCapacity) {
	if s.dd == nil || capacity == nil || capacity.Telemetry == nil {
		return
	}
	cur := capacity.Telemetry.ProcessMemory
	if cur == nil {
		return
	}
	tags := mlxTelemetryTags(provider)
	s.dd.HistogramOrGauge("provider.process_memory.sample_age_ms", float64(cur.SampleAgeMS), tags)
	fresh := cur.SampleAgeMS <= capacitySampleFreshMS
	s.dd.HistogramOrGauge("provider.process_memory.sample_fresh", boolGauge(fresh), tags)
	if !fresh {
		return
	}
	if prev != nil && prev.Telemetry != nil {
		old := prev.Telemetry.ProcessMemory
		if old != nil && old.Generation == cur.Generation && cur.SampleSeq <= old.SampleSeq {
			return
		}
	}
	for _, metric := range []struct {
		name  string
		value uint64
	}{
		{"cap_bytes", cur.CapBytes},
		{"activation_reserve_bytes", cur.ActivationReserveBytes},
		{"active_bytes", cur.ActiveBytes},
		{"cache_bytes", cur.CacheBytes},
		{"charged_bytes", cur.ChargedBytes},
		{"materialized_bytes", cur.MaterializedBytes},
		{"unmaterialized_bytes", cur.UnmaterializedBytes},
		{"remaining_bytes", cur.RemainingBytes},
		{"commitment_debt_bytes", cur.CommitmentDebtBytes},
		{"owner_count", cur.OwnerCount},
		{"closing_owner_count", cur.ClosingOwnerCount},
	} {
		s.dd.HistogramOrGauge("provider.process_memory."+metric.name, float64(metric.value), tags)
	}
	if cur.SystemAvailableBytes != nil {
		s.dd.HistogramOrGauge("provider.process_memory.system_available_bytes", float64(*cur.SystemAvailableBytes), tags)
	}
}
