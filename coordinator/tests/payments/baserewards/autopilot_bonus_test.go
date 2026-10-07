package baserewards_test

import (
	"context"
	"strconv"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/payments/baserewards"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func rewardAutopilotConsent() *protocol.ModelAutopilotState {
	return &protocol.ModelAutopilotState{Protocol: protocol.ModelAutopilotProtocol, Enabled: true, CachedOnly: true, Revision: "consent", SelectedModels: []string{"test-model"}}
}

func TestAutopilotBonusConsentAndSeparatePot(t *testing.T) {
	for _, tc := range []struct {
		name      string
		change    func(*protocol.ModelAutopilotState)
		wantBonus bool
	}{
		{"opted-in-controller-off", func(*protocol.ModelAutopilotState) {}, true},
		{"paused-consent-retained", func(s *protocol.ModelAutopilotState) { s.Paused = true }, true},
		{"observe-only-consent-retained", func(s *protocol.ModelAutopilotState) { s.ObserveOnly = true }, true},
		{"opted-out", func(s *protocol.ModelAutopilotState) { s.Enabled = false }, false},
		{"unsupported-protocol", func(s *protocol.ModelAutopilotState) { s.Protocol = 0 }, false},
		{"empty-selection", func(s *protocol.ModelAutopilotState) { s.SelectedModels = nil }, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			epoch, start, end, clock := closedEpoch()
			st := &machineEngineStore{engineStore: newEngineStore()}
			reg := registry.New(testLogger())
			p, _ := addMachineRewardProvider(t, st, reg, "session", "endpoint", "account", "apple")
			p.ModelAutopilot = rewardAutopilotConsent()
			tc.change(p.ModelAutopilot)
			st.sessions = []store.ProviderSession{fullUptimeSession(p.ID, p.PublicKey, "", p.AccountID, start, end)}
			e := newTestEngine(st, reg, clock, func(c *production.Config) { c.PoolBudgetMicroUSD = 1009 * 8928 })
			result, err := e.SettleEpoch(context.Background(), epoch)
			bonus := int64(0)
			if tc.wantBonus {
				bonus = 100
			}
			if err != nil || result.Settled != 1 || result.TotalDrawMicroUSD != 1009+bonus || result.TotalAutopilotBonusMicroUSD != bonus {
				t.Fatalf("settlement: %+v %v", result, err)
			}
			draws, _ := st.ListFloorDrawsForEpoch(context.Background(), epoch)
			if len(draws) != 1 || draws[0].AmountMicroUSD != 1009 || draws[0].AutopilotBonusMicroUSD != bonus {
				t.Fatalf("draws: %+v", draws)
			}
			used, _ := st.SumFloorDrawsForEpoch(context.Background(), epoch)
			if used != 1009 {
				t.Fatalf("bonus consumed base pool: %d", used)
			}
			// Status is for the preceding period; inspect the same epoch.
			statusEngine := newTestEngine(st, reg, end.Add(time.Second), func(c *production.Config) { c.PoolBudgetMicroUSD = 1009 * 8928 })
			status, err := statusEngine.Status(context.Background())
			if err != nil || status["pool_used"] != int64(1009) || status["autopilot_bonus_pool_used"] != bonus || status["autopilot_bonus_pool_budget"] != int64(100) {
				t.Fatalf("separate status: %+v %v", status, err)
			}
			// A subsequent opt-in/out never rewrites or tops up a frozen settlement.
			p.ModelAutopilot.Enabled = !p.ModelAutopilot.Enabled
			again, err := e.SettleEpoch(context.Background(), epoch)
			if err != nil || again.TotalDrawMicroUSD != 0 || again.Settled != 0 {
				t.Fatalf("repeat: %+v %v", again, err)
			}
			if b, w := st.balance("account"); b != 1009+bonus || w != b {
				t.Fatalf("balance %d withdrawable %d", b, w)
			}
		})
	}
}

