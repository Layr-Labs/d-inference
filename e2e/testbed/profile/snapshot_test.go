package profile

import (
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/e2e/testbed"
	"github.com/stretchr/testify/require"
)

func TestProfileKeepsStartOrderRepeatedStartsAndErrorCount(t *testing.T) {
	buffer := testbed.NewEventBuffer()
	for _, event := range []testbed.Event{
		{Kind: testbed.EventSegmentEnd, RequestID: "b", Segment: testbed.SegmentTTFT, Duration: time.Millisecond},
		{Kind: testbed.EventRequestStart, RequestID: "a"},
		{Kind: testbed.EventError, RequestID: "b"},
		{Kind: testbed.EventRequestStart, RequestID: "b"},
		{Kind: testbed.EventRequestStart, RequestID: "a"},
		{Kind: testbed.EventStreamChunk, RequestID: "a"},
		{Kind: testbed.EventError, RequestID: "b"},
		{Kind: testbed.EventSegmentEnd, RequestID: "orphan", Segment: testbed.SegmentTTFT, Duration: time.Hour},
	} {
		buffer.Consume(event)
	}
	run := NewProfiler(testbed.TestConfig{}, buffer).BuildProfile()
	require.Len(t, run.Requests, 3)
	require.Equal(t, "a", run.Requests[0].RequestID)
	require.Equal(t, "b", run.Requests[1].RequestID)
	require.Equal(t, "a", run.Requests[2].RequestID)
	require.Equal(t, 1, run.Requests[0].Chunks)
	require.Equal(t, run.Requests[0], run.Requests[2])
	require.Equal(t, 2, run.Errors)
	require.Equal(t, time.Millisecond, run.Aggregated[testbed.SegmentTTFT].Total)
}

func TestProfileSummaryShowsEachSegmentOnce(t *testing.T) {
	run := &ProfileRun{Aggregated: map[testbed.Segment]*SegmentStats{
		testbed.SegmentTotalE2E: {Count: 1, Mean: time.Second},
	}}
	require.Equal(t, 1, strings.Count(run.SummaryTable(), string(testbed.SegmentTotalE2E)))
}
