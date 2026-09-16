package testbed

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func fixtureLoad(server *httptest.Server) *LoadGenerator {
	return &LoadGenerator{
		Suite:  &Suite{Ctx: context.Background(), Coordinator: &Coordinator{baseURL: server.URL}},
		Config: RequestConfig{Concurrency: 1, TotalRequests: 1, ModelID: "fixture"},
	}
}

func TestLoadCountsTruncatedSuccessBodyAsFailure(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Length", "100")
		fmt.Fprint(w, "truncated")
	}))
	defer server.Close()
	result := fixtureLoad(server).Run()
	require.Equal(t, 0, result.SuccessCount)
	require.Equal(t, 1, result.ErrorCount)
	require.Equal(t, http.StatusOK, result.RequestResults[0].StatusCode)
	require.ErrorContains(t, result.RequestResults[0].Error, "unexpected EOF")
	require.Empty(t, result.ProfileRun.SegmentTimings)
}

func TestLoadDurationIncludesResponseBody(t *testing.T) {
	bodyHold := make(chan time.Duration, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		start := time.Now()
		time.Sleep(30 * time.Millisecond)
		bodyHold <- time.Since(start)
		fmt.Fprint(w, "complete")
	}))
	defer server.Close()
	result := fixtureLoad(server).Run()
	require.Equal(t, 1, result.SuccessCount)
	require.GreaterOrEqual(t, result.RequestResults[0].Duration, <-bodyHold)
	require.Equal(t, result.RequestResults[0].Duration, result.ProfileRun.SegmentTimings[SegmentTotalE2E][0])
}
