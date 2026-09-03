package api

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func newProfilerTestServer(t *testing.T) *Server {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{AdminKey: "admin-test-key"}, logger)
	t.Cleanup(srv.Close)
	return srv
}

func TestProfilerSamplingIsDeterministicPerLogicalRequest(t *testing.T) {
	p := &profiler{enabled: true, sampleRate: 0.5}
	a, b := p.sampled("coord-abc"), p.sampled("coord-abc")
	if a != b {
		t.Fatal("sampling must be deterministic on the coordinator-minted id")
	}
	if !(&profiler{sampleRate: 1}).sampled("x") || (&profiler{sampleRate: 0}).sampled("x") {
		t.Fatal("rate 1 keeps everything, rate 0 keeps nothing")
	}
	if !(&profiler{sampleRate: 0}).sampled("") {
		t.Fatal("a missing id is always kept")
	}
	kept := 0
	for i := 0; i < 2000; i++ {
		if (&profiler{sampleRate: 0.1}).sampled(newRequestID()) {
			kept++
		}
	}
	if kept < 120 || kept > 300 {
		t.Fatalf("10%% sample kept %d of 2000", kept)
	}
}

func TestProfilerAlwaysRecordPredicates(t *testing.T) {
	p := &profiler{enabled: true, sampleRate: 0}
	slow := int64(6 * time.Second / time.Microsecond)
	cases := []struct {
		name string
		rec  store.RequestProfileRecord
		want bool
	}{
		{"plain success", store.RequestProfileRecord{FinalStatus: finalStatusSuccess, ProviderProfileInvalidReason: providerProfileAbsent}, false},
		{"error", store.RequestProfileRecord{FinalStatus: "error", ProviderProfileInvalidReason: providerProfileAbsent}, true},
		{"slow first content", store.RequestProfileRecord{FinalStatus: finalStatusSuccess, FirstContentUS: &slow, ProviderProfileInvalidReason: providerProfileAbsent}, true},
		{"retried", store.RequestProfileRecord{FinalStatus: finalStatusSuccess, AttemptsTotal: 2, ProviderProfileInvalidReason: providerProfileAbsent}, true},
		{"backup", store.RequestProfileRecord{FinalStatus: finalStatusSuccess, BackupLaunched: true, ProviderProfileInvalidReason: providerProfileAbsent}, true},
		{"anomaly", store.RequestProfileRecord{FinalStatus: finalStatusSuccess, TimingAnomaly: true, ProviderProfileInvalidReason: providerProfileAbsent}, true},
		{"client gone", store.RequestProfileRecord{FinalStatus: finalStatusSuccess, ClientGonePhase: phaseAfterCommit, ProviderProfileInvalidReason: providerProfileAbsent}, true},
		{"invalid provider profile", store.RequestProfileRecord{FinalStatus: finalStatusSuccess, ProviderProfileInvalidReason: "range"}, true},
	}
	for _, tc := range cases {
		rec := tc.rec
		if got := p.alwaysRecord(&rec); got != tc.want {
			t.Errorf("%s: alwaysRecord=%v want %v", tc.name, got, tc.want)
		}
	}
}

func TestBuildProfileRecordFlattensStampsAndDecision(t *testing.T) {
	srv := newProfilerTestServer(t)
	t0 := time.Now().Add(-500 * time.Millisecond)
	rp := registry.NewRequestProfile(t0, "coord-1", nil, 0)
	rp.Endpoint = "POST-/v1/chat/completions"
	rp.Stream = true
	rp.Model = "m"
	rp.AuthDoneUS = 120
	rp.Stamp(&rp.HandlerEntryUS)
	rp.Stamp(&rp.ParsedUS)
	ap := rp.NewAttempt("attempt-uuid", 0, "")
	ap.Mark(registry.StampAttemptStart)
	ap.Mark(registry.StampReserveDone)
	ap.ProviderID = "prov-1"
	ap.ProviderVersion = "0.8.13"
	ap.ChipFamily = "M4"
	ap.SetDecision(registry.RoutingDecision{
		ProviderID: "prov-1", TTFTMs: 900, RawTTFTMs: 1000, CandidateSetSize: 3, NearTiePoolSize: 2,
		RunnerUp: registry.CandidateSummary{Present: true, ProviderID: "prov-2", CostMs: 1234},
		Top:      [4]registry.CandidateSummary{{Present: true, ProviderID: "prov-1", CostMs: 1000}},
	})
	ap.Mark(registry.StampWriteDone)
	ap.Mark(registry.StampFirstContent)
	ap.SetOutcome(finalStatusSuccess, "", "", "completed", "")
	ap.Winning.Store(true)

	rec := srv.buildProfileRecord(rp, ap)
	if rec == nil {
		t.Fatal("nil record")
	}
	if rec.CoordRequestID != "coord-1" || rec.RequestID != "attempt-uuid" || !rec.Winning {
		t.Fatalf("identity mismatch: %+v", rec)
	}
	if rec.AuthDoneUS == nil || *rec.AuthDoneUS != 120 {
		t.Fatal("pre-handler stamp not copied")
	}
	if rec.ParsedUS == nil || rec.ReservedUS != nil {
		t.Fatal("unset stamps must be nil, set stamps non-nil")
	}
	if rec.ProviderVersion != "0.8.13" || rec.ChipFamily != "m4" {
		t.Fatalf("provider snapshot not folded: %q %q", rec.ProviderVersion, rec.ChipFamily)
	}
	if rec.RunnerUpProviderID != "prov-2" || rec.RunnerUpCostMs != 1234 || rec.PredictedTTFTMs != 900 || rec.RawTTFTMs != 1000 {
		t.Fatalf("decision context missing: %+v", rec)
	}
	var cands []candidateJSON
	if err := json.Unmarshal(rec.Candidates, &cands); err != nil || len(cands) != 1 || cands[0].ProviderID != "prov-1" {
		t.Fatalf("candidates JSON: %s (%v)", rec.Candidates, err)
	}
	if rec.ProviderProfileValid || rec.ProviderProfileInvalidReason != providerProfileAbsent {
		t.Fatal("no provider profile must be recorded as absent")
	}
	if rec.TimingAnomaly {
		t.Fatal("monotonic stamps must not flag an anomaly")
	}
}

func TestFoldHelpersNeverPassProviderStringsVerbatim(t *testing.T) {
	if foldChipFamily("M3 Max (evil=1)") != "m3" || foldChipFamily("weird") != profileOther {
		t.Fatal("chip family fold")
	}
	if foldThermalState("SERIOUS") != "serious" || foldThermalState("=cmd") != profileOther || foldThermalState("") != "" {
		t.Fatal("thermal fold")
	}
	if foldProviderVersion("0.8.13") != "0.8.13" || foldProviderVersion("0.8.13-rc.1") != "0.8.13-rc.1" || foldProviderVersion("v0.8; drop") != "invalid" {
		t.Fatal("version fold")
	}
}

func TestCSVCellGuardsFormulaPrefixes(t *testing.T) {
	for _, in := range []string{"=HYPERLINK(1)", "+1", "-1", "@x", "\tx", "\rx"} {
		if got := csvCell(in); got != "'"+in {
			t.Fatalf("csvCell(%q) = %q", in, got)
		}
	}
	if csvCell("plain") != "plain" || csvCell("") != "" {
		t.Fatal("plain cells untouched")
	}
}

