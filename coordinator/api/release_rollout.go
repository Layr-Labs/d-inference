package api

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	RolloutPauseHardwareVerificationRatio    = "hardware_verification_ratio"
	RolloutPauseMDMSaturation                = "mdm_saturation"
	RolloutPauseApplicationVerificationRatio = "application_verification_ratio"
	RolloutPauseReconnectCrashRate           = "reconnect_crash_rate"
	RolloutPauseNetworkCapacityFloor         = "network_capacity_floor"
	RolloutPauseModelCapacityFloor           = "model_capacity_floor"
	RolloutPauseServer5xxRate                = "server_5xx_rate"
	RolloutPauseQueueTimeoutRate             = "queue_timeout_rate"
)

var automaticRolloutPauseReasons = map[string]struct{}{
	RolloutPauseHardwareVerificationRatio: {}, RolloutPauseMDMSaturation: {},
	RolloutPauseApplicationVerificationRatio: {}, RolloutPauseReconnectCrashRate: {},
	RolloutPauseNetworkCapacityFloor: {}, RolloutPauseModelCapacityFloor: {},
	RolloutPauseServer5xxRate: {}, RolloutPauseQueueTimeoutRate: {},
}

type RolloutWindowObservation struct {
	Observations int     `json:"observations"`
	Ratio        float64 `json:"ratio"`
}

type RolloutHealthObservations struct {
	HardwareVerification    RolloutWindowObservation `json:"hardware_verification"`
	MDMSaturation           RolloutWindowObservation `json:"mdm_saturation"`
	ApplicationVerification RolloutWindowObservation `json:"application_verification"`
	ReconnectCrash          RolloutWindowObservation `json:"reconnect_crash"`
	NetworkCapacity         RolloutWindowObservation `json:"network_capacity"`
	ModelCapacity           RolloutWindowObservation `json:"model_capacity"`
	Server5xx               RolloutWindowObservation `json:"server_5xx"`
	ReconnectOverflow       bool                     `json:"reconnect_overflow"`
	ReconnectCohort         int                      `json:"reconnect_cohort"`
	TargetedCohort          int                      `json:"targeted_cohort"`
	QueueTimeout            RolloutWindowObservation `json:"queue_timeout"`
}

type RolloutHealthThresholds struct {
	MinObservations                 int
	MinHardwareVerificationRatio    float64
	MaxMDMSaturation                float64
	MinApplicationVerificationRatio float64
	MaxReconnectCrashRate           float64
	MinNetworkCapacityRatio         float64
	MinModelCapacityRatio           float64
	MaxServer5xxRate                float64
	MaxQueueTimeoutRate             float64
}

func defaultRolloutHealthThresholds() RolloutHealthThresholds {
	return RolloutHealthThresholds{
		MinObservations: 20, MinHardwareVerificationRatio: 0.98,
		MaxMDMSaturation: 0.85, MinApplicationVerificationRatio: 0.95,
		MaxReconnectCrashRate: 0.05, MinNetworkCapacityRatio: 0.80,
		MinModelCapacityRatio: 0.80, MaxServer5xxRate: 0.02,
		MaxQueueTimeoutRate: 0.02,
	}
}

func rolloutThresholdsFromEnvironment() RolloutHealthThresholds {
	thresholds := defaultRolloutHealthThresholds()
	readFloat := func(name string, destination *float64) {
		if value, err := strconv.ParseFloat(strings.TrimSpace(os.Getenv(name)), 64); err == nil && value >= 0 && value <= 1 {
			*destination = value
		}
	}
	if value, err := strconv.Atoi(strings.TrimSpace(os.Getenv("EIGENINFERENCE_ROLLOUT_MIN_OBSERVATIONS"))); err == nil && value > 0 {
		thresholds.MinObservations = value
	}
	readFloat("EIGENINFERENCE_ROLLOUT_MIN_HARDWARE_VERIFICATION_RATIO", &thresholds.MinHardwareVerificationRatio)
	readFloat("EIGENINFERENCE_ROLLOUT_MAX_MDM_SATURATION", &thresholds.MaxMDMSaturation)
	readFloat("EIGENINFERENCE_ROLLOUT_MIN_APPLICATION_VERIFICATION_RATIO", &thresholds.MinApplicationVerificationRatio)
	readFloat("EIGENINFERENCE_ROLLOUT_MAX_RECONNECT_CRASH_RATE", &thresholds.MaxReconnectCrashRate)
	readFloat("EIGENINFERENCE_ROLLOUT_MIN_NETWORK_CAPACITY_RATIO", &thresholds.MinNetworkCapacityRatio)
	readFloat("EIGENINFERENCE_ROLLOUT_MIN_MODEL_CAPACITY_RATIO", &thresholds.MinModelCapacityRatio)
	readFloat("EIGENINFERENCE_ROLLOUT_MAX_SERVER_5XX_RATE", &thresholds.MaxServer5xxRate)
	readFloat("EIGENINFERENCE_ROLLOUT_MAX_QUEUE_TIMEOUT_RATE", &thresholds.MaxQueueTimeoutRate)
	return thresholds
}

