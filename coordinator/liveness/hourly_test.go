package liveness

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// hourlyFakeQuery satisfies HourlyQuery so we can drive the run loop in
// tests without touching a real store.
type hourlyFakeQuery struct {
	mu      sync.Mutex
	calls   int
	written int64
	err     error
}

func (f *hourlyFakeQuery) RollupHeartbeatsHourly(_ context.Context, _ time.Time) (int64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	if f.err != nil {
		return 0, f.err
	}
	return f.written, nil
}

func ptrF32(v float32) *float32 { return &v }

func TestMemoryRollupHeartbeatsHourly(t *testing.T) {
	now := time.Date(2026, 5, 28, 12, 30, 0, 0, time.UTC)
	hour11 := time.Date(2026, 5, 28, 11, 0, 0, 0, time.UTC)
	hour12 := time.Date(2026, 5, 28, 12, 0, 0, 0, time.UTC)

	s := store.NewMemory(store.Config{})

	// p1 / hour11: three heartbeats. Avg pressure 0.2, avg cpu 0.5.
	// Thermal: nominal, fair, nominal → max = fair.
	// Memory available: 4, 5, nil → avg = 4.5 over 2 samples.
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatalf("AppendHeartbeats: %v", err)
		}
	}
	must(s.AppendHeartbeats(context.Background(), []store.HeartbeatEvent{
		{ProviderID: "p1", At: hour11.Add(1 * time.Minute), MemoryPressure: 0.1, CPUUsage: 0.4, ThermalState: "nominal", MemoryAvailableGB: ptrF32(4)},
		{ProviderID: "p1", At: hour11.Add(30 * time.Minute), MemoryPressure: 0.2, CPUUsage: 0.5, ThermalState: "fair", MemoryAvailableGB: ptrF32(5)},
		{ProviderID: "p1", At: hour11.Add(55 * time.Minute), MemoryPressure: 0.3, CPUUsage: 0.6, ThermalState: "nominal"},
	}))
	// p1 / hour12: one heartbeat.
	must(s.AppendHeartbeats(context.Background(), []store.HeartbeatEvent{
		{ProviderID: "p1", At: hour12.Add(15 * time.Minute), MemoryPressure: 0.9, CPUUsage: 0.9, ThermalState: "serious"},
	}))
	// p2 / hour11: two critical heartbeats.
	must(s.AppendHeartbeats(context.Background(), []store.HeartbeatEvent{
		{ProviderID: "p2", At: hour11.Add(10 * time.Minute), MemoryPressure: 0.5, CPUUsage: 0.7, ThermalState: "critical"},
		{ProviderID: "p2", At: hour11.Add(40 * time.Minute), MemoryPressure: 0.7, CPUUsage: 0.8, ThermalState: "critical"},
	}))
	// Stale heartbeat (before the floor) — must be excluded.
	must(s.AppendHeartbeats(context.Background(), []store.HeartbeatEvent{
		{ProviderID: "p3", At: now.Add(-5 * time.Hour), MemoryPressure: 0.9, CPUUsage: 0.9, ThermalState: "critical"},
	}))

	since := now.Add(-2 * time.Hour) // floor → 10:00
	written, err := s.RollupHeartbeatsHourly(context.Background(), since)
	if err != nil {
		t.Fatalf("RollupHeartbeatsHourly: %v", err)
	}
	if written != 3 {
		t.Fatalf("want 3 rows written, got %d", written)
	}

	rows := s.HeartbeatsHourly()
	index := map[string]store.HeartbeatHourlyRow{}
	for _, r := range rows {
		key := r.ProviderID + "@" + r.Hour.Format(time.RFC3339)
		index[key] = r
	}

	p1h11 := index["p1@"+hour11.Format(time.RFC3339)]
	if p1h11.HeartbeatCount != 3 {
		t.Fatalf("p1/hour11 count: want 3, got %d", p1h11.HeartbeatCount)
	}
	if p1h11.MaxThermalState != "fair" {
		t.Fatalf("p1/hour11 max thermal: want fair, got %q", p1h11.MaxThermalState)
	}
	if !approxEq(float64(p1h11.AvgMemoryPressure), 0.2, 1e-3) {
		t.Fatalf("p1/hour11 avg memory pressure: want ~0.2, got %v", p1h11.AvgMemoryPressure)
	}
	if !approxEq(float64(p1h11.AvgCPUUsage), 0.5, 1e-3) {
		t.Fatalf("p1/hour11 avg cpu: want ~0.5, got %v", p1h11.AvgCPUUsage)
	}
	if p1h11.AvgMemoryAvailableGB == nil || !approxEq(float64(*p1h11.AvgMemoryAvailableGB), 4.5, 1e-3) {
		t.Fatalf("p1/hour11 avg mem avail: want ~4.5, got %v", p1h11.AvgMemoryAvailableGB)
	}

	p2h11 := index["p2@"+hour11.Format(time.RFC3339)]
	if p2h11.HeartbeatCount != 2 {
		t.Fatalf("p2/hour11 count: want 2, got %d", p2h11.HeartbeatCount)
	}
	if p2h11.MaxThermalState != "critical" {
		t.Fatalf("p2/hour11 max thermal: want critical, got %q", p2h11.MaxThermalState)
	}
	// p2 had no MemoryAvailableGB samples → should remain nil.
	if p2h11.AvgMemoryAvailableGB != nil {
		t.Fatalf("p2/hour11 avg mem avail: want nil, got %v", *p2h11.AvgMemoryAvailableGB)
	}

	// p3's heartbeat is before the floor — must not appear.
	for _, r := range rows {
		if r.ProviderID == "p3" {
			t.Fatalf("p3 should be excluded (before floor), got %+v", r)
		}
	}

	// Idempotency: a second run overwrites in place; no duplicate rows.
	if _, err := s.RollupHeartbeatsHourly(context.Background(), since); err != nil {
		t.Fatalf("second RollupHeartbeatsHourly: %v", err)
	}
	if got := len(s.HeartbeatsHourly()); got != 3 {
		t.Fatalf("idempotency broken: want 3 rows after second run, got %d", got)
	}

	// Upsert semantics: appending new heartbeats to an existing bucket and
	// re-rolling must produce an updated aggregate, not just leave the old
	// one in place.
	must(s.AppendHeartbeats(context.Background(), []store.HeartbeatEvent{
		{ProviderID: "p2", At: hour11.Add(50 * time.Minute), MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"},
	}))
	if _, err := s.RollupHeartbeatsHourly(context.Background(), since); err != nil {
		t.Fatalf("third RollupHeartbeatsHourly: %v", err)
	}
	rows = s.HeartbeatsHourly()
	index = map[string]store.HeartbeatHourlyRow{}
	for _, r := range rows {
		index[r.ProviderID+"@"+r.Hour.Format(time.RFC3339)] = r
	}
	p2h11 = index["p2@"+hour11.Format(time.RFC3339)]
	if p2h11.HeartbeatCount != 3 {
		t.Fatalf("upsert broken: want p2/hour11 count 3 after append, got %d", p2h11.HeartbeatCount)
	}
	// Max thermal still critical (new sample is nominal, below existing rank).
	if p2h11.MaxThermalState != "critical" {
		t.Fatalf("upsert max thermal: want critical, got %q", p2h11.MaxThermalState)
	}
}