func TestTimingJSONAdditiveKeysAndClamp(t *testing.T) {
	srv := newProfilerTestServer(t)
	rp := registry.NewRequestProfile(time.Now().Add(-time.Second), "c", nil, 0)
	rp.PreflightUS = 300
	rp.Stamp(&rp.HandlerEntryUS)
	ap := rp.NewAttempt("a", 0, "")
	ap.AttemptStartUS.Store(1000)
	ap.ReserveDoneUS.Store(1500)
	ap.WriteSubmittedUS.Store(2000)
	ap.WriteDequeuedUS.Store(2100)
	ap.WriteDoneUS.Store(2400)
	ap.AcceptedUS.Store(3400)
	pr := &registry.PendingRequest{Profile: ap}
	d := &dispatchState{s: srv, profile: rp}
	tj := types.RequestTimingDetails{ParseUs: -5, ProviderUs: 10}
	d.applyProfileTiming(&tj, pr)
	if tj.ParseUs != 0 || !tj.TimingAnomaly {
		t.Fatal("negative legacy segment must clamp to 0 and flag anomaly")
	}
	if tj.RouteReserveUs != 500 || tj.WriterUs != 100 || tj.SocketUs != 300 || tj.ProviderAckUs != 1000 || tj.PreflightUs != 300 {
		t.Fatalf("additive keys wrong: %+v", tj)
	}
	b, _ := json.Marshal(tj)
	for _, key := range []string{"parse_us", "provider_us", "route_reserve_us", "writer_us", "socket_us", "provider_ack_us", "preflight_us"} {
		if !json.Valid(b) || !containsKey(b, key) {
			t.Fatalf("X-Timing missing %s: %s", key, b)
		}
	}
}

func containsKey(b []byte, key string) bool {
	var m map[string]any
	if json.Unmarshal(b, &m) != nil {
		return false
	}
	_, ok := m[key]
	return ok
}

