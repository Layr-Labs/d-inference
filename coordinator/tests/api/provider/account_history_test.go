package provider_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAppAttestAccountBoundInitialHistoryRestore(t *testing.T) {
	s, _ := providerTestOwner(t)
	p := s.registry.Register("connection", nil, &protocol.RegisterMessage{})
	p.Mu().Lock()
	p.AccountID = "account"
	p.Mu().Unlock()
	t.Cleanup(func() { s.registry.Disconnect(p.ID) })
	if err := s.store.UpsertProvider(context.Background(), store.ProviderRecord{ID: "other-history", SEPublicKey: "se", AccountID: "previous-owner", LastSeen: time.Now(), LifetimeTokensGenerated: 99}); err != nil {
		t.Fatal(err)
	}
	if err := s.RestorePersistedProviderState(context.Background(), p, "", "se", "account"); err != nil {
		t.Fatal(err)
	}
	p.Mu().Lock()
	accountID, tokens := p.AccountID, p.Stats.TokensGenerated
	p.Mu().Unlock()
	if accountID != "account" || tokens != 0 {
		t.Fatal("inherited another account history")
	}
}
