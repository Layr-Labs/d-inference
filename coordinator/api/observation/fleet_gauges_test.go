package observation

import (
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestQueueGaugesEmitFinalZeroWhenModelDisappears(t *testing.T) {
	srv := newFleetObservation(t)
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)
	const model = "departing-queue-model"
	q := srv.registry.Queue()
	if err := q.Enqueue(&registry.QueuedRequest{RequestID: "waiting", Model: model}); err != nil {
		t.Fatal(err)
	}
	srv.emitPerModelQueueGauges(map[string]int64{model: 1})
	_ = dd.Statsd.Flush()
	if packets := collector.drain(); sumMetric(t, packets, metricQueueDepthByModel, "model:"+model) != 1 {
		t.Fatal("missing initial nonzero queue depth")
	}
	q.Remove("waiting", model)
	srv.emitPerModelQueueGauges(nil)
	_ = dd.Statsd.Flush()
	packets := collector.drain()
	for _, metric := range []string{metricQueueDepthByModel, metricQueueOldestAgeMs} {
		found := findMetrics(packets, metric)
		if !hasMetric(found, "model:"+model) || sumMetric(t, found, metric, "model:"+model) != 0 {
			t.Errorf("%s did not publish the departing model's zero: %v", metric, found)
		}
	}
	// After the final zero, the model is forgotten instead of being retained
	// and emitted forever as more distinct queued models pass through.
	srv.emitPerModelQueueGauges(nil)
	_ = dd.Statsd.Flush()
	if packets := collector.drain(); len(findMetrics(packets, metricQueueDepthByModel))+len(findMetrics(packets, metricQueueOldestAgeMs)) != 0 {
		t.Fatal("departed model remained in the gauge tracker")
	}
}

func newFleetObservation(t *testing.T) *Owner {
	t.Helper()
	logger := quietLogger()
	srv := New(Dependencies{Registry: registry.New(logger), Logger: logger})
	t.Cleanup(srv.Close)
	return srv
}

// TestFleetGauges_QueueDepth exercises the gauge emitter StartDDGaugeLoop
// calls: a queued request shows up on the per-model depth / oldest-age gauges.
func TestFleetGauges_QueueDepth(t *testing.T) {
	srv := newFleetObservation(t)
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)

	const model = "fleet-gauge-model"
	makeDecodeProvider(t, srv.registry, "fg-healthy", "M3", "Max", 400, 70, model)

	q := srv.registry.Queue()
	queued := &registry.QueuedRequest{RequestID: "fg-queued-1", Model: model}
	if err := q.Enqueue(queued); err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	defer q.Remove(queued.RequestID, model)
	time.Sleep(20 * time.Millisecond)

	srv.emitPerModelQueueGauges(srv.registry.ModelProviderSnapshot())

	_ = dd.Statsd.Flush()
	packets := collector.drain()
	if got := sumMetric(t, packets, metricQueueDepthByModel, "model:"+model); got != 1 {
		t.Errorf("request_queue.depth_by_model{%s} = %v, want 1; packets=%v", model, got, findMetrics(packets, metricQueueDepthByModel))
	}
	ages := findMetrics(packets, metricQueueOldestAgeMs)
	if !hasMetric(ages, "model:"+model) {
		t.Errorf("missing request_queue.oldest_age_ms{model}; packets=%v", packets)
	}
	for _, p := range ages {
		if strings.Contains(p, "model:"+model) && metricSampleValue(t, p) < 10 {
			t.Errorf("oldest_age_ms should reflect the 20ms-old waiter: %q", p)
		}
	}
}
