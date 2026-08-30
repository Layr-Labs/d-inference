package api

import (
	"bytes"
	"context"
	"crypto/sha256"
	"math/rand/v2"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

const (
	mdmSchedulerDispatchInterval = time.Second
	mdmSchedulerCleanupTimeout   = 5 * time.Second
	mdmRetryFirstMin             = 2 * time.Minute
	mdmRetryFirstMax             = 4 * time.Minute
	mdmRetrySecondMin            = 6 * time.Minute
	mdmRetrySecondMax            = 12 * time.Minute
	mdmRetrySteadyMin            = 15 * time.Minute
	mdmRetrySteadyMax            = 30 * time.Minute
)

type mdmSchedulerTimer interface {
	C() <-chan time.Time
	Stop() bool
}

type realMDMSchedulerTimer struct{ *time.Timer }

func (t realMDMSchedulerTimer) C() <-chan time.Time { return t.Timer.C }

type mdmSchedulerAttemptResult struct {
	outcome  store.VerificationOutcome
	granted  bool
	terminal bool
	udid     string
}

type mdmSchedulerDeps struct {
	now      func() time.Time
	newTimer func(time.Duration) mdmSchedulerTimer
	jitter   func(time.Duration, time.Duration) time.Duration
	execute  func(context.Context, mdmLiveBinding, store.VerificationTaskKind, string) mdmSchedulerAttemptResult
	reuseMDA func(mdmLiveBinding) bool
}

type verificationDuePageStore interface {
	ListDueVerificationJobsPage(
		ctx context.Context,
		now time.Time,
		limit, offset int,
	) ([]store.VerificationJob, error)
}

type mdmLiveBinding struct {
	providerID       string
	provider         *registry.Provider
	attestation      attestation.VerificationResult
	generation       uint64
	ctx              context.Context
	challengeSettled bool
	allowMDA         bool
}

type mdmScheduledJob struct {
	record        store.VerificationJob
	bindingGen    uint64
	callbackGen   uint64
	callbackUUID  string
	enqueuedAt    time.Time
	running       bool
	attemptCancel context.CancelFunc
}

type mdmSchedulerWork struct {
	key        string
	job        store.VerificationJob
	binding    mdmLiveBinding
	ctx        context.Context
	cancel     context.CancelFunc
	stopAfter  func() bool
	enqueuedAt time.Time
}

// mdmVerificationScheduler owns the only MDM/MDA dispatcher and worker pool.
// Durable rows are timing/claim metadata only; every attempt still requires a
// current registration-bound live binding.
type mdmVerificationScheduler struct {
	server *Server
	store  store.ProviderStore
	cfg    MDMSchedulerConfig
	deps   mdmSchedulerDeps
	owner  string

	ctx    context.Context
	cancel context.CancelFunc
	start  sync.Once
	close  sync.Once
	wg     sync.WaitGroup
	wake   chan struct{}
	work   chan mdmSchedulerWork

	mu            sync.Mutex
	jobs          map[string]*mdmScheduledJob
	bindings      map[string]*mdmLiveBinding
	generation    atomic.Uint64
	byUDID        map[string]string
	active        map[store.VerificationTaskKind]int
	dueScanOffset int
}

func normalizeMDMSchedulerConfig(cfg MDMSchedulerConfig) MDMSchedulerConfig {
	if cfg.Workers <= 0 {
		cfg.Workers = defaultMDMVerificationWorkers
	} else if cfg.Workers > defaultMDMVerificationWorkers {
		cfg.Workers = defaultMDMVerificationWorkers
	}
	if cfg.QueueCapacity <= 0 {
		cfg.QueueCapacity = defaultMDMVerificationQueue
	} else if cfg.QueueCapacity > defaultMDMVerificationQueue {
		cfg.QueueCapacity = defaultMDMVerificationQueue
	}
	if cfg.InitialSpreadMin < 0 {
		cfg.InitialSpreadMin = 0
	}
	if cfg.InitialSpreadMax < cfg.InitialSpreadMin {
		cfg.InitialSpreadMax = cfg.InitialSpreadMin
	}
	if cfg.InitialSpreadMax == 0 {
		cfg.InitialSpreadMin = 5 * time.Second
		cfg.InitialSpreadMax = 5 * time.Minute
	}
	if cfg.ClaimTTL <= 0 {
		cfg.ClaimTTL = 3 * time.Minute
	}
	return cfg
}

func newMDMVerificationScheduler(s *Server, cfg MDMSchedulerConfig, deps mdmSchedulerDeps) *mdmVerificationScheduler {
	cfg = normalizeMDMSchedulerConfig(cfg)
	if deps.now == nil {
		deps.now = time.Now
	}
	if deps.newTimer == nil {
		deps.newTimer = func(d time.Duration) mdmSchedulerTimer {
			return realMDMSchedulerTimer{time.NewTimer(d)}
		}
	}
	if deps.jitter == nil {
		deps.jitter = func(minimum, maximum time.Duration) time.Duration {
			if maximum <= minimum {
				return minimum
			}
			return minimum + rand.N(maximum-minimum+1)
		}
	}
	if deps.execute == nil {
		deps.execute = s.executeScheduledVerification
	}
	if deps.reuseMDA == nil {
		deps.reuseMDA = func(binding mdmLiveBinding) bool {
			return s.attachCachedMDAProof(binding.providerID, binding.provider, binding.attestation)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	sch := &mdmVerificationScheduler{
		server: s, store: s.store, cfg: cfg, deps: deps,
		owner: uuid.NewString(), ctx: ctx, cancel: cancel,
		wake: make(chan struct{}, 1), work: make(chan mdmSchedulerWork, cfg.Workers),
		jobs: make(map[string]*mdmScheduledJob), bindings: make(map[string]*mdmLiveBinding),
		byUDID: make(map[string]string), active: make(map[store.VerificationTaskKind]int),
	}
	sch.registerMetrics()
	return sch
}

func verificationSchedulerKey(seKey string, kind store.VerificationTaskKind) string {
	return seKey + "\x00" + string(kind)
}

func (s *mdmVerificationScheduler) Start() {
	if s == nil {
		return
	}
	s.start.Do(func() {
		s.wg.Add(1 + s.cfg.Workers)
		go s.dispatcher()
		for range s.cfg.Workers {
			go s.worker()
		}
	})
}

func (s *mdmVerificationScheduler) Close() {
	if s == nil {
		return
	}
	s.close.Do(func() {
		s.cancel()
		s.mu.Lock()
		for _, job := range s.jobs {
			if job.attemptCancel != nil {
				job.attemptCancel()
			}
		}
		s.mu.Unlock()
		s.Start()
		s.wg.Wait()

		s.mu.Lock()
		claimed := make([]store.VerificationJob, 0, s.cfg.Workers)
		for _, job := range s.jobs {
			if job.record.State == store.VerificationStateRunning &&
				job.record.ClaimOwner == s.owner {
				claimed = append(claimed, job.record)
			}
		}
		s.mu.Unlock()
		if len(claimed) == 0 {
			return
		}
		cleanupCtx, cancel := mdmSchedulerCleanupContext()
		defer cancel()
		now := s.deps.now().UTC()
		for _, rec := range claimed {
			if err := s.store.ReleaseVerificationJob(
				cleanupCtx, rec.SEPubKey, rec.Kind, s.owner, now,
			); err != nil {
				s.server.logger.Error(
					"failed to release MDM scheduler claim during shutdown",
					"error", err,
				)
			}
		}
	})
}

func (s *mdmVerificationScheduler) signal() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

func mdmSchedulerCleanupContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), mdmSchedulerCleanupTimeout)
}

