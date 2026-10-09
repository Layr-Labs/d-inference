package store_test

import (
	"errors"
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestMachineAutopilotMergeKeepsWinnerPolicyAndRejectsLoserIDs(t *testing.T) {
	for _, tc := range []struct {
		name        string
		winnerModes []store.MachineAutopilotMode
		loserMode   store.MachineAutopilotMode
	}{
		{"live_loser_shadow_winner", nil, store.MachineAutopilotLive},
		{"shadow_loser_live_winner", []store.MachineAutopilotMode{store.MachineAutopilotLive}, store.MachineAutopilotShadow},
		{"live_winner_keeps_revision", []store.MachineAutopilotMode{store.MachineAutopilotLive, store.MachineAutopilotShadow, store.MachineAutopilotLive}, store.MachineAutopilotLive},
		{"shadow_winner_keeps_revision", []store.MachineAutopilotMode{store.MachineAutopilotLive, store.MachineAutopilotShadow}, store.MachineAutopilotLive},
	} {
		t.Run(tc.name, func(t *testing.T) {
			for name, backend := range storeBackends(t) {
				t.Run(name, func(t *testing.T) {
					inventory, settings := machineAutopilotStores(t, backend)
					now := time.Now().UTC()
					winnerObservation := store.MachineObservation{SessionID: "winner", AccountID: "owner", SEKey: "winner-se", VerifiedSerial: "winner-serial", At: now}
					winner := observeAutopilotMachine(t, inventory, winnerObservation)
					loserObservation := store.MachineObservation{SessionID: "loser", AccountID: "owner", SEKey: "loser-se", At: now}
					loser := observeAutopilotMachine(t, inventory, loserObservation)
					if winner.ID == loser.ID {
						t.Fatal("merge fixture did not create independent machines")
					}
					wantWinner := store.MachineAutopilotSetting{MachineID: winner.ID, DesiredMode: store.MachineAutopilotShadow}
					for i, mode := range tc.winnerModes {
						if _, err := settings.SetMachineAutopilotDesiredMode(t.Context(), winner.ID, mode); err != nil {
							t.Fatal(err)
						}
						wantWinner.DesiredMode, wantWinner.Revision = mode, int64(i+1)
					}
					if _, err := settings.SetMachineAutopilotDesiredMode(t.Context(), loser.ID, tc.loserMode); err != nil {
						t.Fatal(err)
					}

					loserObservation.VerifiedSerial, loserObservation.At = winnerObservation.VerifiedSerial, now.Add(time.Second)
					if got := observeAutopilotMachine(t, inventory, loserObservation); got.ID != winner.ID {
						t.Fatalf("merge chose %+v, want %+v", got, winner)
					}
					assertMachineAutopilotSettings(t, settings, wantWinner)
					for _, mode := range []store.MachineAutopilotMode{store.MachineAutopilotLive, store.MachineAutopilotShadow} {
						if _, err := settings.SetMachineAutopilotDesiredMode(t.Context(), loser.ID, mode); !errors.Is(err, store.ErrNotFound) {
							t.Fatalf("setter followed merged-away ID: %v", err)
						}
					}
					loserObservation.SessionID, loserObservation.At = "loser-reconnect", now.Add(2*time.Second)
					loserObservation.VerifiedSerial = ""
					if got := observeAutopilotMachine(t, inventory, loserObservation); got.ID != winner.ID {
						t.Fatalf("moved alias did not reconnect to winner: %+v", got)
					}
					assertMachineAutopilotSettings(t, settings, wantWinner)
					var wantAfter []store.MachineAutopilotSetting
					if winner.ID > loser.ID {
						wantAfter = append(wantAfter, wantWinner)
					}
					rows, err := settings.ListMachineAutopilotSettings(t.Context(), loser.ID, 100)
					if err != nil || !slices.Equal(rows, wantAfter) {
						t.Fatalf("merged cursor was resolved instead of compared: %+v %v", rows, err)
					}

					finalObservation := store.MachineObservation{SessionID: "final", AccountID: "owner", SEKey: "final-se", VerifiedSerial: "final-serial", At: now}
					final := observeAutopilotMachine(t, inventory, finalObservation)
					winnerObservation.VerifiedSerial, winnerObservation.At = finalObservation.VerifiedSerial, now.Add(3*time.Second)
					if got := observeAutopilotMachine(t, inventory, winnerObservation); got.ID != final.ID {
						t.Fatalf("second merge chose %+v, want %+v", got, final)
					}
					for _, retired := range []string{loser.ID, winner.ID} {
						if _, err := settings.SetMachineAutopilotDesiredMode(t.Context(), retired, store.MachineAutopilotLive); !errors.Is(err, store.ErrNotFound) {
							t.Fatalf("setter followed merge chain from %s: %v", retired, err)
						}
					}
					assertMachineAutopilotSettings(t, settings, store.MachineAutopilotSetting{MachineID: final.ID, DesiredMode: store.MachineAutopilotShadow})
				})
			}
		})
	}
}
