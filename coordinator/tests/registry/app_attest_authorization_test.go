package registry_test

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/modelindex"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

const appAttestTestModel = "app-attest-model"

type appAttestTestClock struct{ atomic.Int64 }

func (c *appAttestTestClock) Now() time.Time {
	if nanos := c.Load(); nanos != 0 {
		return time.Unix(0, nanos)
	}
	return time.Now()
}

func appAttestTestProvider(t *testing.T, retained ...*production.Registry) (*production.Registry, *production.Provider, production.AppAttestServingAuthorization) {
	t.Helper()
	r := production.New(testLogger())
	if len(retained) != 0 {
		r = retained[0]
	}
	return appAttestTestProviderWithProtocol(t, r, 0)
}

func appAttestTestProviderWithProtocol(t *testing.T, r *production.Registry, version int) (*production.Registry, *production.Provider, production.AppAttestServingAuthorization) {
	t.Helper()
	r.SetAppAttestServingPolicy(true, 7)
	r.SetCodeAttestationPolicy(true, time.Now().Add(-time.Hour))
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{ID: appAttestTestModel, ModelType: "chat", Quantization: "4bit"}}
	msg.DecodeTPS = 90
	msg.AppAttestProtocol = version
	p := makeSchedulerProviderWithRegistration(t, r, "app-provider", appAttestTestModel, msg)
	p.RequireVerifiedMachineIdentity()
	p.Mu().Lock()
	p.AccountID = "account-1"
	p.TrustLevel = production.TrustNone
	p.ChallengeVerifiedSIP = false
	p.LastChallengeVerified = time.Time{}
	p.Mu().Unlock()
	if !r.BindVerifiedMachineIdentity(p, "account-1", "machine-1") {
		t.Fatal("bind identity")
	}
	now := time.Now()
	lease := production.AppAttestServingAuthorization{
		AccountID: "account-1", MachineID: "machine-1", CredentialID: "credential-1",
		ConnectionID: p.ID, ProofSessionID: "proof-session", Endpoint: p.PublicKey,
		PolicyGeneration: 7, IssuedAt: now, ValidUntil: now.Add(time.Minute),
		MachineModel: p.Hardware.MachineModel, MemoryGB: p.Hardware.MemoryGB,
	}
	return r, p, lease
}

func TestAppAttestAuthorizationRejectsWrongBindingAndDisabledPolicy(t *testing.T) {
	changes := map[string]func(*production.AppAttestServingAuthorization){
		"account":    func(a *production.AppAttestServingAuthorization) { a.AccountID = "other" },
		"machine":    func(a *production.AppAttestServingAuthorization) { a.MachineID = "other" },
		"credential": func(a *production.AppAttestServingAuthorization) { a.CredentialID = "" },
		"connection": func(a *production.AppAttestServingAuthorization) { a.ConnectionID = "other" },
		"endpoint":   func(a *production.AppAttestServingAuthorization) { a.Endpoint = "other" },
		"generation": func(a *production.AppAttestServingAuthorization) { a.PolicyGeneration++ },
		"expired":    func(a *production.AppAttestServingAuthorization) { a.ValidUntil = time.Now().Add(-time.Second) },
		"future":     func(a *production.AppAttestServingAuthorization) { a.IssuedAt = time.Now().Add(time.Hour) },
		"unbounded":  func(a *production.AppAttestServingAuthorization) { a.ValidUntil = a.IssuedAt.Add(time.Hour) },
	}
	for name, change := range changes {
		t.Run(name, func(t *testing.T) {
			r, p, lease := appAttestTestProvider(t)
			change(&lease)
			if r.GrantAppAttestServingAuthorization(p, lease) {
				t.Fatal("invalid lease granted")
			}
		})
	}
	r, p, lease := appAttestTestProvider(t)
	r.SetAppAttestServingPolicy(false, lease.PolicyGeneration)
	if r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("disabled serving policy granted")
	}
}

