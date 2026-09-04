package registry

// Tests for the registry counter sink (registry_metrics.go): the drain-pass
// series and the planner-attributed load_model sends, asserted against an
// in-process recording sink driving a real Registry, real providers and a
// real queue.

import (
	"fmt"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// recordingMetricsSink implements registryMetricsSink and keeps every emitted
// counter keyed by "name{tag1,tag2}" (tags sorted) so assertions read as the
// series they name.
type recordingMetricsSink struct {
	mu     sync.Mutex
	counts map[string]int64
}

func newRecordingMetricsSink() *recordingMetricsSink {
	return &recordingMetricsSink{counts: make(map[string]int64)}
}

func metricKey(name string, tags []string) string {
	sorted := append([]string(nil), tags...)
	sort.Strings(sorted)
	return name + "{" + strings.Join(sorted, ",") + "}"
}

func (s *recordingMetricsSink) Incr(name string, tags []string) { s.Count(name, 1, tags) }

func (s *recordingMetricsSink) Count(name string, value int64, tags []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.counts[metricKey(name, tags)] += value
}

// get returns the accumulated value for a series and resets it.
func (s *recordingMetricsSink) get(name string, tags ...string) int64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := metricKey(name, tags)
	v := s.counts[key]
	delete(s.counts, key)
	return v
}

// total returns the sum over every series with the given name (any tags) and
// resets them.
func (s *recordingMetricsSink) total(name string) int64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	var sum int64
	for key, v := range s.counts {
		if strings.HasPrefix(key, name+"{") {
			sum += v
			delete(s.counts, key)
		}
	}
	return sum
}

func expectMetric(t *testing.T, sink *recordingMetricsSink, want int64, name string, tags ...string) {
	t.Helper()
	if got := sink.get(name, tags...); got != want {
		t.Fatalf("%s = %d, want %d", metricKey(name, tags), got, want)
	}
}

const metricsTestModel = "metrics-test-model"

func metricsTestEnqueue(t *testing.T, reg *Registry, id string) *QueuedRequest {
	t.Helper()
	req := &QueuedRequest{RequestID: id, Model: metricsTestModel, Pending: &PendingRequest{
		RequestID: id, Model: metricsTestModel, EstimatedPromptTokens: 800, RequestedMaxTokens: 1024,
	}}
	if err := reg.Queue().Enqueue(req); err != nil {
		t.Fatalf("enqueue %s: %v", id, err)
	}
	return req
}

// TestDrainMetricsSaturatedPass: a SetProviderIdle drain over a saturated
// fleet with four identical waiters is one pass{trigger:idle,outcome:saturated}
// and reports the scans it performed; the queue is left intact.
func TestDrainMetricsSaturatedPass(t *testing.T) {
	reg := New(testLogger())
	sink := newRecordingMetricsSink()
	reg.SetMetricsSink(sink)
	for i := 0; i < 3; i++ {
		makeTokenBudgetProvider(t, reg, fmt.Sprintf("sat-%d", i), metricsTestModel, 100, 1000, 1000, 50)
	}
	reg.SetQueue(NewRequestQueue(16, 30*time.Second))
	const depth = 4
	for i := 0; i < depth; i++ {
		metricsTestEnqueue(t, reg, fmt.Sprintf("q-%d", i))
	}

	reg.SetProviderIdle("sat-0")
	expectMetric(t, sink, 1, "queue.drain.pass", "trigger:idle", "outcome:saturated")
	// One scan anchors the verdict; the other three identical waiters are
	// requeued on it without a scan (queue_drain_dominance.go).
	expectMetric(t, sink, 1, "queue.drain.scans", "trigger:idle")
	expectMetric(t, sink, depth-1, "queue.drain.dominated", "trigger:idle")
	if depthNow := reg.Queue().QueueSize(metricsTestModel); depthNow != depth {
		t.Fatalf("queue depth = %d after a saturated pass, want %d", depthNow, depth)
	}
	// A heartbeat carries its own trigger label (after the suppression window).
	clock := drainTestClock(reg)
	clock.Add(heartbeatDrainSuppressWindow)
	reg.Heartbeat("sat-1", drainTestHeartbeatFor(metricsTestModel, 1000, 1000))
	expectMetric(t, sink, 1, "queue.drain.pass", "trigger:heartbeat", "outcome:saturated")
	expectMetric(t, sink, 1, "queue.drain.scans", "trigger:heartbeat")
	expectMetric(t, sink, depth-1, "queue.drain.dominated", "trigger:heartbeat")
}

