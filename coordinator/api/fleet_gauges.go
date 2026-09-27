package api

import "sync"

// Only the immediately preceding set is retained. A departing model gets one
// zero sample, then leaves the tracker rather than accumulating forever.
type queueGaugeState struct {
	mu     sync.Mutex
	models map[string]struct{}
}

func (state *queueGaugeState) reconcile(current map[string]struct{}) []string {
	state.mu.Lock()
	defer state.mu.Unlock()
	var retired []string
	for model := range state.models {
		if _, present := current[model]; !present {
			retired = append(retired, model)
		}
	}
	state.models = current
	return retired
}

// Per-model queue gauges, pushed from StartDDGaugeLoop.
//
// request_queue.depth is a single fleet-wide number and queue_wait_ms is
// sampled only at request terminals, so a model whose queue is backing up is
// invisible until its requests time out. These gauges close that gap.
const (
	// metricQueueDepthByModel is a distinct name (not request_queue.depth with a
	// model tag): the untagged fleet-wide gauge already exists under that name
	// and a mixed tag set would double-count in sum:/avg: queries.
	metricQueueDepthByModel = "request_queue.depth_by_model"
	metricQueueOldestAgeMs  = "request_queue.oldest_age_ms"
)

// emitPerModelQueueGauges pushes request_queue.depth_by_model{model} and
// request_queue.oldest_age_ms{model}. servedModels is the live per-model
// provider snapshot the gauge loop already computed; every served model gets a
// point (0 when nothing is queued) so the series does not go blank between
// queueing episodes, and models that are queued without a live provider are
// still reported.
func (s *Server) emitPerModelQueueGauges(servedModels map[string]int64) {
	if s == nil || s.dd == nil || s.registry == nil {
		return
	}
	q := s.registry.Queue()
	if q == nil {
		return
	}
	models := make(map[string]struct{}, len(servedModels)+4)
	for model := range servedModels {
		models[model] = struct{}{}
	}
	for _, model := range q.QueuedModels() {
		models[model] = struct{}{}
	}
	retired := s.queueGauges.reconcile(models)
	for model := range models {
		depth, oldestAge := q.QueueStats(model)
		tags := []string{"model:" + model}
		s.ddGauge(metricQueueDepthByModel, float64(depth), tags)
		s.ddGauge(metricQueueOldestAgeMs, float64(oldestAge.Milliseconds()), tags)
	}
	for _, model := range retired {
		tags := []string{"model:" + model}
		s.ddGauge(metricQueueDepthByModel, 0, tags)
		s.ddGauge(metricQueueOldestAgeMs, 0, tags)
	}
}