func TestAppAttestAuthorizationRevocationAndGenerationFenceLateGrants(t *testing.T) {
	r, p, lease := appAttestTestProvider(t)
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("grant")
	}
	r.SetReleasePolicyGeneration(8, false, nil)
	if r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("stale generation granted")
	}
	lease.PolicyGeneration = 8
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("new generation grant")
	}
	r.ClearAppAttestServingAuthorization(p)
	// Even after a lease is cleared, revocation fences this credential's
	// connection and cannot be bypassed by independently valid legacy flags.
	p.Mu().Lock()
	testMakeTextRoutable(p)
	p.CodeAttested = true
	p.Mu().Unlock()
	if len(r.RevokeAppAttestCredential(lease.CredentialID)) != 1 {
		t.Fatal("cleared credential not tracked")
	}
	if r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("revoked credential granted")
	}
	if r.ReserveProvider(appAttestTestModel, &production.PendingRequest{RequestID: "revoked"}) != nil {
		t.Fatal("revocation bypassed via legacy")
	}
}

func TestAppAttestAuthorizationTransientAndSecurityFailures(t *testing.T) {
	r, p, lease := appAttestTestProvider(t)
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("grant")
	}
	for i := 0; i < production.MaxFailedChallenges; i++ {
		r.RecordChallengeFailure(p.ID, true)
	}
	r.MarkUntrustedTransient(p.ID)
	if _, ok := r.ProviderServingAuthorization(p); !ok {
		t.Fatal("legacy timeout invalidated independent lease")
	}
	r.ClearAppAttestServingAuthorization(p)
	r.MarkUntrustedTransient(p.ID)
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("fresh App Attest did not recover transient deroute")
	}
	r.RecordChallengeFailure(p.ID, false)
	if _, ok := r.ProviderServingAuthorization(p); ok {
		t.Fatal("negative security evidence bypassed")
	}
	if r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("hard evidence bypassed by regrant")
	}
}

func TestAppAttestAuthorizationQueueAndRetry(t *testing.T) {
	r, p, lease := appAttestTestProvider(t)
	queued := &production.QueuedRequest{RequestID: "queued", Model: appAttestTestModel, ResponseCh: make(chan *production.Provider, 1), Pending: &production.PendingRequest{RequestID: "queued", Model: appAttestTestModel}}
	if err := r.Queue().Enqueue(queued); err != nil {
		t.Fatal(err)
	}
	r.DrainQueuedRequestsForProviderWithReason(p, production.DrainTriggerUnknown)
	select {
	case <-queued.ResponseCh:
		t.Fatal("unverified queue dispatch")
	default:
	}
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("grant")
	}
	if err := r.RefreshAppAttestServingState(p); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-queued.ResponseCh:
		if got != p {
			t.Fatal("wrong provider")
		}
	case <-time.After(time.Second):
		t.Fatal("grant did not drain")
	}
	p.RemovePending("queued")
	r.ClearAppAttestServingAuthorization(p)
	if r.ReserveProvider(appAttestTestModel, &production.PendingRequest{RequestID: "retry", Attempt: 1}) != nil {
		t.Fatal("retry reused stale authorization")
	}
	if r.ColdSpillProviders(appAttestTestModel, production.RequestTraits{}, false) != 0 {
		t.Fatal("unauthorized provider counted for cold spill")
	}
}

func TestAppAttestCanonicalFaultIdentityIgnoresClaimedSerial(t *testing.T) {
	r, p, _ := appAttestTestProvider(t)
	p.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: "victim", PublicKey: "my-se"})
	if got := r.GetProviderStableIdentity(p.ID); got != "machine:account-1:machine-1" {
		t.Fatalf("canonical identity lost: %s", got)
	}
	other := makeSchedulerProvider(t, r, "new-session", appAttestTestModel, 90)
	other.RequireVerifiedMachineIdentity()
	other.Mu().Lock()
	other.AccountID = "other-account"
	other.Mu().Unlock()
	other.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: "victim", PublicKey: "other-se"})
	if got := r.GetProviderStableIdentity(other.ID); got != "sekey:other-account:other-se" {
		t.Fatalf("claimed serial selected fault identity: %s", got)
	}
	if r.BindVerifiedMachineIdentity(other, "account-1", "machine-1") {
		t.Fatal("cross-account identity bound")
	}
}

