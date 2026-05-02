package registry

import (
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/protocol"
)

const testModel = "test-model"

func fullPrivacyCaps() *protocol.PrivacyCapabilities {
	return &protocol.PrivacyCapabilities{
		TextBackendInprocess:    true,
		TextProxyDisabled:       true,
		PythonRuntimeLocked:     true,
		DangerousModulesBlocked: true,
		SIPEnabled:              true,
		AntiDebugEnabled:        true,
		CoreDumpsDisabled:       true,
		EnvScrubbed:             true,
	}
}

type fleetProviderSpec struct {
	ID              string
	TrustLevel      TrustLevel
	Status          ProviderStatus
	RuntimeVerified bool
	ManifestChecked bool
	ChallengeSIP    bool
	EncryptedChunks bool
	Accreditation   AccreditationStatus
	Payment         AccreditationPaymentStatus
	Models          []protocol.ModelInfo
	DecodeTPS       float64
	StaleChallenge  bool
	MaxLoad         bool
	NoPublicKey     bool
	NoPrivacyCaps   bool
	WrongBackend    bool
}

func newFleetRegistry(specs ...fleetProviderSpec) *Registry {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := New(logger)
	reg.MinTrustLevel = TrustNone
	reg.SetQueue(NewRequestQueue(100, 120*time.Second))

	for _, s := range specs {
		backend := "inprocess-mlx"
		if s.WrongBackend {
			backend = "vllm"
		}
		pubKey := "pk-" + s.ID
		if s.NoPublicKey {
			pubKey = ""
		}
		models := s.Models
		if len(models) == 0 {
			models = []protocol.ModelInfo{{ID: testModel}}
		}

		p := &Provider{
			ID:                      s.ID,
			Backend:                 backend,
			PublicKey:               pubKey,
			Status:                  s.Status,
			TrustLevel:              s.TrustLevel,
			RuntimeVerified:         s.RuntimeVerified,
			RuntimeManifestChecked:  s.ManifestChecked,
			EncryptedResponseChunks: s.EncryptedChunks,
			ChallengeVerifiedSIP:    s.ChallengeSIP,
			Accreditation:           s.Accreditation,
			AccreditationPayment:    s.Payment,
			Models:                  models,
			DecodeTPS:               s.DecodeTPS,
			PrivacyCapabilities:     fullPrivacyCaps(),
		}
		if s.NoPrivacyCaps {
			p.PrivacyCapabilities = nil
		}
		if !s.StaleChallenge {
			p.LastChallengeVerified = time.Now()
		} else {
			p.LastChallengeVerified = time.Now().Add(-10 * time.Minute)
		}
		p.pendingReqs = make(map[string]*PendingRequest)
		if s.MaxLoad {
			for i := 0; i < DefaultMaxConcurrent; i++ {
				p.pendingReqs[string(rune(i))] = &PendingRequest{RequestID: string(rune(i))}
			}
		}

		reg.mu.Lock()
		reg.providers[s.ID] = p
		reg.mu.Unlock()
	}
	return reg
}

func healthySpec(id string) fleetProviderSpec {
	return fleetProviderSpec{
		ID:              id,
		TrustLevel:      TrustSelfSigned,
		Status:          StatusOnline,
		RuntimeVerified: true,
		ManifestChecked: true,
		ChallengeSIP:    true,
		EncryptedChunks: true,
		DecodeTPS:       100.0,
	}
}

func accreditedSpec(id string) fleetProviderSpec {
	s := healthySpec(id)
	s.Accreditation = AccreditationActive
	s.Payment = PaymentConfirmed
	return s
}

func TestFleetRouting_PicksHealthiestProvider(t *testing.T) {
	reg := newFleetRegistry(
		healthySpec("p1"),
		func() fleetProviderSpec {
			s := healthySpec("p2")
			s.DecodeTPS = 200.0
			return s
		}(),
	)

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("expected a provider")
	}
	if selected.ID != "p2" {
		t.Fatalf("expected p2 (higher decode_tps), got %s", selected.ID)
	}
}