type RolloutHealthEvaluation struct {
	Sufficient  bool   `json:"sufficient"`
	Healthy     bool   `json:"healthy"`
	PauseReason string `json:"pause_reason,omitempty"`
}

// EvaluateRolloutHealth applies the eight fixed low-cardinality health gates.
// Any sufficiently-observed breach pauses immediately. Promotion requires every
// window to meet its observation floor. An existing explicit pause is returned
// before telemetry and can never be hidden by a healthy or sparse window.
func EvaluateRolloutHealth(policy *store.ReleaseRolloutPolicy, observations RolloutHealthObservations, thresholds RolloutHealthThresholds) RolloutHealthEvaluation {
	if policy != nil && policy.Paused {
		return RolloutHealthEvaluation{Sufficient: true, Healthy: false, PauseReason: policy.PauseReason}
	}
	if observations.ReconnectOverflow {
		return RolloutHealthEvaluation{
			Sufficient: true, Healthy: false,
			PauseReason: RolloutPauseReconnectCrashRate,
		}
	}
	type gate struct {
		observation RolloutWindowObservation
		reason      string
		minimum     int
		breached    func(float64) bool
	}
	reconnectMinimum := thresholds.MinObservations
	reconnectObservation := observations.ReconnectCrash
	if observations.ReconnectCohort == 0 {
		reconnectObservation = RolloutWindowObservation{
			Observations: thresholds.MinObservations, Ratio: 0,
		}
	} else if observations.ReconnectCohort < reconnectMinimum {
		reconnectMinimum = observations.ReconnectCohort
	}
	gates := []gate{
		{observations.HardwareVerification, RolloutPauseHardwareVerificationRatio, thresholds.MinObservations, func(v float64) bool { return v < thresholds.MinHardwareVerificationRatio }},
		{observations.MDMSaturation, RolloutPauseMDMSaturation, thresholds.MinObservations, func(v float64) bool { return v > thresholds.MaxMDMSaturation }},
		{observations.ApplicationVerification, RolloutPauseApplicationVerificationRatio, thresholds.MinObservations, func(v float64) bool { return v < thresholds.MinApplicationVerificationRatio }},
		{reconnectObservation, RolloutPauseReconnectCrashRate, reconnectMinimum, func(v float64) bool { return v > thresholds.MaxReconnectCrashRate }},
		{observations.NetworkCapacity, RolloutPauseNetworkCapacityFloor, thresholds.MinObservations, func(v float64) bool { return v < thresholds.MinNetworkCapacityRatio }},
		{observations.ModelCapacity, RolloutPauseModelCapacityFloor, thresholds.MinObservations, func(v float64) bool { return v < thresholds.MinModelCapacityRatio }},
		{observations.Server5xx, RolloutPauseServer5xxRate, thresholds.MinObservations, func(v float64) bool { return v > thresholds.MaxServer5xxRate }},
		{observations.QueueTimeout, RolloutPauseQueueTimeoutRate, thresholds.MinObservations, func(v float64) bool { return v > thresholds.MaxQueueTimeoutRate }},
	}
	sufficient := true
	for _, gate := range gates {
		if gate.observation.Observations < gate.minimum {
			sufficient = false
			continue
		}
		if gate.breached(gate.observation.Ratio) {
			return RolloutHealthEvaluation{Sufficient: true, Healthy: false, PauseReason: gate.reason}
		}
	}
	return RolloutHealthEvaluation{Sufficient: sufficient, Healthy: sufficient}
}

