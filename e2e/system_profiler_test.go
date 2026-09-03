package e2e

// System-profiler end-to-end coverage (request waterfall, provider/engine
// profile, fleet snapshots). Re-homed from the deleted e2e/profile_test.go
// monolith: threshold/overhead evaluation lives in runBenchmark
// (benchmark_test.go); this file owns only the profiler's own contract.

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/e2e/testbed"
)

// postCompletions sends one legacy /v1/completions request (the generic
// endpoint path) so its profile row can be asserted alongside the chat rows.
func postCompletions(t *testing.T, s *testbed.Suite, prompt string, maxTokens int) *http.Response {
	t.Helper()
	body := map[string]any{"model": s.PrimaryModelID(), "prompt": prompt, "max_tokens": maxTokens, "temperature": 0.0}
	bodyJSON, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(s.Ctx, http.MethodPost,
		s.Coordinator.BaseURL()+"/v1/completions", strings.NewReader(string(bodyJSON)))
	require.NoError(t, err)
	req.Header.Set("Authorization", "Bearer testbed-admin-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := (&http.Client{Timeout: httpTimeout}).Do(req)
	require.NoError(t, err)
	return resp
}

// TestProfile_RequestProfilesRecorded drives a handful of streaming requests
// through the real coordinator + provider and asserts the system profiler
// produced one complete, internally consistent request_profiles row per
// winning attempt, that the fleet sampler writes rows, and that the additive
// X-Timing keys reach the client.
func TestProfile_RequestProfilesRecorded(t *testing.T) {
	// Record every request (the default 10 % sample would drop fast successes).
	t.Setenv("EIGENINFERENCE_PROFILE_SAMPLE_RATE", "1")
	s := startSuite(t)

	// Warm the provider: the first request on a cold slot pays the model load
	// and can exceed the first-content deadline; that is a real profile row
	// too, but the assertions below want steady-state winners.
	warmDeadline := time.Now().Add(4 * time.Minute)
	for {
		resp := postChatCompletions(t, s, "warm up", false, 8)
		code := resp.StatusCode
		resp.Body.Close()
		if code == 200 {
			break
		}
		require.True(t, time.Now().Before(warmDeadline), "provider never warmed (last status %d)", code)
		time.Sleep(2 * time.Second)
	}

	// One generic-endpoint request: its row must carry the admission preflight
	// stamps exactly like the chat rows (review finding on /v1/completions).
	genericResp := postCompletions(t, s, "generic path", 8)
	genericResp.Body.Close()
	require.Equal(t, 200, genericResp.StatusCode, "generic completions request")

	cfg := testbed.DefaultRequestConfig()
	cfg.Streaming = true
	cfg.TotalRequests = 5
	cfg.Concurrency = 2
	cfg.MaxTokens = 24
	cfg.ExpectedSuccesses = cfg.TotalRequests
	// The row assertions below need steady-state winners, not a load SLO: one
	// success is enough, and the generator's threshold error carries every
	// request failure when nothing succeeds.
	cfg.MinimumSuccesses = 1
	result, err := testbed.NewLoadGenerator(s, cfg).Run()
	require.NotNil(t, result, "load generator must return its measurements")
	require.NoError(t, err, "profiled load met no successes")
	require.Greater(t, result.SuccessCount, 0)

	sawAdditive := false
	for _, rr := range result.RequestResults {
		if rr.RouteReserveUs > 0 && rr.WriterUs >= 0 && rr.SocketUs >= 0 {
			sawAdditive = true
		}
	}
	require.True(t, sawAdditive, "X-Timing additive keys (route_reserve_us…) missing on every response")

	// The profile sink batches for up to 250 ms and the terminal half lands
	// after settlement; poll briefly.
	var rows []store.RequestProfileRecord
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		rows = s.PgStore.RequestProfilesSince(time.Time{})
		winning := 0
		for _, r := range rows {
			if r.Winning {
				winning++
			}
		}
		if winning >= result.SuccessCount {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	require.NotEmpty(t, rows, "no request_profiles rows persisted")

	checked := 0
	sawGeneric := false
	for _, r := range rows {
		if !r.Winning {
			continue
		}
		checked++
		if r.Endpoint == "POST-/v1/completions" {
			sawGeneric = true
			require.NotNil(t, r.PreflightDoneUS, "generic endpoint must stamp preflight_done_us")
			require.Greater(t, r.PreflightUS, int64(0), "generic endpoint must record preflight_us")
			require.NotEmpty(t, r.PreflightOutcome, "generic endpoint must record preflight_outcome")
			continue // the chat-shaped assertions below do not apply to the generic row
		}
		if checked == 1 {
			// One full row in the log makes a failure diagnosable without a DB.
			if dump, err := json.MarshalIndent(r, "", "  "); err == nil {
				t.Logf("profile row %s:\n%s", r.RequestID, dump)
			}
		}
		require.NotEmpty(t, r.CoordRequestID, "coord_request_id")
		require.NotEmpty(t, r.RequestID, "attempt request_id")
		require.NotEmpty(t, r.ProviderID, "provider_id")
		require.Equal(t, "POST-/v1/chat/completions", r.Endpoint)
		require.Equal(t, s.PrimaryModelID(), r.Model)
		require.Equal(t, "success", r.FinalStatus, "final_status for %s", r.RequestID)
		require.Equal(t, "completed", r.ProviderOutcome)
		require.Greater(t, r.EstimatedPromptTokens, 0)
		require.False(t, r.TimingAnomaly, "timing anomaly on %s", r.RequestID)
		// Coordinator stamps must be present and monotonic along the waterfall.
		order := []struct {
			name string
			v    *int64
		}{
			{"handler_entry_us", r.HandlerEntryUS}, {"parsed_us", r.ParsedUS}, {"reserved_us", r.ReservedUS},
			{"attempt_start_us", r.AttemptStartUS}, {"reserve_done_us", r.ReserveDoneUS}, {"encrypted_us", r.EncryptedUS},
			{"write_submitted_us", r.WriteSubmittedUS}, {"write_dequeued_us", r.WriteDequeuedUS}, {"write_done_us", r.WriteDoneUS},
			{"first_chunk_ingress_us", r.FirstChunkIngressUS}, {"first_content_us", r.FirstContentUS},
		}
		// complete_ingress_us is stamped on the WS reader goroutine, so it is
		// only ordered against the other reader-side stamp; the egress stamps
		// below are handler-side and can legitimately land either side of it.
		if r.Stream {
			// SSE: headers and the first flush go out at commit.
			order = append(order,
				struct {
					name string
					v    *int64
				}{"headers_written_us", r.HeadersWrittenUS},
				struct {
					name string
					v    *int64
				}{"first_flush_us", r.FirstFlushUS})
		} else {
			// Non-streaming: the JSON body (headers + flush) is written only
			// after the completion frame.
			order = append(order,
				struct {
					name string
					v    *int64
				}{"complete_ingress_us", r.CompleteIngressUS},
				struct {
					name string
					v    *int64
				}{"headers_written_us", r.HeadersWrittenUS},
				struct {
					name string
					v    *int64
				}{"first_flush_us", r.FirstFlushUS})
		}
		order = append(order,
			struct {
				name string
				v    *int64
			}{"done_flushed_us", r.DoneFlushedUS},
			struct {
				name string
				v    *int64
			}{"finalized_us", r.FinalizedUS})
		require.NotNilf(t, r.CompleteIngressUS, "complete_ingress_us missing on %s", r.RequestID)
		require.GreaterOrEqualf(t, *r.CompleteIngressUS, *r.FirstChunkIngressUS, "complete_ingress precedes first_chunk_ingress on %s", r.RequestID)
		var last int64
		for _, st := range order {
			require.NotNilf(t, st.v, "%s missing on %s", st.name, r.RequestID)
			require.GreaterOrEqualf(t, *st.v, last, "%s (%d) precedes previous stamp (%d) on %s", st.name, *st.v, last, r.RequestID)
			last = *st.v
		}
		require.NotNil(t, r.AcceptedUS, "provider ack stamp")
		require.Greater(t, r.ChunksIn, 0)
		require.Greater(t, r.ChunksOut, 0)
		require.Greater(t, r.BytesOut, int64(0))
		require.Greater(t, r.CandidateSetSize, 0)
		require.NotEmpty(t, r.SelectionPath)
		require.NotEmpty(t, r.Candidates, "top candidates JSON")
		require.NotNil(t, r.SettleDBUS, "settle_db_us")
		// Provider-reported profile (slice 2): the testbed provider is built from
		// this tree, so its profile must be present and valid.
		require.Truef(t, r.ProviderProfileValid, "provider profile invalid (%s) on %s", r.ProviderProfileInvalidReason, r.RequestID)
		require.NotNil(t, r.ProvTotalUS)
		require.NotNil(t, r.ProvFirstDeltaUS)
		require.NotNil(t, r.ProvEngineSubmitUS)
		require.NotNil(t, r.TransportEstUS, "transport estimate needs write_done, complete_ingress and provider total")
		require.GreaterOrEqual(t, *r.TransportEstUS, int64(0))
		// Engine sub-object (slice 3).
		require.NotNil(t, r.EngFirstTokenNS, "engine first_token_ns")
		require.NotNil(t, r.EngPrefillChunks, "engine prefill chunks")
		require.NotNil(t, r.EngDecodeSteps, "engine decode steps")
	}
	require.True(t, sawGeneric, "no winning /v1/completions row was recorded")
	require.Greater(t, checked, 0, "no winning rows")

	// Fleet snapshots: one sample writes provider slot rows plus the
	// coordinator row. The background sampler only runs behind
	// StartProfilerLoops (cmd/coordinator), which the testbed never calls, so
	// this explicit sample is the only one and the row counts are exact.
	s.Coordinator.Server.SampleFleetNow()
	snaps := s.PgStore.FleetSnapshotsSince(time.Time{})
	require.NotEmpty(t, snaps)
	var coordRows, slotRows int
	for _, row := range snaps {
		if row.ProviderID == "coordinator" {
			coordRows++
			continue
		}
		slotRows++
		require.NotEqual(t, "", row.SlotState)
		require.NotEqual(t, "", row.EligibilityReason)
		require.NotNil(t, row.LowPowerMode, "heartbeat capacity telemetry (slice 2) missing")
	}
	require.Equal(t, 1, coordRows)
	require.Greater(t, slotRows, 0)
}