func TestFleetRouting_SkipsOfflineProvider(t *testing.T) {
	reg := newFleetRegistry(
		healthySpec("p1"),
		func() fleetProviderSpec {
			s := healthySpec("p2")
			s.Status = StatusOffline
			return s
		}(),
	)

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("expected p1")
	}
	if selected.ID != "p1" {
		t.Fatalf("expected p1, got %s", selected.ID)
	}
}

func TestFleetRouting_SkipsUntrustedProvider(t *testing.T) {
	reg := newFleetRegistry(
		healthySpec("p1"),
		func() fleetProviderSpec {
			s := healthySpec("p2")
			s.Status = StatusUntrusted
			return s
		}(),
	)

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("expected p1")
	}
	if selected.ID != "p1" {
		t.Fatalf("expected p1, got %s", selected.ID)
	}
}

func TestFleetRouting_SkipsProviderWithStaleChallenge(t *testing.T) {
	reg := newFleetRegistry(
		healthySpec("p1"),
		func() fleetProviderSpec {
			s := healthySpec("p2")
			s.StaleChallenge = true
			return s
		}(),
	)

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("expected p1")
	}
	if selected.ID != "p1" {
		t.Fatalf("expected p1, got %s", selected.ID)
	}
}

func TestFleetRouting_SkipsProviderAtMaxConcurrency(t *testing.T) {
	reg := newFleetRegistry(
		healthySpec("p1"),
		func() fleetProviderSpec {
			s := healthySpec("p2")
			s.MaxLoad = true
			return s
		}(),
	)

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("expected p1")
	}
	if selected.ID != "p1" {
		t.Fatalf("expected p1, got %s", selected.ID)
	}
}

func TestFleetRouting_SkipsProviderWithoutRuntimeVerification(t *testing.T) {
	reg := newFleetRegistry(
		healthySpec("p1"),
		func() fleetProviderSpec {
			s := healthySpec("p2")
			s.RuntimeVerified = false
			return s
		}(),
	)

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("expected p1")
	}
	if selected.ID != "p1" {
		t.Fatalf("expected p1, got %s", selected.ID)
	}
}

func TestFleetRouting_SkipsProviderWithoutManifestCheck(t *testing.T) {
	reg := newFleetRegistry(
		healthySpec("p1"),
		func() fleetProviderSpec {
			s := healthySpec("p2")
			s.ManifestChecked = false
			return s
		}(),
	)

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("expected p1")
	}
	if selected.ID != "p1" {
		t.Fatalf("expected p1, got %s", selected.ID)
	}
}

func TestFleetRouting_SkipsProviderWithoutChallengeVerifiedSIP(t *testing.T) {
	reg := newFleetRegistry(
		healthySpec("p1"),
		func() fleetProviderSpec {
			s := healthySpec("p2")
			s.ChallengeSIP = false
			return s
		}(),
	)

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("expected p1")
	}
	if selected.ID != "p1" {
		t.Fatalf("expected p1, got %s", selected.ID)
	}
}

func TestFleetRouting_SkipsProviderWithPendingAccreditation(t *testing.T) {
	reg := newFleetRegistry(
		accreditedSpec("p1"),
		func() fleetProviderSpec {
			s := accreditedSpec("p2")
			s.Accreditation = AccreditationPendingPayment
			s.Payment = PaymentPending
			return s
		}(),
	)

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("expected p1")
	}
	if selected.ID != "p1" {
		t.Fatalf("expected p1 (accredited), got %s", selected.ID)
	}
}

func TestFleetRouting_SkipsProviderWithRevokedAccreditation(t *testing.T) {
	reg := newFleetRegistry(
		accreditedSpec("p1"),
		func() fleetProviderSpec {
			s := accreditedSpec("p2")
			s.Accreditation = AccreditationRevoked
			s.Payment = PaymentConfirmed
			return s
		}(),
	)

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("expected p1")
	}
	if selected.ID != "p1" {
		t.Fatalf("expected p1, got %s", selected.ID)
	}
}

