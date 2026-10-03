package api

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestSelectedFirstContentWaitKeepsBoundCutoff(t *testing.T) {
	for _, wait := range []string{"no-backup", "accepted", "backup-survivor"} {
		t.Run(wait, func(t *testing.T) {
			d, pr := firstTokenWaitState(t, 0, time.Second)
			provider := d.provider
			pr.FirstContentDeadline = time.Now().Add(-time.Millisecond)
			ctx, cancel := context.WithTimeout(d.r.Context(), 150*time.Millisecond)
			defer cancel()
			d.r = d.r.WithContext(ctx)
			var got dispatchOutcome
			switch wait {
			case "no-backup":
				got = d.waitNoBackup()
			case "accepted":
				got = d.waitAccepted()
			case "backup-survivor":
				d.provider, d.pr, d.requestID = nil, nil, ""
				got = d.racePrimaryFailedWaitBackup(provider, pr, nil)
			}
			if got != outcomeRetry {
				t.Fatalf("bound cutoff expired: got %v, want timeout retry before caller cancellation", got)
			}
			if provider.GetPending(pr.RequestID) != nil {
				t.Fatal("expired selected attempt stayed pending")
			}
		})
	}
}

func TestSelectedFirstContentWriteKeepsBoundCutoff(t *testing.T) {
	received := time.Now().Add(-time.Second)
	bound := received.Add(5 * time.Second)
	pr := &registry.PendingRequest{FirstContentDeadline: bound}
	ctx, cancel := firstTokenWriteContextForPending(context.Background(), received, time.Minute, pr)
	defer cancel()
	if got, ok := ctx.Deadline(); !ok || !got.Equal(bound) {
		t.Fatalf("writer cutoff = %v/%v, want selected %v", got, ok, bound)
	}
	callerCutoff := received.Add(2 * time.Second)
	caller, cancelCaller := context.WithDeadline(context.Background(), callerCutoff)
	defer cancelCaller()
	ctx, cancel = firstTokenWriteContextForPending(caller, received, time.Minute, pr)
	defer cancel()
	if got, ok := ctx.Deadline(); !ok || !got.Equal(callerCutoff) {
		t.Fatalf("caller cutoff = %v/%v, want %v", got, ok, callerCutoff)
	}
	ctx, cancel = firstTokenWriteContextForPending(context.Background(), received, 0, pr)
	defer cancel()
	if _, ok := ctx.Deadline(); ok {
		t.Fatal("an account exemption acquired a first-content writer clock")
	}
}

func TestSelectedFirstContentSpeculationUsesBoundIngress(t *testing.T) {
	for _, tc := range []struct {
		name        string
		receivedAgo time.Duration
		advance     time.Duration
		want        time.Duration
	}{
		{"shorter-candidate-halfway", 4 * time.Second, 15 * time.Second, time.Second},
		{"earlier-quote-advance", 4 * time.Second, 4500 * time.Millisecond, 500 * time.Millisecond},
		{"selected-halfway-already-passed", 6 * time.Second, 15 * time.Second, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			received := time.Now().Add(-tc.receivedAgo)
			pr := &registry.PendingRequest{FirstContentDeadline: received.Add(10 * time.Second), Timing: &registry.RequestTiming{ReceivedAt: received}}
			d := &dispatchState{deadline: 30 * time.Second, speculativeAt: tc.advance, timing: pr.Timing}
			got := d.firstTokenSpeculativeWaitFor(pr)
			if got > tc.want || got < max(0, tc.want-200*time.Millisecond) {
				t.Fatalf("bound speculative wait = %v, want %v from original ingress", got, tc.want)
			}
			if !pr.FirstContentDeadline.Equal(received.Add(10 * time.Second)) {
				t.Fatal("hedge calculation changed the selected cutoff")
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
			d, _, primary, primaryPR, backup, backupPR := speculativeFailureTestState(t, time.Second, 500*time.Millisecond)
			received := time.Now().Add(-10 * time.Millisecond)
			for _, pr := range []*registry.PendingRequest{primaryPR, backupPR} {
				pr.Timing.ReceivedAt = received
				pr.FirstContentDeadline = received.Add(time.Second)
			}
			d.timing = primaryPR.Timing
			d.provider, d.pr, d.requestID = primary, primaryPR, primaryPR.RequestID
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
					expiredPR.ChunkCh <- registry.ProviderChunk{Data: roleOnlyChunkSSE(d.model), ReceivedAt: ingress}
				})
				defer classification.Stop()
			}
			ctx, cancel := context.WithTimeout(d.r.Context(), time.Second)
			defer cancel()
			d.r = d.r.WithContext(ctx)
			result := make(chan dispatchOutcome, 1)
			go func() { result <- d.runRace(backup, backupPR) }()
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
				if got != outcomeCommitted || d.pr != survivorPR {
					t.Fatalf("survivor = %v/%p, want committed/%p", got, d.pr, survivorPR)
				}
				if _, ok := d.excludeProviders[expired.ID]; !ok {
					t.Fatal("timed-out racer was not excluded from later attempts")
				}
			case <-ctx.Done():
				t.Fatal("feasible surviving content did not commit")
			}
		})
	}
}
