package legacymdm

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	attestservice "github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type identity struct{ account, seKey string }
type cohort struct{ machines map[identity]string }

// Policy owns the immutable legacy membership shared by registration and trust grants.
type Policy struct {
	store  store.Store
	cohort atomic.Pointer[cohort]
}

func New(st store.Store) *Policy { return &Policy{store: st} }

func (s *Policy) Initialized() bool { return s.cohort.Load() != nil }

// Initialize must run before accepting connections. The store
// freezes membership once, including an empty cohort; restarts only reload it.
// Membership is eligibility, never a substitute for current trust verification.
func (s *Policy) Initialize(ctx context.Context, cfg attestservice.Config) error {
	s.cohort.Store(&cohort{machines: map[identity]string{}})
	if !cfg.ServingEnabled || cfg.Environment != "production" || cfg.RolloutPercent != 100 {
		return fmt.Errorf("legacy MDM freeze requires production App Attest serving enabled with a 100%% account rollout")
	}
	st, ok := store.As[store.LegacyMDMCohortStore](s.store)
	if !ok {
		return fmt.Errorf("store does not support the frozen legacy MDM cohort")
	}
	// Drain the eligible historical backlog before the first snapshot, retaining
	// the backfill's endpoint checks and filters. Later aliases never expand it.
	if backfill, ok := store.As[store.MachineInventoryBackfillStore](s.store); ok {
		for {
			if err := ctx.Err(); err != nil {
				return fmt.Errorf("backfill legacy MDM inventory: %w", err)
			}
			n, err := backfill.BackfillMachineInventory(ctx, 100)
			if err != nil {
				return fmt.Errorf("backfill legacy MDM inventory: %w", err)
			}
			if n == 0 {
				break
			}
		}
	}
	if err := ctx.Err(); err != nil {
		return fmt.Errorf("freeze legacy MDM cohort: %w", err)
	}
	machines, err := st.FreezeLegacyMDMCohort(ctx)
	if err != nil {
		return fmt.Errorf("freeze legacy MDM cohort: %w", err)
	}
	policy := &cohort{machines: make(map[identity]string, len(machines))}
	for _, machine := range machines {
		if machine.AccountID == "" || machine.SEPublicKey == "" || machine.SerialNumber == "" {
			return fmt.Errorf("frozen legacy MDM cohort contains an incomplete identity")
		}
		policy.machines[identity{machine.AccountID, machine.SEPublicKey}] = machine.SerialNumber
	}
	s.cohort.Store(policy)
	return nil
}

func (s *Policy) IdentityAllowed(account, seKey, serial string) bool {
	policy := s.cohort.Load()
	if policy == nil {
		return true // Embedded test/dev servers do not perform the production startup freeze.
	}
	frozenSerial, ok := policy.machines[identity{account, seKey}]
	return ok && frozenSerial == serial
}

func (s *Policy) RegistrationAllowed(r *protocol.RegisterMessage, account string) bool {
	if r == nil {
		return false
	}
	result, err := attestation.VerifyJSON(r.Attestation)
	return err == nil && result.Valid && s.IdentityAllowed(account, result.PublicKey, result.SerialNumber)
}

func (s *Policy) ProviderAllowed(provider *registry.Provider) bool {
	if provider == nil {
		return false
	}
	provider.Mu().Lock()
	account := provider.AccountID
	var seKey, serial string
	if result := provider.AttestationResult; result != nil && result.Valid {
		seKey, serial = result.PublicKey, result.SerialNumber
	}
	provider.Mu().Unlock()
	return s.IdentityAllowed(account, seKey, serial)
}

type EnrollmentProof struct {
	SEPublicKey string `json:"se_public_key"`
	Timestamp   int64  `json:"timestamp"`
	Signature   string `json:"signature"`
}

func (s *Policy) AuthorizeEnrollment(w http.ResponseWriter, r *http.Request, proof EnrollmentProof) bool {
	policy := s.cohort.Load()
	if policy == nil {
		return true
	}
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || token == "" {
		http.Error(w, "linked provider credentials required", http.StatusUnauthorized)
		return false
	}
	credential, err := s.store.GetProviderToken(token)
	if err != nil && !errors.Is(err, store.ErrProviderTokenInvalid) {
		http.Error(w, "provider credentials temporarily unavailable", http.StatusServiceUnavailable)
		return false
	}
	if err != nil || credential == nil || !credential.Active || credential.AccountID == "" {
		http.Error(w, "invalid provider credentials", http.StatusUnauthorized)
		return false
	}
	_, eligible := policy.machines[identity{credential.AccountID, proof.SEPublicKey}]
	if !eligible {
		http.Error(w, "New providers require macOS 27 or later and qualified App Attest verification to join the network. Legacy MDM is restricted to previously linked, successfully verified machines and does not qualify for base rewards.", http.StatusForbidden)
		return false
	}
	issuedAt := time.Unix(proof.Timestamp, 0)
	now := time.Now()
	if issuedAt.Before(now.Add(-5*time.Minute)) || issuedAt.After(now.Add(5*time.Minute)) {
		http.Error(w, "Enrollment proof is outside the five-minute validity window. Check this Mac's clock and retry.", http.StatusForbidden)
		return false
	}
	tokenHash := sha256.Sum256([]byte(token))
	message := fmt.Sprintf("darkbloom-mdm-enroll-v1\n%x\n%s\n%d", tokenHash, proof.SEPublicKey, proof.Timestamp)
	if err := attestation.VerifyChallengeSignature(proof.SEPublicKey, proof.Signature, message); err != nil {
		http.Error(w, "invalid machine enrollment proof", http.StatusForbidden)
		return false
	}
	return true
}
