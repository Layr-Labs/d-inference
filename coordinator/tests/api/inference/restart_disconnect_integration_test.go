package inference_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// awaitCondition polls cond until it holds or timeout elapses.
func awaitCondition(t *testing.T, timeout time.Duration, cond func() bool, what string) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// TestVersionChangedReconnect_LateFlushStrikesAreSuperseded: the flush 502s of
// an abruptly dropped session are recorded by the request goroutines that
// drain its ErrorCh, so they can reach noteInferenceError AFTER the identity's
// version-changed reset — registration evicts a same-serial predecessor
// (DisconnectDuplicatesBySerial) and stores the new version on the same
// goroutine, ahead of those consumers. The reset then ran against empty
// windows and consumed its interval; without the discard the late strikes
// would quarantine the NEW binary for the old one's death. Every tracker must
// stay closed for the new session, while the strikes of a session that died
// under an unchanged version, or after the reset (a throttled third version
// stamps no new reset), still land.
func TestVersionChangedReconnect_LateFlushStrikesAreSuperseded(t *testing.T) {
	const (
		serial = "SER-LATE-FLUSH"
		stable = "serial:" + serial
		model  = "late-flush-model"
	)
	bind := func(t *testing.T, reg *registry.Registry, id, version string) {
		t.Helper()
		p := makeRoutableProvider(t, reg, id, model)
		// Registration order: attestation binds the identity, then the api
		// stores the version (the seam that runs the reset).
		p.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: serial})
		p.SetVersion(version)
	}
	// dropAbruptly parks work on the session and drops it without a close
	// frame: the flush is now in the consumer's ErrorCh, not yet recorded.
	dropAbruptly := func(t *testing.T, reg *registry.Registry, id string) {
		t.Helper()
		p := reg.GetProvider(id)
		if p == nil {
			t.Fatalf("provider %s not registered", id)
		}
		p.AddPending(&registry.PendingRequest{
			RequestID:  id + "-req",
			Model:      model,
			ProviderID: id,
			ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
		})
		reg.DisconnectWithReason(id, registry.DisconnectReasonReadError)
	}
	// feedFlush plays the consumers' recording of the flushed 502s through
	// the breaker chokepoint: enough for the inference-error cooldown (2), the
	// node breaker (5) and the identity ejection (8).
	feedFlush := func(srv *serverFixture, id string) {
		pr := &registry.PendingRequest{RequestID: id + "-req", Model: model, ProviderID: id}
		for i := 0; i < 8; i++ {
			srv.health.RecordError(id, pr, 502, "provider disconnected", "", "", protocol.CoordinatorCauseProviderDisconnected)
		}
	}
	quarantined := func(t *testing.T, reg *registry.Registry, liveID string, want bool) {
		t.Helper()
		if got := reg.InferenceErrorCooldownActive(liveID, model, "base"); got != want {
			t.Errorf("InferenceErrorCooldownActive(%s) = %v, want %v", liveID, got, want)
		}
		if got := reg.ProviderBreakerOpen(liveID); got != want {
			t.Errorf("ProviderBreakerOpen(%s) = %v, want %v", liveID, got, want)
		}
		if got := reg.HealthEjectionOpen(stable); got != want {
			t.Errorf("HealthEjectionOpen(%s) = %v, want %v", stable, got, want)
		}
	}

	t.Run("flush recorded after the version reset is discarded", func(t *testing.T) {
		srv, reg, _, ts := setupTestServer(t)
		defer ts.Close()
		bind(t, reg, "s1", "0.9.0")
		dropAbruptly(t, reg, "s1")
		bind(t, reg, "s2", "0.9.1") // reset runs here, against empty windows
		feedFlush(srv, "s1")        // the consumers catch up afterwards
		quarantined(t, reg, "s2", false)
	})

	t.Run("same version keeps striking", func(t *testing.T) {
		srv, reg, _, ts := setupTestServer(t)
		defer ts.Close()
		bind(t, reg, "s1", "0.9.0")
		dropAbruptly(t, reg, "s1")
		bind(t, reg, "s2", "0.9.0") // the zombie signature: no reset
		feedFlush(srv, "s1")
		quarantined(t, reg, "s2", true)
	})

	t.Run("a drop after the reset still strikes even when the next version change is throttled", func(t *testing.T) {
		srv, reg, _, ts := setupTestServer(t)
		defer ts.Close()
		bind(t, reg, "s1", "0.9.0")
		dropAbruptly(t, reg, "s1")
		bind(t, reg, "s2", "0.9.1")
		feedFlush(srv, "s1")
		quarantined(t, reg, "s2", false)

		dropAbruptly(t, reg, "s2")
		bind(t, reg, "s3", "0.9.2") // inside the interval: throttled, no new reset
		feedFlush(srv, "s2")
		quarantined(t, reg, "s3", true)
	})
}
