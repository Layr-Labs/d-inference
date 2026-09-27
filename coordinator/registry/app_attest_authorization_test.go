package registry

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

const appAttestTestModel = "app-attest-model"

func appAttestTestProvider(t *testing.T) (*Registry, *Provider, AppAttestServingAuthorization) {
	t.Helper()
	r := New(testLogger())
	r.SetAppAttestServingPolicy(true, 7)
	r.SetCodeAttestationPolicy(true, time.Now().Add(-time.Hour))
	p := makeSchedulerProvider(t, r, "app-provider", appAttestTestModel, 90)
	p.RequireVerifiedMachineIdentity()
	p.mu.Lock()
	p.AccountID = "account-1"
	p.TrustLevel = TrustNone
	p.ChallengeVerifiedSIP = false
	p.LastChallengeVerified = time.Time{}
	p.mu.Unlock()
	if !r.BindVerifiedMachineIdentity(p, "account-1", "machine-1") {
		t.Fatal("bind identity")
	}
	now := time.Now()
	lease := AppAttestServingAuthorization{
		AccountID: "account-1", MachineID: "machine-1", CredentialID: "credential-1",
		ConnectionID: p.ID, ProofSessionID: "proof-session", Endpoint: p.PublicKey,
		PolicyGeneration: 7, IssuedAt: now, ValidUntil: now.Add(time.Minute),
		MachineModel: p.Hardware.MachineModel, MemoryGB: p.Hardware.MemoryGB,
	}
	return r, p, lease
}

func TestAppAttestAuthorizationIndependentPathAndExpiry(t *testing.T) {
	r, p, lease := appAttestTestProvider(t)
	if r.ReserveProvider(appAttestTestModel, &PendingRequest{RequestID: "before"}) != nil {
		t.Fatal("unverified provider routed")
	}
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("qualified lease rejected")
	}
	pr := &PendingRequest{RequestID: "authorized", Model: appAttestTestModel}
	if r.ReserveProvider(appAttestTestModel, pr) != p {
		t.Fatal("App Attest-only provider did not route")
	}
	p.RemovePending(pr.RequestID)
	p.mu.Lock()
	if p.CodeAttested || p.FreshCodeAttested || p.MDAVerified || p.TrustLevel != TrustNone || p.ChallengeVerifiedSIP {
		t.Fatal("App Attest fabricated legacy evidence")
	}
	p.mu.Unlock()
	r.mu.RLock()
	p.mu.Lock()
	if r.providerLivenessGateLocked(p, TrustHardware, false, lease.ValidUntil) {
		t.Fatal("lease valid at exclusive expiry")
	}
	p.mu.Unlock()
	r.mu.RUnlock()
	// Legacy independently recovers routing when the App Attest lease expires.
	p.mu.Lock()
	p.appAttestAuthorization.ValidUntil = time.Now().Add(-time.Second)
	testMakeTextRoutable(p)
	p.CodeAttested = true
	p.mu.Unlock()
	if r.ReserveProvider(appAttestTestModel, &PendingRequest{RequestID: "legacy"}) != p {
		t.Fatal("independent legacy fallback failed")
	}
}

func TestAppAttestAuthorizationRejectsWrongBindingAndDisabledPolicy(t *testing.T) {
	changes := map[string]func(*AppAttestServingAuthorization){
		"account":    func(a *AppAttestServingAuthorization) { a.AccountID = "other" },
		"machine":    func(a *AppAttestServingAuthorization) { a.MachineID = "other" },
		"credential": func(a *AppAttestServingAuthorization) { a.CredentialID = "" },
		"connection": func(a *AppAttestServingAuthorization) { a.ConnectionID = "other" },
		"endpoint":   func(a *AppAttestServingAuthorization) { a.Endpoint = "other" },
		"generation": func(a *AppAttestServingAuthorization) { a.PolicyGeneration++ },
		"expired":    func(a *AppAttestServingAuthorization) { a.ValidUntil = time.Now().Add(-time.Second) },
		"future":     func(a *AppAttestServingAuthorization) { a.IssuedAt = time.Now().Add(time.Hour) },
		"unbounded":  func(a *AppAttestServingAuthorization) { a.ValidUntil = a.IssuedAt.Add(time.Hour) },
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
	p.mu.Lock()
	testMakeTextRoutable(p)
	p.CodeAttested = true
	p.mu.Unlock()
	if len(r.RevokeAppAttestCredential(lease.CredentialID)) != 1 {
		t.Fatal("cleared credential not tracked")
	}
	if r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("revoked credential granted")
	}
	if r.ReserveProvider(appAttestTestModel, &PendingRequest{RequestID: "revoked"}) != nil {
		t.Fatal("revocation bypassed via legacy")
	}
}

