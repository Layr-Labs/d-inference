package baserewards_test

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestBaseRewardsRequireVerifiedMacOS27ForOldAndNewProviders(t *testing.T) {
	for _, legacy := range []bool{false, true} {
		for _, version := range []string{"26.5", "27", "27.0", "28.1.2", "", "macOS 27", "27.x", "27.", "27.0.0.1", "+27", " 27", "27.0beta", "18446744073709551616", "27.18446744073709551616"} {
			t.Run(fmt.Sprintf("legacy=%t/os=%s", legacy, version), func(t *testing.T) {
				epoch, start, end, clock := closedEpoch()
				st := &machineEngineStore{engineStore: newEngineStore()}
				reg := registry.New(testLogger())
				p, _ := addMachineRewardProvider(t, st, reg, "provider", "key", "account", "apple")
				p.Mu().Lock()
				p.AttestationResult = &attestation.VerificationResult{Valid: true, OSVersion: "27.0", HardwareModel: "Mac15,8", SerialNumber: "serial"}
				if legacy {
					p.Attested, p.ChallengeVerifiedSIP = true, true
					p.TrustLevel = registry.TrustHardware
				}
				p.Mu().Unlock()
				if !legacy {
					p.RequireAppAttestServingAuthorization()
				}
				lease := p.GetAppAttestServingAuthorization()
				lease.OSVersion = version
				if !reg.GrantAppAttestServingAuthorization(p, lease) {
					t.Fatal("reward OS must not change serving lease validity")
				}
				st.sessions = []store.ProviderSession{fullUptimeSession(p.ID, "key", "serial", "account", start, end)}
				result, err := newTestEngine(st, reg, clock).SettleEpoch(context.Background(), epoch)
				if err != nil {
					t.Fatal(err)
				}
				allowed := version == "27" || version == "27.0" || version == "28.1.2"
				if allowed {
					if result.Settled != 1 || result.TotalDrawMicroUSD <= 0 {
						t.Fatalf("valid OS denied rewards: %+v", result)
					}
				} else if result.Eligible != 0 || result.Settled != 0 || result.TotalDrawMicroUSD != 0 {
					t.Fatalf("invalid verified OS earned rewards: %+v", result)
				}
				if legacy && !reg.ProviderLegacyServingAuthorized(p) {
					t.Fatal("reward OS exclusion changed grandfathered serving")
				}
			})
		}
	}
}

func TestBaseRewardsRequireCurrentAppAttestDespiteLegacyServing(t *testing.T) {
	for _, state := range []string{"legacy-only", "hybrid", "expired", "revoked", "unqualified", "expires-before-credit", "unqualified-before-credit", "expires-at-commit", "unqualified-at-commit"} {
		t.Run(state, func(t *testing.T) {
			epoch, start, end, clock := closedEpoch()
			st := &machineEngineStore{engineStore: newEngineStore()}
			batchStore := &reallocatingEngineStore{machineEngineStore: st}
			now := time.Now()
			reg := registry.NewWithDependencies(testLogger(), registry.Dependencies{AppAttestNow: func() time.Time { return now }})
			p, _ := addMachineRewardProvider(t, st, reg, "hybrid", "key", "account", "apple")
			setSerial(p, "serial", "Mac15,8")
			// This grandfathered connection retains complete legacy authorization.
			p.Mu().Lock()
			p.Attested, p.ChallengeVerifiedSIP = true, true
			p.TrustLevel = registry.TrustHardware
			p.Mu().Unlock()
			if !reg.ProviderLegacyServingAuthorized(p) {
				t.Fatal("fixture must retain legacy serving authorization")
			}
			st.sessions = []store.ProviderSession{fullUptimeSession(p.ID, "key", "serial", "account", start, end)}
			lease := p.GetAppAttestServingAuthorization()
			lease.OSVersion = "28.0"
			if !reg.GrantAppAttestServingAuthorization(p, lease) {
				t.Fatal("grant OS-qualified lease")
			}
			expire := func() { now = p.GetAppAttestServingAuthorization().ValidUntil }
			unqualify := func() { reg.SetAppAttestQualificationGeneration(1) }
			switch state {
			case "legacy-only":
				reg.ClearAppAttestServingAuthorization(p)
			case "expired":
				expire()
			case "revoked":
				reg.RevokeAppAttestCredential("apple")
			case "unqualified":
				unqualify()
			case "expires-before-credit":
				st.onEpochLock = expire
			case "unqualified-before-credit":
				st.onEpochLock = unqualify
			case "expires-at-commit", "unqualified-at-commit":
				batchStore.check = func(plan, index, pass int) {
					if pass == 2 {
						if state == "expires-at-commit" {
							expire()
						} else {
							unqualify()
						}
					}
				}
			}
			result, err := newTestEngine(batchStore, reg, clock).SettleEpoch(context.Background(), epoch)
			if err != nil {
				t.Fatal(err)
			}
			if state == "hybrid" {
				if result.Eligible != 1 || result.Settled != 1 || result.TotalDrawMicroUSD <= 0 {
					t.Fatalf("qualified hybrid lost base rewards: %+v", result)
				}
				return
			}
			if result.Settled != 0 || result.TotalDrawMicroUSD != 0 {
				t.Fatalf("legacy fallback earned new base rewards: %+v", result)
			}
			if state != "revoked" && !reg.ProviderLegacyServingAuthorized(p) {
				t.Fatal("base reward exclusion must not disable legacy serving")
			}
			draws, err := st.ListFloorDrawsForEpoch(context.Background(), epoch)
			if err != nil || len(draws) != 0 {
				t.Fatalf("ineligible provider wrote a floor row: %+v, %v", draws, err)
			}
		})
	}
}