func TestAppAttestAuthorizationIndependentPathAndExpiry(t *testing.T) {
	clock := &appAttestTestClock{}
	var planner *production.ReservationPlanner
	r, p, lease := appAttestTestProvider(t, production.NewWithDependencies(testLogger(), production.Dependencies{
		AppAttestNow: clock.Now,
		Reservations: func(actual *production.ReservationPlanner) production.ReservationPreparation {
			planner = actual
			return actual
		},
	}))
	if r.ReserveProvider(appAttestTestModel, &production.PendingRequest{RequestID: "before"}) != nil {
		t.Fatal("unverified provider routed")
	}
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("qualified lease rejected")
	}
	pr := &production.PendingRequest{RequestID: "authorized", Model: appAttestTestModel}
	if r.ReserveProvider(appAttestTestModel, pr) != p {
		t.Fatal("App Attest-only provider did not route")
	}
	p.RemovePending(pr.RequestID)
	p.Mu().Lock()
	if p.CodeAttested || p.FreshCodeAttested || p.MDAVerified || p.TrustLevel != production.TrustNone || p.ChallengeVerifiedSIP {
		t.Fatal("App Attest fabricated legacy evidence")
	}
	p.Mu().Unlock()
	for _, boundary := range []struct {
		offset time.Duration
		valid  bool
	}{{-time.Nanosecond, true}, {0, false}, {time.Nanosecond, false}} {
		now := lease.ValidUntil.Add(boundary.offset)
		clock.Store(now.UnixNano())
		eligibility := planner.PrepareEligibility()
		valid := eligibility.Public(p.ID, now)
		eligibility.Close()
		if boundary.offset == 0 && valid {
			t.Fatal("lease valid at exclusive expiry")
		}
		if valid != boundary.valid {
			t.Fatalf("lease validity at expiry%+d ns = %v, want %v", boundary.offset.Nanoseconds(), valid, boundary.valid)
		}
	}
	// Advance only the authorization clock: legacy evidence keeps its own age.
	clock.Store(lease.ValidUntil.Add(time.Second).UnixNano())
	p.Mu().Lock()
	testMakeTextRoutable(p)
	p.CodeAttested = true
	p.Mu().Unlock()
	if r.ReserveProvider(appAttestTestModel, &production.PendingRequest{RequestID: "legacy"}) != p {
		t.Fatal("independent legacy fallback failed")
	}
}

func TestAppAttestGrantDoesNotPromoteUntilFinalRuntimeAndPrivacyGatesPass(t *testing.T) {
	for _, blocked := range []string{"runtime", "privacy"} {
		t.Run(blocked, func(t *testing.T) {
			counts := &modelindex.Counts{}
			r, p, lease := appAttestTestProvider(t, production.NewWithDependencies(testLogger(), production.Dependencies{ModelCounts: counts}))
			r.MarkUntrustedTransient(p.ID)
			if p.GetStatus() != production.StatusUntrusted || p.ChallengeShouldStop() {
				t.Fatal("fixture did not enter recoverable state")
			}
			p.Mu().Lock()
			if blocked == "runtime" {
				p.RuntimeVerified = false
			} else {
				p.PrivacyCapabilities.TextBackendInprocess = false
			}
			p.Mu().Unlock()
			beforeOnline := r.OnlineCount()
			beforeModel := counts.Count(appAttestTestModel)
			if r.GrantAppAttestServingAuthorization(p, lease) {
				t.Fatal("incomplete final gate accepted")
			}
			status, recoverable, saved := p.GetStatus(), !p.ChallengeShouldStop(), p.GetAppAttestServingAuthorization()
			p.Mu().Lock()
			if blocked == "runtime" {
				p.RuntimeVerified = true
			} else {
				p.PrivacyCapabilities.TextBackendInprocess = true
			}
			p.Mu().Unlock()
			if status != production.StatusUntrusted || !recoverable || saved.CredentialID != "" ||
				r.OnlineCount() != beforeOnline || counts.Count(appAttestTestModel) != beforeModel {
				t.Fatal("failed grant promoted status or capacity accounting")
			}
			if !r.GrantAppAttestServingAuthorization(p, lease) {
				t.Fatal("recovered final gate did not grant")
			}
			if p.GetStatus() != production.StatusOnline || r.OnlineCount() != beforeOnline+1 ||
				counts.Count(appAttestTestModel) != beforeModel+1 {
				t.Fatal("successful recovery did not promote exactly once")
			}
		})
	}
}