func TestAutopilotBonusUsesReducedGrantAndDoesNotTakeOtherMachinesPool(t *testing.T) {
	epoch, start, end, clock := closedEpoch()
	st := &machineEngineStore{engineStore: newEngineStore()}
	reg := registry.New(testLogger())
	opted, machine := addMachineRewardProvider(t, st, reg, "opted", "opted-key", "same-account", "apple-opted")
	opted.ModelAutopilot = rewardAutopilotConsent()
	st.sessions = []store.ProviderSession{fullUptimeSession(opted.ID, opted.PublicKey, "", opted.AccountID, start, end)}
	floor := production.PeriodFloor(64, 1, start, end)
	st.earnings = []store.ProviderEarning{organicEarning(opted.PublicKey, opted.AccountID, "job", floor-509, start.Add(time.Minute))}
	e := newTestEngine(st, reg, clock, func(c *production.Config) { c.PoolBudgetMicroUSD = 1009 * 8928; c.ReductionK = 1 })
	first, err := e.SettleEpoch(context.Background(), epoch)
	if err != nil || first.TotalDrawMicroUSD != 559 {
		t.Fatalf("reduced draw: %+v %v", first, err)
	}
	// Same canonical machine under another connection cannot collect again.
	alias, _ := addMachineRewardProvider(t, st, reg, "alias", "alias-key", "same-account", "apple-opted")
	alias.ModelAutopilot = rewardAutopilotConsent()
	other, _ := addMachineRewardProvider(t, st, reg, "manual", "manual-key", "same-account", "apple-manual")
	st.sessions = append(st.sessions, fullUptimeSession(alias.ID, alias.PublicKey, "", alias.AccountID, start, end), fullUptimeSession(other.ID, other.PublicKey, "", other.AccountID, start, end))
	second, err := e.SettleEpoch(context.Background(), epoch)
	if err != nil || second.Settled != 1 || second.TotalDrawMicroUSD != 500 || second.TotalAutopilotBonusMicroUSD != 0 {
		t.Fatalf("remaining base pool: %+v %v", second, err)
	}
	draws, _ := st.ListFloorDrawsForEpoch(context.Background(), epoch)
	for _, d := range draws {
		if d.ProviderKey == store.MachineFloorKey(machine) && (d.AmountMicroUSD != 509 || d.AutopilotBonusMicroUSD != 50) {
			t.Fatalf("original draw changed: %+v", d)
		}
	}
	if b, _ := st.balance("same-account"); b != 1059 {
		t.Fatalf("balance=%d", b)
	}
}

func TestAutopilotConsentChangeBeforeCommitReplansWithoutLosingBase(t *testing.T) {
	for _, initiallyEnabled := range []bool{true, false} {
		t.Run(map[bool]string{true: "opt-out", false: "opt-in"}[initiallyEnabled], func(t *testing.T) {
			epoch, start, end, clock := closedEpoch()
			st := &reallocatingEngineStore{machineEngineStore: &machineEngineStore{engineStore: newEngineStore()}}
			reg := registry.New(testLogger())
			p, _ := addMachineRewardProvider(t, st.machineEngineStore, reg, "session", "endpoint", "account", "apple")
			p.ModelAutopilot = rewardAutopilotConsent()
			p.ModelAutopilot.Enabled = initiallyEnabled
			st.sessions = []store.ProviderSession{fullUptimeSession(p.ID, p.PublicKey, "", p.AccountID, start, end)}
			st.check = func(plan, index, pass int) {
				if plan == 1 && pass == 2 {
					p.Mu().Lock()
					p.ModelAutopilot.Enabled = !initiallyEnabled
					p.Mu().Unlock()
				}
			}
			e := newTestEngine(st, reg, clock)
			res, err := e.SettleEpoch(context.Background(), epoch)
			base := production.PeriodFloor(64, 1, start, end)
			bonus := int64(0)
			if !initiallyEnabled {
				bonus = base / 10
			}
			if err != nil || len(st.plans) != 2 || res.Settled != 1 || res.TotalDrawMicroUSD != base+bonus {
				t.Fatalf("replanned settlement: %+v plans=%d err=%v", res, len(st.plans), err)
			}
			if b, _ := st.balance("account"); b != base+bonus {
				t.Fatalf("balance=%d", b)
			}
		})
	}
}

