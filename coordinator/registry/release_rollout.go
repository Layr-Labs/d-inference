package registry

import (
	"context"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/semverutil"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// ReleaseCohortMember deterministically maps a canonical Secure-Enclave
// identity to the frozen rollout stages. Provider/session/account identifiers
// are intentionally absent from this function's input.
func ReleaseCohortMember(canonicalSEIdentity string, stage store.RolloutStage, canaries []string) bool {
	if canonicalSEIdentity == "" {
		return false
	}
	for _, identity := range canaries {
		if identity == canonicalSEIdentity {
			return true
		}
	}
	if stage == store.RolloutStageCanary {
		return false
	}
	percent, ok := store.RolloutStagePercent(stage)
	if !ok {
		return false
	}
	if percent == 100 {
		return true
	}
	digest := sha256.Sum256([]byte(canonicalSEIdentity))
	bucket := binary.BigEndian.Uint64(digest[:8]) % 10_000
	return bucket < uint64(percent*100)
}

func lifecycleStateValue(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

func cloneWarmIntent(value *protocol.WarmIntent) protocol.WarmIntent {
	if value == nil {
		return protocol.WarmIntent{}
	}
	return *value
}

func validUpdateLifecycleState(state string) bool {
	switch state {
	case protocol.UpdateLifecycleServing,
		protocol.UpdateLifecycleDrainingForUpdate,
		protocol.UpdateLifecycleInstalling,
		protocol.UpdateLifecycleReconnecting,
		protocol.UpdateLifecycleApplicationVerifying,
		protocol.UpdateLifecycleModelReloading,
		protocol.UpdateLifecycleReady,
		protocol.UpdateLifecycleBlocked:
		return true
	default:
		return false
	}
}

func lifecycleStep(state string) uint8 {
	switch state {
	case protocol.UpdateLifecycleServing:
		return 0
	case protocol.UpdateLifecycleDrainingForUpdate:
		return 1
	case protocol.UpdateLifecycleInstalling:
		return 2
	case protocol.UpdateLifecycleReconnecting:
		return 3
	case protocol.UpdateLifecycleApplicationVerifying:
		return 4
	case protocol.UpdateLifecycleModelReloading:
		return 5
	case protocol.UpdateLifecycleReady:
		return 6
	default:
		return 0
	}
}

func (p *Provider) beginReleaseUpdateLocked(targetVersion string, desiredGeneration uint64) bool {
	if !p.UpdateLifecycleReported || targetVersion == "" || desiredGeneration == 0 {
		return false
	}
	if p.UpdateDesiredGeneration != 0 {
		if desiredGeneration < p.UpdateDesiredGeneration {
			return false
		}
		if desiredGeneration == p.UpdateDesiredGeneration {
			return p.UpdateTargetVersion == targetVersion
		}
		if p.UpdateTargetVersion == targetVersion {
			return false
		}
		if p.UpdateLifecycleState != protocol.UpdateLifecycleReady &&
			p.UpdateLifecycleState != protocol.UpdateLifecycleBlocked {
			return false
		}
	}
	p.UpdateTargetVersion = targetVersion
	p.UpdateDesiredGeneration = desiredGeneration
	p.updateApplicationEvidenceBase = p.ApplicationEvidence.EvidenceGeneration
	if p.Version == targetVersion {
		p.updateLifecycleStep = 2
		p.UpdateLifecycleState = protocol.UpdateLifecycleReconnecting
	} else {
		p.updateLifecycleStep = 0
		p.UpdateLifecycleState = protocol.UpdateLifecycleServing
	}
	return true
}

// BeginReleaseUpdate binds a v1 provider to the coordinator-approved target and
// generation without writing the network.
func (p *Provider) BeginReleaseUpdate(targetVersion string, desiredGeneration uint64) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.beginReleaseUpdateLocked(targetVersion, desiredGeneration)
}

func (p *Provider) applyUpdateLifecycleReportLocked(state *string, warm *protocol.WarmIntent) bool {
	if state == nil {
		return !p.UpdateLifecycleReported
	}
	p.UpdateLifecycleReported = true
	reported := *state
	if !validUpdateLifecycleState(reported) {
		p.UpdateLifecycleState = protocol.UpdateLifecycleBlocked
		return false
	}
	if p.UpdateDesiredGeneration == 0 {
		if warm != nil {
			p.WarmIntent = *warm
		} else {
			p.WarmIntent = protocol.WarmIntent{}
		}
		if reported == protocol.UpdateLifecycleServing || reported == protocol.UpdateLifecycleReady {
			p.UpdateLifecycleState = reported
			return true
		}
		return false
	}
	if warm == nil {
		// A generation-bound provider with no warm slots legitimately omits the
		// optional object; the coordinator-owned binding supplies generation.
		p.WarmIntent = protocol.WarmIntent{}
	} else {
		if warm.DesiredGeneration != p.UpdateDesiredGeneration {
			return false
		}
		p.WarmIntent = *warm
	}
	if reported == protocol.UpdateLifecycleBlocked {
		p.UpdateLifecycleState = reported
		return true
	}
	nextStep := lifecycleStep(reported)
	if nextStep != p.updateLifecycleStep+1 {
		return false
	}
	if reported == protocol.UpdateLifecycleModelReloading &&
		(p.ApplicationEvidence.EvidenceGeneration <= p.updateApplicationEvidenceBase ||
			p.ApplicationEvidence.Version != p.UpdateTargetVersion) {
		return false
	}
	p.updateLifecycleStep = nextStep
	p.UpdateLifecycleState = reported
	return true
}

// ApplyUpdateLifecycleReport is the lock-safe test/control-plane seam.
func (p *Provider) ApplyUpdateLifecycleReport(state *string, warm *protocol.WarmIntent) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.applyUpdateLifecycleReportLocked(state, warm)
}