func TestProfileSinkBatchesIntoStoreAndAdminEndpointsServeThem(t *testing.T) {
	srv := newProfilerTestServer(t)
	if !srv.profilerEnabled() || srv.profiler.sink == nil {
		t.Fatal("profiler must be on by default with a store")
	}
	for i := 0; i < 100; i++ {
		rp := registry.NewRequestProfile(time.Now(), "coord-"+newRequestID(), nil, 0)
		rp.Model = "m"
		ap := rp.NewAttempt("req-"+newRequestID(), 0, "")
		ap.ProviderID = "prov"
		ap.Mark(registry.StampWriteSubmitted)
		ap.SetOutcome("error", "provider_error", "", "error", "")
		if !srv.profiler.sink.submit(rp, ap) {
			t.Fatal("submit dropped with an empty buffer")
		}
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if len(srv.store.RequestProfilesSince(time.Time{})) == 100 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if n := len(srv.store.RequestProfilesSince(time.Time{})); n != 100 {
		t.Fatalf("expected 100 persisted profiles, got %d", n)
	}

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	get := func(path string) *http.Response {
		req, _ := http.NewRequest(http.MethodGet, ts.URL+path, nil)
		req.Header.Set("Authorization", "Bearer admin-test-key")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		return resp
	}
	resp := get("/v1/admin/profiles?limit=10")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("admin profiles status %d", resp.StatusCode)
	}
	var page struct {
		Count int                          `json:"count"`
		Data  []store.RequestProfileRecord `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&page); err != nil || page.Count != 10 {
		t.Fatalf("admin profiles page: count=%d err=%v", page.Count, err)
	}
	exp := get("/v1/admin/profiles/export?provider=prov")
	defer exp.Body.Close()
	if exp.StatusCode != http.StatusOK || exp.Header.Get("Content-Type") != "application/x-ndjson" {
		t.Fatalf("export status=%d ctype=%q", exp.StatusCode, exp.Header.Get("Content-Type"))
	}
	unauth, _ := http.Get(ts.URL + "/v1/admin/snapshots")
	if unauth.StatusCode == http.StatusOK {
		t.Fatal("admin snapshots must require the admin key")
	}
	unauth.Body.Close()
}

func TestFleetSampleWritesCoordinatorRowAndPruneRuns(t *testing.T) {
	srv := newProfilerTestServer(t)
	srv.SampleFleetNow()
	rows := srv.store.FleetSnapshotsSince(time.Time{})
	if len(rows) == 0 {
		t.Fatal("fleet sample must write at least the coordinator row")
	}
	found := false
	for _, r := range rows {
		if r.ProviderID == "coordinator" {
			found = true
			if r.Goroutines <= 0 {
				t.Fatal("coordinator row must carry goroutine count")
			}
		}
	}
	if !found {
		t.Fatal("coordinator row missing")
	}
	srv.PruneTelemetryNow(context.Background())
}

func TestRequestMetaAlwaysMintsCoordinatorID(t *testing.T) {
	srv := newProfilerTestServer(t)
	var seenCoord, seenReq string
	h := srv.loggingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenCoord = coordRequestIDFromContext(r.Context())
		seenReq = requestIDFromContext(r.Context())
		w.WriteHeader(http.StatusNoContent)
	}))
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	req.Header.Set("X-Request-ID", "=client-controlled@id")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if seenReq != "=client-controlled@id" {
		t.Fatal("client id must still be honoured for logs/header")
	}
	if seenCoord == "" || seenCoord == seenReq {
		t.Fatalf("coordinator id must be minted independently, got %q", seenCoord)
	}
	req2 := httptest.NewRequest(http.MethodGet, "/health", nil)
	h.ServeHTTP(httptest.NewRecorder(), req2)
	if seenCoord != seenReq {
		t.Fatal("without a client id, the minted id serves both roles")
	}
}

func TestProfilerKillSwitchMakesEverySiteNoOp(t *testing.T) {
	t.Setenv(envProfiler, "off")
	srv := newProfilerTestServer(t)
	if srv.profilerEnabled() {
		t.Fatal("kill switch must disable the profiler")
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	if rp := srv.newRequestProfile(req, "m", "m", true); rp != nil {
		t.Fatal("no profile when off")
	}
	// Every stamp helper must be nil-safe.
	var rp *registry.RequestProfile
	rp.Mark(registry.StampReqParsed)
	rp.Stamp(nil)
	profileDBCall(rp, time.Now())
	var ap *registry.AttemptProfile
	ap.Mark(registry.StampAccepted)
	ap.MarkAt(registry.StampCompleteIngress, time.Now())
	ap.SetDecision(registry.RoutingDecision{})
	ap.SetOutcome("x", "", "", "", "")
	ap.CompleteHandler()
	ap.CompleteTerminal()
	ap.ClaimTerminal()
	closeUndispatchedAttempt(ap, "e", 503)
	pr := &registry.PendingRequest{}
	profileClientGone(pr, phaseAfterCommit)
	newRelayStamps(pr.Profile.Parent()).flushed(3)
	d := &dispatchState{s: srv}
	tj := types.RequestTimingDetails{ParseUs: -5}
	d.applyProfileTiming(&tj, pr)
	if tj.ParseUs != -5 || tj.TimingAnomaly {
		t.Fatal("with the profiler off the legacy X-Timing values must be untouched")
	}
	d.finalizeProfile()
	d.stampFirstContent(pr)
	d.stampCommitted(pr)
	h := srv.loggingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if requestMetaFromContext(r.Context()) != nil {
			t.Error("no request meta when the profiler is off")
		}
	}))
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/health", nil))
}

func TestBuildProfileRecordDerivesFinalStatusFromTerminal(t *testing.T) {
	srv := newProfilerTestServer(t)
	rp := registry.NewRequestProfile(time.Now(), "c", nil, 0)
	ap := rp.NewAttempt("a", 0, "")
	ap.SetOutcome("", "", "watchdog", "error", "")
	rec := srv.buildProfileRecord(rp, ap)
	if rec.FinalStatus != "error" || rec.TerminalCause != "watchdog" {
		t.Fatalf("derived status: %+v", rec)
	}
	ap2 := rp.NewAttempt("b", 1, "")
	ap2.SetOutcome("", "", "", "completed", "")
	if rec := srv.buildProfileRecord(rp, ap2); rec.FinalStatus != finalStatusSuccess {
		t.Fatalf("completed must derive success, got %q", rec.FinalStatus)
	}
}

func TestCloseUndispatchedAttemptCoversWriteFailure(t *testing.T) {
	var finalized int
	rp := registry.NewRequestProfile(time.Now(), "c", func(*registry.RequestProfile, *registry.AttemptProfile) { finalized++ }, 0)
	ap := rp.NewAttempt("a", 0, "")
	ap.Mark(registry.StampWriteSubmitted) // submitted, but the write failed: WriteDone never set
	closeUndispatchedAttempt(ap, "failed to send request to provider", 502)
	if finalized != 0 {
		t.Fatalf("closing an undispatched attempt must only complete the terminal half (the record is built after the handler returns), finalized=%d", finalized)
	}
	ap.CompleteHandler() // what finalizeProfile does once the dispatch loop returns
	if finalized != 1 {
		t.Fatalf("write-failed attempt must finalize once the handler half lands, finalized=%d", finalized)
	}
	fs, _, _, po, _ := ap.Outcome()
	if fs != "error" || po != "not_dispatched" {
		t.Fatalf("outcome %q/%q", fs, po)
	}
	ok := rp.NewAttempt("b", 1, "")
	ok.Mark(registry.StampWriteDone)
	closeUndispatchedAttempt(ok, "x", 500)
	if ok.Finalized() {
		t.Fatal("a dispatched attempt must be left to its provider terminal")
	}
}

// TestCompleteHandlerFinalizesTerminalAfterSettlement pins the terminal-half
// ordering of the complete handler on both branches: the attempt must not
// finalize (and so be enqueued to the sink) before the settlement stamp has
// landed. The PARKED branch (consumer already gone; claimSettlement returned
// the parked record) used to complete the terminal inside the billing gate,
// before the stamp, so settle_db_us was nondeterministically missing on rows
// for completed-after-disconnect requests.
func TestCompleteHandlerFinalizesTerminalAfterSettlement(t *testing.T) {
	for _, parked := range []bool{true, false} {
		name := "live"
		if parked {
			name = "parked"
		}
		t.Run(name, func(t *testing.T) {
			srv, _, ledger := billingTestServer(t)
			// Long grace: handleComplete deterministically claims the parked
			// record first; the timer fires after the test and no-ops.
			srv.settleGrace = 5 * time.Second
			model := "settle-order-model"
			provider := srv.registry.Register("settle-order-"+name, nil, &protocol.RegisterMessage{
				Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
			})
			provider.Mu().Lock()
			provider.AccountID = "settle-order-account"
			provider.Mu().Unlock()

			usage := protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 500}
			const reserved int64 = 5_000_000
			if err := ledger.Charge(testConsumerID, reserved, "reserve:settle-order-"+name); err != nil {
				t.Fatalf("reserve balance: %v", err)
			}
			pr := &registry.PendingRequest{
				RequestID:        "settle-order-" + name,
				Model:            model,
				ConsumerKey:      testConsumerID,
				ReservedMicroUSD: reserved,
				ChunkCh:          make(chan registry.ProviderChunk, 1),
				CompleteCh:       make(chan protocol.UsageInfo, 1),
				ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
			}
			var rp *registry.RequestProfile
			finalized := make(chan *store.RequestProfileRecord, 2)
			rp = registry.NewRequestProfile(time.Now(), "coord-"+name, func(_ *registry.RequestProfile, ap *registry.AttemptProfile) {
				// Runs on the completing goroutine at the instant the sink could
				// first read the attempt: the stamps visible here are the stamps
				// the row carries.
				finalized <- srv.buildProfileRecord(rp, ap)
			}, 0)
			ap := rp.NewAttempt(pr.RequestID, 0, "")
			ap.ProviderID = provider.ID
			pr.Profile = ap
			// The handler half is already done (the consumer-side handler has
			// returned), so the terminal half finalizes the attempt wherever
			// handleComplete runs CompleteTerminal.
			ap.CompleteHandler()

			if parked {
				parkConsumerGone(srv, provider, pr)
			} else {
				provider.AddPending(pr)
			}
			srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
				Type:      protocol.TypeInferenceComplete,
				RequestID: pr.RequestID,
				Usage:     usage,
			})

			var rec *store.RequestProfileRecord
			select {
			case rec = <-finalized:
			case <-time.After(2 * time.Second):
				t.Fatal("attempt never finalized")
			}
			if rec.SettleDBUS == nil {
				t.Fatal("attempt finalized before the settlement stamp: settle_db_us missing")
			}
			if rec.ProviderOutcome != "completed" || rec.CompleteIngressUS == nil {
				t.Fatalf("provider_outcome=%q complete_ingress=%v", rec.ProviderOutcome, rec.CompleteIngressUS)
			}
			if p, c, ok := ap.TerminalUsage(); !ok || p != usage.PromptTokens || c != usage.CompletionTokens {
				t.Fatalf("terminal usage = %d/%d ok=%v, want %d/%d recorded at ingress", p, c, ok, usage.PromptTokens, usage.CompletionTokens)
			}
			select {
			case <-finalized:
				t.Fatal("attempt finalized twice")
			default:
			}
			if !parked {
				// The consumer was signalled before the terminal half completed.
				select {
				case got := <-pr.CompleteCh:
					if got.CompletionTokens != usage.CompletionTokens {
						t.Fatalf("consumer got usage %+v", got)
					}
				default:
					t.Fatal("live consumer was not signalled")
				}
			}
		})
	}
}

// TestQueuedAttemptWriteFailureClosesNotDispatched drives the REAL queue
// path: the request queues, the drain hands over a provider whose socket is
// gone, and the frame write fails after d.pr was already assigned. The
// placeholder attempt must close as not_dispatched with the write failure's
// class — not finalize with an empty provider_outcome because d.pr pointed at
// it (the old defer keyed on d.pr == queuePR, which is set BEFORE the write).
// queueDispatchState builds the dispatchState the queue-path tests drive
// through the real dispatchPrimary: with no routable provider registered,
// attempt 0 finds none and the request takes the queue path.
func queueDispatchState(s *Server, model string, rp *registry.RequestProfile, r *http.Request, deadline time.Duration) *dispatchState {
	return &dispatchState{
		s:                      s,
		w:                      httptest.NewRecorder(),
		r:                      r,
		model:                  model,
		publicModel:            model,
		rawBody:                []byte(`{"model":"` + model + `","messages":[]}`),
		consumerEndpoint:       completionsEndpoint,
		timing:                 &registry.RequestTiming{ReceivedAt: time.Now()},
		deadline:               deadline,
		speculativeAt:          deadline / 2,
		refundReservation:      func() {},
		excludeProviders:       make(map[string]struct{}),
		requestedMaxTokens:     16,
		estimatedPromptTokens:  1,
		parallelToolCalls:      true,
		requestedStopSequences: []string{"stop"},
		profile:                rp,
	}
}

// queuedPlaceholder returns the attempt the queue path created. Attempt 0's
// reserve-only profile (no provider available) sits next to it; the
// placeholder is the one that was enqueued.
func queuedPlaceholder(t *testing.T, rp *registry.RequestProfile) *registry.AttemptProfile {
	t.Helper()
	for _, a := range rp.Attempts() {
		if a.Get(registry.StampQueued) != 0 {
			return a
		}
	}
	t.Fatalf("no queued placeholder attempt among %d attempts", len(rp.Attempts()))
	return nil
}

func TestQueuedAttemptWriteFailureClosesNotDispatched(t *testing.T) {
	s := newTestServerForDispatch(t)
	s.registry.SetQueue(registry.NewRequestQueue(4, 5*time.Second))
	const model = "queue-write-failure"
	rp := registry.NewRequestProfile(time.Now(), "coord-queue-write", nil, 0)
	d := queueDispatchState(s, model, rp, httptest.NewRequest(http.MethodPost, "/v1/completions", nil), 10*time.Second)
	outcome := make(chan dispatchOutcome, 1)
	go func() { outcome <- d.dispatchPrimary() }()
	// Register the provider only once the request is queued, or attempt 0
	// would reserve it directly and never take the queue path.
	waitForAdaptiveCondition(t, 3*time.Second, func() bool {
		return s.registry.Queue().QueueSize(model) >= 1
	})
	p := makeRoutableProvider(t, s.registry, "queue-write-failure-provider", model) // nil Conn: the frame write fails
	s.registry.DrainQueuedRequestsForModel(model)

	select {
	case got := <-outcome:
		if got != outcomeRetry {
			t.Fatalf("dispatchPrimary=%v, want retry after the write failure", got)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("dispatchPrimary did not return")
	}
	if d.lastErr != "failed to send request to provider" {
		t.Fatalf("lastErr=%q, want the write failure", d.lastErr)
	}
	ap := queuedPlaceholder(t, rp)
	if ap.Finalized() || !ap.TerminalRecorded() {
		t.Fatalf("failure site must close only the terminal half: finalized=%v terminal=%v", ap.Finalized(), ap.TerminalRecorded())
	}
	ap.CompleteHandler() // what finalizeProfile does once the dispatch loop returns
	if !ap.Finalized() {
		t.Fatal("attempt must finalize once the handler half lands")
	}
	rec := s.buildProfileRecord(rp, ap)
	if rec.ProviderOutcome != "not_dispatched" || rec.FinalStatus != "error" || rec.ErrorReason != "provider_error" {
		t.Fatalf("outcome = %q/%q/%q, want not_dispatched/error/provider_error", rec.ProviderOutcome, rec.FinalStatus, rec.ErrorReason)
	}
	if rec.ProviderID != p.ID || rec.DequeuedUS == nil || rec.WriteSubmittedUS == nil || rec.WriteDoneUS != nil {
		t.Fatalf("row must show the queue handover and a submitted-but-never-done write: provider=%q dequeued=%v submitted=%v done=%v",
			rec.ProviderID, rec.DequeuedUS, rec.WriteSubmittedUS, rec.WriteDoneUS)
	}
}

// TestCloseQueuedAttemptKeepsRecordedErrorText pins the defaulting rule of the
// queue-path close: a real error text with no HTTP status keeps its own class
// (only the code is defaulted); an exit that recorded nothing is classified by
// how the wait ended; a dispatched attempt is left to its provider terminal.
func TestCloseQueuedAttemptKeepsRecordedErrorText(t *testing.T) {
	s := newTestServerForDispatch(t)
	rp := registry.NewRequestProfile(time.Now(), "c", nil, 0)
	newReq := func() *http.Request { return httptest.NewRequest(http.MethodPost, "/v1/completions", nil) }

	d := &dispatchState{s: s, r: newReq()}
	d.setLastError("no provider with E2E encryption", 0)
	enc := rp.NewAttempt("enc", 0, "")
	d.closeQueuedAttempt(enc)
	if _, reason, _, po, _ := enc.Outcome(); reason != "encryption_missing" || po != "not_dispatched" {
		t.Fatalf("encryption failure recorded as %q/%q, want encryption_missing/not_dispatched", reason, po)
	}

	d = &dispatchState{s: s, r: newReq()}
	none := rp.NewAttempt("none", 1, "")
	d.closeQueuedAttempt(none)
	if fs, reason, _, po, _ := none.Outcome(); fs != "rejected" || reason != "provider_error" || po != "not_dispatched" {
		t.Fatalf("queue refusal recorded as %q/%q/%q", fs, reason, po)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	d = &dispatchState{s: s, r: newReq().WithContext(ctx)}
	gone := rp.NewAttempt("gone", 2, "")
	d.closeQueuedAttempt(gone)
	if fs, _, _, po, _ := gone.Outcome(); fs != "cancelled" || po != "not_dispatched" {
		t.Fatalf("client gone while queued recorded as %q/%q", fs, po)
	}

	d = &dispatchState{s: s, r: newReq()}
	d.setLastError("failed to send request to provider", 0)
	sent := rp.NewAttempt("sent", 3, "")
	sent.Mark(registry.StampWriteDone)
	d.closeQueuedAttempt(sent)
	if fs, _, _, po, _ := sent.Outcome(); fs != "" || po != "" || sent.TerminalRecorded() {
		t.Fatalf("a dispatched attempt must be left alone: %q/%q terminal=%v", fs, po, sent.TerminalRecorded())
	}
}

// TestQueuedAttemptExitsCarryRouteOutcome drives each exit of the queue wait
// through the real dispatchPrimary and asserts the placeholder attempt carries
// the same final_status/error_reason the route outcome records there. During
// the wait d.pr is nil, so updateRoutingOutcome never reaches the attempt
// profile; before the fix these rows were closed with the code-based default
// (rejected|cancelled / provider_error) instead of the routes vocabulary.
// queue_full has no route outcome at all (the routing decision is recorded
// only after a successful enqueue), so it carries the rejection vocabulary.
func TestQueuedAttemptExitsCarryRouteOutcome(t *testing.T) {
	const model = "queue-exit-outcome"
	failQueued := func(reason error) func(*testing.T, *Server, context.CancelFunc) {
		return func(t *testing.T, s *Server, _ context.CancelFunc) {
			req := s.registry.Queue().PopNextFresh(model)
			if req == nil {
				t.Fatal("no queued request to fail")
			}
			req.FailureReason = reason // nil → ErrQueueTimeout
			req.ResponseCh <- nil
		}
	}
	cases := []struct {
		name        string
		maxSize     int
		deadline    time.Duration
		trigger     func(*testing.T, *Server, context.CancelFunc) // nil: the exit fires on its own
		wantOutcome dispatchOutcome
		wantStatus  string
		wantReason  string
	}{
		{"queue_full", 0, 10 * time.Second, nil, outcomeResponseWritten, "rejected", "queue_full"},
		{"client_gone", 4, 10 * time.Second, func(_ *testing.T, _ *Server, cancel context.CancelFunc) { cancel() }, outcomeClientGone, "cancelled", "client_gone"},
		{"first_chunk_timeout", 4, 200 * time.Millisecond, nil, outcomeFailFast, "timeout", "first_chunk_timeout"},
		{"ttft_too_slow", 4, 10 * time.Second, failQueued(registry.ErrQueueTTFTTooSlow), outcomeResponseWritten, "error", "ttft_too_slow"},
		{"model_capability_unsupported", 4, 10 * time.Second, failQueued(registry.ErrQueueToolConstraintUnavailable), outcomeResponseWritten, "error", "model_capability_unsupported"},
		{"queue_timeout", 4, 10 * time.Second, failQueued(nil), outcomeResponseWritten, "timeout", "queue_timeout"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := newTestServerForDispatch(t)
			s.registry.SetQueue(registry.NewRequestQueue(tc.maxSize, 5*time.Second))
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			rp := registry.NewRequestProfile(time.Now(), "coord-"+tc.name, nil, 0)
			d := queueDispatchState(s, model, rp, httptest.NewRequest(http.MethodPost, "/v1/completions", nil).WithContext(ctx), tc.deadline)
			outcome := make(chan dispatchOutcome, 1)
			go func() { outcome <- d.dispatchPrimary() }()
			if tc.trigger != nil {
				waitForAdaptiveCondition(t, 3*time.Second, func() bool {
					return s.registry.Queue().QueueSize(model) >= 1
				})
				tc.trigger(t, s, cancel)
			}
			select {
			case got := <-outcome:
				if got != tc.wantOutcome {
					t.Fatalf("dispatchPrimary=%v, want %v", got, tc.wantOutcome)
				}
			case <-time.After(10 * time.Second):
				t.Fatal("dispatchPrimary did not return")
			}
			ap := queuedPlaceholder(t, rp)
			if !ap.TerminalRecorded() || ap.Finalized() {
				t.Fatalf("queue exit must close only the terminal half: terminal=%v finalized=%v", ap.TerminalRecorded(), ap.Finalized())
			}
			ap.CompleteHandler()
			rec := s.buildProfileRecord(rp, ap)
			if rec.FinalStatus != tc.wantStatus || rec.ErrorReason != tc.wantReason || rec.ProviderOutcome != "not_dispatched" {
				t.Fatalf("row = %q/%q/%q, want %s/%s/not_dispatched", rec.FinalStatus, rec.ErrorReason, rec.ProviderOutcome, tc.wantStatus, tc.wantReason)
			}
		})
	}
}

// TestSpeculativeLoserCompletionKeepsFunnelOutcome pins the provider-side half
// of a losing speculative racer's empty completion: the read loop records only
// provider_outcome (completed for a frame that reached the wire, nothing for
// one that never did), retains the usage and profile that arrived with the
// completion, and leaves final_status/error_reason to the dispatch side — the
// route-outcome funnel (markSpeculativeLoser → speculativeLoserOutcome, whose
// closed error_class "speculative_loser" is what the row carries) or, for an
// unsent frame, closeUndispatchedAttempt (not_dispatched). Both goroutine
// orders must produce the identical row: that is the proof there is no
// first-write race and no vocabulary drift between the two writers.
func TestSpeculativeLoserCompletionKeepsFunnelOutcome(t *testing.T) {
	cases := []struct {
		name        string
		dispatched  bool
		readerFirst bool
		wantOutcome string
		wantStatus  string
		wantReason  string
	}{
		{"dispatched, funnel first", true, false, "completed", "cancelled", ""}, // reason: profileErrorReason(speculativeLoserOutcome(pr))
		{"dispatched, reader first", true, true, "completed", "cancelled", ""},
		{"unsent, close first", false, false, "not_dispatched", "error", "provider_error"},
		{"unsent, reader first", false, true, "not_dispatched", "error", "provider_error"},
	}
	for i, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := newProfilerTestServer(t)
			id := "spec-loser-" + strconv.Itoa(i)
			provider := srv.registry.Register(id, nil, &protocol.RegisterMessage{
				Models: []protocol.ModelInfo{{ID: "m", ModelType: "chat", Quantization: "4bit"}},
			})
			pr := &registry.PendingRequest{
				RequestID:            id,
				Model:                "m",
				FirstContentDeadline: time.Now().Add(time.Minute),
				ChunkCh:              make(chan registry.ProviderChunk, 1),
				CompleteCh:           make(chan protocol.UsageInfo, 1),
				ErrorCh:              make(chan protocol.InferenceErrorMessage, 1),
			}
			var rp *registry.RequestProfile
			finalized := make(chan *store.RequestProfileRecord, 2)
			rp = registry.NewRequestProfile(time.Now(), "coord-"+id, func(_ *registry.RequestProfile, ap *registry.AttemptProfile) {
				finalized <- srv.buildProfileRecord(rp, ap)
			}, 0)
			ap := rp.NewAttempt(pr.RequestID, 0, "")
			ap.ProviderID = provider.ID
			ap.Mark(registry.StampWriteSubmitted)
			if tc.dispatched {
				ap.Mark(registry.StampWriteDone)
			}
			pr.Profile = ap
			pr.EnableSpeculativeEmptyCompletionArbitration()
			provider.AddPending(pr)

			done := make(chan struct{})
			go func() {
				srv.handleCompleteAt(provider.ID, provider, &protocol.InferenceCompleteMessage{
					Type:      protocol.TypeInferenceComplete,
					RequestID: pr.RequestID,
					Usage:     protocol.UsageInfo{PromptTokens: 100},
					Profile:   []byte(`{"schema":1,"total_us":1000,"prompt_tokens":100}`),
				}, time.Now())
				close(done)
			}()
			<-pr.CompletionIngressSignal()
			select {
			case <-done:
				t.Fatal("empty completion settled before speculative arbitration")
			default:
			}
			awaitReader := func() {
				select {
				case <-done:
				case <-time.After(2 * time.Second):
					t.Fatal("rejected empty completion did not release the read loop")
				}
			}
			dispatchSide := func() {
				if tc.dispatched {
					(&dispatchState{s: srv}).markSpeculativeLoser(pr)
				} else {
					closeUndispatchedAttempt(ap, "failed to send request to provider", http.StatusBadGateway)
				}
			}
			release := func() {
				if tc.dispatched {
					pr.ResolveSpeculativeEmptyCompletion(false) // what cancelDispatch does for the loser
					provider.RemovePending(pr.RequestID)
				} else {
					srv.releaseUnsentDispatch(provider, pr)
				}
			}
			if tc.readerFirst {
				release()
				awaitReader()
				dispatchSide()
			} else {
				dispatchSide()
				release()
				awaitReader()
			}

			select {
			case <-finalized:
				t.Fatal("attempt finalized before the handler half")
			default:
			}
			ap.CompleteHandler()
			var rec *store.RequestProfileRecord
			select {
			case rec = <-finalized:
			case <-time.After(2 * time.Second):
				t.Fatal("attempt never finalized")
			}
			wantReason := tc.wantReason
			if tc.dispatched {
				loser := speculativeLoserOutcome(pr)
				if loser.FinalStatus != tc.wantStatus || loser.ErrorClass != "speculative_loser" || loser.ErrorReason == "" {
					t.Fatalf("speculativeLoserOutcome = %+v", loser)
				}
				wantReason = profileErrorReason(loser) // the routes error_class vocabulary
			}
			if rec.ProviderOutcome != tc.wantOutcome || rec.FinalStatus != tc.wantStatus || rec.ErrorReason != wantReason {
				t.Fatalf("row = %q/%q/%q, want %s/%s/%s", rec.ProviderOutcome, rec.FinalStatus, rec.ErrorReason, tc.wantOutcome, tc.wantStatus, wantReason)
			}
			if !rec.ProviderProfileValid || rec.ProviderProfileInvalidReason != "" {
				t.Fatalf("profile sent with the losing completion must be retained: valid=%v reason=%q", rec.ProviderProfileValid, rec.ProviderProfileInvalidReason)
			}
			if rec.ProviderProfileConsistent == nil || !*rec.ProviderProfileConsistent {
				t.Fatalf("terminal usage must be recorded for the loser: consistent=%v", rec.ProviderProfileConsistent)
			}
			if p, _, ok := ap.TerminalUsage(); !ok || p != 100 {
				t.Fatalf("terminal usage = %d ok=%v", p, ok)
			}
			select {
			case <-pr.CompleteCh:
				t.Fatal("losing completion was published to the consumer")
			default:
			}
		})
	}
}

// TestClaimedCompleteFrameFinalizesAfterPendingRemoved pins the ownership
// window opened by the terminal claim. A completion frame claims the attempt's
// terminal at ingress; a consumer-side non-terminal remover (client-gone
// cancelDispatch, releaseUnsentDispatch, registry.Disconnect) removes the
// pending request before the frame's own RemovePending, so the frame returns
// through the unknown-request path — directly, or via handleInferenceError on
// the deadline-late branch. Once claimed, neither the route-outcome funnel
// (it skips CompleteTerminal for a claimed attempt) nor the no-terminal
// fallback finishes the record, so the frame must close its own claim on
// those returns (provider_outcome=completed) or the attempt never finalizes.
// claimFixture is one in-flight, dispatched attempt whose provider completion
// the claim-window tests drive by hand: a registered (nil-conn) provider, a
// pending request with a profile, and a finalize callback that captures the
// record the sink would build.
type claimFixture struct {
	srv       *Server
	provider  *registry.Provider
	pr        *registry.PendingRequest
	ap        *registry.AttemptProfile
	finalized chan *store.RequestProfileRecord
}

// claimTestProfile is the profile the completion frame carries; prompt_tokens
// matches the frame's usage so the row's consistency flag is true.
const claimTestProfile = `{"schema":1,"total_us":1000,"prompt_tokens":100}`

func newClaimFixture(t *testing.T, id string, deadline time.Time, reserved int64) claimFixture {
	t.Helper()
	return newClaimFixtureOn(t, newProfilerTestServer(t), id, deadline, reserved)
}

// newClaimFixtureOn is newClaimFixture on an existing server: a fresh
// provider, pending request and attempt per call.
func newClaimFixtureOn(t *testing.T, srv *Server, id string, deadline time.Time, reserved int64) claimFixture {
	t.Helper()
	provider := srv.registry.Register(id, nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: "m", ModelType: "chat", Quantization: "4bit"}},
	})
	pr := &registry.PendingRequest{
		RequestID:            id,
		Model:                "m",
		ConsumerKey:          testConsumerID,
		ReservedMicroUSD:     reserved,
		FirstContentDeadline: deadline,
		ChunkCh:              make(chan registry.ProviderChunk, 1),
		CompleteCh:           make(chan protocol.UsageInfo, 1),
		ErrorCh:              make(chan protocol.InferenceErrorMessage, 1),
	}
	var rp *registry.RequestProfile
	finalized := make(chan *store.RequestProfileRecord, 2)
	rp = registry.NewRequestProfile(time.Now(), "coord-"+id, func(_ *registry.RequestProfile, ap *registry.AttemptProfile) {
		finalized <- srv.buildProfileRecord(rp, ap)
	}, 0)
	ap := rp.NewAttempt(id, 0, "")
	ap.ProviderID = provider.ID
	ap.Mark(registry.StampWriteSubmitted)
	ap.Mark(registry.StampWriteDone)
	pr.Profile = ap
	provider.AddPending(pr)
	return claimFixture{srv: srv, provider: provider, pr: pr, ap: ap, finalized: finalized}
}

// runClaimFrame delivers the provider's completion for requestID (the id the
// pending request was registered under) off the test goroutine, as the read
// loop does.
func runClaimFrame(f claimFixture, requestID string) chan struct{} {
	done := make(chan struct{})
	go func() {
		f.srv.handleCompleteAt(f.provider.ID, f.provider, &protocol.InferenceCompleteMessage{
			Type:      protocol.TypeInferenceComplete,
			RequestID: requestID,
			Usage:     protocol.UsageInfo{PromptTokens: 100},
			Profile:   []byte(claimTestProfile),
		}, time.Now())
		close(done)
	}()
	return done
}

// awaitClaimed blocks until the completion frame has claimed the terminal and
// retained its profile. The ingress signal fires before the claim, and the
// retained profile is the frame's last write before it parks on arbitration,
// so this puts the frame deterministically inside the window (claimed, not
// yet settled).
func awaitClaimed(t *testing.T, f claimFixture) {
	t.Helper()
	<-f.pr.CompletionIngressSignal()
	waitForAdaptiveCondition(t, 2*time.Second, func() bool {
		raw, _ := f.ap.ProviderProfileRaw()
		return f.ap.TerminalClaimed() && raw != nil
	})
}

func awaitClosed(t *testing.T, ch <-chan struct{}, what string) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(2 * time.Second):
		t.Fatal(what)
	}
}

// awaitClaimRecord lands the handler half and returns the finalized record;
// the attempt must not have finalized on the terminal half alone.
func awaitClaimRecord(t *testing.T, f claimFixture) *store.RequestProfileRecord {
	t.Helper()
	select {
	case <-f.finalized:
		t.Fatal("attempt finalized before the handler half landed")
	default:
	}
	f.ap.CompleteHandler()
	select {
	case rec := <-f.finalized:
		return rec
	case <-time.After(2 * time.Second):
		t.Fatal("claimed attempt never finalized")
		return nil
	}
}

// assertClaimRow checks a completed provider outcome, the funnel's
// status/reason and a retained, consistent profile.
func assertClaimRow(t *testing.T, rec *store.RequestProfileRecord, want *store.InferenceRouteOutcome) {
	t.Helper()
	if rec.ProviderOutcome != "completed" || rec.FinalStatus != want.FinalStatus || rec.ErrorReason != profileErrorReason(want) {
		t.Fatalf("row = %q/%q/%q, want completed/%s/%s", rec.ProviderOutcome, rec.FinalStatus, rec.ErrorReason, want.FinalStatus, profileErrorReason(want))
	}
	if !rec.ProviderProfileValid || rec.ProviderProfileInvalidReason != "" || rec.ProviderProfileConsistent == nil || !*rec.ProviderProfileConsistent {
		t.Fatalf("profile sent with the completion must be retained: valid=%v reason=%q consistent=%v",
			rec.ProviderProfileValid, rec.ProviderProfileInvalidReason, rec.ProviderProfileConsistent)
	}
}

func TestClaimedCompleteFrameFinalizesAfterPendingRemoved(t *testing.T) {
	newFixture := func(t *testing.T, id string, deadline time.Time) claimFixture {
		return newClaimFixture(t, id, deadline, 0)
	}
	runFrame, await, awaitRecord, assertRow := runClaimFrame, awaitClosed, awaitClaimRecord, assertClaimRow

	t.Run("arbitration window, client gone", func(t *testing.T) {
		const id = "claim-window-client-gone"
		f := newFixture(t, id, time.Now().Add(time.Minute))
		f.pr.EnableSpeculativeEmptyCompletionArbitration()
		done := runFrame(f, id)
		awaitClaimed(t, f)
		select {
		case <-done:
			t.Fatal("empty completion settled before speculative arbitration")
		default:
		}
		// The consumer-side cleanup lands while the frame is parked on the
		// arbitration: pending removed, cancelled through the funnel (which
		// leaves the claimed terminal to the frame), then the frame is released
		// and finds nothing to settle.
		if f.provider.RemovePending(id) != f.pr {
			t.Fatal("pending request was not in the provider's set")
		}
		want := clientGoneBeforeResponseOutcome(f.pr)
		f.srv.updateInferenceRouteOutcomeForPending(f.pr, want)
		f.pr.ResolveSpeculativeEmptyCompletion(true)
		await(t, done, "released completion frame did not return")
		if n := f.srv.unknownRequestFrames.Load(); n != 1 {
			t.Fatalf("frame must have returned through the unknown-request path, unknown frames=%d", n)
		}
		rec := awaitRecord(t, f)
		assertRow(t, rec, want)
		if f.provider.GetPending(id) != nil {
			t.Fatal("pending request must stay removed")
		}
		select {
		case <-f.pr.CompleteCh:
			t.Fatal("completion was published to a consumer that had left")
		default:
		}
	})

	t.Run("deadline-late, pending gone before handleInferenceError", func(t *testing.T) {
		const id = "claim-window-deadline-late"
		f := newFixture(t, id, time.Now().Add(-time.Second)) // past deadline, no first content
		// There is no synchronization point a test can hold between the claim
		// and the deadline-late handleInferenceError call, so the concurrent
		// remover is stood in for by rebinding the request id before the frame
		// starts: GetPending (keyed by the registered id) still hits and claims,
		// while handleInferenceError's RemovePending/claimSettlement (keyed by
		// pending.RequestID) miss — exactly the state a remover that won the
		// window leaves behind. The write happens-before the goroutine start.
		f.pr.RequestID = id + "-removed"
		defer f.provider.RemovePending(id)
		done := runFrame(f, id)
		await(t, done, "deadline-late completion frame did not return")
		if !f.ap.TerminalClaimed() {
			t.Fatal("the frame must own the terminal claim at ingress")
		}
		if n := f.srv.unknownRequestFrames.Load(); n != 1 {
			t.Fatalf("handleInferenceError must have taken the unknown-request path, unknown frames=%d", n)
		}
		// The dispatch side classifies the timeout through the funnel, which
		// leaves the claimed terminal to the frame.
		want := preResponseTimeoutOutcome(f.pr, "first_chunk_timeout")
		f.srv.updateInferenceRouteOutcomeForPending(f.pr, want)
		rec := awaitRecord(t, f)
		assertRow(t, rec, want)
		select {
		case <-f.pr.CompleteCh:
			t.Fatal("deadline-late completion was published to the consumer")
		default:
		}
	})
}

// TestDuplicateErrorFrameAfterOwnedCompletionIsDropped pins terminal
// ownership across terminal TYPES. Completions settle on a worker goroutine
// while error frames run inline on the read loop, so an inference_error for a
// request whose completion already claimed the terminal used to remove the
// pending request, write the error outcome and settle — the row mixed the
// completion's usage/profile with the error frame's outcome. The error frame
// must instead fail its claim, be dropped as a duplicate without touching the
// pending request, and the completion must settle as the owner.
func TestDuplicateErrorFrameAfterOwnedCompletionIsDropped(t *testing.T) {
	const id = "dup-error-after-owned-completion"
	f := newClaimFixture(t, id, time.Now().Add(time.Minute), 0)
	f.pr.EnableSpeculativeEmptyCompletionArbitration()
	done := runClaimFrame(f, id)
	awaitClaimed(t, f)

	// The error frame lands on the read loop while the completion is parked
	// on arbitration. It carries a distinguishable profile so the row can
	// prove whose bytes it kept.
	f.srv.handleInferenceError(f.provider.ID, f.provider, &protocol.InferenceErrorMessage{
		Type:       protocol.TypeInferenceError,
		RequestID:  id,
		Error:      "provider aborted",
		StatusCode: http.StatusInternalServerError,
		Profile:    []byte(`{"schema":1,"total_us":999}`),
	})
	if f.provider.GetPending(id) != f.pr {
		t.Fatal("a duplicate error frame must leave the pending request to the terminal's owner")
	}
	if n := f.srv.unknownRequestFrames.Load(); n != 1 {
		t.Fatalf("duplicate error must be counted as an unknown-request frame once, got %d", n)
	}
	if fs, er, tc, po, co := f.ap.Outcome(); fs != "" || er != "" || tc != "" || po != "" || co != "" {
		t.Fatalf("a dropped error frame must write no outcome, got %q/%q/%q/%q/%q", fs, er, tc, po, co)
	}
	if raw, _ := f.ap.ProviderProfileRaw(); string(raw) != claimTestProfile {
		t.Fatalf("the owner's profile must be kept, got %s", raw)
	}
	select {
	case <-done:
		t.Fatal("completion settled before arbitration")
	default:
	}

	f.pr.ResolveSpeculativeEmptyCompletion(true)
	awaitClosed(t, done, "owned completion did not settle after arbitration")
	if f.provider.GetPending(id) != nil {
		t.Fatal("the owner must have removed the pending request when settling")
	}
	rec := awaitClaimRecord(t, f)
	assertClaimRow(t, rec, &store.InferenceRouteOutcome{FinalStatus: finalStatusSuccess})
	if rec.ProvTotalUS == nil || *rec.ProvTotalUS != 1000 {
		t.Fatalf("row must carry the completion's profile, not the error frame's: total_us=%v", rec.ProvTotalUS)
	}
	select {
	case usage := <-f.pr.CompleteCh:
		if usage.PromptTokens != 100 {
			t.Fatalf("consumer received usage %+v", usage)
		}
	default:
		t.Fatal("the owning completion must reach the consumer")
	}
}

// TestRefundWinsCompletionKeepsProviderOutcome pins the refund-wins ordering:
// the consumer relay's timeout finalizes (refunds) the reservation after the
// completion frame claimed the terminal but before it settles. The billing
// gate is then skipped, and the only in-gate provider-outcome write with it,
// so the deferred CompleteTerminal used to close the record with an empty
// provider_outcome. The frame must record "completed" outside the gate and
// still carry its usage and profile; final_status comes from the timeout the
// relay classified through the funnel.
func TestRefundWinsCompletionKeepsProviderOutcome(t *testing.T) {
	const id = "refund-wins-completion"
	f := newClaimFixture(t, id, time.Now().Add(time.Minute), 2_000_000)
	f.pr.EnableSpeculativeEmptyCompletionArbitration()
	done := runClaimFrame(f, id)
	awaitClaimed(t, f)

	// What the relay's timer branch does (consumer.go): refund, then classify.
	if !f.srv.refundReservedBalance(f.pr, "provider_timeout:"+id) {
		t.Fatal("the timeout refund must finalize the reservation before the completion settles")
	}
	want := postCommitStreamTimeoutOutcome(f.pr)
	f.srv.updateInferenceRouteOutcomeForPending(f.pr, want)
	select {
	case <-done:
		t.Fatal("completion settled before arbitration")
	default:
	}

	f.pr.ResolveSpeculativeEmptyCompletion(true)
	awaitClosed(t, done, "completion did not settle after the refund")
	if !f.pr.IsReservationFinalized() {
		t.Fatal("reservation must stay finalized by the refund")
	}
	rec := awaitClaimRecord(t, f)
	assertClaimRow(t, rec, want)
	if p, _, ok := f.ap.TerminalUsage(); !ok || p != 100 {
		t.Fatalf("terminal usage must be recorded outside the billing gate: %d ok=%v", p, ok)
	}
}

// TestClaimedErrorFrameFinalizesAfterPendingRemoved pins the error-frame twin
// of the completion claim window: the frame claims the terminal at the peek
// and retains its profile there, a consumer-side remover takes the pending
// request before the frame's own RemovePending, and the frame returns through
// the unknown-request path — which must close the claimed record
// (provider_outcome=error) carrying the profile it already retained, or the
// attempt never finalizes and the profile is recorded absent.
//
// There is no point between the peek-claim and RemovePending a test can hold,
// and both lookups are keyed on msg.RequestID (so the deadline-late
// id-rebinding trick cannot produce a hit-then-miss here). The remover
// therefore races the frame, biased by the provider's own pending-map mutex:
// the test holds it, lets the parked frame through its GetPending only in
// brief unlock/lock gaps, and once the claim is visible (possible only after
// that GetPending hit) releases and removes the pending — the frame's own
// RemovePending, reached a few hundred nanoseconds later or already parked
// behind the test, misses. An iteration the frame still won is discarded and
// retried on a fresh pending; the measured hit rate is well over half, so the
// bound is never approached.
func TestClaimedErrorFrameFinalizesAfterPendingRemoved(t *testing.T) {
	const errorProfile = `{"schema":1,"total_us":999}`
	const attempts = 300
	srv := newProfilerTestServer(t)
	for i := 0; i < attempts; i++ {
		id := "claimed-error-frame-" + strconv.Itoa(i)
		f := newClaimFixtureOn(t, srv, id, time.Now().Add(time.Minute), 0)
		before := srv.unknownRequestFrames.Load()
		mu := f.provider.Mu()
		mu.Lock()
		done := make(chan struct{})
		go func() {
			srv.handleInferenceError(f.provider.ID, f.provider, &protocol.InferenceErrorMessage{
				Type:       protocol.TypeInferenceError,
				RequestID:  id,
				Error:      "provider aborted",
				StatusCode: http.StatusInternalServerError,
				Profile:    []byte(errorProfile),
			})
			close(done)
		}()
		deadline := time.Now().Add(2 * time.Second)
		for !f.ap.TerminalClaimed() {
			if time.Now().After(deadline) {
				mu.Unlock()
				t.Fatal("error frame never claimed the terminal")
			}
			mu.Unlock() // let the parked frame through its GetPending …
			mu.Lock()   // … and hold the map again ahead of its RemovePending
		}
		// The consumer-side remover: the frame owns the claim and is between
		// retention and its own RemovePending (or parked on this mutex).
		mu.Unlock()
		removed := f.provider.RemovePending(id) != nil
		awaitClosed(t, done, "error frame did not return")
		if !removed {
			// The frame's own RemovePending won: normal path, window not hit.
			f.ap.CompleteHandler()
			continue
		}
		t.Logf("remover won the claim→RemovePending window on iteration %d", i)
		if n := srv.unknownRequestFrames.Load() - before; n != 1 {
			t.Fatalf("frame must have returned through the unknown-request path exactly once, got %d", n)
		}
		if raw, _ := f.ap.ProviderProfileRaw(); string(raw) != errorProfile {
			t.Fatalf("profile must be retained at the peek claim, got %q", raw)
		}
		rec := awaitClaimRecord(t, f)
		if rec.ProviderOutcome != "error" || rec.FinalStatus != "error" {
			t.Fatalf("row = %q/%q, want error/error", rec.ProviderOutcome, rec.FinalStatus)
		}
		if !rec.ProviderProfileValid || rec.ProviderProfileInvalidReason != "" || rec.ProvTotalUS == nil || *rec.ProvTotalUS != 999 {
			t.Fatalf("profile sent with the error frame must be retained and valid: valid=%v reason=%q total_us=%v",
				rec.ProviderProfileValid, rec.ProviderProfileInvalidReason, rec.ProvTotalUS)
		}
		select {
		case e := <-f.pr.ErrorCh:
			t.Fatalf("error published to a consumer that had left: %+v", e)
		default:
		}
		return
	}
	t.Fatalf("the remover never won the claim→RemovePending window in %d attempts", attempts)
}

// TestRelayStampsCountOnlyWrittenBytes pins the egress accounting contract:
// only bytes the ResponseWriter accepted are flushed, a failed write marks
// client_write_err, and a stream whose write failed never claims done.
func TestRelayStampsCountOnlyWrittenBytes(t *testing.T) {
	rp := registry.NewRequestProfile(time.Now(), "c", nil, 0)
	rs := newRelayStamps(rp)
	rs.wrote(5, nil)
	rs.wrote(7, nil)
	if got := rp.BytesOut.Load(); got != 12 || rp.ChunksOut.Load() != 2 || rp.FirstFlushUS.Load() == 0 {
		t.Fatalf("clean writes: bytes=%d chunks=%d first_flush=%d", got, rp.ChunksOut.Load(), rp.FirstFlushUS.Load())
	}
	rs.wrote(0, errors.New("broken pipe"))
	if rp.BytesOut.Load() != 12 || rp.ChunksOut.Load() != 2 || !rp.ClientWriteErr.Load() {
		t.Fatalf("failed write must count nothing and flag client_write_err: bytes=%d chunks=%d err=%v", rp.BytesOut.Load(), rp.ChunksOut.Load(), rp.ClientWriteErr.Load())
	}
	rs.wrote(3, errors.New("short")) // partial: the 3 accepted bytes count, the error is kept
	if rp.BytesOut.Load() != 15 || !rp.ClientWriteErr.Load() {
		t.Fatalf("short write: bytes=%d err=%v", rp.BytesOut.Load(), rp.ClientWriteErr.Load())
	}
	rs.done()
	if rp.DoneFlushedUS.Load() != 0 || rp.LastFlushUS.Load() == 0 {
		t.Fatalf("done after a failed write must not claim done_flushed (done=%d last=%d)", rp.DoneFlushedUS.Load(), rp.LastFlushUS.Load())
	}
	clean := registry.NewRequestProfile(time.Now(), "c", nil, 0)
	cs := newRelayStamps(clean)
	cs.wrote(4, nil)
	cs.done()
	if clean.DoneFlushedUS.Load() == 0 || clean.ClientWriteErr.Load() {
		t.Fatal("clean stream must stamp done_flushed")
	}
}
