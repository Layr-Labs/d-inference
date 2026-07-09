package e2e

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/eigeninference/d-inference/e2e/testbed"
	tbassert "github.com/eigeninference/d-inference/e2e/testbed/assert"
)

// TestStress_ConcurrentAdmission fires overlapping waves of concurrent
// streaming requests at a single provider to deterministically surface engine
// crashes under concurrent batch admission (the `broadcast_shapes` class:
// the provider process fatals when concurrent requests race a batch resize).
//
// Choreography: wave 1 starts stressWaveSize streams simultaneously; once the
// wave is mid-stream, ~25% of its requests are cancelled (HTTP context
// cancellation) at the same instant wave 2 joins — maximizing batch
// join/leave churn — and likewise for wave 2 → wave 3.
//
// Wave sizing: 3 waves x 8 streams x <=56 tokens keeps total decode work
// around 1.3k tokens, bounded to a couple of minutes even on ~30-60 TPS CI
// GPUs (plus one warmup request that absorbs the cold model load).
//
// Shedding: on small-capacity CI hardware (e.g. a large MoE on a 48GB
// virtual runner) the coordinator's token-budget admission correctly sheds
// most of a wave with 429/503 before any stream content — that is the
// admission system working, not a failure, so shed volume is unbounded here.
// The waves still exercise concurrent admission timing either way: shed
// decisions race the admitted streams' decode, which is exactly the batch
// join/leave churn this test exists to stress. What must hold is that every
// request the system ACCEPTED (2xx, stream started) reaches a clean terminal
// outcome.
const (
	stressNumWaves            = 3                      // overlapping waves of concurrent streams
	stressWaveSize            = 8                      // concurrent streams started per wave
	stressCancelsPerWave      = stressWaveSize / 4     // ~25% of a wave cancelled mid-stream (last wave: none)
	stressMaxTokens           = 56                     // small per-request budget so runtime stays bounded
	stressRequestTimeout      = 180 * time.Second      // per-request hang guard (terminal-outcome enforcement)
	stressWarmupTimeout       = 5 * time.Minute        // first request absorbs the cold model load
	stressMidstreamWait       = 90 * time.Second       // max wait for a wave to reach mid-stream before the next joins
	stressCancelDelay         = 200 * time.Millisecond // gap between next-wave join and victim cancels landing
	stressMax5xx              = 1                      // >1 provider/coordinator 5xx = failure (a "cluster")
	stressMinAcceptedComplete = 0.9                    // non-cancelled ACCEPTED streams must complete cleanly
)

// stressResult is the terminal outcome of one streaming request.
type stressResult struct {
	wave       int
	index      int
	victim     bool
	statusCode int
	chunks     int
	sawDone    bool
	duration   time.Duration
	err        error
	body       string // first bytes of a non-200 body, for diagnostics
}

// stressWave tracks one wave of concurrent streams.
type stressWave struct {
	number      int
	results     []stressResult
	wg          sync.WaitGroup
	firstChunks atomic.Int32
	finished    atomic.Int32
	// cancelGate is closed when the next wave starts; victims cancel shortly
	// after both (a) receiving their first chunk and (b) the gate opening, so
	// batch leaves race the next wave's batch joins.
	cancelGate chan struct{}
}

