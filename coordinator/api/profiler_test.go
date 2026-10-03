package api

import (
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	inresp "github.com/eigeninference/d-inference/coordinator/api/inference/response"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func newProfilerTestServer(t *testing.T) *Server {
	t.Helper()
	t.Setenv("EIGENINFERENCE_PROFILE_SAMPLE_RATE", "1")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	srv := NewServer(registry.New(logger), memory.NewMemory(store.Config{}), ServerConfig{AdminKey: "admin-test-key"}, logger)
	t.Cleanup(srv.Close)
	return srv
}

func TestRequestMetaAlwaysMintsCoordinatorID(t *testing.T) {
	srv := newProfilerTestServer(t)
	var seenCoord, seenReq string
	h := srv.loggingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenCoord = observation.CoordRequestIDFromContext(r.Context())
		seenReq = access.RequestIDFromContext(r.Context())
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

func TestProfilerKillSwitchDoesNotAttachRequestMetadata(t *testing.T) {
	t.Setenv("EIGENINFERENCE_PROFILER", "off")
	srv := newProfilerTestServer(t)
	h := srv.loggingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if observation.HasRequestMeta(r.Context()) {
			t.Error("no request meta when the profiler is off")
		}
	}))
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/health", nil))
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
	srv      *Server
	provider *registry.Provider
	pr       *registry.PendingRequest
	ap       *registry.AttemptProfile
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
	rp := observedTestProfile(t, srv, time.Now(), "coord-"+id)
	ap := rp.NewAttempt(id, 0, "")
	ap.ProviderID = provider.ID
	ap.Mark(registry.StampWriteSubmitted)
	ap.Mark(registry.StampWriteDone)
	pr.Profile = ap
	provider.AddPending(pr)
	return claimFixture{srv: srv, provider: provider, pr: pr, ap: ap}
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
	if f.ap.Finalized() {
		t.Fatal("attempt finalized before the handler half landed")
	}
	f.ap.CompleteHandler()
	return awaitPersistedProfile(t, f.srv, f.ap)
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
		before := srv.observation.UnknownRequestFrames()
		mu := f.provider.Mu()
		mu.Lock()
		done := make(chan struct{})
		go func() {
			srv.inference.HandleInferenceError(f.provider.ID, f.provider, &protocol.InferenceErrorMessage{
				Type:        protocol.TypeInferenceError,
				RequestID:   id,
				Error:       "provider aborted",
				StatusCode:  http.StatusInternalServerError,
				Profile:     []byte(errorProfile),
				FailureCode: protocol.FailureCodeGenerationFailure,
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
		if n := srv.observation.UnknownRequestFrames() - before; n != 1 {
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
	rs := observation.NewRelayStamps(rp)
	rs.Wrote(5, nil)
	rs.Wrote(7, nil)
	if got := rp.BytesOut.Load(); got != 12 || rp.ChunksOut.Load() != 2 || rp.FirstFlushUS.Load() == 0 {
		t.Fatalf("clean writes: bytes=%d chunks=%d first_flush=%d", got, rp.ChunksOut.Load(), rp.FirstFlushUS.Load())
	}
	rs.Wrote(0, errors.New("broken pipe"))
	if rp.BytesOut.Load() != 12 || rp.ChunksOut.Load() != 2 || !rp.ClientWriteErr.Load() {
		t.Fatalf("failed write must count nothing and flag client_write_err: bytes=%d chunks=%d err=%v", rp.BytesOut.Load(), rp.ChunksOut.Load(), rp.ClientWriteErr.Load())
	}
	rs.Wrote(3, errors.New("short")) // partial: the 3 accepted bytes count, the error is kept
	if rp.BytesOut.Load() != 15 || !rp.ClientWriteErr.Load() {
		t.Fatalf("short write: bytes=%d err=%v", rp.BytesOut.Load(), rp.ClientWriteErr.Load())
	}
	rs.Done()
	if rp.DoneFlushedUS.Load() != 0 || rp.LastFlushUS.Load() == 0 {
		t.Fatalf("done after a failed write must not claim done_flushed (done=%d last=%d)", rp.DoneFlushedUS.Load(), rp.LastFlushUS.Load())
	}
	clean := registry.NewRequestProfile(time.Now(), "c", nil, 0)
	cs := observation.NewRelayStamps(clean)
	cs.Wrote(4, nil)
	cs.Done()
	if clean.DoneFlushedUS.Load() == 0 || clean.ClientWriteErr.Load() {
		t.Fatal("clean stream must stamp done_flushed")
	}
}

// TestRelayStampsCoalescedWriteCountsFrames pins the contract the chat relay's
// batched flush relies on: one client write carrying several SSE frames
// advances chunks_out by the frame count (the field keeps meaning "frames
// delivered" whether or not chunks were coalesced), bytes_out by the accepted
// bytes only, and a failed write flags client_write_err exactly as wrote does.
func TestRelayStampsCoalescedWriteCountsFrames(t *testing.T) {
	rp := registry.NewRequestProfile(time.Now(), "c", nil, 0)
	rs := observation.NewRelayStamps(rp)
	rs.WroteFrames(3, 100, nil)
	if rp.ChunksOut.Load() != 3 || rp.BytesOut.Load() != 100 || rp.FirstFlushUS.Load() == 0 {
		t.Fatalf("coalesced write: chunks=%d bytes=%d first_flush=%d, want 3/100/stamped",
			rp.ChunksOut.Load(), rp.BytesOut.Load(), rp.FirstFlushUS.Load())
	}
	rs.WroteFrames(0, 0, nil) // an empty batch (relay.flush with nothing buffered) counts nothing
	rs.WroteFrames(2, 0, errors.New("broken pipe"))
	if rp.ChunksOut.Load() != 3 || rp.BytesOut.Load() != 100 || !rp.ClientWriteErr.Load() {
		t.Fatalf("failed coalesced write must count nothing and flag client_write_err: chunks=%d bytes=%d err=%v",
			rp.ChunksOut.Load(), rp.BytesOut.Load(), rp.ClientWriteErr.Load())
	}
	rs.WroteFrames(2, 10, errors.New("short")) // partial: the accepted bytes and the frames count, the error is kept
	if rp.ChunksOut.Load() != 5 || rp.BytesOut.Load() != 110 || !rp.ClientWriteErr.Load() {
		t.Fatalf("short coalesced write: chunks=%d bytes=%d err=%v",
			rp.ChunksOut.Load(), rp.BytesOut.Load(), rp.ClientWriteErr.Load())
	}
	// wrote stays the one-frame case of the same accounting.
	rs.Wrote(4, nil)
	if rp.ChunksOut.Load() != 6 || rp.BytesOut.Load() != 114 {
		t.Fatalf("wrote after wroteFrames: chunks=%d bytes=%d, want 6/114", rp.ChunksOut.Load(), rp.BytesOut.Load())
	}
}

// TestChatStreamRelayFlushReportsFramesAndBytes pins the relay side of the
// same contract: flush records the number of frames in the batch and the bytes
// the ResponseWriter accepted in the request profile, in one write and one
// Flush, and an empty batch neither writes nor flushes.
func TestChatStreamRelayFlushReportsFramesAndBytes(t *testing.T) {
	w := newCapturingResponseWriter()
	rp := registry.NewRequestProfile(time.Now(), "c", nil, 0)
	relay := inresp.NewChatStreamRelay(&registry.PendingRequest{}, w, w, observation.NewRelayStamps(rp))
	relay.WriteFrame(`data: {"a":1}`)
	relay.WriteFrame(`data: {"b":2}`)
	relay.WriteFrame("data: [DONE]")
	relay.Flush()
	want := "data: {\"a\":1}\n\ndata: {\"b\":2}\n\ndata: [DONE]\n\n"
	if w.body.String() != want || w.writes != 1 || w.flushes != 1 {
		t.Fatalf("flush wrote %q in %d write(s) / %d flush(es); want %q in 1 / 1",
			w.body.String(), w.writes, w.flushes, want)
	}
	if rp.ChunksOut.Load() != 3 || rp.BytesOut.Load() != int64(len(want)) || rp.ClientWriteErr.Load() {
		t.Fatalf("profile chunks_out=%d bytes_out=%d client_write_err=%v; want 3 / %d / false",
			rp.ChunksOut.Load(), rp.BytesOut.Load(), rp.ClientWriteErr.Load(), len(want))
	}
	relay.Flush()
	if w.writes != 1 || w.flushes != 1 || rp.ChunksOut.Load() != 3 || rp.BytesOut.Load() != int64(len(want)) {
		t.Fatalf("empty flush must neither write nor flush nor count: writes=%d flushes=%d chunks_out=%d bytes_out=%d",
			w.writes, w.flushes, rp.ChunksOut.Load(), rp.BytesOut.Load())
	}
}