func (s *mdmVerificationScheduler) Submit(ctx context.Context, providerID string, provider *registry.Provider, priority store.VerificationPriority) uint64 {
	if s == nil || provider == nil {
		return 0
	}
	result := provider.GetAttestationResult()
	if result == nil || !result.Valid || result.PublicKey == "" || result.SerialNumber == "" {
		return 0
	}
	s.Start()
	now := s.deps.now().UTC()
	record, err := s.store.UpsertVerificationJob(ctx, store.VerificationJob{
		SEPubKey: result.PublicKey, Serial: result.SerialNumber,
		Kind:     store.VerificationTaskSecurityInfo,
		State:    store.VerificationStateWaitingChallenge,
		Priority: priority, LastOutcome: store.VerificationOutcomeNone,
		UpdatedAt: now,
	})
	if err != nil {
		s.server.logger.Error("failed to persist MDM scheduler submission", "error", err)
		s.metricCounter("mdm_scheduler_queue_rejected_total", "priority", schedulerPriorityLabel(priority))
		return 0
	}

	seKey := result.PublicKey
	key := verificationSchedulerKey(seKey, record.Kind)
	s.mu.Lock()
	generation := s.generation.Add(1)
	binding := &mdmLiveBinding{
		providerID: providerID, provider: provider, attestation: *result,
		generation: generation, ctx: ctx,
	}
	s.bindings[seKey] = binding
	for otherKey, other := range s.jobs {
		if other.record.SEPubKey != seKey || other.record.Kind != store.VerificationTaskMDA {
			continue
		}
		if other.attemptCancel != nil {
			other.attemptCancel()
		}
		if other.record.UDID != "" && s.byUDID[other.record.UDID] == otherKey {
			delete(s.byUDID, other.record.UDID)
		}
		delete(s.jobs, otherKey)
	}
	if existing := s.jobs[key]; existing != nil {
		if existing.attemptCancel != nil {
			existing.attemptCancel()
		}
		if existing.record.UDID != "" && s.byUDID[existing.record.UDID] == key {
			delete(s.byUDID, existing.record.UDID)
		}
		existing.record = record
		existing.bindingGen = generation
		existing.callbackGen = 0
		existing.callbackUUID = ""
		existing.enqueuedAt = now
		s.mu.Unlock()
		s.metricCounter("mdm_scheduler_deduplicated_total", "state", string(record.State))
		s.signal()
		return generation
	}
	if record.State == store.VerificationStateRunning &&
		record.ClaimOwner != "" && record.ClaimOwner != s.owner {
		s.mu.Unlock()
		s.metricCounter("mdm_scheduler_deduplicated_total", "state", string(record.State))
		s.signal()
		return generation
	}
	if !s.makeQueueRoomLocked(priority) {
		s.mu.Unlock()
		s.metricCounter("mdm_scheduler_queue_rejected_total", "priority", schedulerPriorityLabel(priority))
		s.signal()
		return generation
	}
	s.jobs[key] = &mdmScheduledJob{record: record, bindingGen: generation, enqueuedAt: now}
	s.mu.Unlock()
	s.metricCounter("mdm_scheduler_enqueued_total", "reason", "registration")
	s.signal()
	return generation
}

// makeQueueRoomLocked never evicts first/expired or recovery work. An evicted
// refresh remains durable and is reloaded only when bounded memory has room.
func (s *mdmVerificationScheduler) makeQueueRoomLocked(priority store.VerificationPriority) bool {
	if len(s.jobs) < s.cfg.QueueCapacity {
		return true
	}
	if priority == store.VerificationPriorityRefresh {
		return false
	}
	for key, job := range s.jobs {
		if !job.running && job.record.Priority == store.VerificationPriorityRefresh {
			delete(s.jobs, key)
			if job.record.UDID != "" && s.byUDID[job.record.UDID] == key {
				delete(s.byUDID, job.record.UDID)
			}
			return true
		}
	}
	return false
}

// ChallengeSettled gates all SecurityInfo work on the current connection's
// phase-1 challenge. A fast-skip completes the durable row before any worker or
// MDM command is consumed.
func (s *mdmVerificationScheduler) ChallengeSettled(provider *registry.Provider, fastSkip bool) {
	if s == nil || provider == nil {
		return
	}
	result := provider.GetAttestationResult()
	if result == nil || result.PublicKey == "" {
		return
	}
	seKey := result.PublicKey
	key := verificationSchedulerKey(seKey, store.VerificationTaskSecurityInfo)
	now := s.deps.now().UTC()
	if fastSkip {
		s.mu.Lock()
		binding := s.bindings[seKey]
		job := s.jobs[key]
		if binding == nil || binding.provider != provider {
			s.mu.Unlock()
			return
		}
		owner := ""
		if job != nil {
			owner = job.record.ClaimOwner
			if job.attemptCancel != nil {
				job.attemptCancel()
			}
			delete(s.jobs, key)
		}
		delete(s.bindings, seKey)
		s.mu.Unlock()
		cleanupCtx, cancel := mdmSchedulerCleanupContext()
		err := s.store.CompleteVerificationJob(
			cleanupCtx, seKey, store.VerificationTaskSecurityInfo, owner,
			store.VerificationOutcomeReused, now,
		)
		cancel()
		if err != nil {
			s.server.logger.Error("failed to complete fast-skip scheduler job", "error", err)
		}
		s.metricCounter("mdm_scheduler_cancelled_total", "reason", "fast_skip")
		s.metricCounter("mdm_scheduler_grants_total", "path", "reuse")
		s.signal()
		return
	}

	s.mu.Lock()
	binding := s.bindings[seKey]
	if binding == nil || binding.provider != provider {
		s.mu.Unlock()
		return
	}
	binding.challengeSettled = true
	generation := binding.generation
	job := s.jobs[key]
	var record *store.VerificationJob
	if job != nil {
		copy := job.record
		record = &copy
	}
	s.mu.Unlock()

	if record == nil {
		durable, err := s.store.GetVerificationJob(s.ctx, seKey, store.VerificationTaskSecurityInfo)
		if err != nil {
			s.server.logger.Error("failed to load queue-rejected MDM scheduler job", "error", err)
			return
		}
		if durable == nil {
			s.signal()
			return
		}
		record = durable
	}

	s.mu.Lock()
	currentBinding := s.bindings[seKey]
	stillCurrent := currentBinding != nil &&
		currentBinding.provider == provider &&
		currentBinding.generation == generation &&
		currentBinding.challengeSettled
	s.mu.Unlock()
	if !stillCurrent {
		return
	}

	record.State = store.VerificationStatePending
	record.NextAttemptAt = now.Add(s.deps.jitter(s.cfg.InitialSpreadMin, s.cfg.InitialSpreadMax))
	record.UpdatedAt = now
	updated, err := s.store.UpsertVerificationJob(s.ctx, *record)
	if err != nil {
		s.server.logger.Error("failed to make MDM scheduler job eligible", "error", err)
		return
	}
	s.mu.Lock()
	if current := s.jobs[key]; current != nil && current.bindingGen == generation {
		current.record = updated
	}
	s.mu.Unlock()
	s.signal()
}

