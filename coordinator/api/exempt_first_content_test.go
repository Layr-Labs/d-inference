package api

import (
	"context"
	"net/http"
	"strconv"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestExemptFirstContentTimersStayDisabledAcrossRetries(t *testing.T) {
	receivedAt := time.Now().Add(-20 * time.Minute)
	for attempt := 0; attempt <= maxFirstChunkTimeoutRetries; attempt++ {
		d := &dispatchState{deadline: 0, attempt: attempt, timing: &registry.RequestTiming{ReceivedAt: receivedAt}}
		if d.firstTokenExpired() {
			t.Fatal("exempt request acquired an absolute timeout")
		}
		for _, fallback := range []time.Duration{0, preambleContentTimeout, inferenceTimeout} {
			timer := d.newFirstContentTimer(d.firstTokenWait(fallback))
			defer timer.Stop()
			if timer.C != nil || timer.timer != nil {
				t.Fatalf("retry %d armed a first-content timer", attempt)
			}
		}
	}
	if ms, ok := firstContentBudgetMillis(receivedAt, 0); !ok || ms != 0 {
		t.Fatal("old exempt request rejected or assigned a provider budget")
	}
}

func TestExemptFirstContentWaitsRemainCancellable(t *testing.T) {
	for _, wait := range []string{"initial", "no-backup", "accepted", "preamble", "race", "backup-failed", "backup-closed", "primary-failed"} {
		t.Run(wait, func(t *testing.T) {
			d, _, primary, primaryPR, backup, backupPR := speculativeFailureTestState(t, 0, time.Hour)
			d.timing = &registry.RequestTiming{ReceivedAt: time.Now().Add(-20 * time.Minute)}
			d.provider, d.pr, d.requestID = primary, primaryPR, primaryPR.RequestID
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			d.r = d.r.WithContext(ctx)
			timer := time.AfterFunc(20*time.Millisecond, cancel)
			defer timer.Stop()
			var got dispatchOutcome
			switch wait {
			case "initial":
				got = d.waitFirstChunk()
			case "no-backup":
				got = d.waitNoBackup()
			case "accepted":
				got = d.waitAccepted()
			case "preamble":
				d.preambleLiveness = true
				got = d.waitAccepted()
			case "race":
				got = d.runRace(backup, backupPR)
			case "backup-failed":
				got = d.raceBackupErrWaitPrimary(primary, primaryPR)
			case "backup-closed":
				got = d.raceBackupChunkClosedWaitPrimary(primary, primaryPR)
			case "primary-failed":
				got = d.racePrimaryFailedWaitBackup(backup, backupPR, nil)
			}
			if got != outcomeClientGone {
				t.Fatalf("wait=%v, want client cancellation", got)
			}
		})
	}
}

func TestExemptEmptySpeculativeCompletionsReleaseBothReaders(t *testing.T) {
	for _, sla := range []bool{false, true} {
		for _, backupWins := range []bool{false, true} {
			t.Run(strconv.FormatBool(sla)+"/backup="+strconv.FormatBool(backupWins), func(t *testing.T) {
				d, _, primary, primaryPR, backup, backupPR := speculativeFailureTestState(t, 0, time.Second)
				ctx, cancel := context.WithTimeout(context.Background(), time.Second)
				defer cancel()
				d.r = d.r.WithContext(ctx)
				d.provider, d.pr, d.requestID = primary, primaryPR, primaryPR.RequestID
				d.timing = &registry.RequestTiming{ReceivedAt: time.Now()}
				winner, loser := primaryPR, backupPR
				if backupWins {
					winner, loser = backupPR, primaryPR
				}
				for _, pr := range []*registry.PendingRequest{primaryPR, backupPR} {
					if sla {
						pr.FirstContentDeadline = time.Now().Add(time.Second)
					}
					pr.EnableSpeculativeEmptyCompletionArbitration()
					defer pr.ResolveSpeculativeEmptyCompletion(false)
				}
				winner.MarkCompletionIngress(time.Now().Add(-time.Millisecond))
				loser.MarkCompletionIngress(time.Now())
				decisions := make(chan *registry.PendingRequest, 2)
				for _, pr := range []*registry.PendingRequest{primaryPR, backupPR} {
					go func(pr *registry.PendingRequest) {
						accepted, _ := pr.AwaitSpeculativeEmptyCompletionDecision()
						if accepted {
							close(pr.ChunkCh)
							decisions <- pr
						} else {
							decisions <- nil
						}
					}(pr)
				}
				if got := d.runRace(backup, backupPR); got != outcomeCommitted || d.pr != winner {
					t.Fatalf("race=%v winner=%p want %p", got, d.pr, winner)
				}
				accepted := 0
				for i := 0; i < 2; i++ {
					select {
					case pr := <-decisions:
						if pr != nil {
							accepted++
						}
					case <-ctx.Done():
						t.Fatal("provider completion reader remained blocked")
					}
				}
				if accepted != 1 {
					t.Fatalf("accepted %d completions", accepted)
				}
			})
		}
	}
}

func TestExemptBackupScanSaturationKeepsPrimaryReadable(t *testing.T) {
	d, pr := firstTokenWaitState(t, time.Second, 0)
	pr.FirstContentDeadline = time.Time{}
	d.s.SetRoutingConcurrency(1)
	d.s.routingScanSem <- struct{}{}
	defer d.s.releaseRoutingScanSlot()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	d.r = d.r.WithContext(ctx)
	// No retained plan: runSpeculative must go through the full-scan funnel.
	pr.ChunkCh <- registry.ProviderChunk{Data: "primary-content", ReceivedAt: time.Now()}
	if got := d.runSpeculative(); got != outcomeCommitted || d.firstChunk != "primary-content" {
		t.Fatalf("saturated backup scan withheld primary: outcome=%v content=%q", got, d.firstChunk)
	}
	if ctx.Err() != nil {
		t.Fatal("primary was held until client cancellation")
	}
	if d.lastErrCode == http.StatusTooManyRequests {
		t.Fatal("optional backup saturation rejected primary")
	}
}
