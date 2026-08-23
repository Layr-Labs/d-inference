package testbed

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type LoadResult struct {
	TotalRequests     int
	ExpectedSuccesses int
	MinimumSuccesses  int
	SuccessCount      int
	ErrorCount        int
	TotalDuration     time.Duration
	ProfileRun        *ProfileRun
	RequestResults    []RequestResult
	Failures          []RequestFailure
	ModelCohorts      map[string]CohortStats
	UserCohorts       map[int]CohortStats
}

type RequestResult struct {
	Index      int
	StatusCode int
	Error      error
	Duration   time.Duration
	TTFT       time.Duration
	UserIndex  int
	ModelID    string

	ParseUs      int64
	ReserveUs    int64
	MediaFetchUs int64
	RouteUs      int64
	QueueUs      int64
	EncryptUs    int64
	DispatchUs   int64
	ProviderUs   int64
}

type RequestFailure struct {
	Index     int
	UserIndex int
	ModelID   string
	Err       error
}

func (f RequestFailure) Error() string {
	return fmt.Sprintf("request %d (model=%q user=%d): %v", f.Index, f.ModelID, f.UserIndex, f.Err)
}

func (f RequestFailure) Unwrap() error {
	return f.Err
}

type CohortStats struct {
	TotalRequests int
	SuccessCount  int
	ErrorCount    int
	Failures      []RequestFailure
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
	Suite              *Suite
	Config             RequestConfig
	Auth               string
	UserPool           *UserPool
	ModelSelector      *ModelSelector
	userIndexByAccount map[string]int
}

