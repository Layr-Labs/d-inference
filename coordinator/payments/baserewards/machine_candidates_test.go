package baserewards

import (
	"context"
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type machineEngineStore struct {
	*engineStore
	onSum       func()
	onEpochLock func()
}

func (s *machineEngineStore) WithEpochSettlementLock(ctx context.Context, epoch string, fn func() error) error {
	if s.onEpochLock != nil {
		s.onEpochLock()
	}
	return s.engineStore.WithEpochSettlementLock(ctx, epoch, fn)
}

func (s *machineEngineStore) GetMachineRewardBindings(ctx context.Context, ids []string) (map[string]store.MachineRewardBinding, error) {
	return s.inner.GetMachineRewardBindings(ctx, ids)
}
func (s *machineEngineStore) SumProviderEarningsByKeysForAccount(_ context.Context, account string, keys []string, start, end time.Time) (int64, error) {
	if s.onSum != nil {
		s.onSum()
	}
	var total int64
	for _, earning := range s.earnings {
		if earning.AccountID == account && slices.Contains(keys, earning.ProviderKey) && earning.Model != "base_reward" && earning.AmountMicroUSD > 0 && !earning.CreatedAt.Before(start) && earning.CreatedAt.Before(end) {
			total += earning.AmountMicroUSD
		}
	}
	return total, nil
}
func (s *machineEngineStore) SettleMachineFloorDraw(ctx context.Context, machine string, draw *store.ProviderFloorDraw) (bool, error) {
	return s.inner.SettleMachineFloorDraw(ctx, machine, draw)
}
func (s *machineEngineStore) SettleProviderFloorDrawForSession(ctx context.Context, session string, draw *store.ProviderFloorDraw) (bool, error) {
	return s.inner.SettleProviderFloorDrawForSession(ctx, session, draw)
}

func addMachineRewardProvider(t *testing.T, st *machineEngineStore, reg *registry.Registry, id, endpoint, account, credential string) (*registry.Provider, string) {
	t.Helper()
	ctx := context.Background()
	now := time.Now()
	machine, err := st.inner.ObserveMachine(ctx, store.MachineObservation{SessionID: id, AccountID: account, VerifiedAppAttestKey: credential, At: now})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.inner.OpenProviderSession(ctx, id, "", account); err != nil {
		t.Fatal(err)
	}
	if err := st.inner.TouchProviderSession(ctx, id, "", account, endpoint, now); err != nil {
		t.Fatal(err)
	}
	p := addProvider(reg, id, endpoint, "", "Mac15,8", 64)
	p.AccountID = account
	p.Attested = false
	p.TrustLevel = registry.TrustNone
	p.ChallengeVerifiedSIP = false
	p.RequireVerifiedMachineIdentity()
	p.CompleteProviderStateRestore()
	reg.SetAppAttestServingPolicy(true, 1)
	if !reg.BindVerifiedMachineIdentity(p, account, machine.ID) {
		t.Fatal("cannot bind verified identity")
	}
	if !reg.GrantAppAttestServingAuthorization(p, registry.AppAttestServingAuthorization{
		AccountID: account, MachineID: machine.ID, CredentialID: credential, ConnectionID: id, ProofSessionID: "proof-" + id,
		Endpoint: endpoint, PolicyGeneration: 1, IssuedAt: now.Add(-time.Second), ValidUntil: now.Add(time.Minute), MachineModel: "Mac15,8", MemoryGB: 64,
	}) {
		t.Fatal("cannot grant App Attest fixture")
	}
	return p, machine.ID
}

func TestAppAttestMachineRewardsUnionRotatedSessionsAndKeepOriginalEarnings(t *testing.T) {
	epoch, start, end, clock := closedEpoch()
	st := &machineEngineStore{engineStore: newEngineStore()}
	reg := registry.New(testLogger())
	_, machine := addMachineRewardProvider(t, st, reg, "first", "old-key", "account", "apple")
	_, same := addMachineRewardProvider(t, st, reg, "second", "new-key", "account", "apple")
	if same != machine {
		t.Fatal("same verified credential diverged")
	}
	// Each session alone is below 90%; together they cover 100%, with overlap
	// that must not be double counted. Separate keys retain their earning rows.
	st.sessions = []store.ProviderSession{
		fullUptimeSession("first", "old-key", "claimed", "account", start, start.Add(3*time.Minute)),
		fullUptimeSession("second", "new-key", "different-claim", "account", start.Add(2*time.Minute), end),
	}
	st.earnings = []store.ProviderEarning{
		organicEarning("old-key", "account", "a", 40, start.Add(time.Minute)),
		organicEarning("new-key", "account", "b", 60, start.Add(time.Minute)),
		organicEarning("old-key", "other-account", "c", 900, start.Add(time.Minute)),
	}
	e := newTestEngine(st, reg, clock)
	result, err := e.SettleEpoch(context.Background(), epoch)
	if err != nil || result.Eligible != 1 || result.Settled != 1 {
		t.Fatalf("canonical settlement: %+v %v", result, err)
	}
	draws, err := st.ListFloorDrawsForEpoch(context.Background(), epoch)
	if err != nil || len(draws) != 1 || draws[0].ProviderKey != store.MachineFloorKey(machine) || draws[0].EarnedMicroUSD != 100 || draws[0].UptimeFrac != 1 || draws[0].MemoryGB != 64 {
		t.Fatalf("canonical audit: %+v %v", draws, err)
	}
	// A third process encryption key still refers to the settled machine.
	_, _ = addMachineRewardProvider(t, st, reg, "third", "third-key", "account", "apple")
	st.sessions = append(st.sessions, fullUptimeSession("third", "third-key", "", "account", start, end))
	result, err = e.SettleEpoch(context.Background(), epoch)
	if err != nil || result.Settled != 0 || result.AlreadySettled != 1 {
		t.Fatalf("rotation duplicated floor: %+v %v", result, err)
	}
}

func TestAppAttestMachineRewardsPreserveEarlierLegacyFloor(t *testing.T) {
	epoch, start, end, clock := closedEpoch()
	st := &machineEngineStore{engineStore: newEngineStore()}
	reg := registry.New(testLogger())
	p, _ := addMachineRewardProvider(t, st, reg, "migrated", "legacy-key", "account", "apple")
	// A hybrid connection has both paths; it still contributes one candidate.
	p.Mu().Lock()
	p.Attested, p.ChallengeVerifiedSIP = true, true
	p.TrustLevel = registry.TrustHardware
	p.Mu().Unlock()
	st.sessions = []store.ProviderSession{fullUptimeSession(p.ID, "legacy-key", "serial", "account", start, end)}
	if paid, err := st.SettleProviderFloorDraw(context.Background(), &store.ProviderFloorDraw{ProviderKey: "legacy-key", AccountID: "account", EpochID: epoch, AmountMicroUSD: 123}); err != nil || !paid {
		t.Fatal("legacy setup", err)
	}
	e := newTestEngine(st, reg, clock)
	result, err := e.SettleEpoch(context.Background(), epoch)
	if err != nil || result.Settled != 0 || result.AlreadySettled != 1 {
		t.Fatalf("legacy floor was paid again: %+v %v", result, err)
	}
	if balance, _ := st.balance("account"); balance != 123 {
		t.Fatal("legacy balance changed")
	}
}

func TestMachineRewardCanonicalFirstFencesCandidateBuiltBeforeBinding(t *testing.T) {
	epoch, start, end, clock := closedEpoch()
	ctx := context.Background()
	st := &machineEngineStore{engineStore: newEngineStore()}
	reg := registry.New(testLogger())
	p := addProvider(reg, "legacy", "old-key", "serial", "Mac15,8", 64)
	setSerial(p, "serial", "Mac15,8")
	p.AccountID = "account"
	st.sessions = []store.ProviderSession{fullUptimeSession(p.ID, p.PublicKey, "serial", "account", start, end)}
	if err := st.inner.OpenProviderSession(ctx, p.ID, "serial", "account"); err != nil {
		t.Fatal(err)
	}
	if err := st.inner.TouchProviderSession(ctx, p.ID, "serial", "account", p.PublicKey, time.Now()); err != nil {
		t.Fatal(err)
	}
	// The candidate was built with the raw key; a concurrent settlement gained
	// the epoch lock first, learned canonical identity, and paid that key.
	st.onEpochLock = func() {
		machine, err := st.inner.ObserveMachine(ctx, store.MachineObservation{SessionID: p.ID, AccountID: "account", VerifiedAppAttestKey: "apple", At: time.Now()})
		if err != nil {
			t.Fatal(err)
		}
		paid, err := st.inner.SettleMachineFloorDraw(ctx, machine.ID, &store.ProviderFloorDraw{AccountID: "account", EpochID: epoch, AmountMicroUSD: 123})
		if err != nil || !paid {
			t.Fatalf("canonical first settlement: %v %v", paid, err)
		}
	}
	e := newTestEngine(st, reg, clock)
	result, err := e.SettleEpoch(ctx, epoch)
	if err != nil || result.Settled != 0 || result.AlreadySettled != 1 {
		t.Fatalf("stale raw candidate paid again: %+v %v", result, err)
	}
	if balance, _ := st.balance("account"); balance != 123 {
		t.Fatal("canonical-first race changed balance")
	}
}

func TestAppAttestMachineRewardFencesRevokeExpiryAndUnboundClaims(t *testing.T) {
	for _, failure := range []string{"revoke-before-credit", "expired", "unbound-machine", "unsigned-hardware", "private-only"} {
		t.Run(failure, func(t *testing.T) {
			epoch, start, end, clock := closedEpoch()
			st := &machineEngineStore{engineStore: newEngineStore()}
			reg := registry.New(testLogger())
			p, _ := addMachineRewardProvider(t, st, reg, "one", "key", "account", "apple")
			st.sessions = []store.ProviderSession{fullUptimeSession(p.ID, "key", "claimed", "account", start, end)}
			switch failure {
			case "revoke-before-credit":
				st.onSum = func() { reg.RevokeAppAttestCredential("apple") }
			case "expired":
				lease := p.GetAppAttestServingAuthorization()
				lease.ValidUntil = time.Now().Add(20 * time.Millisecond)
				if !reg.GrantAppAttestServingAuthorization(p, lease) {
					t.Fatal("cannot shorten fixture lease")
				}
				time.Sleep(30 * time.Millisecond)
			case "unbound-machine":
				// Lookup fails even if a caller accidentally binds a different ID.
				reg.BindVerifiedMachineIdentity(p, "account", "unrelated")
			case "unsigned-hardware":
				lease := p.GetAppAttestServingAuthorization()
				lease.MachineModel = ""
				reg.ClearAppAttestServingAuthorization(p)
				reg.GrantAppAttestServingAuthorization(p, lease)
			case "private-only":
				p.Mu().Lock()
				p.PrivateOnly = true
				p.Mu().Unlock()
			}
			e := newTestEngine(st, reg, clock)
			result, err := e.SettleEpoch(context.Background(), epoch)
			if err != nil || result.Settled != 0 {
				t.Fatalf("unqualified machine received floor: %+v %v", result, err)
			}
		})
	}
}
