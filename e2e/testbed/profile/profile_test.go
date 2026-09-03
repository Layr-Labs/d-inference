package profile

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/e2e/testbed"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func recordProfileRequest(
	buffer *testbed.EventBuffer,
	requestID string,
	at time.Time,
	segments map[testbed.Segment]time.Duration,
) {
	buffer.Consume(testbed.Event{
		Kind:      testbed.EventRequestStart,
		RequestID: requestID,
		Timestamp: at,
	})
	for segment, duration := range segments {
		buffer.Consume(testbed.Event{
			Kind:      testbed.EventSegmentEnd,
			RequestID: requestID,
			Segment:   segment,
			Timestamp: at.Add(duration),
			Duration:  duration,
		})
	}
	buffer.Consume(testbed.Event{
		Kind:      testbed.EventRequestEnd,
		RequestID: requestID,
		Timestamp: at.Add(time.Second),
	})
}

func TestProfilerBuildProfile(t *testing.T) {
	cfg := testbed.DefaultTestConfig()
	buf := testbed.NewEventBuffer()
	p := NewProfiler(cfg, buf)

	base := time.Unix(1_700_000_000, 0)
	for i := range 5 {
		recordProfileRequest(buf, fmt.Sprintf("request-%d", i), base.Add(time.Duration(i)*time.Second), map[testbed.Segment]time.Duration{
			testbed.SegmentTTFT:     2 * time.Millisecond,
			testbed.SegmentTotalE2E: 3 * time.Millisecond,
		})
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

	base := time.Unix(1_700_000_000, 0)
	recordProfileRequest(buf, "previous", base, map[testbed.Segment]time.Duration{
		testbed.SegmentTTFT: time.Millisecond,
	})

	previous := p.BuildProfile()

	buf.Reset()
	recordProfileRequest(buf, "current", base.Add(time.Second), map[testbed.Segment]time.Duration{
		testbed.SegmentTTFT: 5 * time.Millisecond,
	})

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

	recordProfileRequest(buf, "summary", time.Unix(1_700_000_000, 0), map[testbed.Segment]time.Duration{
		testbed.SegmentTTFT: time.Millisecond,
	})

	run := p.BuildProfile()
	assert.NotEmpty(t, run.SummaryTable())
}

func TestProfileRunToJSON(t *testing.T) {
	cfg := testbed.DefaultTestConfig()
	buf := testbed.NewEventBuffer()
	p := NewProfiler(cfg, buf)

	recordProfileRequest(buf, "json", time.Unix(1_700_000_000, 0), map[testbed.Segment]time.Duration{
		testbed.SegmentTTFT: time.Millisecond,
	})

	run := p.BuildProfile()
	b, err := run.ToJSON()
	require.NoError(t, err)
	assert.NotEmpty(t, b)
}
