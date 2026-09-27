package service

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestUnknownInitialPresenterRemainsVisibleToRevocation(t *testing.T) {
	for _, phase := range []string{"admin", "remote refresh", "revocation before presentation"} {
		t.Run(phase, func(t *testing.T) {
			s, p, record, state := newAuthorizationFixture(t)
			makeLegacyAuthorized(p)
			x := sessionForAuthorization(s, p, record)
			e := record.evidence
			applyAppAttestReadiness(&e, state)
			e.RevocationKnown = false
			if phase == "revocation before presentation" {
				s.RevokeCredential(e.Binding.Credential)
			}
			x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
			if s.authorizer.current[p] != nil || p.GetAppAttestServingAuthorization().CredentialID != "" {
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
				s.authorizer.refresh(context.Background())
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
			if !s.authorizer.apply(p, old, state, time.Now()) {
				t.Fatal("grant")
			}
			if current, revoked := s.registry.RecordVerifiedAppAttestPresenter(p, "new-key", old.evidence.Binding.Account, old.evidence.Binding.Endpoint); !current || revoked {
				t.Fatal("new presenter")
			}
			s.authorizer.forget(p)
			s.store = &authorizationBatchStore{Store: s.store, state: map[string]store.AppAttestReadiness{credential: {Revoked: true}}}
			s.authorizer.refresh(context.Background())
			if s.registry.ProviderServingDenialReason(p) == "" {
				t.Fatal("remote revocation missed a retained credential")
			}
		})
	}
}

func TestRefreshAndRevocationQueueNotificationsWithoutProviderIO(t *testing.T) {
	s, p, record, state := newAuthorizationFixture(t)
	a := s.authorizer
	a.post, a.postPending = make(chan *registry.Provider, 2), make(map[*registry.Provider]bool)
	s.trustStatus = func(*registry.Provider, registry.TrustLevel, string, string) {
		t.Fatal("synchronous provider notification on policy worker")
	}
	s.store = &authorizationBatchStore{Store: s.store, state: map[string]store.AppAttestReadiness{record.evidence.Binding.Credential: state}}
	a.remember(p, record)
	a.refresh(context.Background())
	if len(a.post) != 1 {
		t.Fatal("renewal notification was not queued")
	}
	s.RevokeCredential(record.evidence.Binding.Credential)
	if s.registry.ProviderServingDenialReason(p) == "" || len(a.post) != 1 {
		t.Fatal("revocation did not fence immediately and reuse bounded notification queue")
	}
}

func TestNewUnknownPresenterDoesNotHidePreviousQualifiedCredential(t *testing.T) {
	for _, granted := range []bool{false, true} {
		t.Run(map[bool]string{false: "before first grant", true: "existing lease"}[granted], func(t *testing.T) {
			s, p, old, state := newAuthorizationFixture(t)
			makeLegacyAuthorized(p)
			s.authorizer.remember(p, old)
			if granted && !s.authorizer.apply(p, old, state, time.Now()) {
				t.Fatal("old grant")
			}
			newer := *old
			newer.evidence.Binding.Credential, newer.evidence.Expected.Credential = "new-key", "new-key"
			x := sessionForAuthorization(s, p, &newer)
			e := newer.evidence
			applyAppAttestReadiness(&e, state)
			e.RevocationKnown = false
			x.updateServingAuthorization(&newer.status, e, appattest.EvaluateAuthorization(e, time.Now()))
			if s.authorizer.current[p] != old {
				t.Fatal("unknown replaced qualified refresh record")
			}
			s.RevokeCredential(old.evidence.Binding.Credential)
			if s.registry.ProviderLegacyServingAuthorized(p) || s.registry.ProviderServingDenialReason(p) == "" {
				t.Fatal("latest unknown key hid the older qualified credential")
			}
		})
	}
}
