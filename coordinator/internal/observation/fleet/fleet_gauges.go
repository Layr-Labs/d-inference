package fleet

import (
	"sync"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Only the immediately preceding set is retained. A departing model gets one
// zero sample, then leaves the tracker rather than accumulating forever.
type QueueGauges struct {
	mu     sync.Mutex
	models map[string]struct{}
}

func (state *QueueGauges) reconcile(current map[string]struct{}) []string {
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
	QueueDepthByModel = "request_queue.depth_by_model"
	QueueOldestAgeMs  = "request_queue.oldest_age_ms"
)

// emitPerModelQueueGauges pushes request_queue.depth_by_model{model} and
// request_queue.oldest_age_ms{model}. servedModels is the live per-model
// provider snapshot the gauge loop already computed; every served model gets a
// point (0 when nothing is queued) so the series does not go blank between
// queueing episodes, and models that are queued without a live provider are
// still reported.
func (state *QueueGauges) Emit(servedModels map[string]int64, reg *registry.Registry, gauge func(string, float64, []string)) {
	if state == nil || reg == nil {
		return
	}
	q := reg.Queue()
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
	retired := state.reconcile(models)
	for model := range models {
		depth, oldestAge := q.QueueStats(model)
		tags := []string{"model:" + model}
		gauge(QueueDepthByModel, float64(depth), tags)
		gauge(QueueOldestAgeMs, float64(oldestAge.Milliseconds()), tags)
	}
	for _, model := range retired {
		tags := []string{"model:" + model}
		gauge(QueueDepthByModel, 0, tags)
		gauge(QueueOldestAgeMs, 0, tags)
	}
}
