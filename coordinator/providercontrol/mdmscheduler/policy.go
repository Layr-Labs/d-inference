package mdmscheduler

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	dispatchInterval = time.Second
	// reservedUrgentWorkers holds back worker capacity that only
	// first/expired SecurityInfo attempts may occupy. A provider in that state
	// has no usable trust grant, so routed client requests are already burning
	// the 120s dispatch-queue deadline; long-running refresh MDA attempts (up
	// to 60s each) must never be able to occupy every worker and starve it.
	// Urgent work may still use general capacity; the reservation only caps
	// refresh/recovery work at Workers-1 when Workers > 1.
	reservedUrgentWorkers = 1
	// firstVerifySpreadMax caps the initial spread for first/expired
	// SecurityInfo work. A provider in this state has no valid trust grant, so
	// a client request routed to it is already burning the 120s dispatch-queue
	// deadline (plus up to 90s of verification wait). The tiny jitter only
	// de-synchronises mass expiry; it must stay well inside that deadline.
	firstVerifySpreadMax = 5 * time.Second
	cleanupTimeout       = 5 * time.Second
	retryFirstMin        = 2 * time.Minute
	retryFirstMax        = 4 * time.Minute
	retrySecondMin       = 6 * time.Minute
	retrySecondMax       = 12 * time.Minute
	retrySteadyMin       = 15 * time.Minute
	retrySteadyMax       = 30 * time.Minute
)

// busyRetryDelay is the dispatcher's wake interval while due work
// exists but every worker is busy. A freed worker signals the dispatcher
// directly (finishAttempt → signal), so this timer is only a safety net and
// need not spin at the 1 ms retry cadence used when a worker may be free.
const busyRetryDelay = 250 * time.Millisecond

func jobKey(seKey string, kind store.VerificationTaskKind) string {
	return seKey + "\x00" + string(kind)
}

// isUrgentVerification reports whether a job may occupy the reserved urgent
// worker capacity: only first/expired SecurityInfo work qualifies.
func isUrgentVerification(rec store.VerificationJob) bool {
	return rec.Kind == store.VerificationTaskSecurityInfo &&
		rec.Priority == store.VerificationPriorityFirstOrExpired
}

// reservedUrgentSlots is the worker capacity held back for urgent work. A
// single-worker pool cannot be partitioned without starving refresh entirely,
// so the reservation only applies when more than one worker exists.
func (s *Scheduler) reservedUrgentSlots() int {
	if s.cfg.Workers <= reservedUrgentWorkers {
		return 0
	}
	return reservedUrgentWorkers
}

// initialSpread is the delay before the first attempt once the phase-1
// challenge settles. First/expired work backs a provider with no usable trust
// grant — client requests routed to it queue against the 120s dispatch
// deadline — so it becomes due essentially immediately, with at most a tiny
// jitter (never past firstVerifySpreadMax) to de-synchronise mass expiry.
// Refresh and recovery work still holds a valid grant and keeps the full
// configured spread so routine releases and coordinator restarts never
// stampede MDM.
func (s *Scheduler) initialSpread(priority store.VerificationPriority) time.Duration {
	if priority == store.VerificationPriorityFirstOrExpired {
		return s.deps.Jitter(0, min(s.cfg.InitialSpreadMax, firstVerifySpreadMax))
	}
	return s.deps.Jitter(s.cfg.InitialSpreadMin, s.cfg.InitialSpreadMax)
}

func (s *Scheduler) retryDelay(stage int) time.Duration {
	switch stage {
	case 1:
		return s.deps.Jitter(retryFirstMin, retryFirstMax)
	case 2:
		return s.deps.Jitter(retrySecondMin, retrySecondMax)
	default:
		return s.deps.Jitter(retrySteadyMin, retrySteadyMax)
	}
}
