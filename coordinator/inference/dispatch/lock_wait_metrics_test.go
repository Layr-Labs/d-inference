package dispatch

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// TestRoutingScansCounterEmittedPerDecision: the decision's ScanCount is
// emitted as the routing.scans counter with the model and outcome tags; a
// plan-based retry (zero scans) emits nothing.
func TestRoutingScansCounterEmittedPerDecision(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	srv := newTestController(t)
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.deps.Counters = fixtureDatadogCounters{dd}

	req, _ := http.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	d := &execution{s: srv, r: req, model: "scan-metric-model", attempt: 0}
	d.recordRoutingDecision(registry.RoutingDecision{Model: d.model, ScanCount: 2}, "no provider available", "")
	packet := waitForMetric(t, collector, "routing.scans")
	if !strings.Contains(packet, "routing.scans:2|c|") || !strings.Contains(packet, "model:scan-metric-model") || !strings.Contains(packet, "outcome:no_provider") {
		t.Fatalf("routing.scans packet = %s, want count 2 tagged with the model and outcome", packet)
	}

	d.recordRoutingDecision(registry.RoutingDecision{Model: d.model, ScanCount: 0}, "no provider available", "")
	time.Sleep(50 * time.Millisecond)
	for _, p := range collector.drain() {
		if strings.Contains(p, "routing.scans") {
			t.Fatalf("a zero-scan decision emitted routing.scans: %s", p)
		}
	}
}
