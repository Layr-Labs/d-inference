package api

import (
	"runtime"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestRouteOutcomeConcurrentBackupPublication regresses the CI race between
// runRace publishing a backup winner and handleCompleteAt building its outcome.
// Exercise the real telemetry readers without clocks, servers, or shared Timing
// mutation obscuring the speculative flag accesses.
func TestRouteOutcomeConcurrentBackupPublication(t *testing.T) {
	usage := protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 20, ReasoningTokens: 3}
	readers := []struct {
		name string
		read func(*registry.PendingRequest) *store.InferenceRouteOutcome
	}{
		{
			name: "applyPendingRouteTelemetry",
			read: func(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
				out := &store.InferenceRouteOutcome{}
				applyPendingRouteTelemetry(out, pr)
				return out
			},
		},
		{
			name: "completeRouteOutcome",
			read: func(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
				return completeRouteOutcome(pr, usage, 1234, false)
			},
		},
	}
	for _, reader := range readers {
		t.Run(reader.name, func(t *testing.T) {
			for _, tc := range []struct {
				name        string
				alreadyUsed bool
				backupWins  bool
			}{
				{name: "primary_wins"},
				{name: "backup_wins_from_zero", backupWins: true},
				{name: "backup_wins_after_launch", alreadyUsed: true, backupWins: true},
			} {
				t.Run(tc.name, func(t *testing.T) {
					const rounds, samplesPerRound = 64, 16
					for round := 0; round < rounds; round++ {
						attempts := [2]*registry.PendingRequest{
							{RequestID: "primary"},
							{RequestID: "backup"},
						}
						if tc.alreadyUsed {
							for _, pr := range attempts {
								pr.MarkBackupUsed()
							}
						}
						initial := [2]*store.InferenceRouteOutcome{
							reader.read(attempts[0]), reader.read(attempts[1]),
						}
						start, published := make(chan struct{}), make(chan struct{})
						go func() {
							<-start
							attempts[0].MarkBackupUsed()
							if tc.backupWins {
								attempts[1].MarkBackupWon()
							} else {
								attempts[1].MarkBackupUsed()
							}
							close(published)
						}()

						// Both sides start after this barrier. Only join AFTER the
						// reads: waiting sooner would synchronize away the CI race.
						close(start)
						var samples [samplesPerRound][2]*store.InferenceRouteOutcome
						for i := range samples {
							for attempt, pr := range attempts {
								samples[i][attempt] = reader.read(pr)
							}
							runtime.Gosched()
						}
						<-published

						// Check after joining so assertion failures cannot leak the
						// publisher. Each read owns its outcome; only pr is shared.
						for attempt, out := range initial {
							if out.UsedBackup != tc.alreadyUsed || out.BackupWon {
								t.Fatalf("round %d %s initial flags = (%t, %t), want (%t, false)", round, attempts[attempt].RequestID, out.UsedBackup, out.BackupWon, tc.alreadyUsed)
							}
						}
						previous := initial
						for sample, outcomes := range samples {
							for attempt, out := range outcomes {
								if out.BackupWon && (!out.UsedBackup || attempt == 0 || !tc.backupWins) {
									t.Fatalf("round %d sample %d %s invalid flags: used=%t won=%t", round, sample, attempts[attempt].RequestID, out.UsedBackup, out.BackupWon)
								}
								prior := previous[attempt]
								if (prior.UsedBackup && !out.UsedBackup) || (prior.BackupWon && !out.BackupWon) {
									t.Fatalf("round %d sample %d %s flags regressed: (%t, %t) -> (%t, %t)", round, sample, attempts[attempt].RequestID, prior.UsedBackup, prior.BackupWon, out.UsedBackup, out.BackupWon)
								}
								previous[attempt] = out
							}
						}
						for attempt, pr := range attempts {
							out := reader.read(pr)
							wantWon := attempt == 1 && tc.backupWins
							if !out.UsedBackup || out.BackupWon != wantWon {
								t.Fatalf("round %d %s final flags = (%t, %t), want (true, %t)", round, pr.RequestID, out.UsedBackup, out.BackupWon, wantWon)
							}
						}

						// Verify the win alone published both flags before a late
						// participation update; that update must preserve the win.
						attempts[1].MarkBackupUsed()
						winner, loser := attempts[0], attempts[1]
						if tc.backupWins {
							winner, loser = loser, winner
						}
						completed := completeRouteOutcome(winner, usage, 1234, false)
						if completed.FinalStatus != finalStatusSuccess || !completed.UsedBackup || completed.BackupWon != tc.backupWins {
							t.Fatalf("round %d winner outcome = %+v", round, completed)
						}
						cancelled := speculativeLoserOutcome(loser)
						if cancelled.FinalStatus != finalStatusCancelled || cancelled.ErrorClass != "speculative_loser" || !cancelled.UsedBackup || cancelled.BackupWon {
							t.Fatalf("round %d loser outcome = %+v", round, cancelled)
						}
					}
				})
			}
		})
	}
}
