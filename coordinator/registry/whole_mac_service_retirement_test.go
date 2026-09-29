package registry

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func retirementProvider(t *testing.T) (*Registry, *Provider) {
	t.Helper()
	r := New(testLogger())
	p := makeSchedulerProvider(t, r, "p", "m", 100)
	used := 0.0
	p.BackendCapacity.WholeMacServiceUsed = &used
	p.BackendCapacity.WholeMacServiceRetirementProtocol = 1
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: p.BackendCapacity}) {
		t.Fatal("capability heartbeat rejected")
	}
	return r, p
}

func retirementAttempt(p *Provider, id string) *PendingRequest {
	pr := &PendingRequest{RequestID: id, Model: "m", ProviderID: p.ID}
	p.AddPending(pr)
	// Final writer authorization is the only production setter; use a direct
	// owned stamp here to model a committed request without a test socket.
	pr.serviceHandoffAuthorized = true
	return pr
}

func TestWholeMacRetirementKeepsUnseenTerminalLeasesCharged(t *testing.T) {
	r, p := retirementProvider(t)
	var ids []string
	for i := 0; i < 24; i++ {
		if !p.hasWholeMacServiceHeadroomLocked("m") {
			t.Fatalf("early saturation at %d", i)
		}
		pr := retirementAttempt(p, fmt.Sprint(i))
		ids = append(ids, pr.ServiceReservationID())
		p.RemovePending(pr.RequestID)
	}
	if len(p.pendingReqs) != 0 || len(p.serviceRetirementShadows) != 24 || p.hasWholeMacServiceHeadroomLocked("m") {
		t.Fatal("terminal released unseen native leases")
	}
	// A newly numbered, later-received report can still be a cached snapshot
	// built before acquisition. Neither absence nor elapsed time is proof.
	capacity := *p.BackendCapacity
	capacity.CapacitySeq = 50
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: &capacity}) {
		t.Fatal("heartbeat rejected")
	}
	if p.hasWholeMacServiceHeadroomLocked("m") {
		t.Fatal("absent IDs erased terminal leases")
	}
	if !r.ReleaseServiceReservation(p, ids[0]) || !p.hasWholeMacServiceHeadroomLocked("m") {
		t.Fatal("explicit retirement did not free capacity")
	}
	if r.ReleaseServiceReservation(p, ids[0]) {
		t.Fatal("duplicate retirement applied")
	}
}

func TestWholeMacRetirementCorrelatedSnapshotDoesNotDoubleCharge(t *testing.T) {
	r, p := retirementProvider(t)
	pr := retirementAttempt(p, "held")
	pr.reservedServiceCharge = .5
	p.RemovePending(pr.RequestID)
	used := .5
	p.BackendCapacity.WholeMacServiceUsed = &used
	p.BackendCapacity.WholeMacServiceReservations = []protocol.WholeMacServiceReservation{{ID: pr.ServiceReservationID(), UsedFraction: .5}}
	if !p.hasWholeMacServiceHeadroomLocked("m") {
		t.Fatal("reported terminal lease charged twice")
	}
	if !r.ReleaseServiceReservation(p, pr.ServiceReservationID()) {
		t.Fatal("release rejected")
	}
	if len(p.serviceRetirementShadows) != 0 {
		t.Fatal("retired shadow retained")
	}
}

func TestWholeMacRetirementReleaseBeforeTerminalAndNeverSent(t *testing.T) {
	r, p := retirementProvider(t)
	pr := retirementAttempt(p, "fast")
	if !r.ReleaseServiceReservation(p, pr.ServiceReservationID()) {
		t.Fatal("early release rejected")
	}
	p.RemovePending(pr.RequestID)
	neverSent := &PendingRequest{RequestID: "never-sent", Model: "m"}
	p.AddPending(neverSent)
	p.RemovePending(neverSent.RequestID)
	if len(p.serviceRetirementShadows) != 0 {
		t.Fatal("fast/never-sent request leaked a shadow")
	}
	for _, id := range []string{"", "sensitive-invalid-id", newServiceReservationIdentity().wire} {
		if r.ReleaseServiceReservation(p, id) {
			t.Fatal("unknown/malformed release accepted")
		}
	}
	if len(p.serviceRetirementShadows) != 0 {
		t.Fatal("unknown releases allocated history")
	}
}

