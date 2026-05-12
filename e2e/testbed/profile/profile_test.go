package profile

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/e2e/testbed"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
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

	assert.Len(t, run.Requests, 5)

	ttftStats, ok := run.Aggregated[testbed.SegmentTTFT]
	require.True(t, ok, "expected TTFT stats in aggregated")
	assert.Equal(t, 5, ttftStats.Count)
	assert.GreaterOrEqual(t, ttftStats.Mean, time.Millisecond)
	assert.LessOrEqual(t, ttftStats.Min, ttftStats.Max)
	assert.GreaterOrEqual(t, ttftStats.P95, ttftStats.Mean)

	e2eStats, ok := run.Aggregated[testbed.SegmentTotalE2E]
	require.True(t, ok, "expected TotalE2E stats in aggregated")
	assert.Equal(t, 5, e2eStats.Count)
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
	require.True(t, ok, "expected TTFT in diff")
	require.NotNil(t, ttftDiff.Previous)
	require.NotNil(t, ttftDiff.Current)
	assert.Positive(t, ttftDiff.MeanDelta)
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
	assert.NotEmpty(t, run.SummaryTable())
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
	require.NoError(t, err)
	assert.NotEmpty(t, b)
}
