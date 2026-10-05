package identity_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	eligibility "github.com/eigeninference/d-inference/coordinator/internal/appattest/eligibility"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestUnknownInitialPresenterRemainsVisibleToRevocation(t *testing.T) {
	for _, phase := range []string{"admin", "remote refresh", "revocation before presentation"} {
		t.Run(phase, func(t *testing.T) {
			s, p, _, state := newAuthorizationFixture(t)
			makeLegacyAuthorized(p)
			x := identityForAuthorization(s, p, nil)
			e := s.evidence
			eligibility.ApplyReadiness(&e, state)
			e.RevocationKnown = false
			if phase == "revocation before presentation" {
				s.RevokeCredential(e.Binding.Credential)
			}
			x.Update(s.proof(e), appattest.EvaluateAuthorization(e, time.Now()))
			if s.authorizer.Current(p) != nil || p.GetAppAttestServingAuthorization().CredentialID != "" {
				t.Fatal("presenter-only evidence became grantable")
			}
			switch phase {
			case "admin":
				if !s.registry.ProviderLegacyServingAuthorized(p) {
					t.Fatal("unknown evidence removed legacy authorization")
				}
				s.RevokeCredential(e.Binding.Credential)
			case "remote refresh":
				s.store = &authorizationBatchStore{Store: s.store, state: map[string]store.AppAttestReadiness{e.Binding.Credential: {Revoked: true}}}
				s.authorizer.Refresh(context.Background())
			}
			if s.registry.ProviderServingDenialReason(p) == "" || s.registry.ProviderLegacyServingAuthorized(p) {
				t.Fatal("revoked initial presenter remained routable")
			}
		})
	}
}

func TestRemoteRevocationPollsRetainedGrantWithoutRefreshRecord(t *testing.T) {
	for _, credential := range []string{"credential", "new-key"} {
		t.Run(credential, func(t *testing.T) {
			s, p, old, state := newAuthorizationFixture(t)
			if !s.authorizer.Apply(p, old, state, time.Now()) {
				t.Fatal("grant")
			}
			if current, revoked := s.registry.RecordVerifiedAppAttestPresenter(p, "new-key", s.evidence.Binding.Account, s.evidence.Binding.Endpoint); !current || revoked {
				t.Fatal("new presenter")
			}
			s.authorizer.Forget(p)
			s.store = &authorizationBatchStore{Store: s.store, state: map[string]store.AppAttestReadiness{credential: {Revoked: true}}}
			s.authorizer.Refresh(context.Background())
			if s.registry.ProviderServingDenialReason(p) == "" {
				t.Fatal("remote revocation missed a retained credential")
			}
		})
	}
}

func TestRefreshAndRevocationQueueNotificationsWithoutProviderIO(t *testing.T) {
	s, p, record, state := newAuthorizationFixture(t)
	outbox := authorization.NewOutbox(2)
	s.notifications = outbox
	s.authorizer = s.newAuthorizer()
	a := s.authorizer
	s.notify = func(*registry.Provider) {
		t.Fatal("synchronous provider notification on policy worker")
	}
	s.store = &authorizationBatchStore{Store: s.store, state: map[string]store.AppAttestReadiness{s.evidence.Binding.Credential: state}}
	a.Remember(p, record)
	a.Refresh(context.Background())
	if outbox.Pending() != 1 {
		t.Fatal("renewal notification was not queued")
	}
	s.RevokeCredential(s.evidence.Binding.Credential)
	if s.registry.ProviderServingDenialReason(p) == "" || outbox.Pending() != 1 {
		t.Fatal("revocation did not fence immediately and reuse bounded notification queue")
	}
}

func TestNewUnknownPresenterDoesNotHidePreviousQualifiedCredential(t *testing.T) {
	for _, granted := range []bool{false, true} {
		t.Run(map[bool]string{false: "before first grant", true: "existing lease"}[granted], func(t *testing.T) {
			s, p, old, state := newAuthorizationFixture(t)
			makeLegacyAuthorized(p)
			s.authorizer.Remember(p, old)
			if granted && !s.authorizer.Apply(p, old, state, time.Now()) {
				t.Fatal("old grant")
			}
			e := s.evidence
			e.Binding.Credential, e.Expected.Credential = "new-key", "new-key"
			x := identityForAuthorization(s, p, nil)
			eligibility.ApplyReadiness(&e, state)
			e.RevocationKnown = false
			x.Update(s.proof(e), appattest.EvaluateAuthorization(e, time.Now()))
			if s.authorizer.Current(p) != old {
				t.Fatal("unknown replaced qualified refresh record")
			}
			s.RevokeCredential(s.evidence.Binding.Credential)
			if s.registry.ProviderLegacyServingAuthorized(p) || s.registry.ProviderServingDenialReason(p) == "" {
				t.Fatal("latest unknown key hid the older qualified credential")
			}
		})
	}
}
