package store_test

import (
	"context"
	"reflect"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

// The plan lists the Macs to remove from MicroMDM with the ownership rules of
// the scrub. It lists the current device and a device that the account owns
// only through a historical legacy_se alias, because the scrub deletes the
// serial and UDID lookups of both. It leaves out a historical device that a
// live account also owns, because the scrub keeps that device's rows, and a
// device whose serial a provider of a live account reports.
func TestErasurePlanListsMDMDevicesByScrubOwnership(t *testing.T) {
	for backend, s := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			ctx := context.Background()
			a, b := erasurefixture.SeedAccount(t, s), erasurefixture.SeedAccount(t, s)
			inv, ok := store.As[store.MachineInventoryStore](s)
			if !ok {
				t.Fatal("inventory unavailable")
			}
			provider, err := s.GetProviderRecord(ctx, a.ProviderID)
			if err != nil {
				t.Fatal(err)
			}
			otherProvider, err := s.GetProviderRecord(ctx, b.ProviderID)
			if err != nil {
				t.Fatal(err)
			}
			now := time.Now().UTC()
			historical, shared, used := erasurefixture.UniqueID("historical-se"), erasurefixture.UniqueID("shared-se"), erasurefixture.UniqueID("used-se")
			observe := func(owner erasurefixture.Account, key string) {
				t.Helper()
				if _, err := inv.ObserveMachine(ctx, store.MachineObservation{SessionID: erasurefixture.UniqueID("historical-session"), AccountID: owner.AccountID, SEKey: key, At: now, Disconnected: true, Source: "live_registration"}); err != nil {
					t.Fatal(err)
				}
			}
			observe(a, historical)
			observe(a, shared)
			observe(b, shared)
			observe(a, used)
			devices := map[string]store.ErasureMDMDevice{
				a.SEKey:    {Serial: provider.SerialNumber, UDID: erasurefixture.UniqueID("UDID-CURRENT")},
				historical: {Serial: erasurefixture.UniqueID("SERIAL-HISTORICAL"), UDID: erasurefixture.UniqueID("UDID-HISTORICAL")},
				shared:     {Serial: erasurefixture.UniqueID("SERIAL-SHARED"), UDID: erasurefixture.UniqueID("UDID-SHARED")},
				used:       {Serial: otherProvider.SerialNumber, UDID: erasurefixture.UniqueID("UDID-USED")},
			}
			for key, d := range devices {
				if _, err := s.UpsertProviderTrustReuse(ctx, store.ProviderTrustReuse{SEPubKey: key, Serial: d.Serial, MDAUDID: d.UDID, TrustLevel: "hardware", HardwareProofVerifiedAt: now}, 0); err != nil {
					t.Fatal(err)
				}
			}

			plan, err := s.PlanAccountErasure(ctx, a.AccountID, nil)
			if err != nil {
				t.Fatal(err)
			}
			want := []store.ErasureMDMDevice{devices[a.SEKey], devices[historical]}
			if want[1].Serial < want[0].Serial {
				want[0], want[1] = want[1], want[0]
			}
			if !reflect.DeepEqual(plan.MDMDevices, want) {
				t.Fatalf("mdm_devices = %+v; want %+v", plan.MDMDevices, want)
			}

			// The listed devices are exactly the ones whose lookups the scrub deletes.
			req := erasurefixture.PlanAndConfirm(t, s, a, now, 0)
			if _, err := s.ScrubAccount(ctx, req.ID, now); err != nil {
				t.Fatal(err)
			}
			kept, err := s.ListProviderTrustReuse(ctx)
			if err != nil {
				t.Fatal(err)
			}
			left := map[string]bool{}
			for _, r := range kept {
				left[r.SEPubKey] = true
			}
			if left[a.SEKey] || left[historical] || !left[shared] {
				t.Fatalf("trust rows after the scrub = %v; want only the shared key's row", left)
			}
		})
	}
}