type rolloutMutationRequest struct {
	Platform           string             `json:"platform"`
	TargetVersion      string             `json:"target_version,omitempty"`
	Stage              store.RolloutStage `json:"stage,omitempty"`
	CanarySEIdentities []string           `json:"canary_se_identities,omitempty"`
	ExpectedRevision   uint64             `json:"expected_revision"`
	Reason             string             `json:"reason,omitempty"`
}

func requireDefaultRolloutPlatform(w http.ResponseWriter, platform string) bool {
	if platform == defaultReleasePlatform {
		return true
	}
	writeJSON(w, http.StatusBadRequest, errorResponse(
		"unsupported_rollout_platform",
		"provider rollout is supported only for "+defaultReleasePlatform))
	return false
}

func (s *Server) handleAdminReleaseRolloutRead(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	platform := strings.TrimSpace(r.URL.Query().Get("platform"))
	if platform == "" {
		platform = defaultReleasePlatform
	}
	if !requireDefaultRolloutPlatform(w, platform) {
		return
	}
	policy, err := s.store.GetReleaseRollout(r.Context(), platform)
	if err != nil {
		if errors.Is(err, store.ErrRolloutNotFound) {
			writeJSON(w, http.StatusNotFound, errorResponse("not_found", "release rollout not found"))
			return
		}
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("store_unavailable", "failed to read release rollout"))
		return
	}
	transitions, err := s.store.ListReleaseRolloutTransitions(r.Context(), platform)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("store_unavailable", "failed to read rollout audit"))
		return
	}

	observations := s.liveRolloutHealthObservations()
	writeJSON(w, http.StatusOK, map[string]any{
		"policy": policy, "transitions": transitions,
		"providers":           s.registry.ReleaseRolloutProviderSnapshots(),
		"health_observations": observations,
		"health":              EvaluateRolloutHealth(policy, observations, rolloutThresholdsFromEnvironment()),
	})
}

func (s *Server) cancelRolloutDispatchLocked() {
	if s.rolloutDispatchCancel == nil {
		return
	}
	s.rolloutDispatchCancel()
	done := s.rolloutDispatchDone
	s.rolloutDispatchCancel = nil
	s.rolloutDispatchDone = nil
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	select {
	case <-done:
	case <-timer.C:
	}
}
func (s *Server) startReleaseRolloutSerialized(
	ctx context.Context, request store.StartReleaseRolloutRequest,
) (*store.ReleaseRolloutPolicy, error) {
	s.rolloutDispatchMu.Lock()
	s.cancelRolloutDispatchLocked()
	defer s.rolloutDispatchMu.Unlock()
	return s.store.StartReleaseRollout(ctx, request)
}

func (s *Server) transitionReleaseRolloutSerialized(
	ctx context.Context, request store.ReleaseRolloutTransitionRequest,
) (*store.ReleaseRolloutPolicy, error) {
	s.rolloutDispatchMu.Lock()
	s.cancelRolloutDispatchLocked()
	defer s.rolloutDispatchMu.Unlock()
	return s.store.TransitionReleaseRollout(ctx, request)
}

func (s *Server) handleAdminReleaseRolloutPromote(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	var request rolloutMutationRequest
	if !decodeCappedJSON(w, r, maxReleaseRegisterBodyBytes, &request) {
		return
	}
	if request.Platform == "" {
		request.Platform = defaultReleasePlatform
	}
	if !requireDefaultRolloutPlatform(w, request.Platform) {
		return
	}
	var policy *store.ReleaseRolloutPolicy
	var err error
	if request.TargetVersion != "" {
		policy, err = s.startReleaseRolloutSerialized(r.Context(), store.StartReleaseRolloutRequest{
			Platform: request.Platform, TargetVersion: request.TargetVersion,
			CanarySEIdentities: request.CanarySEIdentities,
			ExpectedRevision:   request.ExpectedRevision, Actor: "admin",
		})
	} else {
		observations := s.liveRolloutHealthObservations()
		current, readErr := s.store.GetReleaseRollout(r.Context(), request.Platform)
		if readErr != nil {
			s.writeRolloutError(w, readErr)
			return
		}
		evaluation := EvaluateRolloutHealth(current, observations, rolloutThresholdsFromEnvironment())
		if !evaluation.Sufficient || !evaluation.Healthy {
			response := errorResponse("rollout_health_gate", "rollout health does not permit promotion")
			response["health"] = evaluation
			writeJSON(w, http.StatusConflict, response)
			return
		}
		policy, err = s.transitionReleaseRolloutSerialized(r.Context(), store.ReleaseRolloutTransitionRequest{
			Platform: request.Platform, ExpectedRevision: request.ExpectedRevision,
			Action: "promote", Stage: request.Stage, Actor: "admin",
		})
	}
	if err != nil {
		s.writeRolloutError(w, err)
		return
	}
	if err := s.dispatchApprovedReleaseUpdates(policy); err != nil {
		writeJSON(w, http.StatusServiceUnavailable,
			errorResponse("rollout_dispatch_failed", "rollout committed but live dispatch failed"))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"policy": policy})
}

