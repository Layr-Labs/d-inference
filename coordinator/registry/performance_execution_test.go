package registry

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const executionK4 = "kvq-v1:affine-v1-k4v4-g64-f32-h128-s1:prefill=direct"
const executionK8V4 = "kvq-v1:affine-v1-k8v4-g64-f32-h128-s1:prefill=direct"

func TestExecutionIdentityFiniteNormalization(t *testing.T) {
	for _, id := range []string{"", executionK4, executionK8V4,
		"kvq-v1:affine-v1-k8v8-g32-f32-h0-s1:prefill=opportunisticSDPA"} {
		if got := normalizeExecutionIdentity(id); got != id {
			t.Fatalf("%q became %q", id, got)
		}
	}
	for _, id := range []string{"native", " ", executionK4 + "\n", strings.Repeat("x", 10000),
		"kvq-v1:affine-v1-k4v4-g64-f32-h999-s1:prefill=direct", "kvq-v2:future"} {
		if got := normalizeExecutionIdentity(id); got != invalidExecutionIdentity {
			t.Fatalf("bad identity %q became %q", id, got)
		}
	}
}

func TestExecutionTPSPartitionsAndCannotCollideWithModelNames(t *testing.T) {
	r := NewTPSRegistry()
	for _, tc := range []struct {
		id   string
		rate float64
	}{{"", 90}, {executionK4, 30}, {executionK8V4, 45}} {
		r.Record("m", "M4", tc.rate, tc.id)
		r.RecordSolo("m", "M4|Max", tc.rate, tc.id)
	}
	for _, tc := range []struct {
		id   string
		rate float64
	}{{"", 90}, {executionK4, 30}, {executionK8V4, 45}} {
		if got := r.Median("m", "M4", tc.id); got != tc.rate {
			t.Fatalf("median %q=%v", tc.id, got)
		}
		if got, n := r.SoloMedian("m", "M4|Max", tc.id); got != tc.rate || n != 1 {
			t.Fatalf("solo %q=%v/%d", tc.id, got, n)
		}
		if got, n, classes := r.SoloMedianAllChips("m", tc.id); got != tc.rate || n != 1 || classes != 1 {
			t.Fatalf("aggregate %q=%v/%d/%d", tc.id, got, n, classes)
		}
	}
	r.Record("m:"+executionK4, "M4", 7)
	if r.Median("m", "M4", executionK4) != 30 || r.Median("m:"+executionK4, "M4") != 7 {
		t.Fatal("composite model key collision")
	}
	for i := 1; i <= 100; i++ {
		r.Record("m", "M4", 500, strings.Repeat("bad", i))
		r.RecordSolo("m", "M4", 500, strings.Repeat("bad", i))
	}
	if len(r.samples) != 4 || len(r.soloSamples) != 3 {
		t.Fatal("invalid identities grew performance key cardinality")
	}
	if r.Median("m", "M4") != 90 {
		t.Fatal("legacy lookup changed")
	}
}

func TestExecutionLoadedSlotAndPlaceholderPrecedence(t *testing.T) {
	for _, state := range []string{"running", "idle", "loading", "reloading", "idle_shutdown", "crashed", "unknown", ""} {
		for _, actual := range []string{"", executionK8V4} {
			p := &Provider{Models: []protocol.ModelInfo{{ID: "m", ExecutionIdentity: executionK4}},
				BackendCapacity: &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: "m", State: state, ExecutionIdentity: actual}}}}
			want := executionK4
			if slotStateModelLoaded(state) {
				want = actual
			}
			if got := providerExecutionIdentityLocked(p, "m"); got != want {
				t.Fatalf("state=%q actual=%q got=%q want=%q", state, actual, got, want)
			}
		}
	}
	p := &Provider{Models: []protocol.ModelInfo{{ID: "m", Quantization: "4bit"}}}
	if providerExecutionIdentityLocked(p, "m") != "" {
		t.Fatal("weight quantization became execution identity")
	}
}

func TestExecutionHeartbeatPartitionAndPlaceholderNoTraining(t *testing.T) {
	r := New(testLogger())
	p := makeSchedulerProvider(t, r, "exec-hb", "m", 90)
	for _, tc := range []struct {
		id   string
		rate float64
	}{{"", 90}, {executionK4, 30}, {executionK8V4, 45}} {
		if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "serving", BackendCapacity: &protocol.BackendCapacity{
			Slots: []protocol.BackendSlotCapacity{{Model: "m", State: "running", NumRunning: 1, ObservedDecodeTPS: tc.rate, ExecutionIdentity: tc.id}}}}) {
			t.Fatal("heartbeat refused")
		}
		if got := r.tpsRegistry.Median("m", p.Hardware.ChipFamily, tc.id); got != tc.rate {
			t.Fatalf("ingest %q=%v", tc.id, got)
		}
	}
	p.mu.Lock()
	p.Models[0].ExecutionIdentity = executionK4
	p.mu.Unlock()
	r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "serving", BackendCapacity: &protocol.BackendCapacity{
		Slots: []protocol.BackendSlotCapacity{{Model: "m", State: "reloading", ObservedDecodeTPS: 400}}}})
	if r.tpsRegistry.Median("m", p.Hardware.ChipFamily) != 90 || r.tpsRegistry.Median("m", p.Hardware.ChipFamily, executionK4) != 30 {
		t.Fatal("placeholder trained a rate")
	}
}
