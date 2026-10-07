package registry_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/modelindex"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestAppAttestDenialUpdatesAvailabilityAndFleetViews(t *testing.T) {
	paths := map[string]func(*testing.T, *production.Registry, *production.Provider, production.AppAttestServingAuthorization){
		"granted credential": func(t *testing.T, r *production.Registry, p *production.Provider, lease production.AppAttestServingAuthorization) {
			if !r.GrantAppAttestServingAuthorization(p, lease) {
				t.Fatal("grant rejected")
			}
			r.RevokeAppAttestCredential(lease.CredentialID)
		},
		"presenter before revocation": func(t *testing.T, r *production.Registry, p *production.Provider, lease production.AppAttestServingAuthorization) {
			if current, revoked := r.RecordVerifiedAppAttestPresenter(p, lease.CredentialID, lease.AccountID, lease.Endpoint); !current || revoked {
				t.Fatal("presenter rejected")
			}
			r.RevokeAppAttestCredential(lease.CredentialID)
		},
		"presenter after revocation": func(t *testing.T, r *production.Registry, p *production.Provider, lease production.AppAttestServingAuthorization) {
			r.RevokeAppAttestCredential(lease.CredentialID)
			if current, revoked := r.RecordVerifiedAppAttestPresenter(p, lease.CredentialID, lease.AccountID, lease.Endpoint); !current || !revoked {
				t.Fatal("revoked presenter was not identified")
			}
		},
		"direct denial": func(t *testing.T, r *production.Registry, p *production.Provider, _ production.AppAttestServingAuthorization) {
			if !r.DenyAppAttestProvider(p) {
				t.Fatal("current provider not denied")
			}
		},
	}
	for name, deny := range paths {
		for _, state := range []string{"online", "serving", "transiently untrusted"} {
			t.Run(name+"/"+state, func(t *testing.T) {
				counts := &modelindex.Counts{}
				r, p, lease := appAttestTestProvider(t, production.NewWithDependencies(testLogger(), production.Dependencies{ModelCounts: counts}))
				p.Mu().Lock()
				p.Version = "revocation-test"
				p.Models[0].IsVision = true
				p.CodeAttested = true
				if state == "serving" {
					p.Status = production.StatusServing
				}
				p.Mu().Unlock()
				if !r.HasProviderForModel(appAttestTestModel) || !r.HasVisionProviderForModel(appAttestTestModel) {
					t.Fatal("fixture is not advertised as available")
				}
				if state == "transiently untrusted" {
					r.MarkUntrustedTransient(p.ID)
				}
				deny(t, r, p, lease)
				assertAppAttestDeniedViews(t, r, p, counts)

				// Repeated denial, ordinary heartbeats and successful legacy
				// challenges must neither revive the provider nor subtract twice.
				r.RevokeAppAttestCredential(lease.CredentialID)
				r.DenyAppAttestProvider(p)
				r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle"})
				r.SetProviderIdle(p.ID)
				if r.RecordChallengeSuccess(p.ID) {
					t.Fatal("legacy challenge revived a security-denied provider")
				}
				assertAppAttestDeniedViews(t, r, p, counts)
				if r.GrantAppAttestServingAuthorization(p, lease) {
					t.Fatal("late authorization revived a security-denied provider")
				}
				r.Disconnect(p.ID)
				if r.OnlineCount() != 0 || r.Snapshot().Connected != 0 {
					t.Fatal("disconnect double-decremented or retained the provider")
				}
			})
		}
	}
}

func assertAppAttestDeniedViews(t *testing.T, r *production.Registry, p *production.Provider, counts *modelindex.Counts) {
	t.Helper()
	if p.GetStatus() != production.StatusUntrusted || r.OnlineCount() != 0 {
		t.Errorf("denied provider still online: status=%s count=%d", p.GetStatus(), r.OnlineCount())
	}
	if r.HasProviderForModel(appAttestTestModel) || r.HasVisionProviderForModel(appAttestTestModel) {
		t.Error("denied provider still advertises model availability")
	}
	if len(r.ProviderCountByVersion()) != 0 || len(r.ModelProviderSnapshot()) != 0 {
		t.Error("denied provider remains in live version/model counts")
	}
	if attested, online := r.CodeAttestationCoverage(); attested != 0 || online != 0 {
		t.Errorf("denied provider remains in coverage: attested=%d online=%d", attested, online)
	}
	if snapshot := r.Snapshot(); snapshot.Idle != 0 || snapshot.Connected != 1 {
		t.Errorf("denial should retain the socket but remove idle capacity: %+v", snapshot)
	}
	rawCount := counts.Count(appAttestTestModel)
	if rawCount != 0 {
		t.Errorf("raw model count=%d, want 0", rawCount)
	}
}
