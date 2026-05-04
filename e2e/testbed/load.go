package testbed

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type LoadResult struct {
	TotalRequests  int
	SuccessCount   int
	ErrorCount     int
	TotalDuration  time.Duration
	ProfileRun     *ProfileRun
	RequestResults []RequestResult
}

type RequestResult struct {
	Index      int
	StatusCode int
	Error      error
	Duration   time.Duration
	UserIndex  int
	ModelID    string

	QueueWaitMs      int64
	ProviderLatencyMs int64
}

type ProfileRun struct {
	SegmentTimings map[Segment][]time.Duration
	TTFTs          []time.Duration
}

type UserPool struct {
	users []UserAccount
	next  atomic.Int64
}

func NewUserPool(users []UserAccount) *UserPool {
	return &UserPool{users: users}
}

func (up *UserPool) Next() UserAccount {
	idx := int(up.next.Add(1)-1) % len(up.users)
	return up.users[idx]
}

func (up *UserPool) Count() int {
	return len(up.users)
}

type ModelSelector struct {
	models []string
	next   atomic.Int64
}

func NewModelSelector(modelIDs []string) *ModelSelector {
	return &ModelSelector{models: modelIDs}
}

func (ms *ModelSelector) Next() string {
	if len(ms.models) == 0 {
		return ""
	}
	idx := int(ms.next.Add(1)-1) % len(ms.models)
	return ms.models[idx]
}

type LoadGenerator struct {
	Suite         *Suite
	Config        RequestConfig
	Auth          string
	UserPool      *UserPool
	ModelSelector *ModelSelector
}

func NewLoadGenerator(suite *Suite, cfg RequestConfig) *LoadGenerator {
	lg := &LoadGenerator{
		Suite:  suite,
		Config: cfg,
		Auth:   "testbed-admin-key",
	}
	if len(suite.Users) > 0 {
		lg.UserPool = NewUserPool(suite.Users)
	}
	if len(suite.Config.AllModelIDs()) > 0 {
		lg.ModelSelector = NewModelSelector(suite.Config.AllModelIDs())
	}
	return lg
}

func (lg *LoadGenerator) WithAuth(apiKey string) *LoadGenerator {
	lg.Auth = apiKey
	return lg
}

func (lg *LoadGenerator) WithUserPool(pool *UserPool) *LoadGenerator {
	lg.UserPool = pool
	return lg
}

func (lg *LoadGenerator) WithModelSelector(selector *ModelSelector) *LoadGenerator {
	lg.ModelSelector = selector
	return lg
}