func TestLegacyOnlyBaseRewardExclusionPreservesEarnedLedger(t *testing.T) {
	epoch, start, end, clock := closedEpoch()
	ctx := context.Background()
	st := &machineEngineStore{engineStore: newEngineStore()}
	reg := registry.New(testLogger())
	p, _ := addMachineRewardProvider(t, st, reg, "hybrid", "key", "account", "apple")
	setSerial(p, "serial", "Mac15,8")
	p.Mu().Lock()
	p.Attested, p.ChallengeVerifiedSIP = true, true
	p.TrustLevel = registry.TrustHardware
	p.Mu().Unlock()
	reg.ClearAppAttestServingAuthorization(p)
	if !reg.ProviderLegacyServingAuthorized(p) {
		t.Fatal("fixture cannot serve through legacy authorization")
	}
	st.sessions = []store.ProviderSession{fullUptimeSession(p.ID, "key", "serial", "account", start, end)}
	// Existing legacy floor rows remain earned, including a retry of their epoch.
	settlePriorFloor(t, st.inner, store.ProviderFloorDraw{ProviderKey: "key", AccountID: "account", EpochID: epoch, AmountMicroUSD: 123})
	earning := organicEarning("key", "account", "completed-inference", 456, start.Add(time.Minute))
	if err := st.inner.CreditProviderAccount(&earning); err != nil {
		t.Fatal(err)
	}
	e := newTestEngine(st, reg, clock)
	for _, id := range []string{epoch, end.Format("2006-01-02T15:04Z")} {
		st.sessions = []store.ProviderSession{fullUptimeSession(p.ID, "key", "serial", "account", start, end.Add(5*time.Minute))}
		result, err := e.SettleEpoch(ctx, id)
		if err != nil || result.Eligible != 0 || result.Settled != 0 {
			t.Fatalf("legacy-only settlement: %+v, %v", result, err)
		}
	}
	if balance, withdrawable := st.balance("account"); balance != 579 || withdrawable != 579 {
		t.Fatalf("earned ledger changed: balance=%d withdrawable=%d", balance, withdrawable)
	}
	draws, err := st.ListFloorDrawsForEpoch(ctx, epoch)
	if err != nil || len(draws) != 1 || draws[0].AmountMicroUSD != 123 {
		t.Fatalf("existing legacy reward changed: %+v, %v", draws, err)
	}
	// Completed work continues to use the unchanged organic credit path.
	earning.JobID = "next-completed-inference"
	if err := st.inner.CreditProviderAccount(&earning); err != nil {
		t.Fatal(err)
	}
	if balance, withdrawable := st.balance("account"); balance != 1035 || withdrawable != 1035 {
		t.Fatalf("completed work was not credited: balance=%d withdrawable=%d", balance, withdrawable)
	}
}
