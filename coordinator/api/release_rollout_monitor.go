package api

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	rolloutHealthBucketWidth = 15 * time.Second
	rolloutHealthBucketCount = 20
	rolloutReconnectMaxKeys  = 100_000
)

type rolloutMetricBucket struct {
	epoch int64
	sum   float64
	count uint64
}

type rolloutMetricWindow struct {
	buckets [rolloutHealthBucketCount]rolloutMetricBucket
}

func rolloutEpoch(at time.Time) int64 {
	return at.UnixNano() / int64(rolloutHealthBucketWidth)
}

func (w *rolloutMetricWindow) observe(at time.Time, value float64) {
	if value < 0 {
		value = 0
	} else if value > 1 {
		value = 1
	}
	epoch := rolloutEpoch(at)
	bucket := &w.buckets[epoch%rolloutHealthBucketCount]
	if bucket.epoch != epoch {
		*bucket = rolloutMetricBucket{epoch: epoch}
	}
	bucket.sum += value
	bucket.count++
}

func (w *rolloutMetricWindow) observeAggregate(at time.Time, value float64) {
	if value < 0 {
		value = 0
	} else if value > 1 {
		value = 1
	}
	epoch := rolloutEpoch(at)
	bucket := &w.buckets[epoch%rolloutHealthBucketCount]
	*bucket = rolloutMetricBucket{epoch: epoch, sum: value, count: 1}
}

func (w *rolloutMetricWindow) snapshot(now time.Time) RolloutWindowObservation {
	minimum := rolloutEpoch(now) - rolloutHealthBucketCount + 1
	var sum float64
	var count uint64
	for i := range w.buckets {
		bucket := w.buckets[i]
		if bucket.epoch < minimum {
			continue
		}
		sum += bucket.sum
		count += bucket.count
	}
	if count == 0 {
		return RolloutWindowObservation{}
	}
	return RolloutWindowObservation{Observations: int(count), Ratio: sum / float64(count)}
}

func (w *rolloutMetricWindow) reset() {
	*w = rolloutMetricWindow{}
}

type rolloutTrafficBucket struct {
	epoch         int64
	admitted      uint64
	server5xx     uint64
	queueTimeouts uint64
}

type rolloutTrafficWindow struct {
	buckets [rolloutHealthBucketCount]rolloutTrafficBucket
}

func (w *rolloutTrafficWindow) bucket(at time.Time) *rolloutTrafficBucket {
	epoch := rolloutEpoch(at)
	bucket := &w.buckets[epoch%rolloutHealthBucketCount]
	if bucket.epoch != epoch {
		*bucket = rolloutTrafficBucket{epoch: epoch}
	}
	return bucket
}

func (w *rolloutTrafficWindow) snapshot(now time.Time) (server5xx, queue RolloutWindowObservation) {
	minimum := rolloutEpoch(now) - rolloutHealthBucketCount + 1
	var admitted, failures, timeouts uint64
	for i := range w.buckets {
		bucket := w.buckets[i]
		if bucket.epoch < minimum {
			continue
		}
		admitted += bucket.admitted
		failures += bucket.server5xx
		timeouts += bucket.queueTimeouts
	}
	server5xx.Observations = int(admitted)
	queue.Observations = int(admitted)
	if admitted > 0 {
		server5xx.Ratio = float64(failures) / float64(admitted)
		queue.Ratio = float64(timeouts) / float64(admitted)
	}
	return server5xx, queue
}

type rolloutReconnectKey struct {
	identity   string
	generation uint64
}

type rolloutHealthMonitor struct {
	mu sync.Mutex

	hardwareVerification    rolloutMetricWindow
	mdmSaturation           rolloutMetricWindow
	applicationVerification rolloutMetricWindow
	targetedCohort          int
	reconnectCohort         int
	reconnectCrash          rolloutMetricWindow
	networkCapacity         rolloutMetricWindow
	modelCapacity           rolloutMetricWindow
	traffic                 rolloutTrafficWindow
	reconnectSettled        map[rolloutReconnectKey]time.Time
	reconnectLastPruneEpoch int64
	reconnectOverflow       bool

	policyTarget     string
	policyGeneration uint64
	baselineOnline   int
	baselineModels   int
}