func TestFleetRouting_SkipsProviderWithNoPublicKey(t *testing.T) {
	reg := newFleetRegistry(
		healthySpec("p1"),
		func() fleetProviderSpec {
			s := healthySpec("p2")
			s.NoPublicKey = true
			return s
		}(),
	)

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("expected p1")
	}
	if selected.ID != "p1" {
		t.Fatalf("expected p1, got %s", selected.ID)
	}
}

func TestFleetRouting_SkipsProviderWithNoPrivacyCaps(t *testing.T) {
	reg := newFleetRegistry(
		healthySpec("p1"),
		func() fleetProviderSpec {
			s := healthySpec("p2")
			s.NoPrivacyCaps = true
			return s
		}(),
	)

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("expected p1")
	}
	if selected.ID != "p1" {
		t.Fatalf("expected p1, got %s", selected.ID)
	}
}

func TestFleetRouting_SkipsProviderWithWrongBackend(t *testing.T) {
	reg := newFleetRegistry(
		healthySpec("p1"),
		func() fleetProviderSpec {
			s := healthySpec("p2")
			s.WrongBackend = true
			return s
		}(),
	)

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("expected p1")
	}
	if selected.ID != "p1" {
		t.Fatalf("expected p1, got %s", selected.ID)
	}
}

func TestFleetRouting_AllProvidersDegraded_ReturnsNil(t *testing.T) {
	reg := newFleetRegistry(
		func() fleetProviderSpec {
			s := healthySpec("p1")
			s.Status = StatusOffline
			return s
		}(),
		func() fleetProviderSpec {
			s := healthySpec("p2")
			s.Status = StatusUntrusted
			return s
		}(),
		func() fleetProviderSpec {
			s := healthySpec("p3")
			s.StaleChallenge = true
			return s
		}(),
		func() fleetProviderSpec {
			s := healthySpec("p4")
			s.RuntimeVerified = false
			return s
		}(),
		func() fleetProviderSpec {
			s := healthySpec("p5")
			s.ChallengeSIP = false
			return s
		}(),
		func() fleetProviderSpec {
			s := accreditedSpec("p6")
			s.Accreditation = AccreditationRevoked
			return s
		}(),
	)

	selected := reg.FindProvider(testModel)
	if selected != nil {
		t.Fatalf("expected nil (all providers degraded), got %s", selected.ID)
	}
}

func TestFleetRouting_MixedFleet_OnlyHealthiestSelected(t *testing.T) {
	reg := newFleetRegistry(
		healthySpec("healthy"),
		func() fleetProviderSpec {
			s := healthySpec("offline")
			s.Status = StatusOffline
			return s
		}(),
		func() fleetProviderSpec {
			s := healthySpec("stale-challenge")
			s.StaleChallenge = true
			return s
		}(),
		func() fleetProviderSpec {
			s := healthySpec("no-sip")
			s.ChallengeSIP = false
			return s
		}(),
		func() fleetProviderSpec {
			s := healthySpec("no-runtime")
			s.RuntimeVerified = false
			return s
		}(),
		func() fleetProviderSpec {
			s := accreditedSpec("accredited-fast")
			s.DecodeTPS = 300.0
			return s
		}(),
	)

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("expected a provider")
	}
	if selected.ID != "accredited-fast" {
		t.Fatalf("expected accredited-fast (highest score), got %s", selected.ID)
	}
}

func TestByzantine_ChallengeFailureRemovesFromRouting(t *testing.T) {
	reg := newFleetRegistry(
		healthySpec("p1"),
		healthySpec("p2"),
	)

	reg.RecordChallengeFailure("p1")

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("expected p2")
	}
	if selected.ID != "p2" {
		t.Fatalf("expected p2 (p1 lost challenge), got %s", selected.ID)
	}

	p1 := reg.GetProvider("p1")
	if p1.ChallengeVerifiedSIP {
		t.Error("challenge failure should clear ChallengeVerifiedSIP")
	}
	if !p1.LastChallengeVerified.IsZero() {
		t.Error("challenge failure should clear LastChallengeVerified")
	}
}