func (s *mdmVerificationScheduler) Unbind(seKey string, generation uint64) {
	if s == nil || seKey == "" || generation == 0 {
		return
	}
	s.mu.Lock()
	binding := s.bindings[seKey]
	if binding == nil || binding.generation != generation {
		s.mu.Unlock()
		return
	}
	delete(s.bindings, seKey)
	for key, job := range s.jobs {
		if job.record.SEPubKey != seKey || job.bindingGen != generation {
			continue
		}
		if job.attemptCancel != nil {
			job.attemptCancel()
		}
		if job.record.UDID != "" && s.byUDID[job.record.UDID] == key {
			delete(s.byUDID, job.record.UDID)
		}
		if !job.running {
			delete(s.jobs, key)
		}
	}
	s.mu.Unlock()
	s.metricCounter("mdm_scheduler_cancelled_total", "reason", "disconnect")
	s.signal()
}

func (s *mdmVerificationScheduler) dispatcher() {
	defer s.wg.Done()
	for {
		s.loadDueRows()
		s.dispatchDueRows()
		s.publishDogStatsDGauges()
		timer := s.deps.newTimer(s.nextDispatchDelay())
		select {
		case <-s.ctx.Done():
			timer.Stop()
			return
		case <-s.wake:
			timer.Stop()
		case <-timer.C():
		}
	}
}

func (s *mdmVerificationScheduler) nextDispatchDelay() time.Duration {
	now := s.deps.now()
	delay := mdmSchedulerDispatchInterval
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, job := range s.jobs {
		if job.running || (job.record.State != store.VerificationStatePending && job.record.State != store.VerificationStateBackoff) {
			continue
		}
		candidate := job.record.NextAttemptAt.Sub(now)
		if candidate <= 0 {
			return time.Millisecond
		}
		if candidate < delay {
			delay = candidate
		}
	}
	return delay
}

func (s *mdmVerificationScheduler) loadDueRows() {
	now := s.deps.now().UTC()
	limit := s.cfg.QueueCapacity
	s.mu.Lock()
	offset := s.dueScanOffset
	s.mu.Unlock()

	var (
		rows []store.VerificationJob
		err  error
	)
	if paged, ok := s.store.(verificationDuePageStore); ok {
		rows, err = paged.ListDueVerificationJobsPage(
			s.ctx, now, limit, offset,
		)
	} else {
		rows, err = s.store.ListDueVerificationJobs(s.ctx, now, limit)
		offset = 0
	}
	if err != nil {
		if s.ctx.Err() == nil {
			s.server.logger.Error("failed to load due MDM scheduler rows", "error", err)
		}
		return
	}
	s.mu.Lock()
	if len(rows) < limit {
		s.dueScanOffset = 0
	} else {
		s.dueScanOffset = offset + len(rows)
	}
	for _, rec := range rows {
		key := verificationSchedulerKey(rec.SEPubKey, rec.Kind)
		binding := s.bindings[rec.SEPubKey]
		if binding == nil ||
			(rec.Kind == store.VerificationTaskSecurityInfo && !binding.challengeSettled) ||
			(rec.Kind == store.VerificationTaskMDA && (!binding.challengeSettled || !binding.allowMDA)) {
			continue
		}
		if existing := s.jobs[key]; existing != nil {
			claimExpired := rec.State == store.VerificationStateRunning &&
				rec.ClaimExpiresAt != nil && !rec.ClaimExpiresAt.After(now)
			stalePlaceholder := !existing.running &&
				rec.ClaimOwner != s.owner &&
				claimExpired
			if !stalePlaceholder {
				continue
			}
			if oldUDID := existing.record.UDID; oldUDID != "" &&
				s.byUDID[oldUDID] == key {
				delete(s.byUDID, oldUDID)
			}
			existing.record = rec
			existing.bindingGen = binding.generation
			existing.callbackGen = 0
			existing.callbackUUID = ""
			existing.enqueuedAt = now
			existing.attemptCancel = nil
			continue
		}
		if !s.makeQueueRoomLocked(rec.Priority) {
			continue
		}
		s.jobs[key] = &mdmScheduledJob{
			record: rec, bindingGen: binding.generation, enqueuedAt: now,
		}
	}
	s.mu.Unlock()
}