func TestWholeMacRetirementFreezesAttemptAndSurvivesTemporaryStateLoss(t *testing.T) {
	r, p := retirementProvider(t)
	pr := retirementAttempt(p, "retry")
	pr.reservedServiceCharge = .5
	id := pr.ServiceReservationID()
	p.RemovePending(pr.RequestID)
	p.AddPending(pr)
	if p.serviceRetirementShadows[id] != .5 || id == pr.ServiceReservationID() {
		t.Fatal("retry mutated prior attempt charge")
	}
	r.MarkUntrustedTransient(p.ID)
	r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle"})
	if !p.serviceRetirementProtocol || p.serviceRetirementShadows[id] != .5 || p.hasWholeMacServiceHeadroomLocked("m") {
		t.Fatal("untrust/capacity omission reset lease ownership")
	}
	if !r.ReleaseServiceReservation(p, id) {
		t.Fatal("untrusted connection could not retire its lease")
	}
	r.Disconnect(p.ID)
	if p.serviceRetirementProtocol || len(p.serviceRetirementShadows) != 0 || r.ReleaseServiceReservation(p, pr.ServiceReservationID()) {
		t.Fatal("disconnected session retained lease state")
	}
}

func TestWholeMacRetirementReleaseWakesQueuedRequest(t *testing.T) {
	r, p := retirementProvider(t)
	pr := retirementAttempt(p, "slow-retirement")
	pr.reservedServiceCharge = 1
	p.RemovePending(pr.RequestID)
	queued := swapTestQueued("waiting", "m")
	if err := r.Queue().Enqueue(queued); err != nil {
		t.Fatal(err)
	}
	r.SetProviderIdle(p.ID)
	select {
	case <-queued.ResponseCh:
		t.Fatal("queue bypassed held lease")
	default:
	}
	r.ReleaseServiceReservation(p, pr.ServiceReservationID())
	select {
	case got := <-queued.ResponseCh:
		if got != p {
			t.Fatal("wrong queued provider")
		}
	case <-time.After(time.Second):
		t.Fatal("release did not wake queue without a heartbeat")
	}
}

func TestWholeMacRetirementDefinitiveAbortFencesLateAuthorization(t *testing.T) {
	r, p := retirementProvider(t)
	w, frames := appAttestTestWriter(t, p)
	pr := retirementAttempt(p, "aborted")
	id := pr.ServiceReservationID()
	p.abortServiceReservationHandoff(id)
	if err := r.authorizeInferenceAttemptHandoff(p, pr, w, id); err == nil {
		t.Fatal("late authorization resurrected aborted attempt")
	}
	p.RemovePending(pr.RequestID)
	if len(p.serviceRetirementShadows) != 0 || frames.Load() != 0 {
		t.Fatal("aborted attempt leaked shadow/frame")
	}
	// A retry is a fresh identity and does not inherit the abort fence.
	p.AddPending(pr)
	_, err := p.WriteInferenceTextDeferred(context.Background(), pr,
		func(time.Time) ([]byte, error) { return []byte("sealed"), nil }, nil)
	if err != nil {
		t.Fatalf("fresh retry blocked: %v", err)
	}
}

