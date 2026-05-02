package registry

import (
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/protocol"
)

func addTestProviderWithAccreditation(reg *Registry, id string, acc AccreditationStatus, payment AccreditationPaymentStatus) *Provider {
	p := &Provider{
		ID:                      id,
		Backend:                 "inprocess-mlx",
		PublicKey:               "test-key-" + id,
		Status:                  StatusOnline,
		TrustLevel:              TrustSelfSigned,
		RuntimeVerified:         true,
		RuntimeManifestChecked:  true,
		EncryptedResponseChunks: true,
		ChallengeVerifiedSIP:    true,
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess:    true,
			TextProxyDisabled:       true,
			PythonRuntimeLocked:     true,
			DangerousModulesBlocked: true,
			SIPEnabled:              true,
			AntiDebugEnabled:        true,
			CoreDumpsDisabled:       true,
			EnvScrubbed:             true,
		},
		Accreditation:        acc,
		AccreditationPayment: payment,
		Models:               []protocol.ModelInfo{{ID: "test-model"}},
	}
	p.LastChallengeVerified = time.Now()
	p.pendingReqs = make(map[string]*PendingRequest)
	reg.mu.Lock()
	reg.providers[id] = p
	reg.mu.Unlock()
	return p
}

func TestAccreditationStateMachine(t *testing.T) {
	tests := []struct {
		from AccreditationStatus
		to   AccreditationStatus
		ok   bool
	}{
		{AccreditationNone, AccreditationPendingPayment, true},
		{AccreditationNone, AccreditationActive, false},
		{AccreditationPendingPayment, AccreditationPaymentFailed, true},
		{AccreditationPendingPayment, AccreditationPendingReview, true},
		{AccreditationPendingPayment, AccreditationActive, false},
		{AccreditationPaymentFailed, AccreditationPendingPayment, true},
		{AccreditationPaymentFailed, AccreditationActive, false},
		{AccreditationPendingReview, AccreditationNotVerified, true},
		{AccreditationPendingReview, AccreditationActive, true},
		{AccreditationPendingReview, AccreditationPendingPayment, false},
		{AccreditationNotVerified, AccreditationPendingReview, true},
		{AccreditationNotVerified, AccreditationActive, false},
		{AccreditationActive, AccreditationRevoked, true},
		{AccreditationActive, AccreditationPendingPayment, false},
		{AccreditationRevoked, AccreditationPendingPayment, true},
		{AccreditationRevoked, AccreditationActive, false},
	}

	for _, tt := range tests {
		got := accreditationCanTransition(tt.from, tt.to)
		if got != tt.ok {
			t.Errorf("transition %s → %s: got %v, want %v", tt.from, tt.to, got, tt.ok)
		}
	}
}

func TestAccreditation_SetAccreditationEnforcesTransitions(t *testing.T) {
	p := &Provider{
		ID:            "test",
		Accreditation: AccreditationNone,
	}
	p.pendingReqs = make(map[string]*PendingRequest)

	err := p.SetAccreditation(AccreditationPendingPayment, PaymentPending, "enr-1", "")
	if err != nil {
		t.Fatalf("none → pending_payment should succeed: %v", err)
	}
	if p.Accreditation != AccreditationPendingPayment {
		t.Fatalf("expected pending_payment, got %s", p.Accreditation)
	}
	if p.AccreditationPayment != PaymentPending {
		t.Fatalf("expected payment pending, got %s", p.AccreditationPayment)
	}
	if p.AccreditationEnrollmentID != "enr-1" {
		t.Fatalf("expected enrollment ID enr-1, got %s", p.AccreditationEnrollmentID)
	}

	err = p.SetAccreditation(AccreditationActive, PaymentConfirmed, "", "pay-1")
	if err == nil {
		t.Fatal("pending_payment → accredited should be rejected")
	}

	err = p.SetAccreditation(AccreditationPendingReview, PaymentConfirmed, "", "pay-1")
	if err != nil {
		t.Fatalf("pending_payment → pending_review should succeed: %v", err)
	}

	err = p.SetAccreditation(AccreditationActive, PaymentConfirmed, "", "pay-1")
	if err != nil {
		t.Fatalf("pending_review → accredited should succeed: %v", err)
	}
	if p.AccreditationVerifiedAt == nil {
		t.Fatal("expected AccreditationVerifiedAt to be set")
	}

	err = p.SetAccreditation(AccreditationRevoked, PaymentConfirmed, "", "")
	if err != nil {
		t.Fatalf("accredited → revoked should succeed: %v", err)
	}
	if p.AccreditationRevokedAt == nil {
		t.Fatal("expected AccreditationRevokedAt to be set")
	}
}