func TestAutopilotBonusRoundsDownSmallAllocatedGrants(t *testing.T) {
	for _, grant := range []int64{0, 9, 10} {
		t.Run(strconv.FormatInt(grant, 10), func(t *testing.T) {
			epoch, start, end, clock := closedEpoch()
			st := &machineEngineStore{engineStore: newEngineStore()}
			reg := registry.New(testLogger())
			p, _ := addMachineRewardProvider(t, st, reg, "session", "endpoint", "account", "apple")
			p.ModelAutopilot = rewardAutopilotConsent()
			st.sessions = []store.ProviderSession{fullUptimeSession(p.ID, p.PublicKey, "", p.AccountID, start, end)}
			e := newTestEngine(st, reg, clock, func(c *production.Config) { c.PoolBudgetMicroUSD = grant * 8928 })
			result, err := e.SettleEpoch(context.Background(), epoch)
			if err != nil || result.Settled != 1 || result.TotalDrawMicroUSD != grant+grant/10 || result.TotalAutopilotBonusMicroUSD != grant/10 {
				t.Fatalf("small grant: %+v %v", result, err)
			}
			draws, err := st.ListFloorDrawsForEpoch(context.Background(), epoch)
			if err != nil || len(draws) != 1 || draws[0].AmountMicroUSD != grant || draws[0].AutopilotBonusMicroUSD != grant/10 {
				t.Fatalf("small-grant audit: %+v %v", draws, err)
			}
			if balance, withdrawable := st.balance(p.AccountID); balance != grant+grant/10 || withdrawable != balance {
				t.Fatalf("balance=%d withdrawable=%d", balance, withdrawable)
			}
			wantEntries := 0
			if grant > 0 {
				wantEntries++
			}
			if grant >= 10 {
				wantEntries++
			}
			if entries := st.inner.LedgerHistory(p.AccountID); len(entries) != wantEntries {
				t.Fatalf("zero credit recorded in ledger: %+v", entries)
			}
		})
	}
}

func TestAutopilotBonusPrefersConsentingConnectionForCanonicalMachine(t *testing.T) {
	epoch, start, end, clock := closedEpoch()
	st := &reallocatingEngineStore{machineEngineStore: &machineEngineStore{engineStore: newEngineStore()}}
	reg := registry.New(testLogger())
	manual, machine := addMachineRewardProvider(t, st.machineEngineStore, reg, "manual", "manual-key", "account", "apple")
	opted, aliasMachine := addMachineRewardProvider(t, st.machineEngineStore, reg, "opted", "opted-key", "account", "apple")
	if aliasMachine != machine {
		t.Fatal("fixture connections did not resolve to the same machine")
	}
	opted.ModelAutopilot = rewardAutopilotConsent()
	st.sessions = []store.ProviderSession{
		fullUptimeSession(manual.ID, manual.PublicKey, "", manual.AccountID, start, end),
		fullUptimeSession(opted.ID, opted.PublicKey, "", opted.AccountID, start, end),
	}
	e := newTestEngine(st, reg, clock)
	result, err := e.SettleEpoch(context.Background(), epoch)
	base := production.PeriodFloor(64, 1, start, end)
	if err != nil || result.Eligible != 1 || result.Settled != 1 || result.TotalDrawMicroUSD != base+base/10 || len(st.plans) != 1 || len(st.plans[0]) != 1 {
		t.Fatalf("shared-machine settlement: %+v plans=%+v err=%v", result, st.plans, err)
	}
	if item := st.plans[0][0]; item.SessionID != opted.ID || item.Draw.ProviderKey != store.MachineFloorKey(machine) || item.Draw.AutopilotBonusMicroUSD != base/10 {
		t.Fatalf("consenting connection not selected: %+v", item)
	}
}