func (lg *LoadGenerator) Run() *LoadResult {
	result := &LoadResult{
		TotalRequests: lg.Config.TotalRequests,
	}
	segmentTimings := make(map[Segment][]time.Duration)
	var timingsMu sync.Mutex
	var successCount atomic.Int32
	var errorCount atomic.Int32

	start := time.Now()

	sem := make(chan struct{}, lg.Config.Concurrency)
	var wg sync.WaitGroup
	wg.Add(lg.Config.TotalRequests)

	requestResults := make([]RequestResult, lg.Config.TotalRequests)

	for i := 0; i < lg.Config.TotalRequests; i++ {
		sem <- struct{}{}
		go func(idx int) {
			defer wg.Done()
			defer func() { <-sem }()

			reqStart := time.Now()

			modelID := lg.Config.ModelID
			if modelID == "" && lg.ModelSelector != nil {
				modelID = lg.ModelSelector.Next()
			}
			if modelID == "" {
				modelID = lg.Suite.PrimaryModelID()
			}

			auth := lg.Auth
			var userIndex int
			if lg.UserPool != nil {
				user := lg.UserPool.Next()
				auth = user.APIKey
				for ui, u := range lg.Suite.Users {
					if u.AccountID == user.AccountID {
						userIndex = ui
						break
					}
				}
			}

			body := map[string]any{
				"model":       modelID,
				"messages":    []map[string]string{{"role": "user", "content": fmt.Sprintf("What is %d+%d? Answer with just the number.", idx, idx+1)}},
				"stream":      lg.Config.Streaming,
				"max_tokens":  lg.Config.MaxTokens,
				"temperature": lg.Config.Temperature,
			}
			bodyJSON, _ := json.Marshal(body)

			req, err := http.NewRequestWithContext(lg.Suite.Ctx, http.MethodPost,
				lg.Suite.Coordinator.BaseURL()+"/v1/chat/completions", strings.NewReader(string(bodyJSON)))
			if err != nil {
				errorCount.Add(1)
				requestResults[idx] = RequestResult{Index: idx, Error: err, UserIndex: userIndex, ModelID: modelID}
				return
			}
			req.Header.Set("Authorization", "Bearer "+auth)
			req.Header.Set("Content-Type", "application/json")

			resp, err := (&http.Client{Timeout: 300 * time.Second}).Do(req)
			e2eDuration := time.Since(reqStart)

			if err != nil {
				errorCount.Add(1)
				requestResults[idx] = RequestResult{Index: idx, Error: err, Duration: e2eDuration, UserIndex: userIndex, ModelID: modelID}
				return
			}

			respBody, _ := io.ReadAll(resp.Body)
			resp.Body.Close()

			rr := RequestResult{
				Index:      idx,
				StatusCode: resp.StatusCode,
				Duration:   e2eDuration,
				UserIndex:  userIndex,
				ModelID:    modelID,
			}

			if v := resp.Header.Get("X-Queue-Wait-Ms"); v != "" {
				rr.QueueWaitMs, _ = strconv.ParseInt(v, 10, 64)
			}
			if v := resp.Header.Get("X-Provider-Latency-Ms"); v != "" {
				rr.ProviderLatencyMs, _ = strconv.ParseInt(v, 10, 64)
			}

			if resp.StatusCode == http.StatusOK {
				successCount.Add(1)

				timingsMu.Lock()
				segmentTimings[SegmentClientToCoordinator] = append(segmentTimings[SegmentClientToCoordinator], e2eDuration)
				if rr.QueueWaitMs > 0 {
					segmentTimings[SegmentQueueWait] = append(segmentTimings[SegmentQueueWait], time.Duration(rr.QueueWaitMs)*time.Millisecond)
				}
				if rr.ProviderLatencyMs > 0 {
					segmentTimings[SegmentCoordinatorToProvider] = append(segmentTimings[SegmentCoordinatorToProvider], time.Duration(rr.ProviderLatencyMs)*time.Millisecond)
				}
				coordinatorToClient := e2eDuration - time.Duration(rr.QueueWaitMs)*time.Millisecond - time.Duration(rr.ProviderLatencyMs)*time.Millisecond
				if coordinatorToClient > 0 {
					segmentTimings[SegmentProviderToClient] = append(segmentTimings[SegmentProviderToClient], coordinatorToClient)
				}
				timingsMu.Unlock()

				if lg.Config.Streaming {
					ttft := lg.extractTTFT(respBody)
					if ttft > 0 {
						timingsMu.Lock()
						segmentTimings[SegmentTTFT] = append(segmentTimings[SegmentTTFT], ttft)
						timingsMu.Unlock()
					}
				}
			} else {
				errorCount.Add(1)
				rr.Error = fmt.Errorf("status %d: %s", resp.StatusCode, string(respBody[:min(len(respBody), 200)]))
			}

			requestResults[idx] = rr
		}(i)
	}

	wg.Wait()

	result.TotalDuration = time.Since(start)
	result.SuccessCount = int(successCount.Load())
	result.ErrorCount = int(errorCount.Load())
	result.RequestResults = requestResults
	result.ProfileRun = &ProfileRun{SegmentTimings: segmentTimings}

	return result
}

func (lg *LoadGenerator) extractTTFT(body []byte) time.Duration {
	var resp struct {
		Usage struct {
			PromptTokens     int `json:"prompt_tokens"`
			CompletionTokens int `json:"completion_tokens"`
		} `json:"usage"`
	}
	json.Unmarshal(body, &resp)
	if resp.Usage.CompletionTokens > 0 {
		return 0
	}
	return 0
}

func (r *LoadResult) SummaryTable() string {
	var s strings.Builder

	s.WriteString(fmt.Sprintf("%-20s %d\n", "Total Requests:", r.TotalRequests))
	s.WriteString(fmt.Sprintf("%-20s %d\n", "Success:", r.SuccessCount))
	s.WriteString(fmt.Sprintf("%-20s %d\n", "Errors:", r.ErrorCount))
	s.WriteString(fmt.Sprintf("%-20s %s\n", "Total Duration:", r.TotalDuration.Round(time.Millisecond)))
	if r.SuccessCount > 0 {
		s.WriteString(fmt.Sprintf("%-20s %.1f req/s\n", "Throughput:", float64(r.SuccessCount)/r.TotalDuration.Seconds()))
	}

	if r.ProfileRun != nil && len(r.ProfileRun.SegmentTimings) > 0 {
		s.WriteString("\n")
		s.WriteString(fmt.Sprintf("%-30s %8s %8s %8s %8s %8s\n", "SEGMENT", "COUNT", "MEAN", "P50", "P95", "MAX"))
		s.WriteString("─────────────────────────────────────────────────────────────────────\n")

		for _, seg := range []Segment{
			SegmentClientToCoordinator,
			SegmentQueueWait,
			SegmentCoordinatorToProvider,
			SegmentProviderToClient,
			SegmentTTFT,
		} {
			durations, ok := r.ProfileRun.SegmentTimings[seg]
			if !ok || len(durations) == 0 {
				continue
			}
			stats := computeStats(durations)
			s.WriteString(fmt.Sprintf("%-30s %8d %8s %8s %8s %8s\n",
				seg, stats.Count,
				stats.Mean.Round(time.Millisecond),
				stats.Median.Round(time.Millisecond),
				stats.P95.Round(time.Millisecond),
				stats.Max.Round(time.Millisecond),
			))
		}
	}

	return s.String()
}

type simpleStats struct {
	Count  int
	Mean   time.Duration
	Median time.Duration
	P95    time.Duration
	Max    time.Duration
}

func computeStats(durations []time.Duration) simpleStats {
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