func (p *Provider) ReleaseUpdateReadyLocked() bool {
	if !p.UpdateLifecycleReported {
		return true
	}
	if p.UpdateTargetVersion == "" {
		return p.UpdateLifecycleState == protocol.UpdateLifecycleServing ||
			p.UpdateLifecycleState == protocol.UpdateLifecycleReady
	}
	return p.Version == p.UpdateTargetVersion &&
		p.UpdateLifecycleState == protocol.UpdateLifecycleReady &&
		p.updateLifecycleStep == lifecycleStep(protocol.UpdateLifecycleReady) &&
		p.ApplicationEvidence.EvidenceGeneration > p.updateApplicationEvidenceBase &&
		p.ApplicationEvidence.Version == p.UpdateTargetVersion
}

// BindProviderReleaseReconnect attaches a current-target connection to the
// existing target intent without emitting a redundant install command. It is
// used when a provider reconnected while the rollout was paused.
func (r *Registry) BindProviderReleaseReconnect(providerID, targetVersion string, desiredGeneration uint64) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	provider := r.providers[providerID]
	if provider == nil || targetVersion == "" || desiredGeneration == 0 {
		return false
	}
	provider.mu.Lock()
	defer provider.mu.Unlock()
	if provider.Status == StatusOffline || provider.Status == StatusUntrusted ||
		!provider.RolloutApprovalRequired || !provider.RolloutReleaseApproved {
		return false
	}
	if _, valid := providerRolloutHardwareIdentityLocked(provider, time.Now()); !valid {
		return false
	}
	if !provider.UpdateLifecycleReported || provider.Version != targetVersion {
		return false
	}
	if provider.UpdateTargetVersion != "" || provider.UpdateDesiredGeneration != 0 {
		return provider.UpdateTargetVersion == targetVersion &&
			desiredGeneration == provider.UpdateDesiredGeneration
	}
	state := provider.UpdateLifecycleState
	step := lifecycleStep(state)
	if state == protocol.UpdateLifecycleServing ||
		state == protocol.UpdateLifecycleDrainingForUpdate ||
		state == protocol.UpdateLifecycleInstalling {
		return false
	}
	evidence := provider.ApplicationEvidence
	currentEvidence := evidence.EvidenceGeneration != 0 &&
		evidence.Version == targetVersion
	if provider.WarmIntent.DesiredGeneration != 0 &&
		provider.WarmIntent.DesiredGeneration != desiredGeneration {
		return false
	}
	if (state == protocol.UpdateLifecycleModelReloading ||
		state == protocol.UpdateLifecycleReady) && !currentEvidence {
		return false
	}
	if state != protocol.UpdateLifecycleReconnecting &&
		state != protocol.UpdateLifecycleApplicationVerifying &&
		state != protocol.UpdateLifecycleModelReloading &&
		state != protocol.UpdateLifecycleReady &&
		state != protocol.UpdateLifecycleBlocked {
		return false
	}
	base := evidence.EvidenceGeneration
	if currentEvidence {
		base--
	}
	provider.UpdateTargetVersion = targetVersion
	provider.UpdateDesiredGeneration = desiredGeneration
	provider.updateApplicationEvidenceBase = base
	provider.updateLifecycleStep = step
	return true
}