func (s *Server) handleAdminReleaseRolloutPause(w http.ResponseWriter, r *http.Request) {
	s.handleAdminReleaseRolloutPauseAction(w, r, "pause")
}

func (s *Server) handleAdminReleaseRolloutEvaluate(w http.ResponseWriter, r *http.Request) {
	s.handleAdminReleaseRolloutPauseAction(w, r, "automatic_pause")
}

func (s *Server) handleAdminReleaseRolloutPauseAction(w http.ResponseWriter, r *http.Request, action string) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	var request rolloutMutationRequest
	if !decodeCappedJSON(w, r, maxReleaseRegisterBodyBytes, &request) {
		return
	}
	if request.Platform == "" {
		request.Platform = defaultReleasePlatform
	}
	if !requireDefaultRolloutPlatform(w, request.Platform) {
		return
	}
	if action == "automatic_pause" {
		observations := s.liveRolloutHealthObservations()
		current, err := s.store.GetReleaseRollout(r.Context(), request.Platform)
		if err != nil {
			s.writeRolloutError(w, err)
			return
		}
		if current.Paused {
			evaluation := EvaluateRolloutHealth(current, observations, rolloutThresholdsFromEnvironment())
			writeJSON(w, http.StatusOK, map[string]any{"policy": current, "health": evaluation})
			return
		}
		evaluation := EvaluateRolloutHealth(current, observations, rolloutThresholdsFromEnvironment())
		if evaluation.Healthy || evaluation.PauseReason == "" {
			writeJSON(w, http.StatusOK, map[string]any{"policy": current, "health": evaluation})
			return
		}
		request.ExpectedRevision = current.Revision
		request.Reason = evaluation.PauseReason
	}
	if strings.TrimSpace(request.Reason) == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "reason is required"))
		return
	}
	if action == "automatic_pause" {
		if _, ok := automaticRolloutPauseReasons[request.Reason]; !ok {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid automatic pause reason"))
			return
		}
	}
	policy, err := s.transitionReleaseRolloutSerialized(r.Context(), store.ReleaseRolloutTransitionRequest{
		Platform: request.Platform, ExpectedRevision: request.ExpectedRevision,
		Action: action, Reason: request.Reason, Actor: map[bool]string{true: "system", false: "admin"}[action == "automatic_pause"],
	})
	if err != nil {
		s.writeRolloutError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"policy": policy})
}

func (s *Server) liveRolloutHealthObservations() RolloutHealthObservations {
	if s.rolloutHealth == nil {
		return RolloutHealthObservations{}
	}
	return s.rolloutHealth.snapshot(time.Now())
}

func (s *Server) handleAdminReleaseRolloutResume(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	var request rolloutMutationRequest
	if !decodeCappedJSON(w, r, maxReleaseRegisterBodyBytes, &request) {
		return
	}
	if request.Platform == "" {
		request.Platform = defaultReleasePlatform
	}
	if !requireDefaultRolloutPlatform(w, request.Platform) {
		return
	}
	policy, err := s.transitionReleaseRolloutSerialized(r.Context(), store.ReleaseRolloutTransitionRequest{
		Platform: request.Platform, ExpectedRevision: request.ExpectedRevision,
		Action: "resume", Actor: "admin",
	})
	if err != nil {
		s.writeRolloutError(w, err)
		return
	}
	if err := s.dispatchApprovedReleaseUpdates(policy); err != nil {
		writeJSON(w, http.StatusServiceUnavailable,
			errorResponse("rollout_dispatch_failed", "rollout resumed but live dispatch failed"))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"policy": policy})
}

