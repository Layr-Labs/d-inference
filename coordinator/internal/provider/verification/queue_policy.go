package verification

import (
	"github.com/eigeninference/d-inference/coordinator/store"
	"iter"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

// Queue is the registration-bound scheduling policy state. The dispatch driver,
// workers and callback handlers share this single private ownership lock.
// Never hold it during durable store I/O. Configuration is immutable.
type Queue struct {
	mu                sync.Mutex
	config            Config
	jobs              map[string]*scheduledJob
	bindings          map[string]*Binding
	generation        atomic.Uint64
	erasureGeneration uint64
	byUDID            map[string]string
	active            map[store.VerificationTaskKind]int
	activeUrgent      int
	dueScanOffset     int
}

func NewQueue(cfg Config) *Queue {
	return &Queue{
		config: NormalizeConfig(cfg),
		jobs:   make(map[string]*scheduledJob), bindings: make(map[string]*Binding),
		byUDID: make(map[string]string), active: make(map[store.VerificationTaskKind]int),
	}
}

func (s *Queue) NextDispatchDelay(now time.Time) time.Duration {
	s.mu.Lock()
	defer s.mu.Unlock()
	active := 0
	for _, count := range s.active {
		active += count
	}
	return DispatchDelay(now, s.config.Workers, active, s.activeUrgent, func(yield func(store.VerificationJob) bool) {
		for _, job := range s.jobs {
			if !job.Running && !yield(job.Record) {
				return
			}
		}
	})
}

// DispatchDelay computes a timer from detached capacity and pending work. The
// driver uses this same policy for both automatic and explicit scheduling turns.
func DispatchDelay(now time.Time, workers, active, activeUrgent int, queued iter.Seq[store.VerificationJob]) time.Duration {
	delay := mdmSchedulerDispatchInterval
	// Same worker arithmetic as DispatchDueRows: the reserved urgent slot is
	// not available to refresh/recovery work, so a due non-urgent job with
	// only that slot free cannot dispatch and must not spin at 1 ms.
	available := workers - active
	reservedFree := 0
	if workers > mdmSchedulerReservedUrgentWorkers {
		reservedFree = mdmSchedulerReservedUrgentWorkers
	}
	reservedFree -= activeUrgent
	if reservedFree < 0 {
		reservedFree = 0
	}
	generalAvailable := available - reservedFree
	dueBlocked := false
	for job := range queued {
		if job.State != store.VerificationStatePending && job.State != store.VerificationStateBackoff {
			continue
		}
		candidate := job.NextAttemptAt.Sub(now)
		if candidate <= 0 {
			if available > 0 && (IsUrgent(job) || generalAvailable > 0) {
				return time.Millisecond
			}
			dueBlocked = true
			continue
		}
		if candidate < delay {
			delay = candidate
		}
	}
	// The busy floor is a ceiling on the wake interval, not a replacement for
	// it: a job that becomes due sooner (an urgent one may take the reserved
	// slot) still gets its own timer instead of waiting out the floor.
	if dueBlocked && delay > mdmSchedulerBusyRetryDelay {
		return mdmSchedulerBusyRetryDelay
	}
	return delay
}

// Due selects a bounded batch in priority/due-time order, reserving capacity
// for first/expired SecurityInfo. Claims are performed by the driver after this
// detached selection so durable I/O never runs under the ownership lock.
func (s *Queue) Due(now time.Time) []string {
	type candidate struct {
		key string
		rec store.VerificationJob
	}
	s.mu.Lock()
	available := s.config.Workers
	for _, count := range s.active {
		available -= count
	}
	// Of the free slots, hold back any unused reserved urgent capacity so
	// refresh/recovery work can never occupy the last worker while urgent
	// first/expired SecurityInfo work may still arrive.
	reservedFree := s.reservedUrgentSlots() - s.activeUrgent
	if reservedFree < 0 {
		reservedFree = 0
	}
	generalAvailable := available - reservedFree
	candidates := make([]candidate, 0, available)
	if available > 0 {
		for key, job := range s.jobs {
			binding := s.bindings[job.Record.SEPubKey]
			if job.Running || binding == nil || binding.Generation != job.BindingGen {
				continue
			}
			if job.Record.Kind == store.VerificationTaskSecurityInfo && !binding.ChallengeSettled {
				continue
			}
			if job.Record.Kind == store.VerificationTaskMDA &&
				(!binding.ChallengeSettled || !binding.AllowMDA) {
				continue
			}
			claimExpired := job.Record.State == store.VerificationStateRunning &&
				job.Record.ClaimExpiresAt != nil &&
				!job.Record.ClaimExpiresAt.After(now)
			durableDue := job.Record.State == store.VerificationStatePending ||
				job.Record.State == store.VerificationStateBackoff ||
				claimExpired
			if durableDue && !job.Record.NextAttemptAt.After(now) {
				candidates = append(candidates, candidate{key: key, rec: job.Record})
			}
		}
	}
	s.mu.Unlock()
	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].rec.Priority != candidates[j].rec.Priority {
			return candidates[i].rec.Priority < candidates[j].rec.Priority
		}
		return candidates[i].rec.NextAttemptAt.Before(candidates[j].rec.NextAttemptAt)
	})
	selected := candidates[:0]
	for _, c := range candidates {
		if available <= 0 {
			break
		}
		if !IsUrgent(c.rec) {
			if generalAvailable <= 0 {
				continue
			}
			generalAvailable--
		}
		available--
		selected = append(selected, c)
	}
	keys := make([]string, len(selected))
	for i, candidate := range selected {
		keys[i] = candidate.key
	}
	return keys
}

// makeQueueRoomLocked never evicts first/expired or recovery work. An evicted
// refresh remains durable and is reloaded only when bounded memory has room.
func (s *Queue) makeQueueRoomLocked(priority store.VerificationPriority) bool {
	if len(s.jobs) < s.config.QueueCapacity {
		return true
	}
	if priority == store.VerificationPriorityRefresh {
		return false
	}
	for key, job := range s.jobs {
		if !job.Running && job.Record.Priority == store.VerificationPriorityRefresh {
			delete(s.jobs, key)
			if job.Record.UDID != "" && s.byUDID[job.Record.UDID] == key {
				delete(s.byUDID, job.Record.UDID)
			}
			return true
		}
	}
	return false
}

func Key(seKey string, kind store.VerificationTaskKind) string {
	return seKey + "\x00" + string(kind)
}

// IsUrgent reports whether a job may occupy the reserved urgent
// worker capacity: only first/expired SecurityInfo work qualifies.
func IsUrgent(rec store.VerificationJob) bool {
	return rec.Kind == store.VerificationTaskSecurityInfo &&
		rec.Priority == store.VerificationPriorityFirstOrExpired
}

// reservedUrgentSlots is the worker capacity held back for urgent work. A
// single-worker pool cannot be partitioned without starving refresh entirely,
// so the reservation only applies when more than one worker exists.
func (s *Queue) reservedUrgentSlots() int {
	if s.config.Workers <= mdmSchedulerReservedUrgentWorkers {
		return 0
	}
	return mdmSchedulerReservedUrgentWorkers
}