func TestAppAttestAuthorizationTransientAndSecurityFailures(t *testing.T) {
	r, p, lease := appAttestTestProvider(t)
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("grant")
	}
	for i := 0; i < MaxFailedChallenges; i++ {
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

func TestAppAttestGrantDoesNotPromoteUntilFinalRuntimeAndPrivacyGatesPass(t *testing.T) {
	for _, blocked := range []string{"runtime", "privacy"} {
		t.Run(blocked, func(t *testing.T) {
			r, p, lease := appAttestTestProvider(t)
			r.MarkUntrustedTransient(p.ID)
			p.mu.Lock()
			if p.Status != StatusUntrusted || !p.untrustedRecoverable {
				p.mu.Unlock()
				t.Fatal("fixture did not enter recoverable state")
			}
			if blocked == "runtime" {
				p.RuntimeVerified = false
			} else {
				p.PrivacyCapabilities.TextBackendInprocess = false
			}
			p.mu.Unlock()
			beforeOnline := r.onlineCount.Load()
			modelCount := func() int64 {
				r.mu.RLock()
				count := r.modelProviders[appAttestTestModel]
				r.mu.RUnlock()
				if count == nil {
					return 0
				}
				return count.Load()
			}
			beforeModel := modelCount()
			if r.GrantAppAttestServingAuthorization(p, lease) {
				t.Fatal("incomplete final gate accepted")
			}
			p.mu.Lock()
			status, recoverable, saved := p.Status, p.untrustedRecoverable, p.appAttestAuthorization
			if blocked == "runtime" {
				p.RuntimeVerified = true
			} else {
				p.PrivacyCapabilities.TextBackendInprocess = true
			}
			p.mu.Unlock()
			if status != StatusUntrusted || !recoverable || saved.CredentialID != "" ||
				r.onlineCount.Load() != beforeOnline || modelCount() != beforeModel {
				t.Fatal("failed grant promoted status or capacity accounting")
			}
			if !r.GrantAppAttestServingAuthorization(p, lease) {
				t.Fatal("recovered final gate did not grant")
			}
			if p.GetStatus() != StatusOnline || r.onlineCount.Load() != beforeOnline+1 ||
				modelCount() != beforeModel+1 {
				t.Fatal("successful recovery did not promote exactly once")
			}
		})
	}
}

func TestAppAttestAuthorizationQueueAndRetry(t *testing.T) {
	r, p, lease := appAttestTestProvider(t)
	queued := &QueuedRequest{RequestID: "queued", Model: appAttestTestModel, ResponseCh: make(chan *Provider, 1), Pending: &PendingRequest{RequestID: "queued", Model: appAttestTestModel}}
	if err := r.Queue().Enqueue(queued); err != nil {
		t.Fatal(err)
	}
	r.DrainQueuedRequestsForProvider(p)
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
	if r.ReserveProvider(appAttestTestModel, &PendingRequest{RequestID: "retry", Attempt: 1}) != nil {
		t.Fatal("retry reused stale authorization")
	}
	if r.ColdSpillProviders(appAttestTestModel, RequestTraits{}, false) != 0 {
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
	other.mu.Lock()
	other.AccountID = "other-account"
	other.mu.Unlock()
	other.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: "victim", PublicKey: "other-se"})
	if got := r.GetProviderStableIdentity(other.ID); got != "sekey:other-account:other-se" {
		t.Fatalf("claimed serial selected fault identity: %s", got)
	}
	if r.BindVerifiedMachineIdentity(other, "account-1", "machine-1") {
		t.Fatal("cross-account identity bound")
	}
}

