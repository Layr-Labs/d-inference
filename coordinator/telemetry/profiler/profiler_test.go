package profiler

import (
	"reflect"
	"sort"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry/profilequeue"
)

// A real queue and MemoryStore exercise the config/build/sample boundary.
// An ordinary success is dropped at rate zero, while exceptional attempts and
// a missing correlation ID still reach the store with their original identity.
func TestProfilerWorkerPreservesSamplingBypasses(t *testing.T) {
	st := store.NewMemory(store.Config{})
	var sampledOut atomic.Int64
	p := New(Config{Enabled: true, SampleRate: 0}, Hooks{
		Store: func() profilequeue.Writer { return st },
		Incr: func(name string, tags []string) {
			if name == "profiler.records" && reflect.DeepEqual(tags, []string{"status:sampled_out"}) {
				sampledOut.Add(1)
			}
		},
	}, 8)
	t.Cleanup(p.Close)
	for _, tc := range []struct{ id, coord, status string }{
		{"ordinary", "ordinary", "success"},
		{"error", "error", "error"},
		{"no-id", "", "success"},
	} {
		rp := registry.NewRequestProfile(time.Now(), tc.coord, nil, 0)
		ap := rp.NewAttempt(tc.id, 0, "")
		ap.SetOutcome(tc.status, "", "", "completed", "")
		if !p.Submit(rp, ap) {
			t.Fatalf("empty queue rejected %s", tc.id)
		}
	}
	deadline := time.Now().Add(3 * time.Second)
	var rows []store.RequestProfileRecord
	for time.Now().Before(deadline) {
		rows = st.RequestProfilesSince(time.Time{})
		if sampledOut.Load() == 1 && len(rows) == 2 {
			break
		}
		time.Sleep(time.Millisecond)
	}
	ids := make([]string, 0, len(rows))
	for _, row := range rows {
		ids = append(ids, row.RequestID)
	}
	sort.Strings(ids)
	if sampledOut.Load() != 1 || !reflect.DeepEqual(ids, []string{"error", "no-id"}) {
		t.Fatalf("sampled_out=%d persisted=%v, want 1 and [error no-id]", sampledOut.Load(), ids)
	}
}

func TestProfilerDisabledDoesNotAcquireWriterOrQueue(t *testing.T) {
	writerReads := 0
	p := New(Config{Enabled: false, SampleRate: 1}, Hooks{
		Store: func() profilequeue.Writer {
			writerReads++
			return store.NewMemory(store.Config{})
		},
	}, 1)
	t.Cleanup(p.Close)
	rp := registry.NewRequestProfile(time.Now(), "disabled", nil, 0)
	ap := rp.NewAttempt("disabled", 0, "")
	if p.Enabled() || p.HasSink() || p.Submit(rp, ap) || writerReads != 0 {
		t.Fatalf("disabled profiler acquired work: enabled=%v sink=%v writer reads=%d", p.Enabled(), p.HasSink(), writerReads)
	}
	var absent *Profiler
	if absent.Enabled() || absent.HasSink() || absent.Submit(rp, ap) || absent.Depth() != 0 || absent.DroppedTotal() != 0 {
		t.Fatal("absent profiler must leave the request lifecycle untouched")
	}
	absent.Close()
}