// TestDrainMetricsAdmittingPass: a pass that hands a waiter to a provider is
// outcome:admitted with exactly one scan.
func TestDrainMetricsAdmittingPass(t *testing.T) {
	reg := New(testLogger())
	sink := newRecordingMetricsSink()
	reg.SetMetricsSink(sink)
	p := makeTokenBudgetProvider(t, reg, "free", metricsTestModel, 100, 0, 32_768, 50)
	reg.SetQueue(NewRequestQueue(16, 30*time.Second))
	req := metricsTestEnqueue(t, reg, "q-0")

	reg.SetProviderIdle(p.ID)
	select {
	case got := <-req.ResponseCh:
		if got == nil || got.ID != p.ID {
			t.Fatalf("waiter assigned to %v, want %s", got, p.ID)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("waiter was not assigned")
	}
	expectMetric(t, sink, 1, "queue.drain.pass", "trigger:idle", "outcome:admitted")
	expectMetric(t, sink, 1, "queue.drain.scans", "trigger:idle")
}

// TestDrainMetricsEmptyQueueIsSilent pins the hot path: a heartbeat with
// nothing queued emits no drain series at all.
func TestDrainMetricsEmptyQueueIsSilent(t *testing.T) {
	reg := New(testLogger())
	sink := newRecordingMetricsSink()
	reg.SetMetricsSink(sink)
	p := makeTokenBudgetProvider(t, reg, "idle", metricsTestModel, 100, 0, 32_768, 50)
	reg.SetQueue(NewRequestQueue(16, 30*time.Second))

	reg.Heartbeat(p.ID, drainTestHeartbeatFor(metricsTestModel, 0, 32_768))
	reg.SetProviderIdle(p.ID)
	if n := sink.total("queue.drain.pass"); n != 0 {
		t.Fatalf("queue.drain.pass = %d on an empty queue, want 0", n)
	}
	if n := sink.total("queue.drain.scans"); n != 0 {
		t.Fatalf("queue.drain.scans = %d on an empty queue, want 0", n)
	}
}

// TestModelLoadSentAttributesPlanner: a load issued by TriggerModelSwaps is
// model_load.sent{planner:swap}; one issued by the warm-pool tick is
// {planner:warm_pool}.
func TestModelLoadSentAttributesPlanner(t *testing.T) {
	reg := New(testLogger())
	sink := newRecordingMetricsSink()
	reg.SetMetricsSink(sink)
	const cold = "metrics-cold-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: cold, SizeGB: 15}})
	makeWarmPoolColdProvider(t, reg, "cold-0", cold, 80, 64, 8)
	makeWarmPoolColdProvider(t, reg, "cold-1", cold, 80, 64, 8)
	reg.SetQueue(NewRequestQueue(16, 30*time.Second))
	sent := captureWarmPoolLoads(reg)

	req := &QueuedRequest{RequestID: "q-cold", Model: cold, Pending: &PendingRequest{RequestID: "q-cold", Model: cold}}
	if err := reg.Queue().Enqueue(req); err != nil {
		t.Fatal(err)
	}
	reg.TriggerModelSwaps()
	if len(*sent) != 1 {
		t.Fatalf("TriggerModelSwaps sent %d loads, want 1", len(*sent))
	}
	expectMetric(t, sink, 1, "model_load.sent", "planner:swap")

	reg.ConfigureWarmPool(testWarmPoolConfig())
	reg.RecordWarmPoolCapacityReject(cold)
	reg.warmPool.tick(time.Now())
	if len(*sent) != 2 {
		t.Fatalf("warm-pool tick sent %d loads in total, want 2", len(*sent))
	}
	expectMetric(t, sink, 1, "model_load.sent", "planner:warm_pool")
	if n := sink.total("model_load.sent"); n != 0 {
		t.Fatalf("unexpected extra model_load.sent = %d", n)
	}
}

// TestModelLoadSentNotEmittedOnSendFailure: a send the transport refuses is
// cleared and not counted as sent.
func TestModelLoadSentNotEmittedOnSendFailure(t *testing.T) {
	reg := New(testLogger())
	sink := newRecordingMetricsSink()
	reg.SetMetricsSink(sink)
	const cold = "metrics-cold-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: cold, SizeGB: 15}})
	makeWarmPoolColdProvider(t, reg, "cold-0", cold, 80, 64, 8)
	reg.SetQueue(NewRequestQueue(16, 30*time.Second))
	reg.loadModelSender = func(string, string) error { return fmt.Errorf("socket closed") }

	req := &QueuedRequest{RequestID: "q-cold", Model: cold, Pending: &PendingRequest{RequestID: "q-cold", Model: cold}}
	if err := reg.Queue().Enqueue(req); err != nil {
		t.Fatal(err)
	}
	reg.TriggerModelSwaps()
	if n := sink.total("model_load.sent"); n != 0 {
		t.Fatalf("model_load.sent = %d after a failed send, want 0", n)
	}
	if reg.HasPendingModelLoad("cold-0", cold) {
		t.Fatal("failed send left a pending-load reservation")
	}
}

// TestMetricsNilSinkIsNoop: without a sink every emit is a no-op — the
// registry must never dereference a missing sink on the drain or planner path.
func TestMetricsNilSinkIsNoop(t *testing.T) {
	reg := New(testLogger())
	makeTokenBudgetProvider(t, reg, "sat-0", metricsTestModel, 100, 1000, 1000, 50)
	reg.SetQueue(NewRequestQueue(16, 30*time.Second))
	metricsTestEnqueue(t, reg, "q-0")
	reg.SetProviderIdle("sat-0")
	reg.metricIncr("queue.drain.pass", nil)
	reg.metricCount("queue.drain.scans", 3, nil)
	if reg.metricsSink() != nil {
		t.Fatal("sink present on a fresh registry")
	}
	// Installing and clearing round-trips through the atomic box.
	sink := newRecordingMetricsSink()
	reg.SetMetricsSink(sink)
	reg.metricIncr("x", nil)
	reg.SetMetricsSink(nil)
	reg.metricIncr("x", nil)
	if got := sink.get("x"); got != 1 {
		t.Fatalf("sink saw %d emits, want exactly the one made while installed", got)
	}
}

// drainTestHeartbeatFor is a heartbeat that reports the given token budget for
// model explicitly, so the heartbeat itself never changes the provider's
// admission state; shared with the queue-drain tests.
func drainTestHeartbeatFor(model string, used, max int64) *protocol.HeartbeatMessage {
	return &protocol.HeartbeatMessage{
		Type:       protocol.TypeHeartbeat,
		Status:     "serving",
		WarmModels: []string{model},
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 64,
			Slots: []protocol.BackendSlotCapacity{{
				Model:                 model,
				State:                 "running",
				NumRunning:            1,
				ActiveTokenBudgetUsed: used,
				ActiveTokenBudgetMax:  max,
				ObservedDecodeTPS:     50,
			}},
		},
		SystemMetrics: protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"},
	}
}