func (s *mdmVerificationScheduler) dispatchDueRows() {
	now := s.deps.now().UTC()
	type candidate struct {
		key string
		rec store.VerificationJob
	}
	s.mu.Lock()
	available := s.cfg.Workers
	for _, count := range s.active {
		available -= count
	}
	candidates := make([]candidate, 0, available)
	if available > 0 {
		for key, job := range s.jobs {
			binding := s.bindings[job.record.SEPubKey]
			if job.running || binding == nil || binding.generation != job.bindingGen {
				continue
			}
			if job.record.Kind == store.VerificationTaskSecurityInfo && !binding.challengeSettled {
				continue
			}
			if job.record.Kind == store.VerificationTaskMDA &&
				(!binding.challengeSettled || !binding.allowMDA) {
				continue
			}
			claimExpired := job.record.State == store.VerificationStateRunning &&
				job.record.ClaimExpiresAt != nil &&
				!job.record.ClaimExpiresAt.After(now)
			durableDue := job.record.State == store.VerificationStatePending ||
				job.record.State == store.VerificationStateBackoff ||
				claimExpired
			if durableDue && !job.record.NextAttemptAt.After(now) {
				candidates = append(candidates, candidate{key: key, rec: job.record})
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
	if len(candidates) > available {
		candidates = candidates[:available]
	}
	for _, candidate := range candidates {
		s.claimAndDispatch(candidate.key, now)
	}
}

func (s *mdmVerificationScheduler) claimAndDispatch(key string, now time.Time) {
	s.mu.Lock()
	job := s.jobs[key]
	if job == nil || job.running {
		s.mu.Unlock()
		return
	}
	rec := job.record
	s.mu.Unlock()
	claimed, ok, err := s.store.ClaimVerificationJob(s.ctx, rec.SEPubKey, rec.Kind, s.owner, now, now.Add(s.cfg.ClaimTTL))
	if err != nil || !ok {
		if err != nil && s.ctx.Err() == nil {
			s.server.logger.Error("failed to claim MDM scheduler job", "error", err)
		}
		return
	}

	s.mu.Lock()
	job = s.jobs[key]
	binding := s.bindings[rec.SEPubKey]
	if job == nil || job.running || binding == nil || binding.generation != job.bindingGen {
		s.mu.Unlock()
		cleanupCtx, cancel := mdmSchedulerCleanupContext()
		_ = s.store.ReleaseVerificationJob(
			cleanupCtx, rec.SEPubKey, rec.Kind, s.owner, s.deps.now().UTC(),
		)
		cancel()
		return
	}
	attemptCtx, cancel := context.WithCancel(s.ctx)
	stopAfter := context.AfterFunc(binding.ctx, cancel)
	job.record = claimed
	job.running = true
	job.attemptCancel = cancel
	s.active[rec.Kind]++
	work := mdmSchedulerWork{
		key: key, job: claimed, binding: *binding,
		ctx: attemptCtx, cancel: cancel, stopAfter: stopAfter,
		enqueuedAt: job.enqueuedAt,
	}
	s.mu.Unlock()
	s.work <- work
}

func (s *mdmVerificationScheduler) worker() {
	defer s.wg.Done()
	for {
		select {
		case <-s.ctx.Done():
			return
		case work := <-s.work:
			if s.ctx.Err() != nil {
				work.stopAfter()
				work.cancel()
				return
			}
			started := s.deps.now()
			result := s.deps.execute(work.ctx, work.binding, work.job.Kind, work.job.UDID)
			work.stopAfter()
			s.observeAttempt(work, result, s.deps.now().Sub(started))
			s.finishAttempt(work, result)
			work.cancel()
		}
	}
}

func (s *mdmVerificationScheduler) finishAttempt(work mdmSchedulerWork, result mdmSchedulerAttemptResult) {
	now := s.deps.now().UTC()
	s.mu.Lock()
	job := s.jobs[work.key]
	binding := s.bindings[work.job.SEPubKey]
	if s.active[work.job.Kind] > 0 {
		s.active[work.job.Kind]--
	}
	if job != nil {
		job.running = false
		job.attemptCancel = nil
	}
	current := job != nil && binding != nil &&
		binding.generation == work.binding.generation &&
		job.bindingGen == work.binding.generation
	s.mu.Unlock()

	if !current || work.ctx.Err() != nil {
		cleanupCtx, cancel := mdmSchedulerCleanupContext()
		err := s.store.ReleaseVerificationJob(
			cleanupCtx, work.job.SEPubKey, work.job.Kind, s.owner, now,
		)
		cancel()
		if err != nil {
			s.server.logger.Error("failed to release stale MDM scheduler claim", "error", err)
			s.mu.Lock()
			orphan := s.jobs[work.key]
			if s.bindings[work.job.SEPubKey] == nil && orphan != nil &&
				orphan.bindingGen == work.binding.generation {
				if orphan.record.UDID != "" && s.byUDID[orphan.record.UDID] == work.key {
					delete(s.byUDID, orphan.record.UDID)
				}
				delete(s.jobs, work.key)
			}
			s.mu.Unlock()
		} else if s.ctx.Err() == nil {
			s.refreshReleasedJob(work)
		}
		s.signal()
		return
	}

	if result.udid != "" {
		work.job.UDID = result.udid
		work.job.UpdatedAt = now
		if updated, err := s.store.UpsertVerificationJob(s.ctx, work.job); err == nil {
			work.job = updated
		}
		s.mu.Lock()
		if currentJob := s.jobs[work.key]; currentJob != nil &&
			currentJob.bindingGen == work.binding.generation {
			currentJob.record.UDID = result.udid
			if currentJob.callbackGen == work.binding.generation &&
				currentJob.callbackUUID != "" {
				s.byUDID[result.udid] = work.key
			}
		}
		s.mu.Unlock()
	}

	if result.granted || result.terminal {
		cleanupCtx, cancel := mdmSchedulerCleanupContext()
		err := s.store.CompleteVerificationJob(
			cleanupCtx, work.job.SEPubKey, work.job.Kind,
			s.owner, result.outcome, now,
		)
		cancel()
		if err != nil {
			s.server.logger.Error("failed to complete MDM scheduler job", "error", err)
		}
		s.mu.Lock()
		delete(s.jobs, work.key)
		if work.job.UDID != "" && s.byUDID[work.job.UDID] == work.key {
			delete(s.byUDID, work.job.UDID)
		}
		s.mu.Unlock()
		if result.granted && work.job.Kind == store.VerificationTaskSecurityInfo {
			if s.deps.reuseMDA(work.binding) {
				s.metricCounter("mda_verification_total", "outcome", "reused")
				s.mu.Lock()
				delete(s.bindings, work.job.SEPubKey)
				s.mu.Unlock()
			} else {
				s.enqueueMDA(work.binding, result.udid)
			}
		} else {
			s.mu.Lock()
			delete(s.bindings, work.job.SEPubKey)
			s.mu.Unlock()
		}
		s.signal()
		return
	}

	stage := work.job.RetryStage + 1
	delay := s.retryDelay(stage)
	priority := store.VerificationPriorityRecovery
	if work.job.Kind == store.VerificationTaskMDA {
		priority = store.VerificationPriorityRefresh
	}
	next := now.Add(delay)
	cleanupCtx, cancel := mdmSchedulerCleanupContext()
	err := s.store.RescheduleVerificationJob(
		cleanupCtx, work.job.SEPubKey, work.job.Kind, s.owner, priority, stage,
		delay, next, result.outcome, now,
	)
	cancel()
	if err != nil {
		s.server.logger.Error("failed to reschedule MDM scheduler job", "error", err)
	}
	s.mu.Lock()
	if currentJob := s.jobs[work.key]; currentJob != nil &&
		currentJob.bindingGen == work.binding.generation {
		currentJob.record.State = store.VerificationStateBackoff
		currentJob.record.Priority = priority
		currentJob.record.RetryStage = stage
		currentJob.record.PreviousDelay = delay
		currentJob.record.NextAttemptAt = next
		currentJob.record.LastOutcome = result.outcome
		currentJob.record.ClaimOwner = ""
		currentJob.record.ClaimExpiresAt = nil
	}
	s.mu.Unlock()
	if s.server.metrics != nil {
		s.server.metrics.ObserveHistogram(
			"mdm_scheduler_retry_delay_seconds", delay.Seconds(),
			MetricLabel{"stage", schedulerRetryStageLabel(stage)},
		)
	}
	s.server.ddHistogram("mdm.scheduler.retry_delay_seconds", delay.Seconds(), []string{"stage:" + schedulerRetryStageLabel(stage)})
	s.signal()
}

// refreshReleasedJob reconciles a rebound live job with durable state after the
// prior connection generation releases its claim. Reconnect submission can race
// an in-flight attempt and therefore observe the durable row while it is still
// running. The release is authoritative: copy its preserved retry stage and due
// time into the new generation before redispatching. Never synthesize an
// immediate retry or reuse the stale generation's in-memory state.
func (s *mdmVerificationScheduler) refreshReleasedJob(work mdmSchedulerWork) {
	rec, err := s.store.GetVerificationJob(
		s.ctx, work.job.SEPubKey, work.job.Kind,
	)
	if err != nil {
		if s.ctx.Err() == nil {
			s.server.logger.Error("failed to refresh rebound MDM scheduler job", "error", err)
		}
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	job := s.jobs[work.key]
	if job == nil {
		return
	}
	binding := s.bindings[work.job.SEPubKey]
	if binding == nil {
		if job.bindingGen == work.binding.generation {
			if job.record.UDID != "" && s.byUDID[job.record.UDID] == work.key {
				delete(s.byUDID, job.record.UDID)
			}
			delete(s.jobs, work.key)
		}
		return
	}
	if job.bindingGen != binding.generation ||
		job.bindingGen == work.binding.generation {
		return
	}
	if rec == nil || rec.State == store.VerificationStateCompleted {
		if job.record.UDID != "" && s.byUDID[job.record.UDID] == work.key {
			delete(s.byUDID, job.record.UDID)
		}
		delete(s.jobs, work.key)
		return
	}
	if rec.State == store.VerificationStateRunning {
		// A different coordinator still owns the durable claim. Drop the local
		// copy; the bounded due-row loader will reseed it after claim expiry.
		if job.record.UDID != "" && s.byUDID[job.record.UDID] == work.key {
			delete(s.byUDID, job.record.UDID)
		}
		delete(s.jobs, work.key)
		return
	}
	if oldUDID := job.record.UDID; oldUDID != "" &&
		s.byUDID[oldUDID] == work.key {
		delete(s.byUDID, oldUDID)
	}
	job.record = *rec
	job.running = false
	job.callbackGen = 0
	job.callbackUUID = ""
	job.attemptCancel = nil
	job.enqueuedAt = s.deps.now()
}

func (s *mdmVerificationScheduler) enqueueMDA(binding mdmLiveBinding, udid string) {
	if udid == "" {
		s.metricCounter("mda_verification_total", "outcome", "invalid")
		s.mu.Lock()
		delete(s.bindings, binding.attestation.PublicKey)
		s.mu.Unlock()
		return
	}
	now := s.deps.now().UTC()
	rec, err := s.store.UpsertVerificationJob(s.ctx, store.VerificationJob{
		SEPubKey: binding.attestation.PublicKey, Serial: binding.attestation.SerialNumber,
		UDID: udid, Kind: store.VerificationTaskMDA,
		State: store.VerificationStatePending, Priority: store.VerificationPriorityRefresh,
		NextAttemptAt: now, LastOutcome: store.VerificationOutcomeNone, UpdatedAt: now,
	})
	if err != nil {
		s.server.logger.Error("failed to persist MDA scheduler job", "error", err)
		return
	}
	key := verificationSchedulerKey(rec.SEPubKey, rec.Kind)
	s.mu.Lock()
	live := s.bindings[rec.SEPubKey]
	if live == nil || live.generation != binding.generation {
		s.mu.Unlock()
		return
	}
	live.allowMDA = true
	if existing := s.jobs[key]; existing != nil {
		if existing.record.UDID != "" && s.byUDID[existing.record.UDID] == key {
			delete(s.byUDID, existing.record.UDID)
		}
		existing.record = rec
		existing.bindingGen = binding.generation
		existing.callbackGen = 0
		existing.callbackUUID = ""
		s.mu.Unlock()
		s.metricCounter("mdm_scheduler_deduplicated_total", "state", string(rec.State))
		return
	}
	if !s.makeQueueRoomLocked(rec.Priority) {
		s.mu.Unlock()
		s.metricCounter("mdm_scheduler_queue_rejected_total", "priority", "refresh")
		return
	}
	s.jobs[key] = &mdmScheduledJob{record: rec, bindingGen: binding.generation, enqueuedAt: now}
	s.mu.Unlock()
	s.metricCounter("mdm_scheduler_enqueued_total", "reason", "mda_followup")
	s.signal()
}

func (s *mdmVerificationScheduler) retryDelay(stage int) time.Duration {
	switch stage {
	case 1:
		return s.deps.jitter(mdmRetryFirstMin, mdmRetryFirstMax)
	case 2:
		return s.deps.jitter(mdmRetrySecondMin, mdmRetrySecondMax)
	default:
		return s.deps.jitter(mdmRetrySteadyMin, mdmRetrySteadyMax)
	}
}

type mdmSchedulerAttemptMetadata struct {
	udid       string
	mdaOutcome string
}
type mdmSchedulerAttemptContextKey struct{}

func (s *Server) executeScheduledVerification(ctx context.Context, binding mdmLiveBinding, kind store.VerificationTaskKind, udid string) mdmSchedulerAttemptResult {
	if binding.provider == nil || binding.provider.ChallengeShouldStop() {
		return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomePostureMismatch, terminal: true}
	}
	metadata := &mdmSchedulerAttemptMetadata{}
	ctx = context.WithValue(ctx, mdmSchedulerAttemptContextKey{}, metadata)
	if kind == store.VerificationTaskSecurityInfo {
		outcome := s.verifyProviderViaMDM(ctx, binding.providerID, binding.provider, binding.attestation)
		switch outcome {
		case mdmVerifyGranted:
			return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeSuccess, granted: true, udid: metadata.udid}
		case mdmVerifyTerminal:
			return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomePostureMismatch, terminal: true, udid: metadata.udid}
		default:
			fixed := store.VerificationOutcomeTransient
			if binding.provider.GetMDMFailureReason() == "securityinfo-timeout" {
				fixed = store.VerificationOutcomeTimeout
			}
			return mdmSchedulerAttemptResult{outcome: fixed, udid: metadata.udid}
		}
	}
	if udid == "" {
		return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeInvalid, terminal: true}
	}
	s.mdmScheduler.metricCounter("mda_verification_total", "outcome", "sent")
	s.verifyAppleDeviceAttestation(ctx, binding.providerID, binding.provider, binding.attestation, udid)
	if ctx.Err() != nil {
		return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeCancelled}
	}
	binding.provider.Mu().Lock()
	verified := binding.provider.MDAVerified
	binding.provider.Mu().Unlock()
	if verified {
		return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeSuccess, granted: true, udid: udid}
	}
	if binding.provider.ChallengeShouldStop() {
		return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeInvalid, terminal: true, udid: udid}
	}
	if metadata.mdaOutcome == "timeout" {
		return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeTimeout, udid: udid}
	}
	if metadata.mdaOutcome == "invalid" ||
		metadata.mdaOutcome == "binding_mismatch" {
		return mdmSchedulerAttemptResult{
			outcome: store.VerificationOutcomeInvalid, terminal: true, udid: udid,
		}
	}
	return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeTransient, udid: udid}
}

