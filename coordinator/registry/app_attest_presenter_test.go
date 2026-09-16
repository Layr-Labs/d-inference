package registry

import (
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestVerifiedPresenterAndRevocationHaveSafeEitherOrder(t *testing.T) {
	for i := 0; i < 32; i++ {
		r, p, lease := appAttestTestProvider(t)
		var wg sync.WaitGroup
		start := make(chan struct{})
		wg.Add(2)
		go func() {
			defer wg.Done()
			<-start
			r.RecordVerifiedAppAttestPresenter(p, lease.CredentialID, lease.AccountID, lease.Endpoint)
		}()
		go func() { defer wg.Done(); <-start; r.RevokeAppAttestCredential(lease.CredentialID) }()
		close(start)
		wg.Wait()
		if r.ProviderServingDenialReason(p) == "" || r.GrantAppAttestServingAuthorization(p, lease) {
			t.Fatal("revocation/presentation ordering allowed a grant")
		}
	}
}

func TestPresenterBindingCannotTouchAReplacementOrAnotherAccount(t *testing.T) {
	r, old, lease := appAttestTestProvider(t)
	if current, _ := r.RecordVerifiedAppAttestPresenter(old, lease.CredentialID, "other-account", lease.Endpoint); current {
		t.Fatal("account mismatch accepted")
	}
	if current, _ := r.RecordVerifiedAppAttestPresenter(old, lease.CredentialID, lease.AccountID, "other-endpoint"); current {
		t.Fatal("endpoint mismatch accepted")
	}
	if current, revoked := r.RecordVerifiedAppAttestPresenter(old, lease.CredentialID, lease.AccountID, lease.Endpoint); !current || revoked {
		t.Fatal("valid presenter rejected")
	}
	if old.GetAppAttestServingAuthorization().CredentialID != "" {
		t.Fatal("presentation granted a lease")
	}
	r.Disconnect(old.ID)
	p := r.Register(old.ID, nil, &protocol.RegisterMessage{PublicKey: lease.Endpoint})
	p.Mu().Lock()
	p.AccountID = lease.AccountID
	p.Mu().Unlock()
	if current, _ := r.RecordVerifiedAppAttestPresenter(old, "late-key", lease.AccountID, lease.Endpoint); current {
		t.Fatal("stale connection associated a credential")
	}
	if r.DenyAppAttestProvider(old) {
		t.Fatal("stale presenter denied its replacement")
	}
	r.RevokeAppAttestCredential(lease.CredentialID)
	if r.ProviderServingDenialReason(p) != "" || len(r.VerifiedAppAttestPresenters()) != 0 {
		t.Fatal("replacement inherited the old presenter's revocation")
	}
}