func TestAppAttestConcurrentGrantRevocationAndHandoff(t *testing.T) {
	w := newWriterFixture(8, 8, nil, nil, func([]byte) error { return nil }, nil)
	t.Cleanup(w.Close)
	r, p, lease := appAttestTestProvider(t, production.NewWithDependencies(testLogger(), production.Dependencies{
		Connections: retainedWriterFactory{writer: w.Writer},
	}))
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("grant")
	}
	go w.Run()
	pr := &production.PendingRequest{RequestID: "race", Model: appAttestTestModel}
	if r.ReserveProvider(appAttestTestModel, pr) != p {
		t.Fatal("reserve")
	}
	handoff := p.NewInferenceHandoff(pr)
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				r.GrantAppAttestServingAuthorization(p, lease)
				_ = handoff.Authorize()
			}
		}()
	}
	r.RevokeAppAttestCredential(lease.CredentialID)
	wg.Wait()
	if r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("revocation lost to concurrent grant")
	}
	if err := handoff.Authorize(); !errors.Is(err, production.ErrProviderServingUnauthorized) {
		t.Fatalf("late handoff = %v", err)
	}
}

func TestAppAttestFinalWriterRechecksAfterOwnerHandoff(t *testing.T) {
	// Subtests are synchronous. These closures point at each subtest's actual
	// retained directory and lease clock, not alternate authorization state.
	var replaceCurrent func(*production.Provider)
	var expire func()
	changes := map[string]func(*production.Registry, *production.Provider, *production.PendingRequest){
		"expiry": func(_ *production.Registry, _ *production.Provider, _ *production.PendingRequest) { expire() },
		"revocation": func(r *production.Registry, _ *production.Provider, _ *production.PendingRequest) {
			r.RevokeAppAttestCredential("credential-1")
		},
		"policy": func(r *production.Registry, _ *production.Provider, _ *production.PendingRequest) {
			r.SetAppAttestServingPolicy(true, 8)
		},
		"key_change": func(_ *production.Registry, p *production.Provider, _ *production.PendingRequest) {
			p.Mu().Lock()
			p.PublicKey = "new-endpoint"
			p.Mu().Unlock()
		},
		"account_change": func(_ *production.Registry, p *production.Provider, _ *production.PendingRequest) {
			p.Mu().Lock()
			p.AccountID = "new-account"
			p.Mu().Unlock()
		},
		"cancellation": func(_ *production.Registry, p *production.Provider, pr *production.PendingRequest) {
			p.RemovePending(pr.RequestID)
		},
		"replacement": func(_ *production.Registry, p *production.Provider, _ *production.PendingRequest) { replaceCurrent(p) },
		"runtime": func(_ *production.Registry, p *production.Provider, _ *production.PendingRequest) {
			p.Mu().Lock()
			p.RuntimeManifestChecked = false
			p.Mu().Unlock()
		},
		"hard_untrust": func(r *production.Registry, p *production.Provider, _ *production.PendingRequest) {
			r.MarkUntrusted(p.ID)
		},
	}
	for name, change := range changes {
		t.Run(name, func(t *testing.T) {
			directory := &production.ProviderDirectory{}
			clock := &appAttestTestClock{}
			frames := &atomic.Int32{}
			w := newWriterFixture(8, 8, nil, nil, func([]byte) error { frames.Add(1); return nil }, nil)
			t.Cleanup(w.Close)
			r, p, lease := appAttestTestProvider(t, production.NewWithDependencies(testLogger(), production.Dependencies{
				ProviderDirectory: directory,
				AppAttestNow:      clock.Now,
				Connections:       retainedWriterFactory{writer: w.Writer},
			}))
			replaceCurrent = func(old *production.Provider) { directory.Store(old.ID, &production.Provider{ID: old.ID}) }
			expire = func() { clock.Store(lease.ValidUntil.Add(time.Second).UnixNano()) }
			if !r.GrantAppAttestServingAuthorization(p, lease) {
				t.Fatal("grant")
			}
			go w.Run()
			pr := &production.PendingRequest{RequestID: "inference", Model: appAttestTestModel}
			if r.ReserveProvider(appAttestTestModel, pr) != p {
				t.Fatal("reserve")
			}
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			_, err := p.WriteInferenceTextDeferred(ctx, pr, func(time.Time) ([]byte, error) { return []byte("sealed inference"), nil }, func(production.TextFrameWriteMetadata) { change(r, p, pr) })
			if !errors.Is(err, production.ErrProviderServingUnauthorized) {
				t.Fatalf("write error = %v", err)
			}
			if frames.Load() != 0 {
				t.Fatal("unauthorized bytes reached socket")
			}
			if err := p.WriteTextControl(ctx, []byte("recovery")); err != nil {
				t.Fatalf("recovery blocked: %v", err)
			}
		})
	}
}