// ObserveAttemptUDID persists transport identity for the exact running
// SecurityInfo job. It does not authorize late callbacks until the command UUID
// observer below binds the command MicroMDM actually issued.
func (s *mdmVerificationScheduler) ObserveAttemptUDID(provider *registry.Provider, udid string) {
	if s == nil || provider == nil || udid == "" {
		return
	}
	result := provider.GetAttestationResult()
	if result == nil || result.PublicKey == "" {
		return
	}
	key := verificationSchedulerKey(result.PublicKey, store.VerificationTaskSecurityInfo)
	s.mu.Lock()
	job := s.jobs[key]
	binding := s.bindings[result.PublicKey]
	if job == nil || binding == nil || binding.provider != provider ||
		binding.generation != job.bindingGen || !job.running {
		s.mu.Unlock()
		return
	}
	generation := binding.generation
	claimOwner := job.record.ClaimOwner
	record := job.record
	s.mu.Unlock()

	record.UDID = udid
	record.UpdatedAt = s.deps.now().UTC()
	updated, err := s.store.UpsertVerificationJob(s.ctx, record)
	if err != nil {
		if s.ctx.Err() == nil {
			s.server.logger.Error("failed to persist MDM attempt UDID", "error", err)
		}
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	job = s.jobs[key]
	binding = s.bindings[result.PublicKey]
	if job == nil || binding == nil || binding.provider != provider ||
		binding.generation != generation || job.bindingGen != generation ||
		!job.running || job.record.ClaimOwner != claimOwner {
		return
	}
	if oldUDID := job.record.UDID; oldUDID != "" &&
		oldUDID != udid && s.byUDID[oldUDID] == key {
		delete(s.byUDID, oldUDID)
	}
	job.record = updated
	job.callbackGen = 0
	job.callbackUUID = ""
}

func (s *mdmVerificationScheduler) ObserveAttemptCommand(
	provider *registry.Provider,
	kind store.VerificationTaskKind,
	udid, commandUUID string,
) {
	if s == nil || provider == nil || udid == "" || commandUUID == "" {
		return
	}
	result := provider.GetAttestationResult()
	if result == nil || result.PublicKey == "" {
		return
	}
	key := verificationSchedulerKey(result.PublicKey, kind)
	s.mu.Lock()
	defer s.mu.Unlock()
	job := s.jobs[key]
	binding := s.bindings[result.PublicKey]
	if job == nil || binding == nil ||
		binding.provider != provider ||
		binding.generation != job.bindingGen ||
		!binding.challengeSettled ||
		!job.running ||
		job.record.UDID != udid {
		return
	}
	if oldUDID := job.record.UDID; oldUDID != "" &&
		oldUDID != udid && s.byUDID[oldUDID] == key {
		delete(s.byUDID, oldUDID)
	}
	job.callbackGen = binding.generation
	job.callbackUUID = commandUUID
	s.byUDID[udid] = key
}

func (s *mdmVerificationScheduler) ApplyLateSecurityInfo(
	udid, commandUUID string,
	infoSecurityOK bool,
) *mdmLiveBinding {
	if s == nil || udid == "" || commandUUID == "" {
		return nil
	}
	s.mu.Lock()
	key := s.byUDID[udid]
	job := s.jobs[key]
	if key == "" ||
		job == nil ||
		job.record.Kind != store.VerificationTaskSecurityInfo ||
		job.record.UDID != udid {
		s.mu.Unlock()
		return nil
	}
	binding := s.bindings[job.record.SEPubKey]
	if binding == nil ||
		binding.generation != job.bindingGen ||
		binding.attestation.PublicKey != job.record.SEPubKey ||
		!binding.challengeSettled {
		s.mu.Unlock()
		return nil
	}
	if job.callbackGen != binding.generation ||
		job.callbackUUID != commandUUID {
		s.mu.Unlock()
		return nil
	}
	copy := *binding
	if !infoSecurityOK && job.attemptCancel != nil {
		job.attemptCancel()
	}
	s.mu.Unlock()
	return &copy
}

func (s *mdmVerificationScheduler) CompleteLateSecurityInfo(
	binding mdmLiveBinding,
	udid, commandUUID string,
) {
	now := s.deps.now().UTC()
	key := verificationSchedulerKey(binding.attestation.PublicKey, store.VerificationTaskSecurityInfo)
	s.mu.Lock()
	job := s.jobs[key]
	currentBinding := s.bindings[binding.attestation.PublicKey]
	if job == nil ||
		job.bindingGen != binding.generation ||
		job.callbackGen != binding.generation ||
		job.callbackUUID != commandUUID ||
		job.record.UDID != udid ||
		s.byUDID[udid] != key ||
		currentBinding == nil ||
		currentBinding.generation != binding.generation ||
		currentBinding.provider != binding.provider ||
		!currentBinding.challengeSettled {
		s.mu.Unlock()
		return
	}
	if job.attemptCancel != nil {
		job.attemptCancel()
	}
	owner := job.record.ClaimOwner
	delete(s.jobs, key)
	if s.byUDID[udid] == key {
		delete(s.byUDID, udid)
	}
	s.mu.Unlock()
	cleanupCtx, cancel := mdmSchedulerCleanupContext()
	_ = s.store.CompleteVerificationJob(
		cleanupCtx, binding.attestation.PublicKey,
		store.VerificationTaskSecurityInfo, owner,
		store.VerificationOutcomeSuccess, now,
	)
	cancel()
	if s.deps.reuseMDA(binding) {
		s.metricCounter("mda_verification_total", "outcome", "reused")
		s.mu.Lock()
		delete(s.bindings, binding.attestation.PublicKey)
		s.mu.Unlock()
	} else {
		s.enqueueMDA(binding, udid)
	}
	s.metricCounter("mdm_scheduler_grants_total", "path", "late")
	s.signal()
}

func (s *mdmVerificationScheduler) RejectLateSecurityInfo(
	binding mdmLiveBinding,
	udid, commandUUID string,
) {
	now := s.deps.now().UTC()
	key := verificationSchedulerKey(binding.attestation.PublicKey, store.VerificationTaskSecurityInfo)
	s.mu.Lock()
	job := s.jobs[key]
	currentBinding := s.bindings[binding.attestation.PublicKey]
	if job == nil ||
		job.bindingGen != binding.generation ||
		job.callbackGen != binding.generation ||
		job.callbackUUID != commandUUID ||
		job.record.UDID != udid ||
		s.byUDID[udid] != key ||
		currentBinding == nil ||
		currentBinding.generation != binding.generation ||
		currentBinding.provider != binding.provider ||
		!currentBinding.challengeSettled {
		s.mu.Unlock()
		return
	}
	if job.attemptCancel != nil {
		job.attemptCancel()
	}
	owner := job.record.ClaimOwner
	delete(s.jobs, key)
	delete(s.bindings, binding.attestation.PublicKey)
	if s.byUDID[udid] == key {
		delete(s.byUDID, udid)
	}
	s.mu.Unlock()
	cleanupCtx, cancel := mdmSchedulerCleanupContext()
	_ = s.store.CompleteVerificationJob(
		cleanupCtx, binding.attestation.PublicKey,
		store.VerificationTaskSecurityInfo, owner,
		store.VerificationOutcomePostureMismatch, now,
	)
	cancel()
	s.signal()
}

// ApplyLateMDA attaches a late Apple response only to the exact scheduler job
// that issued work for this UDID. Unowned and stale-generation callbacks are
// dropped without any fleet-wide fallback.
func (s *Server) ApplyLateMDA(
	udid, commandUUID string,
	certChain [][]byte,
) {
	if s == nil || s.mdmScheduler == nil ||
		udid == "" || commandUUID == "" || len(certChain) == 0 {
		return
	}
	s.mdmScheduler.applyLateMDA(udid, commandUUID, certChain)
}

func (s *mdmVerificationScheduler) applyLateMDA(
	udid, commandUUID string,
	certChain [][]byte,
) bool {
	s.mu.Lock()
	key := s.byUDID[udid]
	job := s.jobs[key]
	if key == "" ||
		job == nil ||
		job.record.Kind != store.VerificationTaskMDA ||
		job.record.UDID != udid {
		s.mu.Unlock()
		return false
	}
	binding := s.bindings[job.record.SEPubKey]
	if binding == nil ||
		binding.generation != job.bindingGen ||
		job.callbackGen != binding.generation ||
		job.callbackUUID != commandUUID ||
		binding.attestation.PublicKey != job.record.SEPubKey ||
		!binding.challengeSettled ||
		!binding.allowMDA {
		s.mu.Unlock()
		return true
	}
	bound := *binding
	owner := job.record.ClaimOwner
	seKey := job.record.SEPubKey
	attemptCancel := job.attemptCancel
	s.mu.Unlock()

	mdaResult, err := attestation.VerifyMDADeviceAttestation(certChain)
	if err != nil || mdaResult == nil || !mdaResult.Valid {
		s.metricCounter("mda_verification_total", "outcome", "invalid")
		return true
	}
	wantFreshness := sha256.Sum256([]byte(bound.attestation.PublicKey))
	if len(mdaResult.FreshnessCode) == 0 ||
		!bytes.Equal(mdaResult.FreshnessCode, wantFreshness[:]) ||
		(mdaResult.DeviceSerial != "" &&
			mdaResult.DeviceSerial != bound.attestation.SerialNumber) ||
		(mdaResult.DeviceUDID != "" && mdaResult.DeviceUDID != udid) {
		s.metricCounter("mda_verification_total", "outcome", "binding_mismatch")
		return true
	}

	s.mu.Lock()
	currentJob := s.jobs[key]
	currentBinding := s.bindings[seKey]
	stillCurrent := currentJob != nil &&
		currentJob.record.Kind == store.VerificationTaskMDA &&
		currentJob.record.UDID == udid &&
		currentJob.bindingGen == bound.generation &&
		currentJob.callbackGen == bound.generation &&
		currentJob.callbackUUID == commandUUID &&
		s.byUDID[udid] == key &&
		currentBinding != nil &&
		currentBinding.generation == bound.generation &&
		currentBinding.provider == bound.provider &&
		currentBinding.challengeSettled &&
		currentBinding.allowMDA
	s.mu.Unlock()
	if !stillCurrent {
		return true
	}
	if !bound.provider.SetMDAProofIfHardwareBound(certChain, mdaResult, true) {
		return true
	}
	if attemptCancel != nil {
		attemptCancel()
	}
	s.server.registry.PersistProvider(bound.provider)
	now := s.deps.now().UTC()
	cleanupCtx, cancel := mdmSchedulerCleanupContext()
	_ = s.store.CompleteVerificationJob(
		cleanupCtx, seKey, store.VerificationTaskMDA,
		owner, store.VerificationOutcomeSuccess, now,
	)
	cancel()
	s.mu.Lock()
	if current := s.jobs[key]; current != nil &&
		current.bindingGen == bound.generation {
		delete(s.jobs, key)
		delete(s.bindings, seKey)
		if s.byUDID[udid] == key {
			delete(s.byUDID, udid)
		}
	}
	s.mu.Unlock()
	s.metricCounter("mda_verification_total", "outcome", "late")
	s.signal()
	return true
}

func schedulerPriorityLabel(priority store.VerificationPriority) string {
	switch priority {
	case store.VerificationPriorityFirstOrExpired:
		return "first_or_expired"
	case store.VerificationPriorityRecovery:
		return "recovery"
	default:
		return "refresh"
	}
}

func schedulerRetryStageLabel(stage int) string {
	if stage <= 1 {
		return "first"
	}
	if stage == 2 {
		return "second"
	}
	return "steady"
}

func (s *mdmVerificationScheduler) metricCounter(name, labelName, labelValue string) {
	if s.server.metrics != nil {
		s.server.metrics.IncCounter(name, MetricLabel{labelName, labelValue})
	}
	ddName := map[string]string{
		"mdm_scheduler_enqueued_total":       "mdm.scheduler.enqueued",
		"mdm_scheduler_deduplicated_total":   "mdm.scheduler.deduplicated",
		"mdm_scheduler_cancelled_total":      "mdm.scheduler.cancelled",
		"mdm_scheduler_queue_rejected_total": "mdm.scheduler.queue_rejected",
		"mdm_scheduler_grants_total":         "mdm.scheduler.grants",
		"mda_verification_total":             "mda.verification",
	}[name]
	if ddName == "" {
		ddName = name
	}
	s.server.ddIncr(ddName, []string{labelName + ":" + labelValue})
}

func (s *mdmVerificationScheduler) observeAttempt(work mdmSchedulerWork, result mdmSchedulerAttemptResult, duration time.Duration) {
	kind := string(work.job.Kind)
	outcome := string(result.outcome)
	queueWait := s.deps.now().Sub(work.enqueuedAt)
	if queueWait < 0 {
		queueWait = 0
	}
	if s.server.metrics != nil {
		s.server.metrics.IncCounter("mdm_scheduler_attempts_total", MetricLabel{"kind", kind}, MetricLabel{"outcome", outcome})
		s.server.metrics.ObserveHistogram("mdm_scheduler_attempt_seconds", duration.Seconds(), MetricLabel{"kind", kind}, MetricLabel{"outcome", outcome})
		s.server.metrics.ObserveHistogram("mdm_scheduler_queue_wait_seconds", queueWait.Seconds(), MetricLabel{"kind", kind}, MetricLabel{"priority", schedulerPriorityLabel(work.job.Priority)})
		if result.outcome == store.VerificationOutcomeTimeout {
			s.server.metrics.IncCounter("mdm_scheduler_timeouts_total", MetricLabel{"kind", kind})
		}
	}
	s.server.ddIncr("mdm.scheduler.attempts", []string{"kind:" + kind, "outcome:" + outcome})
	s.server.ddHistogram("mdm.scheduler.attempt_seconds", duration.Seconds(), []string{"kind:" + kind, "outcome:" + outcome})
	s.server.ddHistogram("mdm.scheduler.queue_wait_seconds", queueWait.Seconds(),
		[]string{"kind:" + kind, "priority:" + schedulerPriorityLabel(work.job.Priority)})
	if result.outcome == store.VerificationOutcomeTimeout {
		s.server.ddIncr("mdm.scheduler.timeouts", []string{"kind:" + kind})
	}
	if result.granted && work.job.Kind == store.VerificationTaskSecurityInfo {
		s.metricCounter("mdm_scheduler_grants_total", "path", "live")
	}
	if work.job.Kind == store.VerificationTaskMDA {
		mdaOutcome := outcome
		if result.outcome == store.VerificationOutcomeSuccess {
			mdaOutcome = "verified"
		}
		s.metricCounter("mda_verification_total", "outcome", mdaOutcome)
	}
}

func (s *mdmVerificationScheduler) publishDogStatsDGauges() {
	type gauge struct {
		name  string
		value float64
		tags  []string
	}
	values := make([]gauge, 0, 8)
	s.mu.Lock()
	for _, kind := range []store.VerificationTaskKind{
		store.VerificationTaskSecurityInfo, store.VerificationTaskMDA,
	} {
		values = append(values, gauge{
			name:  "mdm.scheduler.active_attempts",
			value: float64(s.active[kind]),
			tags:  []string{"kind:" + string(kind)},
		})
		for _, priority := range []store.VerificationPriority{
			store.VerificationPriorityFirstOrExpired,
			store.VerificationPriorityRecovery,
			store.VerificationPriorityRefresh,
		} {
			count := 0
			for _, job := range s.jobs {
				if !job.running && job.record.Kind == kind &&
					job.record.Priority == priority {
					count++
				}
			}
			values = append(values, gauge{
				name: "mdm.scheduler.queue_depth", value: float64(count),
				tags: []string{
					"kind:" + string(kind),
					"priority:" + schedulerPriorityLabel(priority),
				},
			})
		}
	}
	s.mu.Unlock()
	for _, value := range values {
		s.server.ddGauge(value.name, value.value, value.tags)
	}
}

func (s *mdmVerificationScheduler) registerMetrics() {
	if s.server.metrics == nil {
		return
	}
	for _, kind := range []store.VerificationTaskKind{store.VerificationTaskSecurityInfo, store.VerificationTaskMDA} {
		kind := kind
		s.server.metrics.RegisterGaugeLabels("mdm_scheduler_active_attempts", func() float64 {
			s.mu.Lock()
			defer s.mu.Unlock()
			return float64(s.active[kind])
		}, MetricLabel{"kind", string(kind)})
		for _, priority := range []store.VerificationPriority{store.VerificationPriorityFirstOrExpired, store.VerificationPriorityRecovery, store.VerificationPriorityRefresh} {
			priority := priority
			s.server.metrics.RegisterGaugeLabels("mdm_scheduler_queue_depth", func() float64 {
				s.mu.Lock()
				defer s.mu.Unlock()
				count := 0
				for _, job := range s.jobs {
					if !job.running && job.record.Kind == kind && job.record.Priority == priority {
						count++
					}
				}
				return float64(count)
			}, MetricLabel{"kind", string(kind)}, MetricLabel{"priority", schedulerPriorityLabel(priority)})
		}
	}
}

func (s *mdmVerificationScheduler) rolloutSaturation(allowed map[string]struct{}) float64 {
	if s == nil || len(allowed) == 0 {
		return 0
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	active, queued := 0, 0
	for _, job := range s.jobs {
		if _, ok := allowed[job.record.SEPubKey]; !ok {
			continue
		}
		if job.running {
			active++
		} else {
			queued++
		}
	}
	maxTasks := len(allowed) * 2
	activeDenominator := min(s.cfg.Workers, maxTasks)
	queueDenominator := min(s.cfg.QueueCapacity, maxTasks)
	ratio := 0.0
	if activeDenominator > 0 {
		ratio = float64(active) / float64(activeDenominator)
	}
	if queueDenominator > 0 {
		if queueRatio := float64(queued) / float64(queueDenominator); queueRatio > ratio {
			ratio = queueRatio
		}
	}
	if ratio > 1 {
		return 1
	}
	return ratio
}