func TestStress_ConcurrentAdmission(t *testing.T) {
	ctx := context.Background()
	s := testbed.NewSuite(testbed.SuiteConfig{
		NumUsers:       1,
		SeedBalance:    500_000_000,
		UseMemoryStore: true,
	})
	require.NoError(t, s.Start(ctx), "suite startup failed")
	t.Cleanup(s.Stop)
	require.Len(t, s.Providers, 1, "stress test expects exactly one provider")

	model := s.PrimaryModelID()
	apiKey := s.Users[0].APIKey
	provider := s.Providers[0]

	// Warmup: one small request so the model is loaded before the waves.
	// The stress target is batch join/leave churn on a warm engine, not cold
	// load; without this, wave 1 would just measure model load time.
	stressWarmup(t, s, apiKey, model)
	require.True(t, provider.Alive(), "provider process died during warmup (exit code %d)", provider.ExitCode())

	waves := make([]*stressWave, stressNumWaves)
	for w := 0; w < stressNumWaves; w++ {
		victims := stressCancelsPerWave
		if w == stressNumWaves-1 {
			victims = 0 // last wave runs to completion
		}
		waves[w] = startStressWave(t, s, apiKey, model, w, victims)

		if w < stressNumWaves-1 {
			// Let this wave get mid-stream, then simultaneously release its
			// victim cancellations and start the next wave.
			waitForMidstream(t, provider, waves[w])
		}
		close(waves[w].cancelGate)
	}

	for _, wave := range waves {
		wave.wg.Wait()
	}

	// A fatal in the engine can land as the last stream unwinds; give the
	// process a moment so the liveness check below observes it.
	time.Sleep(2 * time.Second)

	// Tally outcomes before any assertion so a crashed run still logs the
	// full per-request outcome table for triage. "Accepted" = the coordinator
	// committed to serving the request (2xx, stream started), as opposed to
	// shedding it with 429/503 before any stream content.
	var completed, cancelled, shed, serverErrs, hung int
	var accepted, acceptedCancelled int
	var failures []string
	total := 0
	for _, wave := range waves {
		for _, r := range wave.results {
			total++
			outcome, detail := classifyStressOutcome(r)
			if r.statusCode == http.StatusOK {
				accepted++
				if outcome == "cancelled" {
					acceptedCancelled++
				}
			}
			switch outcome {
			case "completed":
				completed++
			case "cancelled":
				cancelled++
			case "shed":
				shed++
			case "server_error":
				serverErrs++
				failures = append(failures, detail)
			case "hung":
				hung++
				failures = append(failures, detail)
			default: // "failed"
				failures = append(failures, detail)
			}
		}
	}
	t.Logf("outcomes: completed=%d cancelled=%d shed(429/503)=%d server_5xx=%d hung=%d failed=%d accepted=%d",
		completed, cancelled, shed, serverErrs, hung, len(failures)-serverErrs-hung, accepted)
	for _, f := range failures {
		t.Logf("  failure: %s", f)
	}

	// (a) Provider process liveness — a crashed provider is the primary
	// failure signal this test exists to catch.
	require.True(t, provider.Alive(),
		"provider process CRASHED during concurrent batch admission (exit code %d) — engine fatal under batch join/leave churn (broadcast_shapes class)",
		provider.ExitCode())
	t.Logf("provider process alive after all waves (registry providers: %d)", s.Coordinator.Registry.ProviderCount())

	// (b)+(c) Every request reached a terminal outcome, and no 5xx storm.
	require.Equal(t, stressNumWaves*stressWaveSize, total, "every launched request must record a terminal outcome")
	require.Zero(t, hung, "requests exceeded the per-request timeout — request(s) hung without a terminal outcome")
	require.LessOrEqual(t, serverErrs, stressMax5xx,
		"5xx cluster under concurrent admission (%d server errors, allowed %d)", serverErrs, stressMax5xx)
	otherFailures := len(failures) - serverErrs - hung
	require.Zero(t, otherFailures, "requests with malformed/unexpected terminal outcomes")

	// (c') Sanity: the model actually serves under concurrent load — at least
	// one request must complete end-to-end regardless of how much was shed.
	require.Greater(t, completed, 0, "no request completed successfully — model never served under concurrent load (shed=%d)", shed)

	// Shed (429/503 before any stream content) is unbounded — on
	// small-capacity CI hardware the admission system correctly rejects most
	// of a wave (see the shedding note on the wave-sizing comment). But of
	// the requests the system ACCEPTED, the non-cancelled ones must
	// overwhelmingly run to clean completion.
	acceptedNonCancelled := accepted - acceptedCancelled
	require.Greater(t, acceptedNonCancelled, 0, "no accepted non-cancelled requests to evaluate (accepted=%d, acceptedCancelled=%d)", accepted, acceptedCancelled)
	acceptedCompleteRate := float64(completed) / float64(acceptedNonCancelled)
	require.GreaterOrEqual(t, acceptedCompleteRate, stressMinAcceptedComplete,
		"accepted non-cancelled streams should overwhelmingly complete: %d/%d completed (%.0f%%, accepted=%d, shed=%d)",
		completed, acceptedNonCancelled, acceptedCompleteRate*100, accepted, shed)

	// (d) Accounting integrity. The suite runs on the in-memory store, so the
	// Postgres ledger asserter does not apply; the store-level asserter still
	// verifies no account went negative across streams + mid-flight cancels.
	storeReport := tbassert.NewAccountingAsserter(s.PgStore).EvaluateAll(s.Ctx)
	require.True(t, storeReport.Passed, "store-level accounting check failed after stress\n%s", storeReport.SummaryTable())

	t.Logf("stress: %d requests, %d accepted, %d completed, %d cancelled mid-stream, %d shed — provider survived", total, accepted, completed, cancelled, shed)
}

