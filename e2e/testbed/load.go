package testbed

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
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

	ParseUs    int64
	ReserveUs  int64
	RouteUs    int64
	QueueUs    int64
	EncryptUs  int64
	DispatchUs int64
	ProviderUs int64
	// Additive profiler segments (0 when the coordinator did not report them).
	PreHandlerUs   int64
	PreflightUs    int64
	RouteReserveUs int64
	QueuePureUs    int64
	WriterUs       int64
	SocketUs       int64
	ProviderAckUs  int64
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

			prompt := fmt.Sprintf("What is %d+%d? Answer with just the number.", idx, idx+1)
			if lg.Config.PromptBytes > 0 {
				padding := lg.Config.PromptBytes - len(prompt)
				if padding > 0 {
					prompt += strings.Repeat(" ", padding)
				}
			}

			body := map[string]any{
				"model":       modelID,
				"messages":    []map[string]string{{"role": "user", "content": prompt}},
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

			if v := resp.Header.Get("X-Timing"); v != "" {
				var tj struct {
					ParseUs    int64 `json:"parse_us"`
					ReserveUs  int64 `json:"reserve_us"`
					RouteUs    int64 `json:"route_us"`
					QueueUs    int64 `json:"queue_us"`
					EncryptUs  int64 `json:"encrypt_us"`
					DispatchUs int64 `json:"dispatch_us"`
					ProviderUs int64 `json:"provider_us"`
					// Additive profiler keys (system profiler); omitted when absent.
					PreHandlerUs   int64 `json:"pre_handler_us"`
					PreflightUs    int64 `json:"preflight_us"`
					RouteReserveUs int64 `json:"route_reserve_us"`
					QueuePureUs    int64 `json:"queue_pure_us"`
					WriterUs       int64 `json:"writer_us"`
					SocketUs       int64 `json:"socket_us"`
					ProviderAckUs  int64 `json:"provider_ack_us"`
				}
				if json.Unmarshal([]byte(v), &tj) == nil {
					rr.ParseUs = tj.ParseUs
					rr.ReserveUs = tj.ReserveUs
					rr.RouteUs = tj.RouteUs
					rr.QueueUs = tj.QueueUs
					rr.EncryptUs = tj.EncryptUs
					rr.DispatchUs = tj.DispatchUs
					rr.ProviderUs = tj.ProviderUs
					rr.PreHandlerUs = tj.PreHandlerUs
					rr.PreflightUs = tj.PreflightUs
					rr.RouteReserveUs = tj.RouteReserveUs
					rr.QueuePureUs = tj.QueuePureUs
					rr.WriterUs = tj.WriterUs
					rr.SocketUs = tj.SocketUs
					rr.ProviderAckUs = tj.ProviderAckUs
				}
			}

			if resp.StatusCode == http.StatusOK {
				successCount.Add(1)

				timingsMu.Lock()
				segmentTimings[SegmentTotalE2E] = append(segmentTimings[SegmentTotalE2E], e2eDuration)
				if rr.ParseUs > 0 {
					segmentTimings[SegmentParse] = append(segmentTimings[SegmentParse], time.Duration(rr.ParseUs)*time.Microsecond)
				}
				if rr.ReserveUs > 0 {
					segmentTimings[SegmentReserve] = append(segmentTimings[SegmentReserve], time.Duration(rr.ReserveUs)*time.Microsecond)
				}
				if rr.RouteUs > 0 {
					segmentTimings[SegmentRoute] = append(segmentTimings[SegmentRoute], time.Duration(rr.RouteUs)*time.Microsecond)
				}
				if rr.QueueUs > 0 {
					segmentTimings[SegmentQueueWait] = append(segmentTimings[SegmentQueueWait], time.Duration(rr.QueueUs)*time.Microsecond)
				}
				if rr.EncryptUs > 0 {
					segmentTimings[SegmentEncrypt] = append(segmentTimings[SegmentEncrypt], time.Duration(rr.EncryptUs)*time.Microsecond)
				}
				if rr.DispatchUs > 0 {
					segmentTimings[SegmentDispatch] = append(segmentTimings[SegmentDispatch], time.Duration(rr.DispatchUs)*time.Microsecond)
				}
				if rr.ProviderUs > 0 {
					segmentTimings[SegmentCoordinatorToProvider] = append(segmentTimings[SegmentCoordinatorToProvider], time.Duration(rr.ProviderUs)*time.Microsecond)
				}
				for seg, us := range map[Segment]int64{
					SegmentPreHandler:   rr.PreHandlerUs,
					SegmentPreflight:    rr.PreflightUs,
					SegmentRouteReserve: rr.RouteReserveUs,
					SegmentQueuePure:    rr.QueuePureUs,
					SegmentWriter:       rr.WriterUs,
					SegmentSocket:       rr.SocketUs,
					SegmentProviderAck:  rr.ProviderAckUs,
				} {
					if us > 0 {
						segmentTimings[seg] = append(segmentTimings[seg], time.Duration(us)*time.Microsecond)
					}
				}
				timingsMu.Unlock()

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