func (s *Server) writeRolloutError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrRolloutConflict):
		writeJSON(w, http.StatusConflict, errorResponse("revision_conflict", err.Error()))
	case errors.Is(err, store.ErrRolloutNotFound):
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", err.Error()))
	case errors.Is(err, store.ErrRolloutInvalid):
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_transition", err.Error()))
	default:
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("store_unavailable", "release rollout operation failed"))
	}
}

func (s *Server) failClosedLifecycleRolloutProviders() {
	for _, provider := range s.registry.ReleaseRolloutProviderSnapshots() {
		if provider.LifecycleReported {
			s.registry.SetProviderReleaseApproval(provider.ProviderID, false)
		}
	}
}

type rolloutDispatchProviderError struct {
	err error
}

func (e *rolloutDispatchProviderError) Error() string { return e.err.Error() }
func (e *rolloutDispatchProviderError) Unwrap() error { return e.err }

func (s *Server) dispatchApprovedReleaseUpdates(policy *store.ReleaseRolloutPolicy) error {
	if policy == nil || policy.Paused {
		return nil
	}
	preflightCtx, preflightCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer preflightCancel()
	s.rolloutDispatchMu.Lock()
	s.cancelRolloutDispatchLocked()
	current, err := s.store.GetReleaseRollout(preflightCtx, policy.Platform)
	if err != nil {
		s.failClosedLifecycleRolloutProviders()
		s.rolloutDispatchMu.Unlock()
		return fmt.Errorf("read current rollout before dispatch: %w", err)
	}
	if current.Revision != policy.Revision ||
		current.TargetVersion != policy.TargetVersion ||
		current.DesiredGeneration != policy.DesiredGeneration {
		s.rolloutDispatchMu.Unlock()
		return store.ErrRolloutConflict
	}
	releases, err := s.store.ListReleasesWithError()
	if err != nil {
		s.failClosedLifecycleRolloutProviders()
		s.rolloutDispatchMu.Unlock()
		return fmt.Errorf("read target release inventory: %w", err)
	}
	var target *store.Release
	for i := range releases {
		if releases[i].Active && releases[i].Platform == policy.Platform &&
			releases[i].Version == policy.TargetVersion {
			copy := releases[i]
			target = &copy
			break
		}
	}
	if target == nil {
		s.failClosedLifecycleRolloutProviders()
		s.rolloutDispatchMu.Unlock()
		return fmt.Errorf("active target release %s/%s disappeared",
			policy.Platform, policy.TargetVersion)
	}
	for _, provider := range s.registry.ReleaseRolloutProviderSnapshots() {
		approved, _ := registry.ApprovedReleaseVersion(
			*policy, provider.CanonicalSEIdentity, provider.Version)
		s.registry.SetProviderReleaseApproval(provider.ProviderID, approved != "")
	}
	if s.rolloutHealth != nil {
		s.rolloutHealth.sampleFleet(s, policy, time.Now())
	}
	var firstError error
	tasks := make([]string, 0)
	for _, provider := range s.registry.ReleaseRolloutProviderSnapshots() {
		approved, command := registry.ApprovedReleaseVersion(
			*policy, provider.CanonicalSEIdentity, provider.Version)
		s.registry.SetProviderReleaseApproval(provider.ProviderID, approved != "")
		if approved != target.Version || !provider.LifecycleReported {
			continue
		}
		if !command {
			if provider.ApprovedTargetVersion == "" &&
				provider.DesiredGeneration == 0 &&
				provider.UpdateLifecycleState == protocol.UpdateLifecycleServing {
				continue
			}
			if (provider.ApprovedTargetVersion != target.Version ||
				provider.DesiredGeneration != policy.DesiredGeneration) &&
				!s.registry.BindProviderReleaseReconnect(
					provider.ProviderID, target.Version, policy.DesiredGeneration) {
				s.registry.SetProviderReleaseApproval(provider.ProviderID, false)
				if firstError == nil {
					firstError = fmt.Errorf("bind current-target provider %s", provider.ProviderID)
				}
			}
			continue
		}
		if provider.ApprovedTargetVersion == target.Version &&
			provider.DesiredGeneration == policy.DesiredGeneration {
			continue
		}
		tasks = append(tasks, provider.ProviderID)
	}
	dispatchCtx, dispatchCancel := context.WithCancel(context.Background())
	dispatchDone := make(chan struct{})
	s.rolloutDispatchCancel = dispatchCancel
	s.rolloutDispatchDone = dispatchDone
	s.rolloutDispatchMu.Unlock()

	const concurrentReleaseWrites = 8
	semaphore := make(chan struct{}, concurrentReleaseWrites)
	var wait sync.WaitGroup
	var errorMu sync.Mutex
	var staleError error
	for _, providerID := range tasks {
		providerID := providerID
		wait.Add(1)
		go func() {
			defer wait.Done()
			select {
			case semaphore <- struct{}{}:
			case <-dispatchCtx.Done():
				return
			}
			defer func() { <-semaphore }()
			checkCtx, checkCancel := context.WithTimeout(dispatchCtx, 5*time.Second)
			latest, readErr := s.store.GetReleaseRollout(checkCtx, policy.Platform)
			checkCancel()
			if readErr != nil || latest.Paused ||
				latest.Revision != policy.Revision ||
				latest.TargetVersion != policy.TargetVersion ||
				latest.DesiredGeneration != policy.DesiredGeneration {
				if readErr == nil {
					readErr = store.ErrRolloutConflict
				}
				errorMu.Lock()
				if staleError == nil {
					staleError = readErr
				}
				errorMu.Unlock()
				return
			}
			sendCtx, sendCancel := context.WithTimeout(dispatchCtx, 5*time.Second)
			sendErr := s.registry.SendReleaseUpdateContext(
				sendCtx, providerID, *target, policy.DesiredGeneration)
			sendCancel()
			if sendErr != nil {
				if errors.Is(sendErr, context.Canceled) ||
					errors.Is(sendErr, context.DeadlineExceeded) {
					errorMu.Lock()
					if staleError == nil {
						staleError = sendErr
					}
					errorMu.Unlock()
					return
				}
				s.registry.SetProviderReleaseApproval(providerID, false)
				errorMu.Lock()
				if firstError == nil {
					firstError = fmt.Errorf("send release update to %s: %w", providerID, sendErr)
				}
				errorMu.Unlock()
			}
		}()
	}
	wait.Wait()
	close(dispatchDone)
	dispatchCancel()
	s.rolloutDispatchMu.Lock()
	if s.rolloutDispatchDone == dispatchDone {
		s.rolloutDispatchCancel = nil
		s.rolloutDispatchDone = nil
	}
	s.rolloutDispatchMu.Unlock()
	if staleError != nil {
		return staleError
	}
	if firstError != nil {
		return &rolloutDispatchProviderError{err: firstError}
	}
	return nil
}
func (s *Server) reconcileConnectedProviderReleaseRollout(providerID string) {
	provider := s.registry.GetProvider(providerID)
	if provider == nil {
		return
	}
	provider.Mu().Lock()
	reported := provider.UpdateLifecycleReported
	state := provider.UpdateLifecycleState
	warm := provider.WarmIntent
	version := provider.Version
	provider.Mu().Unlock()
	if !reported {
		return
	}
	s.reconcileProviderReleaseRollout(providerID, provider, &protocol.RegisterMessage{
		Version: version, UpdateLifecycleState: &state, WarmIntent: &warm,
	})
}

