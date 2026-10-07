package observation

import fleet "github.com/eigeninference/d-inference/coordinator/internal/observation/fleet"

func (s *Owner) emitPerModelQueueGauges(servedModels map[string]int64) {
	if s == nil || s.Datadog() == nil {
		return
	}
	s.queueGauges.Emit(servedModels, s.registry, s.Gauge)
}
func (s *Owner) emitStoreCacheGauges() {
	if s.Datadog() == nil {
		return
	}
	fleet.EmitStoreCacheGauges(s.store, s.Gauge)
}