// SendReleaseUpdate uses the standard bounded control-write deadline.
func (r *Registry) SendReleaseUpdate(providerID string, release store.Release, desiredGeneration uint64) error {
	ctx, cancel := context.WithTimeout(context.Background(), providerControlWriteTimeout)
	defer cancel()
	return r.SendReleaseUpdateContext(ctx, providerID, release, desiredGeneration)
}

// SendReleaseUpdateContext binds and hands off one approved target under a
// caller-owned cancellation boundary.
func (r *Registry) SendReleaseUpdateContext(
	ctx context.Context, providerID string, release store.Release, desiredGeneration uint64,
) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, providerControlWriteTimeout)
	defer cancel()
	r.mu.RLock()
	provider, ok := r.providers[providerID]
	sender := r.releaseUpdateSender
	if !ok {
		r.mu.RUnlock()
		return fmt.Errorf("provider %q not found", providerID)
	}
	defer r.mu.RUnlock()
	provider.mu.Lock()
	locked := true
	defer func() {
		if locked {
			provider.mu.Unlock()
		}
	}()
	if provider.Status == StatusOffline || provider.Status == StatusUntrusted {
		return fmt.Errorf("provider %q is not trusted for release update", providerID)
	}
	if !provider.RolloutApprovalRequired || !provider.RolloutReleaseApproved {
		return fmt.Errorf("provider %q has no active rollout approval", providerID)
	}
	if _, valid := providerRolloutHardwareIdentityLocked(provider, time.Now()); !valid {
		return fmt.Errorf("provider %q has no live canonical hardware identity", providerID)
	}
	if !provider.UpdateLifecycleReported {
		return fmt.Errorf("provider %q does not support release lifecycle v1", providerID)
	}
	comparison, validVersions := semverutil.Compare(release.Version, provider.Version)
	if !validVersions || comparison < 0 {
		return fmt.Errorf("refusing release downgrade from %s to %s", provider.Version, release.Version)
	}
	previousTarget := provider.UpdateTargetVersion
	previousGeneration := provider.UpdateDesiredGeneration
	previousState := provider.UpdateLifecycleState
	previousStep := provider.updateLifecycleStep
	previousEvidenceBase := provider.updateApplicationEvidenceBase
	if !provider.beginReleaseUpdateLocked(release.Version, desiredGeneration) {
		return fmt.Errorf("provider %q rejected release update binding", providerID)
	}
	boundState := provider.UpdateLifecycleState
	boundStep := provider.updateLifecycleStep
	boundEvidenceBase := provider.updateApplicationEvidenceBase
	writer := provider.writer
	provider.mu.Unlock()
	locked = false
	restoreBinding := func() {
		provider.mu.Lock()
		if provider.UpdateTargetVersion == release.Version &&
			provider.UpdateDesiredGeneration == desiredGeneration &&
			provider.UpdateLifecycleState == boundState &&
			provider.updateLifecycleStep == boundStep &&
			provider.updateApplicationEvidenceBase == boundEvidenceBase {
			provider.UpdateTargetVersion = previousTarget
			provider.UpdateDesiredGeneration = previousGeneration
			provider.UpdateLifecycleState = previousState
			provider.updateLifecycleStep = previousStep
			provider.updateApplicationEvidenceBase = previousEvidenceBase
		}
		provider.mu.Unlock()
	}
	message := protocol.ReleaseUpdateMessage{
		Type: protocol.TypeReleaseUpdate, Version: release.Version, Platform: release.Platform,
		Backend: release.Backend, BinaryHash: release.BinaryHash, BundleHash: release.BundleHash,
		MetallibHash: release.MetallibHash, URL: release.URL, DesiredGeneration: desiredGeneration,
	}
	if sender != nil {
		if err := sender(ctx, providerID, message); err != nil {
			restoreBinding()
			return err
		}
		return nil
	}
	data, err := json.Marshal(message)
	if err != nil {
		restoreBinding()
		return err
	}
	if writer == nil {
		restoreBinding()
		return errProviderWriterStopped
	}
	if err := ctx.Err(); err != nil {
		restoreBinding()
		return err
	}
	if err := writer.writeControl(ctx, data); err != nil {
		restoreBinding()
		return fmt.Errorf("send release_update to provider %q: %w", providerID, err)
	}
	return nil
}