// stressWarmup issues a single small request and requires it to succeed,
// absorbing the cold model load so the waves hit a warm engine.
func stressWarmup(t *testing.T, s *testbed.Suite, apiKey, model string) {
	t.Helper()

	warmCtx, cancel := context.WithTimeout(s.Ctx, stressWarmupTimeout)
	defer cancel()

	body, _ := json.Marshal(map[string]any{
		"model":       model,
		"messages":    []map[string]string{{"role": "user", "content": "Say OK."}},
		"stream":      false,
		"max_tokens":  8,
		"temperature": 0.0,
	})
	req, err := http.NewRequestWithContext(warmCtx, http.MethodPost,
		s.Coordinator.BaseURL()+"/v1/chat/completions", strings.NewReader(string(body)))
	require.NoError(t, err)
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", "application/json")

	start := time.Now()
	resp, err := (&http.Client{Timeout: stressWarmupTimeout}).Do(req)
	require.NoError(t, err, "warmup request failed")
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	require.Equal(t, http.StatusOK, resp.StatusCode,
		"warmup request must succeed before stressing; body: %s", string(respBody[:min(len(respBody), 500)]))
	t.Logf("warmup completed in %s (model %s loaded)", time.Since(start).Round(time.Millisecond), model)
}

// startStressWave launches waveSize concurrent streaming requests. The first
// `victims` request indexes are cancellation victims: a canceller goroutine
// cancels each victim's HTTP request context shortly after the victim has
// received its first chunk AND the wave's cancelGate has been closed.
func startStressWave(t *testing.T, s *testbed.Suite, apiKey, model string, waveNum, victims int) *stressWave {
	t.Helper()

	wave := &stressWave{
		number:     waveNum,
		results:    make([]stressResult, stressWaveSize),
		cancelGate: make(chan struct{}),
	}
	wave.wg.Add(stressWaveSize)

	for i := 0; i < stressWaveSize; i++ {
		go func(idx int) {
			defer wave.wg.Done()
			victim := idx < victims
			wave.results[idx] = runStressRequest(s, apiKey, model, waveNum, idx, victim, wave)
			wave.finished.Add(1)
		}(i)
	}

	t.Logf("wave %d started: %d streams (%d cancellation victims)", waveNum+1, stressWaveSize, victims)
	return wave
}

// waitForMidstream blocks until at least half the wave's requests have
// received their first streamed chunk (i.e. the wave is genuinely mid-stream
// in the batch), or a generous timeout passes — in which case we proceed
// anyway: overlapping the next wave still produces admission churn. It bails
// out immediately when the provider process has died or the whole wave has
// already reached terminal outcomes (mid-stream can never happen then).
func waitForMidstream(t *testing.T, provider *testbed.Provider, wave *stressWave) {
	t.Helper()

	deadline := time.Now().Add(stressMidstreamWait)
	target := int32(stressWaveSize / 2)
	for time.Now().Before(deadline) {
		if wave.firstChunks.Load() >= target {
			t.Logf("wave %d mid-stream (%d/%d streams received first chunk)", wave.number+1, wave.firstChunks.Load(), stressWaveSize)
			return
		}
		if !provider.Alive() {
			t.Logf("wave %d: provider process already exited — skipping mid-stream wait", wave.number+1)
			return
		}
		if wave.finished.Load() >= int32(stressWaveSize) {
			t.Logf("wave %d already fully terminal (%d/%d first chunks) — proceeding", wave.number+1, wave.firstChunks.Load(), stressWaveSize)
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Logf("wave %d did not reach mid-stream within %s (%d/%d first chunks) — proceeding",
		wave.number+1, stressMidstreamWait, wave.firstChunks.Load(), stressWaveSize)
}

// runStressRequest issues one streaming chat completion and drains its SSE
// stream to a terminal outcome. Victims get a canceller goroutine that calls
// the request context's cancel func mid-stream (see startStressWave).
func runStressRequest(s *testbed.Suite, apiKey, model string, waveNum, idx int, victim bool, wave *stressWave) stressResult {
	res := stressResult{wave: waveNum, index: idx, victim: victim}
	start := time.Now()

	reqCtx, cancelTimeout := context.WithTimeout(s.Ctx, stressRequestTimeout)
	defer cancelTimeout()
	reqCtx, cancelReq := context.WithCancel(reqCtx)
	defer cancelReq()

	firstChunk := make(chan struct{})
	var firstChunkOnce sync.Once
	markFirstChunk := func() {
		firstChunkOnce.Do(func() {
			wave.firstChunks.Add(1)
			close(firstChunk)
		})
	}

	if victim {
		go func() {
			// Wait until the stream is actually producing tokens (or give up
			// waiting and cancel anyway — a queued-request cancel is still
			// valid churn), then wait for the gate that coincides with the
			// next wave joining the batch.
			select {
			case <-firstChunk:
			case <-time.After(stressMidstreamWait):
			case <-reqCtx.Done():
				return
			}
			select {
			case <-wave.cancelGate:
			case <-reqCtx.Done():
				return
			}
			time.Sleep(stressCancelDelay)
			cancelReq()
		}()
	}

	body, _ := json.Marshal(map[string]any{
		"model":       model,
		"messages":    []map[string]string{{"role": "user", "content": fmt.Sprintf("Count from %d upward, one number per line.", idx+1)}},
		"stream":      true,
		"max_tokens":  stressMaxTokens,
		"temperature": 0.0,
	})
	req, err := http.NewRequestWithContext(reqCtx, http.MethodPost,
		s.Coordinator.BaseURL()+"/v1/chat/completions", strings.NewReader(string(body)))
	if err != nil {
		res.err = err
		res.duration = time.Since(start)
		return res
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		res.err = err
		res.duration = time.Since(start)
		return res
	}
	defer resp.Body.Close()
	res.statusCode = resp.StatusCode

	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		res.body = string(respBody[:min(len(respBody), 300)])
		res.duration = time.Since(start)
		return res
	}

	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		if strings.TrimPrefix(line, "data: ") == "[DONE]" {
			res.sawDone = true
			break
		}
		res.chunks++
		markFirstChunk()
	}
	if err := scanner.Err(); err != nil {
		res.err = err
	}
	res.duration = time.Since(start)
	return res
}