func TestAccreditation_PaymentFailedThenRetry(t *testing.T) {
	p := &Provider{ID: "test", Accreditation: AccreditationNone}
	p.pendingReqs = make(map[string]*PendingRequest)

	p.SetAccreditation(AccreditationPendingPayment, PaymentPending, "enr-1", "")
	p.SetAccreditation(AccreditationPaymentFailed, PaymentFailed, "", "pay-fail")

	if p.Accreditation != AccreditationPaymentFailed {
		t.Fatalf("expected payment_failed, got %s", p.Accreditation)
	}

	err := p.SetAccreditation(AccreditationPendingPayment, PaymentPending, "enr-2", "")
	if err != nil {
		t.Fatalf("payment_failed → pending_payment (retry) should succeed: %v", err)
	}
}

func TestAccreditation_VerificationFailedThenRetry(t *testing.T) {
	p := &Provider{ID: "test", Accreditation: AccreditationNone}
	p.pendingReqs = make(map[string]*PendingRequest)

	p.SetAccreditation(AccreditationPendingPayment, PaymentPending, "enr-1", "")
	p.SetAccreditation(AccreditationPendingReview, PaymentConfirmed, "", "pay-1")
	p.SetAccreditation(AccreditationNotVerified, PaymentConfirmed, "", "")

	if p.Accreditation != AccreditationNotVerified {
		t.Fatalf("expected not_accredited, got %s", p.Accreditation)
	}
	if p.AccreditationPayment != PaymentConfirmed {
		t.Fatalf("payment should remain confirmed, got %s", p.AccreditationPayment)
	}

	err := p.SetAccreditation(AccreditationPendingReview, PaymentConfirmed, "", "")
	if err != nil {
		t.Fatalf("not_accredited → pending_review (re-verify) should succeed: %v", err)
	}

	p.SetAccreditation(AccreditationActive, PaymentConfirmed, "", "")
	if !p.IsEligibleForPaidWork() {
		t.Fatal("accredited provider should be eligible for paid work")
	}
}

func TestAccreditation_EnrollmentIdempotent(t *testing.T) {
	p := &Provider{ID: "test", Accreditation: AccreditationNone}
	p.pendingReqs = make(map[string]*PendingRequest)

	p.SetAccreditation(AccreditationPendingPayment, PaymentPending, "enr-1", "")
	p.SetAccreditation(AccreditationPendingReview, PaymentConfirmed, "", "pay-1")
	p.SetAccreditation(AccreditationActive, PaymentConfirmed, "", "")

	if p.AccreditationEnrollmentID != "enr-1" {
		t.Fatalf("enrollment ID should remain enr-1, got %s", p.AccreditationEnrollmentID)
	}

	if !p.IsEligibleForPaidWork() {
		t.Fatal("accredited provider should be eligible for paid work")
	}
}

func TestAccreditation_RevokedNotEligibleForPaidWork(t *testing.T) {
	p := &Provider{ID: "test", Accreditation: AccreditationNone}
	p.pendingReqs = make(map[string]*PendingRequest)

	p.SetAccreditation(AccreditationPendingPayment, PaymentPending, "enr-1", "")
	p.SetAccreditation(AccreditationPendingReview, PaymentConfirmed, "", "pay-1")
	p.SetAccreditation(AccreditationActive, PaymentConfirmed, "", "")

	if !p.IsEligibleForPaidWork() {
		t.Fatal("accredited should be eligible")
	}

	p.SetAccreditation(AccreditationRevoked, PaymentConfirmed, "", "")

	if p.IsEligibleForPaidWork() {
		t.Fatal("revoked should NOT be eligible for paid work")
	}
}

func TestAccreditation_RevokedCanReapply(t *testing.T) {
	p := &Provider{ID: "test", Accreditation: AccreditationNone}
	p.pendingReqs = make(map[string]*PendingRequest)

	p.SetAccreditation(AccreditationPendingPayment, PaymentPending, "enr-1", "")
	p.SetAccreditation(AccreditationPendingReview, PaymentConfirmed, "", "pay-1")
	p.SetAccreditation(AccreditationActive, PaymentConfirmed, "", "")
	p.SetAccreditation(AccreditationRevoked, PaymentConfirmed, "", "")

	err := p.SetAccreditation(AccreditationPendingPayment, PaymentPending, "enr-2", "")
	if err != nil {
		t.Fatalf("revoked → pending_payment (reapply) should succeed: %v", err)
	}

	p.SetAccreditation(AccreditationPendingReview, PaymentConfirmed, "", "pay-2")
	p.SetAccreditation(AccreditationActive, PaymentConfirmed, "", "")

	if !p.IsEligibleForPaidWork() {
		t.Fatal("re-accredited provider should be eligible for paid work")
	}
}