// SetReleaseUpdateSenderForTesting installs a synchronous command observer.
// Passing nil restores the production WebSocket path.
func (r *Registry) SetReleaseUpdateSenderForTesting(
	sender func(context.Context, string, protocol.ReleaseUpdateMessage) error,
) {
	r.mu.Lock()
	r.releaseUpdateSender = sender
	r.mu.Unlock()
}

// ApprovedReleaseVersion returns the only release acceptable for this identity.
// Outside the active cohort, only an already-running previous release remains
// accepted; it is never emitted as an update target.
func ApprovedReleaseVersion(policy store.ReleaseRolloutPolicy, canonicalSEIdentity, currentVersion string) (version string, command bool) {
	if canonicalSEIdentity == "" {
		return "", false
	}
	comparison, validVersions := semverutil.Compare(currentVersion, policy.TargetVersion)
	if !validVersions {
		return "", false
	}
	if ReleaseCohortMember(canonicalSEIdentity, policy.Stage, policy.CanarySEIdentities) {
		if comparison > 0 {
			return "", false
		}
		return policy.TargetVersion, currentVersion != policy.TargetVersion
	}
	if currentVersion == policy.PreviousVersion {
		return policy.PreviousVersion, false
	}
	return "", false
}

// SetProviderReleaseApproval applies the coordinator's cohort decision to the
// routing gate. Once required, an empty/unknown approval fails closed.
func (r *Registry) SetProviderReleaseApproval(providerID string, approved bool) bool {
	r.mu.RLock()
	provider := r.providers[providerID]
	r.mu.RUnlock()
	if provider == nil {
		return false
	}
	provider.mu.Lock()
	defer provider.mu.Unlock()
	if approved {
		if provider.Status == StatusOffline || provider.Status == StatusUntrusted {
			approved = false
		} else if _, valid := providerRolloutHardwareIdentityLocked(provider, time.Now()); !valid {
			approved = false
		}
	}
	provider.RolloutApprovalRequired = true
	provider.RolloutReleaseApproved = approved
	return true
}

func canonicalRolloutP256Identity(raw string) (string, bool) {
	decoded, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		return "", false
	}
	key, err := attestation.ParseP256PublicKey(decoded)
	if err != nil {
		return "", false
	}
	return base64.StdEncoding.EncodeToString(
		elliptic.Marshal(key.Curve, key.X, key.Y)), true
}

func providerRolloutAttestedIdentityLocked(provider *Provider) (string, bool) {
	if provider == nil || provider.AttestationResult == nil ||
		!provider.AttestationResult.Valid ||
		provider.Status == StatusOffline || provider.Status == StatusUntrusted ||
		trustRank(provider.TrustLevel) < trustRank(TrustHardware) {
		return "", false
	}
	attestedIdentity, ok := canonicalRolloutP256Identity(
		provider.AttestationResult.PublicKey)
	if !ok {
		return "", false
	}
	device := provider.DeviceEvidence
	deviceIdentity, ok := canonicalRolloutP256Identity(device.SEPublicKey)
	if !ok || device.EvidenceGeneration == 0 || device.Serial == "" ||
		device.Serial != provider.AttestationResult.SerialNumber ||
		deviceIdentity != attestedIdentity {
		return "", false
	}
	return attestedIdentity, true
}

