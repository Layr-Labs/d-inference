package registry_test

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/providerwrite"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/google/uuid"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func retirementProvider(t *testing.T, configure ...func(*production.Dependencies)) (*production.Registry, *production.Provider) {
	t.Helper()
	deps := production.Dependencies{}
	for _, configure := range configure {
		configure(&deps)
	}
	r := production.NewWithDependencies(testLogger(), deps)
	p := makeSchedulerProvider(t, r, "p", "m", 100)
	used := 0.0
	p.BackendCapacity.WholeMacServiceUsed = &used
	p.BackendCapacity.WholeMacServiceRetirementProtocol = 1
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: p.BackendCapacity}) {
		t.Fatal("capability heartbeat rejected")
	}
	return r, p
}

func TestWholeMacRetirementKeepsUnseenTerminalLeasesCharged(t *testing.T) {
	f := newServiceRetirementFixture(t, true)
	r, p := f.r, f.p
	var ids []string
	for i := 0; i < 24; i++ {
		if !f.headroom() {
			t.Fatalf("early saturation at %d", i)
		}
		pr := f.attempt(t, fmt.Sprint(i), 1.0/24)
		ids = append(ids, pr.ServiceReservationID())
		p.RemovePending(pr.RequestID)
	}
	if p.PendingCount() != 0 || f.account().Retiring != 24 || f.headroom() {
		t.Fatal("terminal released unseen native leases")
	}
	// A newly numbered, later-received report can still be a cached snapshot
	// built before acquisition. Neither absence nor elapsed time is proof.
	capacity := *p.BackendCapacity
	capacity.CapacitySeq = 50
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: &capacity}) {
		t.Fatal("heartbeat rejected")
	}
	if f.headroom() {
		t.Fatal("absent IDs erased terminal leases")
	}
	if !r.ReleaseServiceReservation(p, ids[0]) || !f.headroom() {
		t.Fatal("explicit retirement did not free capacity")
	}
	if r.ReleaseServiceReservation(p, ids[0]) {
		t.Fatal("duplicate retirement applied")
	}
}

func TestWholeMacRetirementCorrelatedSnapshotDoesNotDoubleCharge(t *testing.T) {
	f := newServiceRetirementFixture(t, true)
	r, p := f.r, f.p
	pr := f.attempt(t, "held", .5)
	p.RemovePending(pr.RequestID)
	used := .5
	p.BackendCapacity.WholeMacServiceUsed = &used
	p.BackendCapacity.WholeMacServiceReservations = []protocol.WholeMacServiceReservation{{ID: pr.ServiceReservationID(), UsedFraction: .5}}
	if !f.headroom() {
		t.Fatal("reported terminal lease charged twice")
	}
	if !r.ReleaseServiceReservation(p, pr.ServiceReservationID()) {
		t.Fatal("release rejected")
	}
	if f.account().Retiring != 0 {
		t.Fatal("retired shadow retained")
	}
}

func TestWholeMacRetirementReleaseBeforeTerminalAndNeverSent(t *testing.T) {
	f := newServiceRetirementFixture(t, true)
	r, p := f.r, f.p
	pr := f.attempt(t, "fast", 1.0/24)
	if !r.ReleaseServiceReservation(p, pr.ServiceReservationID()) {
		t.Fatal("early release rejected")
	}
	p.RemovePending(pr.RequestID)
	neverSent := &production.PendingRequest{RequestID: "never-sent", Model: "m"}
	p.AddPending(neverSent)
	p.RemovePending(neverSent.RequestID)
	if f.account().Retiring != 0 {
		t.Fatal("fast/never-sent request leaked a shadow")
	}
	for _, id := range []string{"", "sensitive-invalid-id", uuid.NewString()} {
		if r.ReleaseServiceReservation(p, id) {
			t.Fatal("unknown/malformed release accepted")
		}
	}
	if f.account().Retiring != 0 {
		t.Fatal("unknown releases allocated history")
	}
}

func TestWholeMacRetirementFreezesAttemptAndSurvivesTemporaryStateLoss(t *testing.T) {
	f := newServiceRetirementFixture(t, true)
	r, p := f.r, f.p
	pr := f.attempt(t, "retry", .5)
	id := pr.ServiceReservationID()
	p.RemovePending(pr.RequestID)
	p.AddPending(pr)
	prior := protocol.WholeMacServiceReservation{ID: id, UsedFraction: .5}
	if f.account().UnreportedCharge != .5 || f.account(prior).UnreportedCharge != 0 || id == pr.ServiceReservationID() {
		t.Fatal("retry mutated prior attempt charge")
	}
	r.MarkUntrustedTransient(p.ID)
	r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle"})
	if f.account().UnreportedCharge != .5 || f.account(prior).UnreportedCharge != 0 || f.headroom() {
		t.Fatal("untrust/capacity omission reset lease ownership")
	}
	if !r.ReleaseServiceReservation(p, id) {
		t.Fatal("untrusted connection could not retire its lease")
	}
	r.Disconnect(p.ID)
	// With capacity still omitted, headroom proves the sticky protocol was
	// cleared as well as the ledger and live-connection release authority.
	if !f.headroom() || f.account().Retiring != 0 || r.ReleaseServiceReservation(p, pr.ServiceReservationID()) {
		t.Fatal("disconnected session retained lease state")
	}
}

