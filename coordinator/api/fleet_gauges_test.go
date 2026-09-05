package api

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestQueueGaugesEmitFinalZeroWhenModelDisappears(t *testing.T) {
	srv, _ := testServer(t)
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