func TestRunHourlyCountsOnSuccess(t *testing.T) {
	q := &hourlyFakeQuery{written: 7}

	var sumByName sync.Map
	count := func(name string, value int64) {
		v, _ := sumByName.LoadOrStore(name, new(atomic.Int64))
		v.(*atomic.Int64).Add(value)
	}

	runHourly(context.Background(), q, quietLogger(), count, HourlyConfig{Interval: time.Minute, Lookback: time.Hour})

	get := func(name string) int64 {
		v, ok := sumByName.Load(name)
		if !ok {
			return 0
		}
		return v.(*atomic.Int64).Load()
	}
	if got := get("liveness_hourly_runs_total"); got != 1 {
		t.Fatalf("runs_total: want 1, got %d", got)
	}
	if got := get("liveness_hourly_rows_total"); got != 7 {
		t.Fatalf("rows_total: want 7, got %d", got)
	}
	if got := get("liveness_hourly_errors_total"); got != 0 {
		t.Fatalf("errors_total: want 0, got %d", got)
	}
}

func TestRunHourlyCountsOnError(t *testing.T) {
	q := &hourlyFakeQuery{err: errors.New("simulated")}

	var sumByName sync.Map
	count := func(name string, value int64) {
		v, _ := sumByName.LoadOrStore(name, new(atomic.Int64))
		v.(*atomic.Int64).Add(value)
	}

	runHourly(context.Background(), q, quietLogger(), count, HourlyConfig{Interval: time.Minute, Lookback: time.Hour})

	get := func(name string) int64 {
		v, ok := sumByName.Load(name)
		if !ok {
			return 0
		}
		return v.(*atomic.Int64).Load()
	}
	if got := get("liveness_hourly_runs_total"); got != 1 {
		t.Fatalf("runs_total: want 1, got %d", got)
	}
	if got := get("liveness_hourly_rows_total"); got != 0 {
		t.Fatalf("rows_total: want 0 on error path, got %d", got)
	}
	if got := get("liveness_hourly_errors_total"); got != 1 {
		t.Fatalf("errors_total: want 1, got %d", got)
	}
}

func approxEq(a, b, eps float64) bool {
	d := a - b
	if d < 0 {
		d = -d
	}
	return d <= eps
}