func TestAccreditation_PaymentNotConfirmedNotEligible(t *testing.T) {
	states := []struct {
		acc     AccreditationStatus
		payment AccreditationPaymentStatus
	}{
		{AccreditationPendingPayment, PaymentPending},
		{AccreditationPaymentFailed, PaymentFailed},
		{AccreditationPendingReview, PaymentConfirmed},
		{AccreditationNotVerified, PaymentConfirmed},
	}

	for _, s := range states {
		p := &Provider{
			ID:                   "test",
			Accreditation:        s.acc,
			AccreditationPayment: s.payment,
		}
		p.pendingReqs = make(map[string]*PendingRequest)
		if p.IsEligibleForPaidWork() {
			t.Errorf("provider with accreditation=%s payment=%s should NOT be eligible", s.acc, s.payment)
		}
	}
}

func TestAccreditation_RoutingExcludesNonAccredited(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := New(logger)
	reg.MinTrustLevel = TrustNone
	reg.SetQueue(NewRequestQueue(100, 120*time.Second))

	p1 := addTestProviderWithAccreditation(reg, "prov-accredited", AccreditationActive, PaymentConfirmed)
	p1.Models = []protocol.ModelInfo{{ID: "test-model"}}

	p2 := addTestProviderWithAccreditation(reg, "prov-pending", AccreditationPendingPayment, PaymentPending)
	p2.Models = []protocol.ModelInfo{{ID: "test-model"}}

	p3 := addTestProviderWithAccreditation(reg, "prov-revoked", AccreditationRevoked, PaymentConfirmed)
	p3.Models = []protocol.ModelInfo{{ID: "test-model"}}

	selected := reg.FindProvider("test-model")
	if selected == nil {
		t.Fatal("expected to find an accredited provider")
	}
	if selected.ID != "prov-accredited" {
		t.Fatalf("expected prov-accredited, got %s", selected.ID)
	}
}

func TestAccreditation_RoutingIncludesUnaccreditedWhenNoAccreditationRequired(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := New(logger)
	reg.MinTrustLevel = TrustNone
	reg.SetQueue(NewRequestQueue(100, 120*time.Second))

	p := addTestProviderWithAccreditation(reg, "prov-none", AccreditationNone, PaymentNone)
	p.Models = []protocol.ModelInfo{{ID: "test-model"}}

	selected := reg.FindProvider("test-model")
	if selected == nil {
		t.Fatal("providers with no accreditation (empty string) should still be routable")
	}
}

func TestAccreditation_DuplicateEnrollmentIdempotent(t *testing.T) {
	p := &Provider{ID: "test", Accreditation: AccreditationNone}
	p.pendingReqs = make(map[string]*PendingRequest)

	p.SetAccreditation(AccreditationPendingPayment, PaymentPending, "enr-1", "")

	beforeEnrollment := p.AccreditationEnrollmentID
	beforeAcc := p.Accreditation

	p.SetAccreditation(AccreditationPendingPayment, PaymentPending, "enr-1", "")

	if p.Accreditation != beforeAcc {
		t.Fatalf("duplicate enrollment should not change accreditation state")
	}
	if p.AccreditationEnrollmentID != beforeEnrollment {
		t.Fatalf("duplicate enrollment should not change enrollment ID")
	}
}

func TestAccreditation_ConcurrentEnrollments(t *testing.T) {
	p := &Provider{ID: "test", Accreditation: AccreditationNone}
	p.pendingReqs = make(map[string]*PendingRequest)

	var wg sync.WaitGroup
	results := make([]error, 10)

	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			results[idx] = p.SetAccreditation(AccreditationPendingPayment, PaymentPending, "enr-concurrent", "")
		}(i)
	}
	wg.Wait()

	successCount := 0
	for _, err := range results {
		if err == nil {
			successCount++
		}
	}

	if p.Accreditation != AccreditationPendingPayment {
		t.Fatalf("expected pending_payment after concurrent enrollment, got %s", p.Accreditation)
	}
	if p.AccreditationEnrollmentID != "enr-concurrent" {
		t.Fatalf("expected single enrollment ID, got %s", p.AccreditationEnrollmentID)
	}

	_ = successCount
}