func newRolloutHealthMonitor() *rolloutHealthMonitor {
	return &rolloutHealthMonitor{
		reconnectSettled: make(map[rolloutReconnectKey]time.Time),
	}
}

type rolloutRequestHealthState struct {
	admitted      atomic.Bool
	queueRecorded atomic.Bool
}

type rolloutHealthContextKey struct{}

func rolloutHealthState(ctx context.Context) *rolloutRequestHealthState {
	state, _ := ctx.Value(rolloutHealthContextKey{}).(*rolloutRequestHealthState)
	return state
}

func (m *rolloutHealthMonitor) recordDispatchAdmission(ctx context.Context, now time.Time) {
	state := rolloutHealthState(ctx)
	if state == nil || !state.admitted.CompareAndSwap(false, true) {
		return
	}
	m.mu.Lock()
	m.traffic.bucket(now).admitted++
	m.mu.Unlock()
}

func (m *rolloutHealthMonitor) recordDispatchHTTPOutcome(ctx context.Context, status int, now time.Time) {
	state := rolloutHealthState(ctx)
	if state == nil || !state.admitted.Load() || status < 500 {
		return
	}
	m.mu.Lock()
	m.traffic.bucket(now).server5xx++
	m.mu.Unlock()
}

func (m *rolloutHealthMonitor) recordDispatchQueueTimeout(ctx context.Context, now time.Time) {
	state := rolloutHealthState(ctx)
	if state == nil || !state.admitted.Load() ||
		!state.queueRecorded.CompareAndSwap(false, true) {
		return
	}
	m.mu.Lock()
	m.traffic.bucket(now).queueTimeouts++
	m.mu.Unlock()
}