func TestWholeMacRetirementCancellationWhileAuthorizationBlocked(t *testing.T) {
	r, p := retirementProvider(t)
	w, frames := appAttestTestWriter(t, p)
	pr := retirementAttempt(p, "blocked-authorization")
	pr.serviceHandoffAuthorized = false
	id := pr.ServiceReservationID()
	entered, resume, authorized := make(chan struct{}), make(chan struct{}), make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan TextFrameWriteMetadata, 1)
	go func() {
		metadata, _ := w.writeRequest(ctx, &providerWriteRequest{
			builder: func(time.Time) ([]byte, error) { return []byte("sealed"), nil },
			beforeWrite: func() error {
				close(entered)
				<-resume
				defer close(authorized)
				return r.authorizeInferenceAttemptHandoff(p, pr, w, id)
			},
		}, false, nil)
		if !metadata.Committed {
			p.abortServiceReservationHandoff(id)
		}
		done <- metadata
	}()
	<-entered // writer is authorizing, but its callback has not taken p.mu
	cancel()
	metadata := <-done
	if metadata.Committed {
		t.Fatal("blocked frame marked dispatched")
	}
	close(resume)
	<-authorized
	p.RemovePending(pr.RequestID)
	if pr.serviceHandoffAuthorized || len(p.serviceRetirementShadows) != 0 || frames.Load() != 0 {
		t.Fatal("late callback resurrected the definitely-unsent reservation")
	}
}

func TestWholeMacRetirementLegacyProviderDoesNotRetainShadows(t *testing.T) {
	r := New(testLogger())
	p := makeSchedulerProvider(t, r, "legacy", "m", 100)
	used := 0.0
	p.BackendCapacity.WholeMacServiceUsed = &used
	pr := retirementAttempt(p, "legacy-request")
	p.RemovePending(pr.RequestID)
	if len(p.serviceRetirementShadows) != 0 || !p.hasWholeMacServiceHeadroomLocked("m") {
		t.Fatal("provider without release protocol acquired permanent shadows")
	}
}

func TestWholeMacRetirementCapabilityAtAuthorizedHandoff(t *testing.T) {
	for _, beforeHandoff := range []bool{true, false} {
		t.Run(fmt.Sprintf("capability_before_handoff_%t", beforeHandoff), func(t *testing.T) {
			r := New(testLogger())
			p := makeSchedulerProvider(t, r, "p", "m", 100)
			used := 0.0
			p.BackendCapacity.WholeMacServiceUsed = &used
			_, frames := appAttestTestWriter(t, p)
			pr := &PendingRequest{RequestID: "reserved-before-capability", Model: "m", ProviderID: p.ID}
			p.AddPending(pr)
			if pr.serviceRetirementTracked {
				t.Fatal("reservation predates capability")
			}
			optIn := func() {
				capacity := *p.BackendCapacity
				capacity.WholeMacServiceRetirementProtocol = 1
				if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: &capacity}) {
					t.Fatal("capability heartbeat rejected")
				}
			}
			metadata, err := p.WriteInferenceTextDeferred(context.Background(), pr,
				func(time.Time) ([]byte, error) { return []byte("sealed"), nil },
				func(TextFrameWriteMetadata) {
					// The reservation and frame already exist; capability lands
					// immediately before the final writer authorization.
					if beforeHandoff {
						optIn()
					}
				})
			if err != nil || !metadata.Committed || frames.Load() != 1 {
				t.Fatalf("handoff failed: metadata=%+v frames=%d err=%v", metadata, frames.Load(), err)
			}
			if !beforeHandoff {
				// An actual legacy handoff may fully retire before the first
				// capability report. That ignored proof cannot be replayed, so
				// upgrading the attempt later would leak a permanent shadow.
				if r.ReleaseServiceReservation(p, pr.ServiceReservationID()) {
					t.Fatal("legacy release unexpectedly accepted")
				}
				optIn()
			}
			p.RemovePending(pr.RequestID)
			_, shadowed := p.serviceRetirementShadows[pr.ServiceReservationID()]
			if shadowed != beforeHandoff {
				t.Fatalf("shadowed=%t, want %t for capability at authorized handoff", shadowed, beforeHandoff)
			}
			if beforeHandoff && !r.ReleaseServiceReservation(p, pr.ServiceReservationID()) {
				t.Fatal("tracked handoff did not retire through explicit proof")
			}
			if len(p.serviceRetirementShadows) != 0 {
				t.Fatal("retirement shadow leaked")
			}
		})
	}
}
