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

	recordTTFT := func(requestID string, duration time.Duration) {
		startedAt := time.Date(2026, time.January, 1, 0, 0, 0, 0, time.UTC)
		buf.Consume(testbed.Event{
			Kind: testbed.EventRequestStart, RequestID: requestID, Timestamp: startedAt,
		})
		buf.Consume(testbed.Event{
			Kind: testbed.EventSegmentStart, RequestID: requestID,
			Segment: testbed.SegmentTTFT, Timestamp: startedAt,
		})
		buf.Consume(testbed.Event{
			Kind: testbed.EventSegmentEnd, RequestID: requestID,
			Segment: testbed.SegmentTTFT, Timestamp: startedAt.Add(duration), Duration: duration,
		})
		buf.Consume(testbed.Event{
			Kind: testbed.EventRequestEnd, RequestID: requestID, Timestamp: startedAt.Add(duration),
		})
	}
	recordTTFT("previous", time.Millisecond)

	previous := p.BuildProfile()

	buf.Reset()

	recordTTFT("current", 5*time.Millisecond)

	diff := p.Diff(previous)

	ttftDiff, ok := diff.Segments[testbed.SegmentTTFT]
	require.True(t, ok, "expected TTFT in diff")
	require.NotNil(t, ttftDiff.Previous)
	require.NotNil(t, ttftDiff.Current)
	assert.Equal(t, 1, ttftDiff.Previous.Count)
	assert.Equal(t, 1, ttftDiff.Current.Count)
	assert.Equal(t, time.Millisecond, ttftDiff.Previous.Mean)
	assert.Equal(t, 5*time.Millisecond, ttftDiff.Current.Mean)
	assert.Equal(t, 4*time.Millisecond, ttftDiff.MeanDelta)
	assert.Equal(t, 4*time.Millisecond, ttftDiff.P95Delta)
	assert.Equal(t, 400.0, ttftDiff.MeanPctChange)
	assert.Equal(t, 400.0, ttftDiff.P95PctChange)
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