func providerRolloutHardwareIdentityLocked(
	provider *Provider, now time.Time,
) (string, bool) {
	identity, valid := providerRolloutAttestedIdentityLocked(provider)
	if !valid {
		return "", false
	}
	device := provider.DeviceEvidence
	if device.VerifiedAt.IsZero() || device.ExpiresAt.IsZero() ||
		!now.Before(device.ExpiresAt) {
		return "", false
	}
	return identity, true
}

func providerRolloutDisconnectIdentityLocked(provider *Provider, now time.Time) (string, bool) {
	if provider == nil || provider.Status == StatusUntrusted {
		return "", false
	}
	originalStatus := provider.Status
	if originalStatus == StatusOffline {
		provider.Status = StatusOnline
	}
	identity, valid := providerRolloutHardwareIdentityLocked(provider, now)
	provider.Status = originalStatus
	return identity, valid
}

func (r *Registry) SetRolloutDisconnectObserver(
	observer func(identity string, generation uint64, state string),
) {
	r.mu.Lock()
	r.rolloutDisconnectObserver = observer
	r.mu.Unlock()
}

// CanonicalSEIdentityForRollout returns only a live, attestation-matched device
// identity suitable for authoritative cohort selection.
func (r *Registry) CanonicalSEIdentityForRollout(providerID string) (string, bool) {
	r.mu.RLock()
	provider := r.providers[providerID]
	r.mu.RUnlock()
	if provider == nil {
		return "", false
	}
	provider.mu.Lock()
	defer provider.mu.Unlock()
	return providerRolloutHardwareIdentityLocked(provider, time.Now())
}

// ReleaseRolloutProviderSnapshot is fully detached from mutable provider state.
type ReleaseRolloutProviderSnapshot struct {
	ProviderID            string              `json:"provider_id"`
	AttestedSEIdentity    string              `json:"attested_se_identity,omitempty"`
	CanonicalSEIdentity   string              `json:"canonical_se_identity,omitempty"`
	Version               string              `json:"version,omitempty"`
	LifecycleReported     bool                `json:"lifecycle_reported"`
	UpdateLifecycleState  string              `json:"update_lifecycle_state,omitempty"`
	WarmIntent            protocol.WarmIntent `json:"warm_intent,omitempty"`
	DesiredGeneration     uint64              `json:"desired_generation,omitempty"`
	ApprovedTargetVersion string              `json:"approved_target_version,omitempty"`
	Ready                 bool                `json:"ready"`
	ReleaseApproved       bool                `json:"release_approved"`
	HardwareVerified      bool                `json:"hardware_verified"`
	LastHeartbeat         time.Time           `json:"last_heartbeat"`
}

func (r *Registry) ReleaseRolloutProviderSnapshots() []ReleaseRolloutProviderSnapshot {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]ReleaseRolloutProviderSnapshot, 0, len(r.providers))
	now := time.Now()
	for _, provider := range r.providers {
		provider.mu.Lock()
		attestedIdentity, _ := providerRolloutAttestedIdentityLocked(provider)
		identity, hardwareVerified := providerRolloutHardwareIdentityLocked(provider, now)
		out = append(out, ReleaseRolloutProviderSnapshot{
			ProviderID: provider.ID, AttestedSEIdentity: attestedIdentity,
			CanonicalSEIdentity: identity, Version: provider.Version,
			LifecycleReported:    provider.UpdateLifecycleReported,
			UpdateLifecycleState: provider.UpdateLifecycleState, WarmIntent: provider.WarmIntent,
			DesiredGeneration:     provider.UpdateDesiredGeneration,
			ApprovedTargetVersion: provider.UpdateTargetVersion,
			ReleaseApproved:       provider.RolloutReleaseApproved,
			HardwareVerified:      hardwareVerified,
			Ready:                 provider.ReleaseUpdateReadyLocked(), LastHeartbeat: provider.LastHeartbeat,
		})
		provider.mu.Unlock()
	}
	return out
}
