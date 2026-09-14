package mdmscheduler

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestMDMSchedulerMDAReuseCannotForgetReplacementBinding(t *testing.T) {
	for _, tc := range []struct {
		name   string
		late   bool
		reused bool
	}{
		{name: "worker_reused", reused: true},
		{name: "late_reused", late: true, reused: true},
		{name: "worker_missing_udid"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reusing := make(chan struct{})
			release := make(chan struct{})
			var releaseOnce sync.Once
			unblock := func() { releaseOnce.Do(func() { close(release) }) }
			t.Cleanup(unblock)
			srv, st, sch := newSchedulerHarness(t, Config{Workers: 1, QueueCapacity: 8}, Dependencies{
				Jitter: func(time.Duration, time.Duration) time.Duration { return 0 },
				ReuseMDA: func(Target) bool {
					close(reusing)
					<-release
					return tc.reused
				},
			})
			withoutLiveDispatcher(sch)
			old := schedulerProvider(t, srv, "completed-old", "se-completion")
			sch.Submit(context.Background(), old.ID, old, store.VerificationPriorityFirstOrExpired)
			sch.ChallengeSettled(old, false)
			key := jobKey("se-completion", store.VerificationTaskSecurityInfo)
			sch.claimAndDispatch(key, time.Now().UTC())
			var work workItem
			select {
			case work = <-sch.work:
			case <-time.After(time.Second):
				t.Fatal("initial SecurityInfo job was not claimed")
			}
			t.Cleanup(func() { work.stopAfter(); work.cancel() })
			if tc.late {
				sch.ObserveAttemptUDID(old, "udid-completion")
				sch.ObserveAttemptCommand(old, store.VerificationTaskSecurityInfo, "udid-completion", "command-completion")
			}
			done := make(chan struct{})
			go func() {
				defer close(done)
				if tc.late {
					sch.CompleteLateSecurityInfo(work.binding, "udid-completion", "command-completion")
				} else {
					sch.finishAttempt(work, AttemptResult{Outcome: store.VerificationOutcomeSuccess, Granted: true})
				}
			}()
			waitDone := func() {
				t.Helper()
				select {
				case <-done:
				case <-time.After(time.Second):
					t.Fatal("SecurityInfo completion did not finish after releasing MDA reuse")
				}
			}
			t.Cleanup(func() { unblock(); waitDone() })
			select {
			case <-reusing:
			case <-time.After(time.Second):
				t.Fatal("completed SecurityInfo never entered MDA reuse")
			}
			replacement := schedulerProvider(t, srv, "completed-replacement", "se-completion")
			generation := sch.Submit(context.Background(), replacement.ID, replacement, store.VerificationPriorityFirstOrExpired)
			sch.ChallengeSettled(replacement, false)
			unblock()
			waitDone()

			sch.mu.Lock()
			binding := sch.bindings["se-completion"]
			current := binding != nil && binding.provider == replacement && binding.generation == generation && binding.challengeSettled
			sch.mu.Unlock()
			if !current {
				t.Fatal("old MDA reuse completion forgot the replacement's live binding")
			}
			rec, err := st.GetVerificationJob(context.Background(), "se-completion", store.VerificationTaskSecurityInfo)
			if err != nil || rec == nil || rec.State != store.VerificationStatePending {
				t.Fatalf("replacement durable verification changed: %+v, %v", rec, err)
			}
		})
	}
}
