package verification_test

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestMDMSchedulerEmitsMetricsForLiveLifecycle(t *testing.T) {
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{Workers: 1, QueueCapacity: 1}, mdmSchedulerDeps{
		Jitter: func(minimum, _ time.Duration) time.Duration { return minimum },
		Execute: func(context.Context, mdmLiveBinding, store.VerificationTaskKind, string) mdmSchedulerAttemptResult {
			return mdmSchedulerAttemptResult{Outcome: store.VerificationOutcomeTimeout}
		},
	})
	p := schedulerTestProvider(t, srv, "metrics", "secret-se-key")
	g := sch.Submit(context.Background(), p.ID, p, store.VerificationPriorityRefresh)
	sch.Submit(context.Background(), p.ID, p, store.VerificationPriorityRefresh)
	other := schedulerTestProvider(t, srv, "rejected", "secret-other-key")
	sch.Submit(context.Background(), other.ID, other, store.VerificationPriorityRefresh)
	sch.Unbind("secret-se-key", g+1)
	sch.Submit(context.Background(), p.ID, p, store.VerificationPriorityRefresh)
	sch.ChallengeSettled(p, true)
	sch.Submit(context.Background(), p.ID, p, store.VerificationPriorityFirstOrExpired)
	sch.ChallengeSettled(p, false)
	sch.ObserveMDASent()
	waitSchedulerCondition(t, func() bool {
		rec, err := st.GetVerificationJob(context.Background(), "secret-se-key", store.VerificationTaskSecurityInfo)
		return err == nil && rec != nil && rec.State == store.VerificationStateBackoff
	}, "timeout attempt did not settle")
	rendered := srv.observation.Metrics().Snapshot().RenderProm()
	for _, name := range []string{
		"mdm_scheduler_queue_depth", "mdm_scheduler_active_attempts",
		"mdm_scheduler_enqueued_total", "mdm_scheduler_deduplicated_total",
		"mdm_scheduler_cancelled_total", "mdm_scheduler_queue_rejected_total",
		"mdm_scheduler_queue_wait_seconds", "mdm_scheduler_attempt_seconds",
		"mdm_scheduler_attempts_total", "mdm_scheduler_timeouts_total",
		"mdm_scheduler_grants_total", "mda_verification_total",
	} {
		if !strings.Contains(rendered, name) {
			t.Fatalf("metric %q missing from snapshot", name)
		}
	}
	if strings.Contains(rendered, "secret-se-key") {
		t.Fatal("scheduler metric labels leaked stable device identity")
	}
}