func TestByzantine_ConsecutiveChallengeFailures_MarkUntrusted(t *testing.T) {
	reg := newFleetRegistry(
		healthySpec("p1"),
		healthySpec("p2"),
	)

	for range 3 {
		reg.RecordChallengeFailure("p1")
	}
	reg.MarkUntrusted("p1")

	p1 := reg.GetProvider("p1")
	if p1.Status != StatusUntrusted {
		t.Fatal("provider should be untrusted after max failures")
	}

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("expected p2")
	}
	if selected.ID != "p2" {
		t.Fatalf("expected p2, got %s", selected.ID)
	}
}

func TestByzantine_ChallengeSuccessRestoresRouting(t *testing.T) {
	reg := newFleetRegistry(healthySpec("p1"))

	reg.RecordChallengeFailure("p1")

	if reg.FindProvider(testModel) != nil {
		t.Fatal("p1 should be unroutable after challenge failure")
	}

	reg.RecordChallengeSuccess("p1")

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("p1 should be routable again after challenge success")
	}
	if selected.ID != "p1" {
		t.Fatalf("expected p1, got %s", selected.ID)
	}
}

func TestByzantine_ChallengeSuccessRestoresSIPVerification(t *testing.T) {
	reg := newFleetRegistry(healthySpec("p1"))

	reg.RecordChallengeFailure("p1")

	p1 := reg.GetProvider("p1")
	if p1.ChallengeVerifiedSIP {
		t.Error("expected SIP verification cleared after failure")
	}

	reg.RecordChallengeSuccess("p1")

	p1 = reg.GetProvider("p1")
	if !p1.ChallengeVerifiedSIP {
		t.Error("expected SIP verification restored after success")
	}
}

func TestByzantine_AccreditedProviderLosesChallenge_ExcludedFromRouting(t *testing.T) {
	reg := newFleetRegistry(
		accreditedSpec("accredited"),
		healthySpec("fallback"),
	)

	reg.RecordChallengeFailure("accredited")

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("fallback should be routable")
	}
	if selected.ID != "fallback" {
		t.Fatalf("expected fallback (accredited lost challenge), got %s", selected.ID)
	}
}

func TestByzantine_AccreditedProviderLosesRuntimeVerification(t *testing.T) {
	reg := newFleetRegistry(
		accreditedSpec("accredited"),
		healthySpec("fallback"),
	)

	p := reg.GetProvider("accredited")
	p.RuntimeVerified = false

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("fallback should be routable")
	}
	if selected.ID != "fallback" {
		t.Fatalf("expected fallback, got %s", selected.ID)
	}
}

func TestByzantine_AccreditedProviderLosesManifestCheck(t *testing.T) {
	reg := newFleetRegistry(
		accreditedSpec("accredited"),
		healthySpec("fallback"),
	)

	p := reg.GetProvider("accredited")
	p.RuntimeManifestChecked = false

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("fallback should be routable")
	}
	if selected.ID != "fallback" {
		t.Fatalf("expected fallback, got %s", selected.ID)
	}
}

func TestByzantine_AccreditedProviderGoesOffline(t *testing.T) {
	reg := newFleetRegistry(
		accreditedSpec("accredited"),
		healthySpec("fallback"),
	)

	p := reg.GetProvider("accredited")
	p.Status = StatusOffline

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("fallback should be routable")
	}
	if selected.ID != "fallback" {
		t.Fatalf("expected fallback, got %s", selected.ID)
	}
}

func TestByzantine_AccreditedProviderRevokedMidFlight(t *testing.T) {
	reg := newFleetRegistry(
		accreditedSpec("p1"),
		healthySpec("p2"),
	)

	p1 := reg.GetProvider("p1")
	p1.SetAccreditation(AccreditationRevoked, PaymentConfirmed, "", "")

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("p2 should be routable")
	}
	if selected.ID != "p2" {
		t.Fatalf("expected p2 after p1 revoked, got %s", selected.ID)
	}

	if p1.IsEligibleForPaidWork() {
		t.Error("revoked provider should not be eligible for paid work")
	}
}