func NewLoadGenerator(suite *Suite, cfg RequestConfig) *LoadGenerator {
	lg := &LoadGenerator{
		Suite:              suite,
		Config:             cfg,
		Auth:               "testbed-admin-key",
		userIndexByAccount: make(map[string]int, len(suite.Users)),
	}
	for i, user := range suite.Users {
		lg.userIndexByAccount[user.AccountID] = i
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

func (lg *LoadGenerator) Run() (*LoadResult, error) {
	result := &LoadResult{
		TotalRequests:     lg.Config.TotalRequests,
		ExpectedSuccesses: lg.Config.ExpectedSuccesses,
		MinimumSuccesses:  lg.Config.MinimumSuccesses,
	}
	if err := validateRequestConfig(lg.Config); err != nil {
		return result, err
	}

	segmentTimings := make(map[Segment][]time.Duration)
	var timingsMu sync.Mutex
	var successCount atomic.Int32
	var errorCount atomic.Int32

	start := time.Now()
	client := &http.Client{Timeout: 300 * time.Second}
	sem := make(chan struct{}, lg.Config.Concurrency)
	var wg sync.WaitGroup
	wg.Add(lg.Config.TotalRequests)

	requestResults := make([]RequestResult, lg.Config.TotalRequests)

	for i := range lg.Config.TotalRequests {
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
			userIndex := -1
			if lg.UserPool != nil {
				user := lg.UserPool.Next()
				auth = user.APIKey
				if idx, ok := lg.userIndexByAccount[user.AccountID]; ok {
					userIndex = idx
				}
			}

			rr := RequestResult{Index: idx, UserIndex: userIndex, ModelID: modelID}
			prompt := fmt.Sprintf("What is %d+%d? Answer with just the number.", idx, idx+1)
			if padding := lg.Config.PromptBytes - len(prompt); padding > 0 {
				prompt += strings.Repeat(" ", padding)
			}

			bodyJSON, err := json.Marshal(map[string]any{
				"model":       modelID,
				"messages":    []map[string]string{{"role": "user", "content": prompt}},
				"stream":      lg.Config.Streaming,
				"max_tokens":  lg.Config.MaxTokens,
				"temperature": lg.Config.Temperature,
			})
			if err != nil {
				rr.Error = fmt.Errorf("encode request body: %w", err)
				rr.Duration = time.Since(reqStart)
				errorCount.Add(1)
				requestResults[idx] = rr
				return
			}

			req, err := http.NewRequestWithContext(
				lg.Suite.Ctx,
				http.MethodPost,
				lg.Suite.Coordinator.BaseURL()+"/v1/chat/completions",
				bytes.NewReader(bodyJSON),
			)
			if err != nil {
				rr.Error = fmt.Errorf("create request: %w", err)
				rr.Duration = time.Since(reqStart)
				errorCount.Add(1)
				requestResults[idx] = rr
				return
			}
			req.Header.Set("Authorization", "Bearer "+auth)
			req.Header.Set("Content-Type", "application/json")

			resp, err := client.Do(req)
			if err != nil {
				rr.Error = fmt.Errorf("send request: %w", err)
				rr.Duration = time.Since(reqStart)
				errorCount.Add(1)
				requestResults[idx] = rr
				return
			}
			rr.StatusCode = resp.StatusCode

			timing, timingErr := parseResponseTiming(resp.Header.Get("X-Timing"))
			rr.ParseUs = timing.ParseUs
			rr.ReserveUs = timing.ReserveUs
			rr.MediaFetchUs = timing.MediaFetchUs
			rr.RouteUs = timing.RouteUs
			rr.QueueUs = timing.QueueUs
			rr.EncryptUs = timing.EncryptUs
			rr.DispatchUs = timing.DispatchUs
			rr.ProviderUs = timing.ProviderUs

			respBody, observedTTFT, readErr := readResponseBody(resp.Body, reqStart, lg.Config.Streaming)
			closeErr := resp.Body.Close()
			rr.Duration = time.Since(reqStart)
			rr.TTFT = observedTTFT
			if rr.TTFT <= 0 && timingErr == nil {
				rr.TTFT = timing.TTFT()
			}

			var responseErrors []error
			if timingErr != nil {
				responseErrors = append(responseErrors, fmt.Errorf("invalid X-Timing response header: %w", timingErr))
			}
			if readErr != nil {
				responseErrors = append(responseErrors, fmt.Errorf("drain response body: %w", readErr))
			}
			if closeErr != nil {
				responseErrors = append(responseErrors, fmt.Errorf("close response body: %w", closeErr))
			}
			if resp.StatusCode != http.StatusOK {
				responseErrors = append(responseErrors, fmt.Errorf(
					"status %d: %s",
					resp.StatusCode,
					strings.TrimSpace(string(respBody)),
				))
			}
			if resp.StatusCode == http.StatusOK && lg.Config.Streaming && rr.TTFT <= 0 && timingErr == nil {
				responseErrors = append(responseErrors, errors.New(
					"streaming response contained no content event and X-Timing had no positive pre-first-chunk duration",
				))
			}

			rr.Error = errors.Join(responseErrors...)
			if rr.Error != nil {
				errorCount.Add(1)
				requestResults[idx] = rr
				return
			}

			successCount.Add(1)
			timingsMu.Lock()
			segmentTimings[SegmentTotalE2E] = append(segmentTimings[SegmentTotalE2E], rr.Duration)
			appendTimingSegments(segmentTimings, rr)
			if rr.TTFT > 0 {
				segmentTimings[SegmentTTFT] = append(segmentTimings[SegmentTTFT], rr.TTFT)
			}
			timingsMu.Unlock()
			requestResults[idx] = rr
		}(i)
	}

	wg.Wait()

	result.TotalDuration = time.Since(start)
	result.SuccessCount = int(successCount.Load())
	result.ErrorCount = int(errorCount.Load())
	result.RequestResults = requestResults
	result.ProfileRun = &ProfileRun{
		SegmentTimings: segmentTimings,
		TTFTs:          append([]time.Duration(nil), segmentTimings[SegmentTTFT]...),
	}
	result.Failures, result.ModelCohorts, result.UserCohorts = buildCohorts(requestResults)

	if result.SuccessCount < lg.Config.MinimumSuccesses {
		errs := make([]error, len(result.Failures))
		for i := range result.Failures {
			errs[i] = result.Failures[i]
		}
		thresholdErr := fmt.Errorf(
			"load success threshold unmet: got %d successes, expected %d, minimum %d",
			result.SuccessCount,
			lg.Config.ExpectedSuccesses,
			lg.Config.MinimumSuccesses,
		)
		if requestErr := errors.Join(errs...); requestErr != nil {
			thresholdErr = errors.Join(thresholdErr, requestErr)
		}
		return result, thresholdErr
	}

	return result, nil
}

type responseTiming struct {
	ParseUs      int64 `json:"parse_us"`
	ReserveUs    int64 `json:"reserve_us"`
	MediaFetchUs int64 `json:"media_fetch_us"`
	RouteUs      int64 `json:"route_us"`
	QueueUs      int64 `json:"queue_us"`
	EncryptUs    int64 `json:"encrypt_us"`
	DispatchUs   int64 `json:"dispatch_us"`
	ProviderUs   int64 `json:"provider_us"`
}

func (t responseTiming) TTFT() time.Duration {
	if t.ProviderUs <= 0 {
		return 0
	}
	return time.Duration(t.ProviderUs) * time.Microsecond
}

func validateRequestConfig(cfg RequestConfig) error {
	switch {
	case cfg.TotalRequests <= 0:
		return fmt.Errorf("total requests must be positive, got %d", cfg.TotalRequests)
	case cfg.Concurrency <= 0:
		return fmt.Errorf("concurrency must be positive, got %d", cfg.Concurrency)
	case cfg.ExpectedSuccesses <= 0:
		return fmt.Errorf("expected successes must be positive, got %d", cfg.ExpectedSuccesses)
	case cfg.ExpectedSuccesses > cfg.TotalRequests:
		return fmt.Errorf(
			"expected successes %d exceed total requests %d",
			cfg.ExpectedSuccesses,
			cfg.TotalRequests,
		)
	case cfg.MinimumSuccesses <= 0:
		return fmt.Errorf("minimum successes must be positive, got %d", cfg.MinimumSuccesses)
	case cfg.MinimumSuccesses > cfg.ExpectedSuccesses:
		return fmt.Errorf(
			"minimum successes %d exceed expected successes %d",
			cfg.MinimumSuccesses,
			cfg.ExpectedSuccesses,
		)
	default:
		return nil
	}
}

func parseResponseTiming(header string) (responseTiming, error) {
	if header == "" {
		return responseTiming{}, nil
	}
	var timing responseTiming
	if err := json.Unmarshal([]byte(header), &timing); err != nil {
		return responseTiming{}, fmt.Errorf("decode X-Timing %q: %w", header, err)
	}
	if err := validateTimingValue("parse_us", timing.ParseUs); err != nil {
		return responseTiming{}, err
	}
	if err := validateTimingValue("reserve_us", timing.ReserveUs); err != nil {
		return responseTiming{}, err
	}
	if err := validateTimingValue("media_fetch_us", timing.MediaFetchUs); err != nil {
		return responseTiming{}, err
	}
	if err := validateTimingValue("route_us", timing.RouteUs); err != nil {
		return responseTiming{}, err
	}
	if err := validateTimingValue("queue_us", timing.QueueUs); err != nil {
		return responseTiming{}, err
	}
	if err := validateTimingValue("encrypt_us", timing.EncryptUs); err != nil {
		return responseTiming{}, err
	}
	if err := validateTimingValue("dispatch_us", timing.DispatchUs); err != nil {
		return responseTiming{}, err
	}
	if err := validateTimingValue("provider_us", timing.ProviderUs); err != nil {
		return responseTiming{}, err
	}
	return timing, nil
}

func validateTimingValue(name string, value int64) error {
	if value < 0 {
		return fmt.Errorf("X-Timing %s must be non-negative, got %d", name, value)
	}
	return nil
}

func readResponseBody(body io.Reader, requestStart time.Time, streaming bool) ([]byte, time.Duration, error) {
	if !streaming {
		data, err := io.ReadAll(body)
		return data, 0, err
	}

	reader := bufio.NewReader(body)
	var response bytes.Buffer
	var ttft time.Duration
	for {
		line, err := reader.ReadBytes('\n')
		_, _ = response.Write(line)
		if ttft <= 0 && sseLineHasContent(line) {
			ttft = time.Since(requestStart)
		}
		if err == nil {
			continue
		}
		if errors.Is(err, io.EOF) {
			return response.Bytes(), ttft, nil
		}
		return response.Bytes(), ttft, err
	}
}

func sseLineHasContent(line []byte) bool {
	line = bytes.TrimSpace(line)
	if !bytes.HasPrefix(line, []byte("data:")) {
		return false
	}
	payload := bytes.TrimSpace(bytes.TrimPrefix(line, []byte("data:")))
	if len(payload) == 0 || bytes.Equal(payload, []byte("[DONE]")) {
		return false
	}

	var event map[string]json.RawMessage
	if err := json.Unmarshal(payload, &event); err != nil {
		return false
	}
	return eventHasContent(event)
}

func eventHasContent(event map[string]json.RawMessage) bool {
	for _, key := range []string{
		"content",
		"reasoning",
		"reasoning_content",
		"reasoning_details",
		"refusal",
		"text",
		"tool_calls",
		"function_call",
		"audio",
	} {
		if rawHasContent(event[key]) {
			return true
		}
	}
	for _, key := range []string{"choices", "output"} {
		var nested []map[string]json.RawMessage
		if err := json.Unmarshal(event[key], &nested); err == nil {
			for _, item := range nested {
				if eventHasContent(item) {
					return true
				}
			}
		}
	}
	for _, key := range []string{"delta", "message"} {
		var nested map[string]json.RawMessage
		if err := json.Unmarshal(event[key], &nested); err == nil && eventHasContent(nested) {
			return true
		}
	}
	return false
}

func rawHasContent(raw json.RawMessage) bool {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 ||
		bytes.Equal(raw, []byte("null")) ||
		bytes.Equal(raw, []byte(`""`)) ||
		bytes.Equal(raw, []byte("[]")) ||
		bytes.Equal(raw, []byte("{}")) {
		return false
	}
	if raw[0] != '"' {
		return true
	}
	var value string
	return json.Unmarshal(raw, &value) == nil && value != ""
}

func appendTimingSegments(segmentTimings map[Segment][]time.Duration, rr RequestResult) {
	appendTimingSegment(segmentTimings, SegmentParse, rr.ParseUs)
	appendTimingSegment(segmentTimings, SegmentReserve, rr.ReserveUs)
	appendTimingSegment(segmentTimings, SegmentRoute, rr.RouteUs)
	appendTimingSegment(segmentTimings, SegmentQueueWait, rr.QueueUs)
	appendTimingSegment(segmentTimings, SegmentEncrypt, rr.EncryptUs)
	appendTimingSegment(segmentTimings, SegmentDispatch, rr.DispatchUs)
	appendTimingSegment(segmentTimings, SegmentCoordinatorToProvider, rr.ProviderUs)
}

func appendTimingSegment(segmentTimings map[Segment][]time.Duration, segment Segment, micros int64) {
	if micros > 0 {
		segmentTimings[segment] = append(segmentTimings[segment], time.Duration(micros)*time.Microsecond)
	}
}

func buildCohorts(results []RequestResult) ([]RequestFailure, map[string]CohortStats, map[int]CohortStats) {
	failures := make([]RequestFailure, 0)
	models := make(map[string]CohortStats)
	users := make(map[int]CohortStats)
	for _, result := range results {
		modelStats := models[result.ModelID]
		userStats := users[result.UserIndex]
		modelStats.TotalRequests++
		userStats.TotalRequests++

		if result.Error == nil && result.StatusCode == http.StatusOK {
			modelStats.SuccessCount++
			userStats.SuccessCount++
		} else {
			failure := RequestFailure{
				Index:     result.Index,
				UserIndex: result.UserIndex,
				ModelID:   result.ModelID,
				Err:       result.Error,
			}
			failures = append(failures, failure)
			modelStats.ErrorCount++
			userStats.ErrorCount++
			modelStats.Failures = append(modelStats.Failures, failure)
			userStats.Failures = append(userStats.Failures, failure)
		}
		models[result.ModelID] = modelStats
		users[result.UserIndex] = userStats
	}
	return failures, models, users
}

func (r *LoadResult) SummaryTable() string {
	var s strings.Builder

	s.WriteString(fmt.Sprintf("%-20s %d\n", "Expected Success:", r.ExpectedSuccesses))
	s.WriteString(fmt.Sprintf("%-20s %d\n", "Minimum Success:", r.MinimumSuccesses))
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
			SegmentTotalE2E,
			SegmentParse,
			SegmentReserve,
			SegmentRoute,
			SegmentQueueWait,
			SegmentEncrypt,
			SegmentDispatch,
			SegmentCoordinatorToProvider,
			SegmentTTFT,
		} {
			durations, ok := r.ProfileRun.SegmentTimings[seg]
			if !ok || len(durations) == 0 {
				continue
			}
			stats := computeStats(durations)
			precision := time.Millisecond
			if stats.Max < time.Millisecond {
				precision = time.Microsecond
			}
			s.WriteString(fmt.Sprintf("%-30s %8d %8s %8s %8s %8s\n",
				seg, stats.Count,
				stats.Mean.Round(precision),
				stats.Median.Round(precision),
				stats.P95.Round(precision),
				stats.Max.Round(precision),
			))
		}
	}

	return s.String()
}

