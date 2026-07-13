//go:build pilotload

package main

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type pilotSeedStore struct {
	store.Store
	key           string
	fundedAccount string
	fundedAmount  int64
	model         string
	alias         *store.ModelAlias
}

func (s *pilotSeedStore) SeedKey(key string) error {
	s.key = key
	return nil
}

func (s *pilotSeedStore) CreditWithdrawableOnce(account string, amount int64, _ store.LedgerEntryType, _ string) (bool, error) {
	s.fundedAccount = account
	s.fundedAmount = amount
	return true, nil
}

func (s *pilotSeedStore) SetModelVersion(entry *store.ModelRegistryEntry, _ *store.ModelVersion, _ []store.ModelVersionFile) error {
	s.model = entry.ID
	return nil
}

func (s *pilotSeedStore) PromoteModelVersion(string, string) error {
	return nil
}

func (s *pilotSeedStore) UpsertModelAlias(alias *store.ModelAlias) error {
	s.alias = alias
	return nil
}

func TestSeedPilotLoadStateRequiresExplicitOptIn(t *testing.T) {
	st := &pilotSeedStore{}
	if err := seedPilotLoadState(st); err != nil {
		t.Fatal(err)
	}
	if st.key != "" {
		t.Fatal("pilot state was seeded without explicit opt-in")
	}
}

func TestPilotLoadBindsOnlyToIPv4Loopback(t *testing.T) {
	if got := pilotListenAddress("18080"); got != "127.0.0.1:18080" {
		t.Fatalf("pilot listen address = %q", got)
	}
}

func TestSeedPilotLoadStateCreatesFundedConsumerAndCatalog(t *testing.T) {
	t.Setenv("EIGENINFERENCE_PILOT_LOAD_ENABLED", "true")
	t.Setenv("EIGENINFERENCE_PILOT_CONSUMER_KEY", "pilot-consumer-key")
	t.Setenv("EIGENINFERENCE_PILOT_MODEL_ID", "darkbloom/pilot-text")
	t.Setenv("EIGENINFERENCE_PILOT_MODEL_ALIAS", "darkbloom-pilot")
	t.Setenv("EIGENINFERENCE_PILOT_FUNDING_MICRO_USD", "123456")
	st := &pilotSeedStore{}

	if err := seedPilotLoadState(st); err != nil {
		t.Fatal(err)
	}
	if st.key != "pilot-consumer-key" {
		t.Fatalf("seeded key = %q", st.key)
	}
	if st.fundedAccount != store.LegacyAccountID("pilot-consumer-key") || st.fundedAmount != 123456 {
		t.Fatalf("funding = %q/%d", st.fundedAccount, st.fundedAmount)
	}
	if st.model != "darkbloom/pilot-text" {
		t.Fatalf("seeded model = %q", st.model)
	}
	if st.alias == nil || st.alias.AliasID != "darkbloom-pilot" || st.alias.DesiredBuild != st.model {
		t.Fatalf("seeded alias = %#v", st.alias)
	}
}
