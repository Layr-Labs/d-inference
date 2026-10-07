package store_test

import (
	"context"
	"errors"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func machineAutopilotStores(t *testing.T, backend store.Store) (store.MachineInventoryStore, store.MachineAutopilotStore) {
	t.Helper()
	inventory, ok := store.As[store.MachineInventoryStore](backend)
	if !ok {
		t.Fatal("backend lacks machine inventory")
	}
	settings, ok := store.As[store.MachineAutopilotStore](backend)
	if !ok {
		t.Fatal("backend lacks machine Autopilot settings")
	}
	return inventory, settings
}

func observeAutopilotMachine(t *testing.T, inventory store.MachineInventoryStore, observation store.MachineObservation) store.MachineIdentity {
	t.Helper()
	identity, err := inventory.ObserveMachine(t.Context(), observation)
	if err != nil {
		t.Fatal(err)
	}
	return identity
}

func assertMachineAutopilotSettings(t *testing.T, settings store.MachineAutopilotStore, want ...store.MachineAutopilotSetting) {
	t.Helper()
	slices.SortFunc(want, func(a, b store.MachineAutopilotSetting) int { return strings.Compare(a.MachineID, b.MachineID) })
	got, err := settings.ListMachineAutopilotSettings(t.Context(), "", 200)
	if err != nil || got == nil || !slices.Equal(got, want) {
		t.Fatalf("settings=%+v err=%v, want %+v", got, err, want)
	}
	var wantLive []store.MachineAutopilotSetting
	for _, setting := range want {
		if setting.DesiredMode == store.MachineAutopilotLive {
			wantLive = append(wantLive, setting)
		}
	}
	live, err := settings.LiveMachineAutopilotSettings(t.Context())
	if err != nil || live == nil || !slices.Equal(live, wantLive) {
		t.Fatalf("live settings=%+v err=%v, want %+v", live, err, wantLive)
	}
}

func TestMachineAutopilotDefaultsAndModeRevisions(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			inventory, settings := machineAutopilotStores(t, backend)
			assertMachineAutopilotSettings(t, settings)
			if _, err := settings.SetMachineAutopilotDesiredMode(t.Context(), uuid.NewString(), store.MachineAutopilotLive); !errors.Is(err, store.ErrNotFound) {
				t.Fatalf("setter without inventory: %v", err)
			}
			assertMachineAutopilotSettings(t, settings)

			observation := store.MachineObservation{SessionID: "original", AccountID: "owner", At: time.Now().UTC()}
			identity := observeAutopilotMachine(t, inventory, observation)
			parsed, err := uuid.Parse(identity.ID)
			if err != nil || parsed.String() != identity.ID || parsed == uuid.Nil {
				t.Fatalf("inventory ID is not a canonical UUID: %+v %v", identity, err)
			}
			observation.SessionID = "same-owner-other-machine"
			other := observeAutopilotMachine(t, inventory, observation)
			otherSetting := store.MachineAutopilotSetting{MachineID: other.ID, DesiredMode: store.MachineAutopilotShadow}
			assertMachineAutopilotSettings(t, settings,
				store.MachineAutopilotSetting{MachineID: identity.ID, DesiredMode: store.MachineAutopilotShadow}, otherSetting)

			for _, transition := range []struct {
				mode     store.MachineAutopilotMode
				revision int64
			}{
				{store.MachineAutopilotShadow, 0},
				{store.MachineAutopilotLive, 1},
				{store.MachineAutopilotLive, 1},
				{store.MachineAutopilotShadow, 2},
				{store.MachineAutopilotShadow, 2},
				{store.MachineAutopilotLive, 3},
			} {
				want := store.MachineAutopilotSetting{MachineID: identity.ID, DesiredMode: transition.mode, Revision: transition.revision}
				got, err := settings.SetMachineAutopilotDesiredMode(t.Context(), identity.ID, transition.mode)
				if err != nil || got != want {
					t.Fatalf("set %s: %+v %v, want %+v", transition.mode, got, err, want)
				}
				assertMachineAutopilotSettings(t, settings, want, otherSetting)
			}

			rows, err := settings.ListMachineAutopilotSettings(t.Context(), "", 200)
			if err != nil {
				t.Fatal(err)
			}
			rows[0].DesiredMode, rows[0].Revision = "mutated", 999
			live, err := settings.LiveMachineAutopilotSettings(t.Context())
			if err != nil || len(live) != 1 {
				t.Fatalf("live settings=%+v err=%v", live, err)
			}
			live[0].MachineID = "mutated"
			assertMachineAutopilotSettings(t, settings,
				store.MachineAutopilotSetting{MachineID: identity.ID, DesiredMode: store.MachineAutopilotLive, Revision: 3}, otherSetting)
		})
	}
}