func (s *Server) reconcileProviderReleaseRollout(
	providerID string,
	provider *registry.Provider,
	register *protocol.RegisterMessage,
) {
	if register.UpdateLifecycleState == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	policy, err := s.store.GetReleaseRollout(ctx, defaultReleasePlatform)
	if err != nil {
		if !errors.Is(err, store.ErrRolloutNotFound) {
			s.registry.SetProviderReleaseApproval(providerID, false)
		}
		return
	}
	identity, validIdentity := s.registry.CanonicalSEIdentityForRollout(providerID)
	if !validIdentity {
		// v1 fails closed unless cohort selection is backed by a live,
		// attestation-matched Secure-Enclave device lease.
		s.registry.SetProviderReleaseApproval(providerID, false)
		return
	}
	approved, _ := registry.ApprovedReleaseVersion(
		*policy, identity, register.Version)
	s.registry.SetProviderReleaseApproval(providerID, approved != "")
	if policy.Paused {
		return
	}
	if approved != policy.TargetVersion {
		return
	}
	if err := s.dispatchApprovedReleaseUpdates(policy); err != nil &&
		!errors.Is(err, store.ErrRolloutConflict) &&
		!errors.Is(err, context.Canceled) {
		s.logger.Warn("rollout: provider-triggered reconcile failed",
			"provider_id", providerID, "error", err)
	}
}