type SegmentStatsView struct {
	Count  int
	Mean   time.Duration
	Median time.Duration
	P95    time.Duration
	P99    time.Duration
	Max    time.Duration
}

func (r *LoadResult) SummaryMarkdown() string {
	var s strings.Builder

	s.WriteString(fmt.Sprintf("| Metric | Value |\n|---|---|\n"))
	s.WriteString(fmt.Sprintf("| Total Requests | %d |\n", r.TotalRequests))
	s.WriteString(fmt.Sprintf("| Expected Success | %d |\n", r.ExpectedSuccesses))
	s.WriteString(fmt.Sprintf("| Minimum Success | %d |\n", r.MinimumSuccesses))
	s.WriteString(fmt.Sprintf("| Success | %d |\n", r.SuccessCount))
	s.WriteString(fmt.Sprintf("| Errors | %d |\n", r.ErrorCount))
	s.WriteString(fmt.Sprintf("| Total Duration | %s |\n", r.TotalDuration.Round(time.Millisecond)))
	if r.SuccessCount > 0 {
		s.WriteString(fmt.Sprintf("| Throughput | %.1f req/s |\n", float64(r.SuccessCount)/r.TotalDuration.Seconds()))
	}

	if r.ProfileRun != nil && len(r.ProfileRun.SegmentTimings) > 0 {
		s.WriteString("\n### Latency Decomposition\n\n")
		s.WriteString("| Segment | Count | Mean | P50 | P95 | Max |\n|---|---|---|---|---|---|\n")

		for _, seg := range []Segment{
			SegmentTotalE2E,
			SegmentParse,
			SegmentReserve,
			SegmentRoute,
			SegmentQueueWait,
			SegmentEncrypt,
			SegmentDispatch,
			SegmentCoordinatorToProvider,
			SegmentTTFT,
		} {
			durations, ok := r.ProfileRun.SegmentTimings[seg]
			if !ok || len(durations) == 0 {
				continue
			}
			stats := computeStats(durations)
			precision := time.Millisecond
			if stats.Max < time.Millisecond {
				precision = time.Microsecond
			}
			s.WriteString(fmt.Sprintf("| %s | %d | %s | %s | %s | %s |\n",
				seg, stats.Count,
				stats.Mean.Round(precision),
				stats.Median.Round(precision),
				stats.P95.Round(precision),
				stats.Max.Round(precision),
			))
		}
	}

	return s.String()
}

func (r *LoadResult) SegmentStatsMap() map[Segment]*SegmentStatsView {
	if r.ProfileRun == nil {
		return nil
	}
	out := make(map[Segment]*SegmentStatsView, len(r.ProfileRun.SegmentTimings))
	for seg, durations := range r.ProfileRun.SegmentTimings {
		if len(durations) == 0 {
			continue
		}
		sorted := make([]time.Duration, len(durations))
		copy(sorted, durations)
		sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })

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
		p99Idx := len(sorted) * 99 / 100
		if p99Idx >= len(sorted) {
			p99Idx = len(sorted) - 1
		}

		out[seg] = &SegmentStatsView{
			Count:  len(sorted),
			Mean:   mean,
			Median: median,
			P95:    sorted[p95Idx],
			P99:    sorted[p99Idx],
			Max:    sorted[len(sorted)-1],
		}
	}
	return out
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
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })

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
