package inference_test

import (
	"context"
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestSelectedFirstContentWaitKeepsBoundCutoff(t *testing.T) {
	for _, wait := range []string{"no-backup", "accepted", "backup-survivor"} {
		t.Run(wait, func(t *testing.T) {
			fixture, pr := newContentWaitFixture(t, 0, time.Second)
			provider := fixture.provider
			pr.FirstContentDeadline = time.Now().Add(-time.Millisecond)
			ctx, cancel := context.WithTimeout(fixture.r.Context(), 150*time.Millisecond)
			defer cancel()
			fixture.r = fixture.r.WithContext(ctx)
			var got attempt.Outcome
			switch wait {
			case "no-backup":
				got = fixture.single()
			case "accepted":
				got = fixture.accepted()
			case "backup-survivor":
				race := fixture.s.NewRace(attempt.RaceConfig{Model: pr.Model, Deadline: fixture.deadline,
					SpeculativeAt: fixture.speculativeAt, Clock: firstcontent.NewClock(pr.Timing.ReceivedAt, fixture.deadline, fixture.speculativeAt)},
					retry.New(retry.Config{Model: pr.Model, Observation: fixture.s.observation}),
					&retry.TerminalEvidence{}, fixture.s.NewBackendLatch(), func() {}, nil)
				got = race.WaitBackup(ctx, attempt.RaceAttempt{}, attempt.RaceAttempt{Provider: provider, Pending: pr, RequestID: pr.RequestID}).Outcome
			}
			if got != attempt.Retry {
				t.Fatalf("bound cutoff expired: got %v, want timeout retry before caller cancellation", got)
			}
			if provider.GetPending(pr.RequestID) != nil {
				t.Fatal("expired selected attempt stayed pending")
			}
		})
	}
}

func TestSpeculativeRaceExpiresOnlyBoundCandidate(t *testing.T) {
	for _, tc := range []struct {
		name            string
		primaryExpires  bool
		lateBoilerplate bool
	}{
		{"primary-expires", true, false},
		{"backup-expires", false, false},
		{"primary-boilerplate-classified-after-cutoff", true, true},
		{"backup-boilerplate-classified-after-cutoff", false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d, _, primary, primaryPR, backup, backupPR := newSpeculativeFailureFixture(t, time.Second, 500*time.Millisecond)
			received := time.Now().Add(-10 * time.Millisecond)
			for _, pr := range []*registry.PendingRequest{primaryPR, backupPR} {
				pr.Timing.ReceivedAt = received
				pr.FirstContentDeadline = received.Add(time.Second)
			}
			d.config.Clock = firstcontent.NewClock(received, d.config.Deadline, d.config.SpeculativeAt)
			expired, expiredPR, survivor, survivorPR := backup, backupPR, primary, primaryPR
			if tc.primaryExpires {
				expired, expiredPR, survivor, survivorPR = primary, primaryPR, backup, backupPR
			}
			expiredPR.FirstContentDeadline = received.Add(time.Millisecond)
			if tc.lateBoilerplate {
				expiredPR.FirstContentDeadline = time.Now().Add(25 * time.Millisecond)
				gotPR, ingress := expired.BeginPendingChunkIngress(expiredPR.RequestID)
				if gotPR != expiredPR || ingress.IsZero() {
					t.Fatal("failed to publish on-time ingress before classification")
				}
				classification := time.AfterFunc(60*time.Millisecond, func() {
					if expired.GetPending(expiredPR.RequestID) != expiredPR {
						t.Error("timeout stole the on-time event before classification")
					}
					expiredPR.FinishProviderChunkIngress(ingress, false)
					expiredPR.ChunkCh <- registry.ProviderChunk{Data: roleOnlyChunkSSE(d.config.Model), ReceivedAt: ingress}
				})
				defer classification.Stop()
			}
			ctx, cancel := context.WithTimeout(d.r.Context(), time.Second)
			defer cancel()
			d.r = d.r.WithContext(ctx)
			race := d.s.NewRace(d.config, d.policy, d.evidence, d.latch, func() {}, nil)
			result := make(chan attempt.RaceResult, 1)
			go func() {
				result <- race.Run(ctx,
					attempt.RaceAttempt{Provider: primary, Pending: primaryPR, RequestID: primaryPR.RequestID},
					attempt.RaceAttempt{Provider: backup, Pending: backupPR, RequestID: backupPR.RequestID})
			}()
			joined := false
			defer func() {
				cancel()
				if joined {
					return
				}
				select {
				case <-result:
				case <-time.After(time.Second):
					t.Error("speculative wait remained running after cancellation")
				}
			}()

			cutoff := time.NewTimer(150 * time.Millisecond)
			defer cutoff.Stop()
			tick := time.NewTicker(time.Millisecond)
			defer tick.Stop()
			for expired.GetPending(expiredPR.RequestID) != nil {
				select {
				case <-tick.C:
				case <-cutoff.C:
					t.Fatal("earlier candidate cutoff did not retire that attempt")
				}
			}
			if survivor.GetPending(survivorPR.RequestID) != survivorPR {
				t.Fatal("earlier cutoff cancelled the feasible longer-lived racer")
			}
			gotPR, arrived := survivor.BeginPendingChunkIngress(survivorPR.RequestID)
			if gotPR != survivorPR || arrived.IsZero() {
				t.Fatal("surviving racer could not publish content ingress")
			}
			survivorPR.FinishProviderChunkIngress(arrived, true)
			survivorPR.ChunkCh <- registry.ProviderChunk{Data: "data: {\"choices\":[{\"delta\":{\"content\":\"survivor\"}}]}\n\n", ReceivedAt: arrived}
			select {
			case got := <-result:
				joined = true
				if got.Outcome != attempt.Committed || got.Attempt.Pending != survivorPR {
					t.Fatalf("survivor = %v/%p, want committed/%p", got.Outcome, got.Attempt.Pending, survivorPR)
				}
				if !slices.Contains(got.ExcludedProviderIDs, expired.ID) {
					t.Fatal("timed-out racer was not excluded from later attempts")
				}
			case <-ctx.Done():
				t.Fatal("feasible surviving content did not commit")
			}
		})
	}
}