func appAttestTestWriter(t *testing.T, p *Provider) (*providerWriter, *atomic.Int32) {
	t.Helper()
	frames := &atomic.Int32{}
	w := &providerWriter{queue: make(chan *providerWriteRequest, 8), control: make(chan *providerWriteRequest, 8), stop: make(chan struct{}), done: make(chan struct{}), writeFrameForTest: func([]byte) error { frames.Add(1); return nil }}
	p.mu.Lock()
	p.writer = w
	p.mu.Unlock()
	go w.run()
	t.Cleanup(w.closeNow)
	return w, frames
}

func TestAppAttestFinalWriterRechecksAfterOwnerHandoff(t *testing.T) {
	changes := map[string]func(*Registry, *Provider, *PendingRequest){
		"expiry": func(r *Registry, p *Provider, _ *PendingRequest) {
			p.mu.Lock()
			p.appAttestAuthorization.ValidUntil = time.Now().Add(-time.Second)
			p.mu.Unlock()
		},
		"revocation": func(r *Registry, p *Provider, _ *PendingRequest) { r.RevokeAppAttestCredential("credential-1") },
		"policy":     func(r *Registry, p *Provider, _ *PendingRequest) { r.SetAppAttestServingPolicy(true, 8) },
		"key_change": func(r *Registry, p *Provider, _ *PendingRequest) {
			p.mu.Lock()
			p.PublicKey = "new-endpoint"
			p.mu.Unlock()
		},
		"account_change": func(r *Registry, p *Provider, _ *PendingRequest) {
			p.mu.Lock()
			p.AccountID = "new-account"
			p.mu.Unlock()
		},
		"cancellation": func(r *Registry, p *Provider, pr *PendingRequest) { p.RemovePending(pr.RequestID) },
		"replacement": func(r *Registry, p *Provider, _ *PendingRequest) {
			r.mu.Lock()
			r.providers[p.ID] = &Provider{ID: p.ID}
			r.mu.Unlock()
		},
		"runtime": func(r *Registry, p *Provider, _ *PendingRequest) {
			p.mu.Lock()
			p.RuntimeManifestChecked = false
			p.mu.Unlock()
		},
		"hard_untrust": func(r *Registry, p *Provider, _ *PendingRequest) { r.MarkUntrusted(p.ID) },
	}
	for name, change := range changes {
		t.Run(name, func(t *testing.T) {
			r, p, lease := appAttestTestProvider(t)
			if !r.GrantAppAttestServingAuthorization(p, lease) {
				t.Fatal("grant")
			}
			_, frames := appAttestTestWriter(t, p)
			pr := &PendingRequest{RequestID: "inference", Model: appAttestTestModel}
			if r.ReserveProvider(appAttestTestModel, pr) != p {
				t.Fatal("reserve")
			}
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			_, err := p.WriteInferenceTextDeferred(ctx, pr, func(time.Time) ([]byte, error) { return []byte("sealed inference"), nil }, func(TextFrameWriteMetadata) { change(r, p, pr) })
			if !errors.Is(err, ErrProviderServingUnauthorized) {
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

func TestAppAttestConcurrentGrantRevocationAndHandoff(t *testing.T) {
	r, p, lease := appAttestTestProvider(t)
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("grant")
	}
	w, _ := appAttestTestWriter(t, p)
	pr := &PendingRequest{RequestID: "race", Model: appAttestTestModel}
	if r.ReserveProvider(appAttestTestModel, pr) != p {
		t.Fatal("reserve")
	}
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				r.GrantAppAttestServingAuthorization(p, lease)
				_ = r.authorizeInferenceHandoff(p, pr, w)
			}
		}()
	}
	r.RevokeAppAttestCredential(lease.CredentialID)
	wg.Wait()
	if r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("revocation lost to concurrent grant")
	}
	if err := r.authorizeInferenceHandoff(p, pr, w); !errors.Is(err, ErrProviderServingUnauthorized) {
		t.Fatalf("late handoff = %v", err)
	}
}
