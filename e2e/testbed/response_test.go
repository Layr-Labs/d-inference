package testbed

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestLoadGeneratorStreamingMeasuresContentAndFullDrain(t *testing.T) {
	contentFlushed := make(chan struct{})
	finishStream := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n")
		w.(http.Flusher).Flush()
		_, _ = fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"4\"}}]}\n\n")
		w.(http.Flusher).Flush()
		close(contentFlushed)
		<-finishStream
		_, _ = fmt.Fprint(w, "data: [DONE]\n\n")
	}))
	t.Cleanup(server.Close)

	generator := NewLoadGenerator(loadTestSuite(server.URL, []string{"model-a"}, 1), RequestConfig{
		MaxTokens:         8,
		Streaming:         true,
		Concurrency:       1,
		TotalRequests:     1,
		ExpectedSuccesses: 1,
		MinimumSuccesses:  1,
	})
	type runResult struct {
		result *LoadResult
		err    error
	}
	runDone := make(chan runResult, 1)
	go func() {
		result, err := generator.Run()
		runDone <- runResult{result: result, err: err}
	}()

	<-contentFlushed
	select {
	case <-runDone:
		t.Fatal("load run returned before the streaming response body drained")
	default:
	}
	close(finishStream)

	run := <-runDone
	require.NoError(t, run.err)
	require.Len(t, run.result.RequestResults, 1)
	request := run.result.RequestResults[0]
	assert.Positive(t, request.TTFT)
	assert.Greater(t, request.Duration, request.TTFT)
	require.Len(t, run.result.ProfileRun.SegmentTimings[SegmentTotalE2E], 1)
	assert.Equal(t, request.Duration, run.result.ProfileRun.SegmentTimings[SegmentTotalE2E][0])
	assert.Equal(t, []time.Duration{request.TTFT}, run.result.ProfileRun.TTFTs)
}

func TestLoadGeneratorUsesXTimingForStreamingTTFTFallback(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("X-Timing", `{"parse_us":1,"reserve_us":2,"media_fetch_us":3,"route_us":4,"queue_us":5,"encrypt_us":6,"dispatch_us":7,"provider_us":8}`)
		_, _ = fmt.Fprint(w, "data: [DONE]\n\n")
	}))
	t.Cleanup(server.Close)

	result, err := NewLoadGenerator(loadTestSuite(server.URL, []string{"model-a"}, 1), RequestConfig{
		MaxTokens:         8,
		Streaming:         true,
		Concurrency:       1,
		TotalRequests:     1,
		ExpectedSuccesses: 1,
		MinimumSuccesses:  1,
	}).Run()

	require.NoError(t, err)
	require.Len(t, result.RequestResults, 1)
	assert.Equal(t, 8*time.Microsecond, result.RequestResults[0].TTFT)
}

func TestLoadGeneratorUsesObservedStreamingTTFTWithValidXTiming(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("X-Timing", `{"parse_us":1,"reserve_us":2,"media_fetch_us":3,"route_us":4,"queue_us":5,"encrypt_us":6,"dispatch_us":7,"provider_us":3600000000}`)
		_, _ = fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n")
		_, _ = fmt.Fprint(w, "data: [DONE]\n\n")
	}))
	t.Cleanup(server.Close)

	result, err := NewLoadGenerator(loadTestSuite(server.URL, []string{"model-a"}, 1), RequestConfig{
		MaxTokens:         8,
		Streaming:         true,
		Concurrency:       1,
		TotalRequests:     1,
		ExpectedSuccesses: 1,
		MinimumSuccesses:  1,
	}).Run()

	require.NoError(t, err)
	require.Len(t, result.RequestResults, 1)
	request := result.RequestResults[0]
	assert.NoError(t, request.Error)
	assert.Positive(t, request.TTFT)
	assert.Less(t, request.TTFT, time.Hour)
	assert.Equal(t, 1, result.SuccessCount)
	assert.Equal(t, 0, result.ErrorCount)
}

func TestLoadGeneratorRejectsInvalidXTimingWithObservedStreamingTTFT(t *testing.T) {
	tests := []struct {
		name        string
		header      string
		errorSubstr string
	}{
		{
			name:        "malformed",
			header:      "not-json",
			errorSubstr: "decode X-Timing",
		},
		{
			name:        "negative",
			header:      `{"parse_us":1,"reserve_us":2,"media_fetch_us":3,"route_us":4,"queue_us":-5,"encrypt_us":6,"dispatch_us":7,"provider_us":8}`,
			errorSubstr: "X-Timing queue_us must be non-negative",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.Header().Set("Content-Type", "text/event-stream")
				w.Header().Set("X-Timing", test.header)
				_, _ = fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n")
				_, _ = fmt.Fprint(w, "data: [DONE]\n\n")
			}))
			t.Cleanup(server.Close)

			result, err := NewLoadGenerator(loadTestSuite(server.URL, []string{"model-a"}, 1), RequestConfig{
				MaxTokens:         8,
				Streaming:         true,
				Concurrency:       1,
				TotalRequests:     1,
				ExpectedSuccesses: 1,
				MinimumSuccesses:  1,
			}).Run()

			require.Error(t, err)
			assert.ErrorContains(t, err, test.errorSubstr)
			require.Len(t, result.RequestResults, 1)
			request := result.RequestResults[0]
			require.Error(t, request.Error)
			assert.ErrorContains(t, request.Error, test.errorSubstr)
			assert.Positive(t, request.TTFT)
			assert.Equal(t, 0, result.SuccessCount)
			assert.Equal(t, 1, result.ErrorCount)
			assert.Empty(t, result.ProfileRun.SegmentTimings)
			assert.Empty(t, result.ProfileRun.TTFTs)
		})
	}
}

func TestSSELineHasContent(t *testing.T) {
	assert.False(t, sseLineHasContent([]byte("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n")))
	assert.False(t, sseLineHasContent([]byte("data: {\"choices\":[],\"usage\":{\"completion_tokens\":1}}\n")))
	assert.False(t, sseLineHasContent([]byte("data: [DONE]\n")))
	assert.True(t, sseLineHasContent([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"token\"}}]}\n")))
	assert.True(t, sseLineHasContent([]byte("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{}]}}]}\n")))
}