func (m *rolloutHealthMonitor) sampleFleet(server *Server, policy *store.ReleaseRolloutPolicy, now time.Time) {
	providers := server.registry.ListProviders()
	providerByID := make(map[string]registry.ProviderSnapshot, len(providers))
	for _, provider := range providers {
		providerByID[provider.ID] = provider
	}

	type identityState struct {
		hardware, online, modelLoaded, targeted, reconnectRequired, ready bool
	}
	byIdentity := make(map[string]identityState)
	allowedMDM := make(map[string]struct{})
	for _, rollout := range server.registry.ReleaseRolloutProviderSnapshots() {
		identity := rollout.AttestedSEIdentity
		if identity == "" {
			continue
		}
		approvedVersion, _ := registry.ApprovedReleaseVersion(
			*policy, identity, rollout.Version)
		if approvedVersion == "" {
			continue
		}
		state := byIdentity[identity]
		provider := providerByID[rollout.ProviderID]
		state.hardware = state.hardware || rollout.HardwareVerified
		available := rollout.HardwareVerified && rollout.ReleaseApproved &&
			provider.Online &&
			(rollout.ApprovedTargetVersion == "" || rollout.Ready)
		state.online = state.online || available
		state.modelLoaded = state.modelLoaded || (available && provider.ModelLoaded)
		if approvedVersion == policy.TargetVersion {
			state.targeted = true
			state.ready = state.ready ||
				(rollout.HardwareVerified && rollout.ReleaseApproved && rollout.Ready)
			freshTarget := rollout.Version == policy.TargetVersion &&
				rollout.ApprovedTargetVersion == "" &&
				rollout.DesiredGeneration == 0 &&
				rollout.UpdateLifecycleState == protocol.UpdateLifecycleServing
			state.reconnectRequired = state.reconnectRequired || !freshTarget
		}
		byIdentity[identity] = state
		allowedMDM[identity] = struct{}{}
	}

	intended, verified, available, models, targeted, reconnectRequired, ready := 0, 0, 0, 0, 0, 0, 0
	if policy.Stage == store.RolloutStageCanary {
		for _, identity := range policy.CanarySEIdentities {
			state, exists := byIdentity[identity]
			state.targeted = true
			if !exists {
				state.reconnectRequired = true
			}
			byIdentity[identity] = state
			allowedMDM[identity] = struct{}{}
		}
	}
	for _, state := range byIdentity {
		intended++
		if state.hardware {
			verified++
		}
		if state.online {
			available++
		}
		if state.modelLoaded {
			models++
		}
		if state.targeted {
			targeted++
			if state.reconnectRequired {
				reconnectRequired++
			}
			if state.ready {
				ready++
			}
		}
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	if m.policyTarget != policy.TargetVersion {
		m.hardwareVerification.reset()
		m.mdmSaturation.reset()
		m.reconnectCrash.reset()
		m.reconnectSettled = make(map[rolloutReconnectKey]time.Time)
		m.reconnectOverflow = false
		m.applicationVerification.reset()
		m.networkCapacity.reset()
		m.modelCapacity.reset()
		m.policyTarget = policy.TargetVersion
		m.baselineOnline = available
		m.baselineModels = models
	}
	if available > m.baselineOnline {
		m.baselineOnline = available
	}
	if models > m.baselineModels {
		m.baselineModels = models
	}
	m.targetedCohort = targeted
	m.reconnectCohort = reconnectRequired
	if intended > 0 {
		m.hardwareVerification.observeAggregate(now, float64(verified)/float64(intended))
	}
	m.policyGeneration = policy.DesiredGeneration
	if server.mdmScheduler != nil && len(allowedMDM) > 0 {
		m.mdmSaturation.observeAggregate(now, server.mdmScheduler.rolloutSaturation(allowedMDM))
	}
	if targeted > 0 {
		m.applicationVerification.observeAggregate(now, float64(ready)/float64(targeted))
	}
	if m.baselineOnline > 0 {
		m.networkCapacity.observeAggregate(now, float64(available)/float64(m.baselineOnline))
	}
	if m.baselineModels > 0 {
		m.modelCapacity.observeAggregate(now, float64(models)/float64(m.baselineModels))
	}
}

func (m *rolloutHealthMonitor) recordReconnect(identity string, generation uint64, crashed bool, now time.Time) {
	if identity == "" || generation == 0 {
		return
	}
	key := rolloutReconnectKey{identity: identity, generation: generation}
	cutoff := now.Add(-rolloutHealthBucketWidth * rolloutHealthBucketCount)
	m.mu.Lock()
	defer m.mu.Unlock()
	if generation != m.policyGeneration {
		return
	}
	if settledAt, exists := m.reconnectSettled[key]; exists && !settledAt.Before(cutoff) {
		return
	}
	currentEpoch := rolloutEpoch(now)
	if currentEpoch != m.reconnectLastPruneEpoch {
		for candidate, settledAt := range m.reconnectSettled {
			if settledAt.Before(cutoff) {
				delete(m.reconnectSettled, candidate)
			}
		}
		m.reconnectLastPruneEpoch = currentEpoch
	}
	if len(m.reconnectSettled) >= rolloutReconnectMaxKeys {
		m.reconnectOverflow = true
		// Never evict a live key: repeated Ready heartbeats must not mint fresh
		// successes when the bounded table reaches capacity.
		return
	}
	m.reconnectSettled[key] = now
	value := 0.0
	if crashed {
		value = 1
	}
	m.reconnectCrash.observe(now, value)
}

func (m *rolloutHealthMonitor) recordProviderDisconnectState(
	identity string, generation uint64, state string, now time.Time,
) {
	crashed := generation != 0 &&
		(state == protocol.UpdateLifecycleReconnecting ||
			state == protocol.UpdateLifecycleApplicationVerifying ||
			state == protocol.UpdateLifecycleModelReloading)
	if crashed {
		m.recordReconnect(identity, generation, true, now)
	}
}

func (m *rolloutHealthMonitor) recordProviderReady(server *Server, provider *registry.Provider, now time.Time) {
	if provider == nil {
		return
	}
	identity, valid := server.registry.CanonicalSEIdentityForRollout(provider.ID)
	if !valid {
		return
	}
	provider.Mu().Lock()
	generation := provider.UpdateDesiredGeneration
	ready := provider.UpdateLifecycleState == protocol.UpdateLifecycleReady
	provider.Mu().Unlock()
	if ready {
		m.recordReconnect(identity, generation, false, now)
	}
}

func (m *rolloutHealthMonitor) snapshot(now time.Time) RolloutHealthObservations {
	m.mu.Lock()
	defer m.mu.Unlock()
	server5xx, queue := m.traffic.snapshot(now)
	return RolloutHealthObservations{
		HardwareVerification:    m.hardwareVerification.snapshot(now),
		MDMSaturation:           m.mdmSaturation.snapshot(now),
		ReconnectOverflow:       m.reconnectOverflow,
		ApplicationVerification: m.applicationVerification.snapshot(now),
		ReconnectCrash:          m.reconnectCrash.snapshot(now),
		NetworkCapacity:         m.networkCapacity.snapshot(now),
		TargetedCohort:          m.targetedCohort,
		ReconnectCohort:         m.reconnectCohort,
		ModelCapacity:           m.modelCapacity.snapshot(now),
		Server5xx:               server5xx, QueueTimeout: queue,
	}
}

// StartReleaseRolloutHealthLoop samples live server-owned windows and performs
// CAS-protected automatic pauses. It never promotes.
func (s *Server) StartReleaseRolloutHealthLoop(ctx context.Context) {
	ticker := time.NewTicker(rolloutHealthBucketWidth)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			s.evaluateLiveReleaseRollout(now)
		}
	}
}

