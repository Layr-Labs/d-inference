package inference_test

import (
	"context"
	"net/http"
	"strconv"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	firstcontent "github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestExemptFirstContentWaitsRemainCancellable(t *testing.T) {
	for _, wait := range []string{"initial", "no-backup", "accepted", "preamble", "race", "backup-failed", "backup-closed", "primary-failed"} {
		t.Run(wait, func(t *testing.T) {
			fixture, _, primary, primaryPR, backup, backupPR := newSpeculativeFailureFixture(t, 0, time.Hour)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			d := &contentWaitFixture{
				s: fixture.s, r: fixture.r.WithContext(ctx),
				provider: primary, pr: primaryPR, speculativeAt: time.Hour,
				timing: &registry.RequestTiming{ReceivedAt: time.Now().Add(-20 * time.Minute)},
			}
			fixture.config.Clock = d.clock()
			race := fixture.s.NewRace(fixture.config, fixture.policy, fixture.evidence, fixture.latch, func() {}, nil)
			primaryAttempt := attempt.RaceAttempt{Provider: primary, Pending: primaryPR, RequestID: primaryPR.RequestID}
			backupAttempt := attempt.RaceAttempt{Provider: backup, Pending: backupPR, RequestID: backupPR.RequestID}
			timer := time.AfterFunc(20*time.Millisecond, cancel)
			defer timer.Stop()
			var got attempt.Outcome
			switch wait {
			case "initial":
				got = d.first()
			case "no-backup":
				got = d.single()
			case "accepted":
				got = d.accepted()
			case "preamble":
				d.preambleLiveness = true
				got = d.accepted()
			case "race":
				got = race.Run(ctx, primaryAttempt, backupAttempt).Outcome
			case "backup-failed":
				got = race.WaitPrimary(ctx, primaryAttempt, primary, primaryPR, false).Outcome
			case "backup-closed":
				got = race.WaitPrimary(ctx, primaryAttempt, primary, primaryPR, true).Outcome
			case "primary-failed":
				got = race.WaitBackup(ctx, primaryAttempt, backupAttempt).Outcome
			}
			if got != attempt.ClientGone {
				t.Fatalf("wait=%v, want client cancellation", got)
			}
		})
	}
}

func TestExemptFirstContentTimersStayDisabledAcrossRetries(t *testing.T) {
	receivedAt := time.Now().Add(-20 * time.Minute)
	for attempt := 0; attempt <= retry.TimeoutRetryLimit; attempt++ {
		clock := firstcontent.NewClock(receivedAt, 0, 0)
		if clock.Expired() {
			t.Fatal("exempt request acquired an absolute timeout")
		}
		for _, fallback := range []time.Duration{0, firstcontent.PreambleContentTimeout, 600 * time.Second} {
			timer := clock.Timer(clock.Wait(fallback))
			defer timer.Stop()
			if timer.C != nil || timer.Stop() {
				t.Fatalf("retry %d armed a first-content timer", attempt)
			}
		}
	}
	if ms, ok := firstcontent.FirstContentBudgetMillis(receivedAt, 0); !ok || ms != 0 {
		t.Fatal("old exempt request rejected or assigned a provider budget")
	}
}

func TestExemptEmptySpeculativeCompletionsReleaseBothReaders(t *testing.T) {
	for _, sla := range []bool{false, true} {
		for _, backupWins := range []bool{false, true} {
			t.Run(strconv.FormatBool(sla)+"/backup="+strconv.FormatBool(backupWins), func(t *testing.T) {
				fixture, _, primary, primaryPR, backup, backupPR := newSpeculativeFailureFixture(t, 0, time.Second)
				ctx, cancel := context.WithTimeout(context.Background(), time.Second)
				defer cancel()
				d := &contentWaitFixture{
					s: fixture.s, r: fixture.r.WithContext(ctx),
					provider: primary, pr: primaryPR, speculativeAt: time.Second,
					timing: &registry.RequestTiming{ReceivedAt: time.Now()},
				}
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
				if got := d.race(backup, backupPR); got != attempt.Committed || d.pr != winner {
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
	d, pr := newContentWaitFixture(t, time.Second, 0)
	pr.FirstContentDeadline = time.Time{}
	d.s.SetRoutingConcurrency(1)
	d.s.scanGate.Acquire(0, nil)
	defer d.s.scanGate.Release()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	d.r = d.r.WithContext(ctx)
	// No retained plan: runSpeculative must go through the full-scan funnel.
	pr.ChunkCh <- registry.ProviderChunk{Data: "primary-content", ReceivedAt: time.Now()}
	if got := d.speculate(); got != attempt.Committed || d.content.FirstChunk != "primary-content" {
		t.Fatalf("saturated backup scan withheld primary: outcome=%v content=%q", got, d.content.FirstChunk)
	}
	if ctx.Err() != nil {
		t.Fatal("primary was held until client cancellation")
	}
	if d.failure.Message.StatusCode == http.StatusTooManyRequests {
		t.Fatal("optional backup saturation rejected primary")
	}
}