// TestStress_OutcomeClassification pins the terminal-outcome buckets of
// classifyStressOutcome. Pure function — needs no provider/model, so it also
// runs in environments where the full stress suite cannot.
func TestStress_OutcomeClassification(t *testing.T) {
	cases := []struct {
		name string
		in   stressResult
		want string
	}{
		{"completed", stressResult{statusCode: 200, chunks: 5, sawDone: true}, "completed"},
		{"victim cancelled mid-read", stressResult{victim: true, statusCode: 200, chunks: 3, err: fmt.Errorf("read: %w", context.Canceled)}, "cancelled"},
		{"victim cancelled before response", stressResult{victim: true, err: fmt.Errorf("do: %w", context.Canceled)}, "cancelled"},
		{"victim truncated cleanly", stressResult{victim: true, statusCode: 200, chunks: 2}, "cancelled"},
		{"shed 429", stressResult{statusCode: 429}, "shed"},
		{"shed 503", stressResult{statusCode: 503}, "shed"},
		{"server 500", stressResult{statusCode: 500}, "server_error"},
		{"server 502", stressResult{statusCode: 502}, "server_error"},
		{"hung", stressResult{err: fmt.Errorf("await: %w", context.DeadlineExceeded)}, "hung"},
		{"hung victim", stressResult{victim: true, err: context.DeadlineExceeded}, "hung"},
		{"non-victim truncated stream", stressResult{statusCode: 200, chunks: 4}, "failed"},
		{"non-victim spurious cancel", stressResult{err: context.Canceled}, "failed"},
		{"unexpected 4xx", stressResult{statusCode: 402}, "failed"},
		{"transport error", stressResult{err: errors.New("connection reset")}, "failed"},
	}
	for _, tc := range cases {
		got, detail := classifyStressOutcome(tc.in)
		require.Equal(t, tc.want, got, "%s: %s", tc.name, detail)
	}
}

// classifyStressOutcome buckets a terminal request outcome:
//
//	completed    — 200, stream drained through [DONE]
//	cancelled    — designated victim that was cancelled cleanly mid-flight
//	shed         — 429/503 back-pressure (allowed under load)
//	server_error — 5xx other than 503 (fails the test beyond stressMax5xx)
//	hung         — per-request timeout hit (no terminal outcome in time)
//	failed       — anything else (truncated stream, transport error, 4xx)
func classifyStressOutcome(r stressResult) (string, string) {
	desc := fmt.Sprintf("wave=%d idx=%d victim=%v status=%d chunks=%d done=%v dur=%s err=%v body=%s",
		r.wave+1, r.index, r.victim, r.statusCode, r.chunks, r.sawDone, r.duration.Round(time.Millisecond), r.err, r.body)

	if errors.Is(r.err, context.DeadlineExceeded) {
		return "hung", desc
	}
	if r.victim && errors.Is(r.err, context.Canceled) {
		return "cancelled", desc
	}
	if r.err == nil && r.statusCode == http.StatusOK {
		if r.sawDone {
			return "completed", desc
		}
		if r.victim {
			// Cancel raced stream shutdown: body ended without [DONE] but
			// with no error. Clean enough for a victim.
			return "cancelled", desc
		}
		return "failed", "stream truncated without [DONE]: " + desc
	}
	if r.statusCode == http.StatusTooManyRequests || r.statusCode == http.StatusServiceUnavailable {
		return "shed", desc
	}
	if r.statusCode >= 500 {
		return "server_error", desc
	}
	return "failed", desc
}
