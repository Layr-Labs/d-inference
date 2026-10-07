package store_test

import (
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestMachineAutopilotKeysetPaginationAndUnboundedLiveList(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			inventory, settings := machineAutopilotStores(t, backend)
			now := time.Now().UTC()
			var want, wantLive []store.MachineAutopilotSetting
			for i := range 207 {
				identity := observeAutopilotMachine(t, inventory, store.MachineObservation{SessionID: fmt.Sprintf("page-%d", i), At: now})
				setting := store.MachineAutopilotSetting{MachineID: identity.ID, DesiredMode: store.MachineAutopilotShadow}
				if i != 206 {
					var err error
					setting, err = settings.SetMachineAutopilotDesiredMode(t.Context(), identity.ID, store.MachineAutopilotLive)
					if err != nil {
						t.Fatal(err)
					}
					wantLive = append(wantLive, setting)
				}
				want = append(want, setting)
			}
			compare := func(a, b store.MachineAutopilotSetting) int { return strings.Compare(a.MachineID, b.MachineID) }
			slices.SortFunc(want, compare)
			slices.SortFunc(wantLive, compare)
			for _, tc := range []struct{ limit, count int }{{-1, 100}, {0, 100}, {1, 1}, {99, 99}, {100, 100}, {200, 200}, {201, 200}, {10000, 200}} {
				rows, err := settings.ListMachineAutopilotSettings(t.Context(), "", tc.limit)
				if err != nil || !slices.Equal(rows, want[:tc.count]) {
					t.Fatalf("limit %d: got %d rows err=%v, want first %d in ID order", tc.limit, len(rows), err, tc.count)
				}
			}
			var paged []store.MachineAutopilotSetting
			after := ""
			for range 10 {
				rows, err := settings.ListMachineAutopilotSettings(t.Context(), after, 37)
				if err != nil {
					t.Fatal(err)
				}
				if len(rows) == 0 {
					break
				}
				paged = append(paged, rows...)
				after = rows[len(rows)-1].MachineID
			}
			if !slices.Equal(paged, want) {
				t.Fatalf("keyset traversal skipped, repeated, or reordered rows: got %d, want %d", len(paged), len(want))
			}
			rows, err := settings.ListMachineAutopilotSettings(t.Context(), want[99].MachineID, 200)
			if err != nil || !slices.Equal(rows, want[100:]) {
				t.Fatalf("cursor must be exclusive: %d rows %v", len(rows), err)
			}
			rows, err = settings.ListMachineAutopilotSettings(t.Context(), "ffffffff-ffff-ffff-ffff-ffffffffffff", 100)
			if err != nil || rows == nil || len(rows) != 0 {
				t.Fatalf("cursor beyond inventory: %+v %v", rows, err)
			}
			live, err := settings.LiveMachineAutopilotSettings(t.Context())
			if err != nil || !slices.Equal(live, wantLive) {
				t.Fatalf("live list must include all 206 live machines in ID order: got %d err=%v", len(live), err)
			}
		})
	}
}
