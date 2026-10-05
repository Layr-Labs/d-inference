package legacymdm_test

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	attestservice "github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/legacymdm"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type enrollmentTokenFailureStore struct {
	store.Store
	err error
}

func (s *enrollmentTokenFailureStore) Unwrap() store.Store { return s.Store }

func (s *enrollmentTokenFailureStore) GetProviderToken(token string) (*store.ProviderToken, error) {
	if s.err != nil {
		return nil, s.err
	}
	return s.Store.GetProviderToken(token)
}

func TestEnrollmentTokenLookupFailureClassification(t *testing.T) {
	for _, tc := range []struct {
		name   string
		err    error
		status int
	}{
		{"missing token", nil, http.StatusUnauthorized},
		{"wrapped invalid token", fmt.Errorf("private detail: %w", store.ErrProviderTokenInvalid), http.StatusUnauthorized},
		{"store unavailable", fmt.Errorf("private database credentials"), http.StatusServiceUnavailable},
	} {
		t.Run(tc.name, func(t *testing.T) {
			st := &enrollmentTokenFailureStore{Store: memory.NewMemory(store.Config{}), err: tc.err}
			policy := legacymdm.New(st)
			if err := policy.Initialize(context.Background(), attestservice.Config{ServingEnabled: true, Environment: "production", RolloutPercent: 100}); err != nil {
				t.Fatal(err)
			}
			r := httptest.NewRequest(http.MethodPost, "/enroll", nil)
			r.Header.Set("Authorization", "Bearer secret-token")
			w := httptest.NewRecorder()
			if policy.AuthorizeEnrollment(w, r, legacymdm.EnrollmentProof{}) || w.Code != tc.status {
				t.Fatalf("authorization status=%d, want %d", w.Code, tc.status)
			}
			if strings.Contains(w.Body.String(), "private") || strings.Contains(w.Body.String(), "secret-token") {
				t.Fatalf("authorization leaked store/token details: %q", w.Body.String())
			}
		})
	}
}

func seedMachine(t *testing.T, st *memory.MemoryStore, account, key, serial string) {
	t.Helper()
	ctx := context.Background()
	old := time.Now().Add(-time.Hour)
	if err := st.CreateUser(&store.User{AccountID: account, PrivyUserID: "did:privy:" + account, CreatedAt: old}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.ObserveMachine(ctx, store.MachineObservation{SessionID: account, AccountID: account, SEKey: key, VerifiedSerial: serial, At: old}); err != nil {
		t.Fatal(err)
	}
	if err := st.UpsertProvider(ctx, store.ProviderRecord{ID: account, AccountID: account, SEPublicKey: key, SerialNumber: serial, RegisteredAt: old}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.UpsertProviderTrustReuse(ctx, store.ProviderTrustReuse{
		SEPubKey: key, Serial: serial, TrustLevel: "hardware", HardwareProofVerifiedAt: old,
		SIPEnabled: true, SecureBootFull: true, MDAUDID: "verified-device",
	}, 0); err != nil {
		t.Fatal(err)
	}
}

func TestFrozenCohortThroughCachedStore(t *testing.T) {
	for _, empty := range []bool{false, true} {
		t.Run(fmt.Sprintf("empty=%t", empty), func(t *testing.T) {
			st := memory.NewMemory(store.Config{})
			if !empty {
				seedMachine(t, st, "old-account", "old-key", "old-serial")
			}
			cached := store.NewCached(st, store.CacheConfig{})
			initialize := func() *legacymdm.Policy {
				policy := legacymdm.New(cached)
				if err := policy.Initialize(context.Background(), attestservice.Config{ServingEnabled: true, Environment: "production", RolloutPercent: 100}); err != nil {
					t.Fatal(err)
				}
				return policy
			}
			policy := initialize()
			seedMachine(t, st, "late-account", "late-key", "late-serial")
			for _, current := range []*legacymdm.Policy{policy, initialize()} {
				if got := current.IdentityAllowed("old-account", "old-key", "old-serial"); got == empty {
					t.Fatalf("old membership=%t, empty=%t", got, empty)
				}
				if current.IdentityAllowed("late-account", "late-key", "late-serial") ||
					current.IdentityAllowed("other-account", "old-key", "old-serial") ||
					current.IdentityAllowed("old-account", "new-key", "old-serial") ||
					current.IdentityAllowed("old-account", "old-key", "copied-serial") {
					t.Fatal("frozen account/key/serial membership changed")
				}
			}
		})
	}
}

func TestConfigurationValidatedBeforeFreeze(t *testing.T) {
	for _, cfg := range []attestservice.Config{
		{}, {Environment: "production", RolloutPercent: 100},
		{ServingEnabled: true, Environment: "production", RolloutPercent: 50},
		{ServingEnabled: true, Environment: "development", RolloutPercent: 100},
	} {
		st := memory.NewMemory(store.Config{})
		policy := legacymdm.New(st)
		if err := policy.Initialize(context.Background(), cfg); err == nil {
			t.Fatal("unsafe serving configuration accepted")
		}
		if !policy.Initialized() || policy.IdentityAllowed("account", "key", "serial") {
			t.Fatal("failed initialization did not close eligibility")
		}
		seedMachine(t, st, "account", "key", "serial")
		valid := legacymdm.New(st)
		if err := valid.Initialize(context.Background(), attestservice.Config{ServingEnabled: true, Environment: "production", RolloutPercent: 100}); err != nil {
			t.Fatal(err)
		}
		if !valid.IdentityAllowed("account", "key", "serial") {
			t.Fatal("invalid configuration permanently froze an empty cohort")
		}
	}
}
