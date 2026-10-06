package verification_test

import (
	"github.com/eigeninference/d-inference/coordinator/internal/provider/verification"
	"github.com/eigeninference/d-inference/coordinator/store"
	"strings"
	"testing"
	"time"
)

func TestMDMSchedulerMetricsUseFixedLowCardinalityEnums(t *testing.T) {
	srv, _, _ := newSchedulerTestServer(t, MDMSchedulerConfig{}, mdmSchedulerDeps{})
	observer := verification.NewObserver(srv.observation, time.Now)
	observer.Counter("mdm_scheduler_enqueued_total", "reason", "registration")
	observer.Counter("mdm_scheduler_deduplicated_total", "state", string(store.VerificationStateBackoff))
	observer.Counter("mdm_scheduler_cancelled_total", "reason", "disconnect")
	observer.Counter("mdm_scheduler_queue_rejected_total", "priority", "refresh")
	observer.Counter("mdm_scheduler_grants_total", "path", "reuse")
	observer.Counter("mda_verification_total", "outcome", "binding_mismatch")
	job := store.VerificationJob{
		SEPubKey: "secret-se-key", Kind: store.VerificationTaskSecurityInfo,
		Priority: store.VerificationPriorityRecovery, UpdatedAt: time.Now(),
	}
	observer.Attempt(job, time.Time{}, mdmSchedulerAttemptResult{
		Outcome: store.VerificationOutcomeTimeout,
	}, time.Second)
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