func TestMachineAutopilotRejectsInvalidModesExactIDsAndCanceledCalls(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			inventory, settings := machineAutopilotStores(t, backend)
			identity := observeAutopilotMachine(t, inventory, store.MachineObservation{
				SessionID: "session", AccountID: "owner", SEKey: "se-key", VerifiedSerial: "serial", At: time.Now().UTC(),
			})
			want, err := settings.SetMachineAutopilotDesiredMode(t.Context(), identity.ID, store.MachineAutopilotLive)
			if err != nil {
				t.Fatal(err)
			}
			for _, mode := range []store.MachineAutopilotMode{"", "LIVE", "Shadow", "live ", " live", "disabled", "*"} {
				if got, err := settings.SetMachineAutopilotDesiredMode(t.Context(), identity.ID, mode); !errors.Is(err, store.ErrInvalidMachineAutopilotMode) || got != (store.MachineAutopilotSetting{}) {
					t.Fatalf("invalid mode %q: %+v %v", mode, got, err)
				}
			}
			ids := []string{"", uuid.NewString(), uuid.Nil.String(), "session", "owner", "se-key", "serial",
				" " + identity.ID, identity.ID + " ", "{" + identity.ID + "}", "urn:uuid:" + identity.ID,
				strings.ReplaceAll(identity.ID, "-", ""), identity.ID + "' OR TRUE --"}
			if upper := strings.ToUpper(identity.ID); upper != identity.ID {
				ids = append(ids, upper)
			}
			for _, id := range ids {
				if got, err := settings.SetMachineAutopilotDesiredMode(t.Context(), id, store.MachineAutopilotLive); !errors.Is(err, store.ErrNotFound) || got != (store.MachineAutopilotSetting{}) {
					t.Fatalf("nonexact or unknown ID %q: %+v %v", id, got, err)
				}
			}
			canceled, cancel := context.WithCancel(t.Context())
			cancel()
			expired, cancelDeadline := context.WithDeadline(t.Context(), time.Now().Add(-time.Second))
			defer cancelDeadline()
			for _, ctx := range []context.Context{canceled, expired} {
				if rows, err := settings.ListMachineAutopilotSettings(ctx, "", 100); !errors.Is(err, ctx.Err()) || len(rows) != 0 {
					t.Fatalf("canceled list: %+v %v", rows, err)
				}
				if rows, err := settings.LiveMachineAutopilotSettings(ctx); !errors.Is(err, ctx.Err()) || len(rows) != 0 {
					t.Fatalf("canceled live list: %+v %v", rows, err)
				}
				if got, err := settings.SetMachineAutopilotDesiredMode(ctx, identity.ID, store.MachineAutopilotShadow); !errors.Is(err, ctx.Err()) || got != (store.MachineAutopilotSetting{}) {
					t.Fatalf("canceled setter: %+v %v", got, err)
				}
			}
			assertMachineAutopilotSettings(t, settings, want)
		})
	}
}

func TestAsMachineAutopilotThroughCachedStore(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			cached := store.NewCached(store.NewCached(backend, store.CacheConfig{}), store.CacheConfig{})
			if _, ok := any(cached).(store.MachineAutopilotStore); ok {
				t.Fatal("test must exercise optional capability unwrapping")
			}
			inventory, settings := machineAutopilotStores(t, cached)
			if any(settings) != any(backend) {
				t.Fatal("As did not return the underlying backend")
			}
			identity := observeAutopilotMachine(t, inventory, store.MachineObservation{SessionID: "cached-session", At: time.Now().UTC()})
			got, err := settings.SetMachineAutopilotDesiredMode(t.Context(), identity.ID, store.MachineAutopilotLive)
			if err != nil || got.Revision != 1 {
				t.Fatalf("cached setter: %+v %v", got, err)
			}
			_, direct := machineAutopilotStores(t, backend)
			assertMachineAutopilotSettings(t, direct, got)
			got, err = direct.SetMachineAutopilotDesiredMode(t.Context(), identity.ID, store.MachineAutopilotShadow)
			if err != nil || got.Revision != 2 {
				t.Fatalf("direct setter: %+v %v", got, err)
			}
			assertMachineAutopilotSettings(t, settings, got)
		})
	}
}

func TestMachineAutopilotObservationAndReconnectPreserveDesiredMode(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			inventory, settings := machineAutopilotStores(t, backend)
			now := time.Now().UTC()
			observation := store.MachineObservation{SessionID: "original", AccountID: "owner", SEKey: "se-key", At: now}
			identity := observeAutopilotMachine(t, inventory, observation)
			want, err := settings.SetMachineAutopilotDesiredMode(t.Context(), identity.ID, store.MachineAutopilotLive)
			if err != nil {
				t.Fatal(err)
			}
			for _, step := range []string{"heartbeat", "disconnect", "historical_registration", "reconnect", "upgrade"} {
				t.Run(step, func(t *testing.T) {
					observation.At = observation.At.Add(time.Second)
					switch step {
					case "heartbeat":
						observation.Version = "new-version"
					case "disconnect":
						observation.Disconnected = true
					case "historical_registration":
						observation.Source, observation.At = step, now.Add(-time.Hour)
					case "reconnect":
						observation.SessionID, observation.Source = "reconnected", "live_registration"
						observation.Disconnected, observation.At = false, now.Add(time.Minute)
					case "upgrade":
						observation.VerifiedSerial = "verified-serial"
					}
					got := observeAutopilotMachine(t, inventory, observation)
					if got.ID != identity.ID {
						t.Fatalf("observation changed machine: %+v, want %+v", got, identity)
					}
					assertMachineAutopilotSettings(t, settings, want)
				})
			}
		})
	}
}

func TestMachineAutopilotConcurrentSetIsIdempotent(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			inventory, settings := machineAutopilotStores(t, backend)
			identity := observeAutopilotMachine(t, inventory, store.MachineObservation{SessionID: "concurrent", At: time.Now().UTC()})
			for i, mode := range []store.MachineAutopilotMode{store.MachineAutopilotLive, store.MachineAutopilotShadow, store.MachineAutopilotLive} {
				want := store.MachineAutopilotSetting{MachineID: identity.ID, DesiredMode: mode, Revision: int64(i + 1)}
				var wg sync.WaitGroup
				start := make(chan struct{})
				for range 8 {
					wg.Go(func() {
						<-start
						if got, err := settings.SetMachineAutopilotDesiredMode(t.Context(), identity.ID, mode); err != nil || got != want {
							t.Errorf("concurrent set: %+v %v, want %+v", got, err, want)
						}
					})
				}
				close(start)
				wg.Wait()
				assertMachineAutopilotSettings(t, settings, want)
			}
		})
	}
}
