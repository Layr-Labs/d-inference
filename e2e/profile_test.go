package e2e

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/eigeninference/d-inference/e2e/testbed"
	tbprofile "github.com/eigeninference/d-inference/e2e/testbed/profile"
)

func TestProfile_SingleProviderStreaming(t *testing.T) {
	s := startSuite(t)

	cfg := testbed.DefaultRequestConfig()
	cfg.Streaming = true
	cfg.TotalRequests = 20
	cfg.Concurrency = 5
	cfg.MaxTokens = 64

	result := runProfiledLoad(t, s, cfg)

	t.Logf("\n%s", result.SummaryTable())

	buf := testbed.NewEventBuffer()
	inst := testbed.NewInstrument(buf)
	p := tbprofile.NewProfiler(testbed.DefaultTestConfig(), buf)

	for i := 0; i < cfg.TotalRequests; i++ {
		ri := inst.NewRequest()
		timer := ri.StartSegment(testbed.SegmentClientToCoordinator)

		resp := postChatCompletionsWithConfig(t, s, cfg, fmt.Sprintf("What is %d*%d?", i, i+1))
		respBody, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		timer.Stop()

		if resp.StatusCode == http.StatusOK {
			ri.EndWithDuration(0)

			if cfg.Streaming {
				var parsed struct {
					Choices []struct {
						Message struct {
							Content string `json:"content"`
						} `json:"message"`
					} `json:"choices"`
				}
				json.Unmarshal(respBody, &parsed)
			}
		} else {
			ri.Error(fmt.Errorf("status %d", resp.StatusCode))
		}
	}

	run := p.BuildProfile()
	t.Logf("\nSegment Profile:\n%s", run.SummaryTable())

	require.Greater(t, result.SuccessCount, 0, "at least some requests should succeed")
}

func TestProfile_SingleProviderNonStreaming(t *testing.T) {
	s := startSuite(t)

	cfg := testbed.DefaultRequestConfig()
	cfg.Streaming = false
	cfg.TotalRequests = 10
	cfg.Concurrency = 3
	cfg.MaxTokens = 32

	result := runProfiledLoad(t, s, cfg)

	t.Logf("\n%s", result.SummaryTable())
	require.Greater(t, result.SuccessCount, 0)
}

func TestProfile_HighConcurrency(t *testing.T) {
	s := startSuite(t)

	cfg := testbed.DefaultRequestConfig()
	cfg.Streaming = true
	cfg.TotalRequests = 30
	cfg.Concurrency = 10
	cfg.MaxTokens = 32

	result := runProfiledLoad(t, s, cfg)

	t.Logf("\n%s", result.SummaryTable())
	require.Greater(t, result.SuccessCount, 0)

	if result.SuccessCount > 1 {
		successDurations := make([]time.Duration, 0, result.SuccessCount)
		for _, rr := range result.RequestResults {
			if rr.StatusCode == http.StatusOK {
				successDurations = append(successDurations, rr.Duration)
			}
		}
		stats := computeSimpleStats(successDurations)
		t.Logf("Latency: mean=%s p50=%s p95=%s max=%s",
			stats.Mean.Round(time.Millisecond),
			stats.Median.Round(time.Millisecond),
			stats.P95.Round(time.Millisecond),
			stats.Max.Round(time.Millisecond),
		)
	}
}

func runProfiledLoad(t *testing.T, s *testbed.Suite, cfg testbed.RequestConfig) *testbed.LoadResult {
	t.Helper()

	lg := testbed.NewLoadGenerator(s, cfg)
	result := lg.Run()

	if result.ErrorCount > 0 {
		var sampleErrors []string
		for _, rr := range result.RequestResults {
			if rr.Error != nil && len(sampleErrors) < 3 {
				sampleErrors = append(sampleErrors, rr.Error.Error())
			}
		}
		t.Logf("errors (%d/%d): %v", result.ErrorCount, result.TotalRequests, sampleErrors)
	}

	return result
}

func postChatCompletionsWithConfig(t *testing.T, s *testbed.Suite, cfg testbed.RequestConfig, prompt string) *http.Response {
	t.Helper()

	body := map[string]any{
		"model":       s.ModelID,
		"messages":    []map[string]string{{"role": "user", "content": prompt}},
		"stream":      cfg.Streaming,
		"max_tokens":  cfg.MaxTokens,
		"temperature": cfg.Temperature,
	}
	bodyJSON, _ := json.Marshal(body)

	req, err := http.NewRequestWithContext(s.Ctx, http.MethodPost,
		s.Coordinator.BaseURL()+"/v1/chat/completions", strings.NewReader(string(bodyJSON)))
	require.NoError(t, err)
	req.Header.Set("Authorization", "Bearer testbed-admin-key")
	req.Header.Set("Content-Type", "application/json")

	resp, err := (&http.Client{Timeout: httpTimeout}).Do(req)
	require.NoError(t, err)
	return resp
}

type simpleStats struct {
	Count  int
	Mean   time.Duration
	Median time.Duration
	P95    time.Duration
	Max    time.Duration
}

func computeSimpleStats(durations []time.Duration) simpleStats {
	if len(durations) == 0 {
		return simpleStats{}
	}

	sorted := make([]time.Duration, len(durations))
	copy(sorted, durations)
	for i := 0; i < len(sorted)-1; i++ {
		for j := i + 1; j < len(sorted); j++ {
			if sorted[j] < sorted[i] {
				sorted[i], sorted[j] = sorted[j], sorted[i]
			}
		}
	}

	var total time.Duration
	for _, d := range sorted {
		total += d
	}
	mean := total / time.Duration(len(sorted))
	median := sorted[len(sorted)/2]
	p95Idx := len(sorted) * 95 / 100
	if p95Idx >= len(sorted) {
		p95Idx = len(sorted) - 1
	}

	return simpleStats{
		Count:  len(sorted),
		Mean:   mean,
		Median: median,
		P95:    sorted[p95Idx],
		Max:    sorted[len(sorted)-1],
	}
}