func TestByzantine_ProviderDisconnectRemovesFromFleet(t *testing.T) {
	reg := newFleetRegistry(
		healthySpec("p1"),
		healthySpec("p2"),
	)

	reg.Disconnect("p1")

	if reg.GetProvider("p1") != nil {
		t.Fatal("disconnected provider should be removed from registry")
	}

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("p2 should be routable")
	}
	if selected.ID != "p2" {
		t.Fatalf("expected p2, got %s", selected.ID)
	}
}

func TestByzantine_ProviderDisconnectErrorsPendingRequests(t *testing.T) {
	reg := newFleetRegistry(healthySpec("p1"))

	p1 := reg.GetProvider("p1")
	req := &PendingRequest{
		RequestID:  "req-1",
		ProviderID: "p1",
		ChunkCh:    make(chan string, 1),
		CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
	}
	p1.mu.Lock()
	p1.pendingReqs["req-1"] = req
	p1.mu.Unlock()

	reg.Disconnect("p1")

	select {
	case err := <-req.ErrorCh:
		if err.StatusCode != 502 {
			t.Fatalf("expected 502 error, got %d", err.StatusCode)
		}
	default:
		t.Fatal("pending request should receive error on disconnect")
	}
}

func TestByzantine_SelfReportedSIPOverriddenByChallengeFailure(t *testing.T) {
	s := healthySpec("p1")
	s.ChallengeSIP = true
	reg := newFleetRegistry(s)

	p1 := reg.GetProvider("p1")
	p1.PrivacyCapabilities.SIPEnabled = true

	if !p1.ChallengeVerifiedSIP {
		t.Fatal("initial state: challenge-verified SIP should be true")
	}

	reg.RecordChallengeFailure("p1")

	p1 = reg.GetProvider("p1")
	if !p1.PrivacyCapabilities.SIPEnabled {
		t.Error("provider self-reported SIP should remain unchanged (only ChallengeVerifiedSIP is cleared)")
	}
	if p1.ChallengeVerifiedSIP {
		t.Error("coordinator-verified SIP should be cleared after challenge failure")
	}
	if reg.FindProvider(testModel) != nil {
		t.Fatal("provider with cleared SIP verification should be unroutable")
	}
}

func TestByzantine_PartialPrivacyCapsBlockRouting(t *testing.T) {
	capsToTest := []struct {
		name   string
		modify func(*protocol.PrivacyCapabilities)
	}{
		{"no_text_inprocess", func(c *protocol.PrivacyCapabilities) { c.TextBackendInprocess = false }},
		{"no_proxy_disabled", func(c *protocol.PrivacyCapabilities) { c.TextProxyDisabled = false }},
		{"no_python_locked", func(c *protocol.PrivacyCapabilities) { c.PythonRuntimeLocked = false }},
		{"no_dangerous_blocked", func(c *protocol.PrivacyCapabilities) { c.DangerousModulesBlocked = false }},
		{"no_anti_debug", func(c *protocol.PrivacyCapabilities) { c.AntiDebugEnabled = false }},
		{"no_core_dumps_disabled", func(c *protocol.PrivacyCapabilities) { c.CoreDumpsDisabled = false }},
		{"no_env_scrubbed", func(c *protocol.PrivacyCapabilities) { c.EnvScrubbed = false }},
	}

	for _, ct := range capsToTest {
		t.Run(ct.name, func(t *testing.T) {
			reg := newFleetRegistry(healthySpec("p1"))
			p := reg.GetProvider("p1")
			ct.modify(p.PrivacyCapabilities)

			selected := reg.FindProvider(testModel)
			if selected != nil {
				t.Errorf("provider with %s=false should be unroutable", ct.name)
			}
		})
	}
}