func TestWholeMacRetirementReleaseWakesQueuedRequest(t *testing.T) {
	f := newServiceRetirementFixture(t, true)
	r, p := f.r, f.p
	pr := f.attempt(t, "slow-retirement", 1)
	p.RemovePending(pr.RequestID)
	queued := &production.QueuedRequest{
		RequestID: "waiting", Model: "m", ResponseCh: make(chan *production.Provider, 1),
		Pending: &production.PendingRequest{
			RequestID: "waiting", Model: "m", RequestedMaxTokens: 64, EstimatedPromptTokens: 32,
		},
	}
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
	f := newServiceRetirementFixture(t, true)
	p := f.p
	pr := f.attempt(t, "aborted", 1.0/24)
	handoff := p.NewInferenceHandoff(pr)
	handoff.Abort()
	if err := handoff.Authorize(); err == nil {
		t.Fatal("late authorization resurrected aborted attempt")
	}
	p.RemovePending(pr.RequestID)
	if f.account().Retiring != 0 || f.frames.Load() != 0 {
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
	f := newServiceRetirementFixture(t, true)
	p := f.p
	pr := &production.PendingRequest{RequestID: "blocked-authorization", Model: "m", ProviderID: p.ID}
	p.AddPending(pr)
	handoff := p.NewInferenceHandoff(pr)
	entered, resume, authorized := make(chan struct{}), make(chan struct{}), make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan production.TextFrameWriteMetadata, 1)
	authorizationErr := make(chan error, 1)
	go func() {
		metadata, _ := f.writer.WriteRequest(ctx, providerwrite.NewDeferred(func(time.Time) ([]byte, error) { return []byte("sealed"), nil }, func() error {
			close(entered)
			<-resume
			defer close(authorized)
			err := handoff.Authorize()
			authorizationErr <- err
			return err
		}), false, nil)
		if !metadata.Committed {
			handoff.Abort()
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
	if <-authorizationErr == nil || f.account().Retiring != 0 || f.frames.Load() != 0 {
		t.Fatal("late callback resurrected the definitely-unsent reservation")
	}
}

func TestWholeMacRetirementLegacyProviderDoesNotRetainShadows(t *testing.T) {
	f := newServiceRetirementFixture(t, false)
	pr := f.attempt(t, "legacy-request", 1.0/24)
	f.p.RemovePending(pr.RequestID)
	if f.account().Retiring != 0 || !f.headroom() {
		t.Fatal("provider without release protocol acquired permanent shadows")
	}
}

func TestWholeMacRetirementCapabilityAtAuthorizedHandoff(t *testing.T) {
	for _, beforeHandoff := range []bool{true, false} {
		t.Run(fmt.Sprintf("capability_before_handoff_%t", beforeHandoff), func(t *testing.T) {
			f := newServiceRetirementFixture(t, false)
			r, p := f.r, f.p
			pr := &production.PendingRequest{RequestID: "reserved-before-capability", Model: "m", ProviderID: p.ID}
			p.AddPending(pr)
			p.Mu().Lock()
			tracked := f.reservations.ReleasePending(pr.ServiceReservationID())
			p.Mu().Unlock()
			if tracked {
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
				func(production.TextFrameWriteMetadata) {
					// The reservation and frame already exist; capability lands
					// immediately before the final writer authorization.
					if beforeHandoff {
						optIn()
					}
				})
			if err != nil || !metadata.Committed || f.frames.Load() != 1 {
				t.Fatalf("handoff failed: metadata=%+v frames=%d err=%v", metadata, f.frames.Load(), err)
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
			shadowed := f.account().Retiring == 1
			if shadowed != beforeHandoff {
				t.Fatalf("shadowed=%t, want %t for capability at authorized handoff", shadowed, beforeHandoff)
			}
			if beforeHandoff && !r.ReleaseServiceReservation(p, pr.ServiceReservationID()) {
				t.Fatal("tracked handoff did not retire through explicit proof")
			}
			if f.account().Retiring != 0 {
				t.Fatal("retirement shadow leaked")
			}
		})
	}
}
