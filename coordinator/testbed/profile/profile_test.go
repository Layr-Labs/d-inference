package profile

import (
	"testing"
	"time"

	"github.com/eigeninference/coordinator/testbed"
)

func TestProfilerBuildProfile(t *testing.T) {
	cfg := testbed.DefaultTestConfig()
	buf := testbed.NewEventBuffer()
	p := NewProfiler(cfg, buf)

	inst := testbed.NewInstrument(buf)

	for i := 0; i < 5; i++ {
		rid := inst.NewRequestID()
		inst.RequestStart(rid)

		timer := inst.StartSegment(rid, testbed.SegmentTTFT)
		time.Sleep(2 * time.Millisecond)
		timer.Stop()

		timer2 := inst.StartSegment(rid, testbed.SegmentTotalE2E)
		time.Sleep(1 * time.Millisecond)
		timer2.Stop()

		inst.RequestEnd(rid, 0)
	}

	run := p.BuildProfile()

	if len(run.Requests) != 5 {
		t.Fatalf("expected 5 requests, got %d", len(run.Requests))
	}

	ttftStats, ok := run.Aggregated[testbed.SegmentTTFT]
	if !ok {
		t.Fatal("expected TTFT stats in aggregated")
	}
	if ttftStats.Count != 5 {
		t.Fatalf("expected 5 TTFT measurements, got %d", ttftStats.Count)
	}
	if ttftStats.Mean < time.Millisecond {
		t.Fatalf("TTFT mean too low: %s", ttftStats.Mean)
	}
	if ttftStats.Min > ttftStats.Max {
		t.Fatalf("min > max: min=%s max=%s", ttftStats.Min, ttftStats.Max)
	}
	if ttftStats.P95 < ttftStats.Mean {
		t.Fatalf("p95 < mean: p95=%s mean=%s", ttftStats.P95, ttftStats.Mean)
	}

	e2eStats, ok := run.Aggregated[testbed.SegmentTotalE2E]
	if !ok {
		t.Fatal("expected TotalE2E stats in aggregated")
	}
	if e2eStats.Count != 5 {
		t.Fatalf("expected 5 E2E measurements, got %d", e2eStats.Count)
	}
}

func TestProfilerDiff(t *testing.T) {
	cfg := testbed.DefaultTestConfig()
	buf := testbed.NewEventBuffer()
	p := NewProfiler(cfg, buf)

	inst := testbed.NewInstrument(buf)

	rid := inst.NewRequestID()
	inst.RequestStart(rid)
	timer := inst.StartSegment(rid, testbed.SegmentTTFT)
	time.Sleep(1 * time.Millisecond)
	timer.Stop()
	inst.RequestEnd(rid, 0)

	previous := p.BuildProfile()

	buf.Reset()

	rid2 := inst.NewRequestID()
	inst.RequestStart(rid2)
	timer2 := inst.StartSegment(rid2, testbed.SegmentTTFT)
	time.Sleep(5 * time.Millisecond)
	timer2.Stop()
	inst.RequestEnd(rid2, 0)

	diff := p.Diff(previous)

	ttftDiff, ok := diff.Segments[testbed.SegmentTTFT]
	if !ok {
		t.Fatal("expected TTFT in diff")
	}
	if ttftDiff.Previous == nil || ttftDiff.Current == nil {
		t.Fatal("expected both previous and current stats")
	}
	if ttftDiff.MeanDelta <= 0 {
		t.Fatalf("expected positive mean delta (slower run), got %s", ttftDiff.MeanDelta)
	}
}

func TestProfileRunSummaryTable(t *testing.T) {
	cfg := testbed.DefaultTestConfig()
	buf := testbed.NewEventBuffer()
	p := NewProfiler(cfg, buf)

	inst := testbed.NewInstrument(buf)
	rid := inst.NewRequestID()
	inst.RequestStart(rid)
	timer := inst.StartSegment(rid, testbed.SegmentTTFT)
	timer.Stop()
	inst.RequestEnd(rid, 0)

	run := p.BuildProfile()
	table := run.SummaryTable()
	if table == "" {
		t.Fatal("expected non-empty summary table")
	}
}

func TestProfileRunToJSON(t *testing.T) {
	cfg := testbed.DefaultTestConfig()
	buf := testbed.NewEventBuffer()
	p := NewProfiler(cfg, buf)

	inst := testbed.NewInstrument(buf)
	rid := inst.NewRequestID()
	inst.RequestStart(rid)
	timer := inst.StartSegment(rid, testbed.SegmentTTFT)
	timer.Stop()
	inst.RequestEnd(rid, 0)

	run := p.BuildProfile()
	b, err := run.ToJSON()
	if err != nil {
		t.Fatalf("JSON marshal failed: %v", err)
	}
	if len(b) == 0 {
		t.Fatal("expected non-empty JSON output")
	}
}