func TestFleetRouting_LargeFleetConcurrency(t *testing.T) {
	const numProviders = 50
	specs := make([]fleetProviderSpec, numProviders)
	for i := 0; i < numProviders; i++ {
		s := healthySpec("p" + string(rune('A'+i%26)) + string(rune('0'+i/26)))
		if i%7 == 0 {
			s.Status = StatusOffline
		}
		if i%11 == 0 {
			s.StaleChallenge = true
		}
		if i%13 == 0 {
			s.RuntimeVerified = false
		}
		if i%5 == 0 {
			s.ChallengeSIP = false
		}
		specs[i] = s
	}

	reg := newFleetRegistry(specs...)

	var wg sync.WaitGroup
	results := make(chan string, 100)

	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if p := reg.FindProvider(testModel); p != nil {
				results <- p.ID
			}
		}()
	}
	wg.Wait()
	close(results)

	count := 0
	for range results {
		count++
	}
	if count == 0 {
		t.Error("expected at least one routable provider in large fleet")
	}
}

func TestByzantine_ProviderClearedDuringChallengeWindow(t *testing.T) {
	reg := newFleetRegistry(healthySpec("p1"))

	p1 := reg.GetProvider("p1")
	boundary := time.Now().Add(-5*time.Minute - 50*time.Second)
	p1.LastChallengeVerified = boundary

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Error("provider just inside the 6-minute window should be routable")
	}

	p1.LastChallengeVerified = boundary.Add(-2 * time.Minute)
	selected = reg.FindProvider(testModel)
	if selected != nil {
		t.Error("provider well outside the 6-minute window should not be routable")
	}
}

func TestByzantine_ExcludeIDsParameter(t *testing.T) {
	reg := newFleetRegistry(
		healthySpec("p1"),
		healthySpec("p2"),
		healthySpec("p3"),
	)

	selected := reg.FindProvider(testModel, "p1", "p2")
	if selected == nil {
		t.Fatal("expected p3")
	}
	if selected.ID != "p3" {
		t.Fatalf("expected p3 (p1 and p2 excluded), got %s", selected.ID)
	}
}

func TestByzantine_TrustLevelEscalation(t *testing.T) {
	reg := newFleetRegistry(
		func() fleetProviderSpec {
			s := healthySpec("self-signed")
			s.TrustLevel = TrustSelfSigned
			return s
		}(),
		func() fleetProviderSpec {
			s := healthySpec("hardware")
			s.TrustLevel = TrustHardware
			return s
		}(),
	)

	reg.MinTrustLevel = TrustNone
	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("expected a provider")
	}

	selected = reg.FindProviderWithTrust(testModel, TrustHardware)
	if selected == nil {
		t.Fatal("expected hardware-trusted provider")
	}
	if selected.ID != "hardware" {
		t.Fatalf("expected hardware-trusted provider, got %s", selected.ID)
	}

	selected = reg.FindProviderWithTrust(testModel, TrustSelfSigned)
	if selected == nil {
		t.Fatal("both providers should match self_signed minimum")
	}
}

func TestByzantine_RevokedThenReaccredited_RoutesAgain(t *testing.T) {
	reg := newFleetRegistry(
		accreditedSpec("p1"),
		healthySpec("p2"),
	)

	p1 := reg.GetProvider("p1")
	p1.SetAccreditation(AccreditationRevoked, PaymentConfirmed, "", "")

	if p1.IsEligibleForPaidWork() {
		t.Error("revoked provider should not be eligible for paid work")
	}

	p1.SetAccreditation(AccreditationPendingPayment, PaymentPending, "enr-2", "")
	p1.SetAccreditation(AccreditationPendingReview, PaymentConfirmed, "", "pay-2")
	p1.SetAccreditation(AccreditationActive, PaymentConfirmed, "", "")

	if !p1.IsEligibleForPaidWork() {
		t.Error("re-accredited provider should be eligible for paid work")
	}

	selected := reg.FindProvider(testModel)
	if selected == nil {
		t.Fatal("re-accredited p1 should be routable")
	}
}