func (s *Server) evaluateLiveReleaseRollout(now time.Time) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	policy, err := s.store.GetReleaseRollout(ctx, defaultReleasePlatform)
	if err != nil || policy.Paused {
		return
	}
	if dispatchErr := s.dispatchApprovedReleaseUpdates(policy); dispatchErr != nil {
		var providerError *rolloutDispatchProviderError
		if !errors.As(dispatchErr, &providerError) {
			s.logger.Warn("rollout: background reconcile failed", "error", dispatchErr)
			return
		}
		s.logger.Warn("rollout: provider dispatch failed; evaluating health", "error", dispatchErr)
	}
	s.rolloutDispatchMu.Lock()
	latest, readErr := s.store.GetReleaseRollout(ctx, policy.Platform)
	if readErr != nil || latest.Revision != policy.Revision ||
		latest.TargetVersion != policy.TargetVersion ||
		latest.DesiredGeneration != policy.DesiredGeneration {
		s.rolloutDispatchMu.Unlock()
		return
	}
	// Sampling is inside the same short mutation boundary as the revision
	// check, so an old target can never reset a newly committed target's window.
	s.rolloutHealth.sampleFleet(s, policy, now)
	s.rolloutDispatchMu.Unlock()
	observations := s.rolloutHealth.snapshot(now)
	evaluation := EvaluateRolloutHealth(policy, observations, rolloutThresholdsFromEnvironment())
	if evaluation.Healthy || evaluation.PauseReason == "" {
		return
	}
	_, err = s.transitionReleaseRolloutSerialized(ctx, store.ReleaseRolloutTransitionRequest{
		Platform: policy.Platform, ExpectedRevision: policy.Revision,
		Action: "automatic_pause", Reason: evaluation.PauseReason, Actor: "system",
	})
	if err != nil && !errors.Is(err, store.ErrRolloutConflict) {
		s.logger.Error("rollout: automatic pause failed", "reason", evaluation.PauseReason, "error", err)
	}
}
