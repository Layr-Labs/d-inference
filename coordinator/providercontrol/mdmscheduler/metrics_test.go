package mdmscheduler

import (
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestMDMSchedulerMetricsUseFixedLowCardinalityEnums(t *testing.T) {
	srv, _, sch := newSchedulerHarness(t, Config{}, Dependencies{})
	sch.metricCounter("mdm_scheduler_enqueued_total", "reason", "registration")
	sch.metricCounter("mdm_scheduler_deduplicated_total", "state", string(store.VerificationStateBackoff))
	sch.metricCounter("mdm_scheduler_cancelled_total", "reason", "disconnect")
	sch.metricCounter("mdm_scheduler_queue_rejected_total", "priority", "refresh")
	sch.metricCounter("mdm_scheduler_grants_total", "path", "reuse")
	sch.metricCounter("mda_verification_total", "outcome", "binding_mismatch")
	work := workItem{job: store.VerificationJob{
		SEPubKey: "secret-se-key", Kind: store.VerificationTaskSecurityInfo,
		Priority: store.VerificationPriorityRecovery, UpdatedAt: time.Now(),
	}}
	sch.observeAttempt(work, AttemptResult{
		Outcome: store.VerificationOutcomeTimeout,
	}, time.Second)
	rendered := srv.metrics.Snapshot().RenderProm()
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
