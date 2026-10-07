package authorization

import (
	"context"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/eligibility"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// VerifiedProof is the immutable handoff from a durably verified exchange.
// Readiness is still re-read before a grant; this value never grants by itself.
type VerifiedProof struct {
	evidence      appattest.AuthorizationEvidence
	status        protocol.AppAttestStatus
	statusPresent bool
	session       string
	dropped       func() uint64
	baseline      uint64
}

func NewVerifiedProof(e appattest.AuthorizationEvidence, status *protocol.AppAttestStatus, session string, dropped func() uint64, baseline uint64) VerifiedProof {
	if e.ValidationCategory != nil {
		v := *e.ValidationCategory
		e.ValidationCategory = &v
	}
	if e.RiskMetric != nil {
		v := *e.RiskMetric
		e.RiskMetric = &v
	}
	proof := VerifiedProof{evidence: e, session: session, dropped: dropped, baseline: baseline}
	if status != nil {
		proof.status, proof.statusPresent = *status, true
	}
	return proof
}

// Inventory supplies the authenticated live observation and re-captures the
// canonical identity after a historical tombstone has been reopened.
type Inventory interface {
	Observation() store.MachineObservation
	CaptureIdentity() store.MachineIdentity
}

type IdentityDependencies struct {
	Controller  *Controller
	Registry    *registry.Registry
	Operational func() store.MachineOperationalStore
	Recovery    func() store.MachineContinuityRecoveryStore
	Readiness   func() store.AppAttestReadinessStore
	Inventory   Inventory
	Notify      func(*registry.Provider)
	Count       func(string)
	Observe     func(string, string)
}

// Identity is owned by one serialized connection worker. Controller owns the
// concurrent proof/grant fences; no worker-owned retry state crosses that lock.
type Identity struct {
	deps          IdentityDependencies
	provider      *registry.Provider
	account       string
	ready         bool
	retryPending  bool
	retryFailures int
}

func NewIdentity(deps IdentityDependencies, provider *registry.Provider, account string) *Identity {
	return &Identity{deps: deps, provider: provider, account: account}
}

func (x *Identity) Update(proof VerifiedProof, verdict appattest.AuthorizationVerdict) (result string) {
	x.retryPending = false
	result = "serving_unavailable"
	defer func() {
		if x.deps.Observe != nil {
			x.deps.Observe("authorization", result)
		}
	}()
	a := x.deps.Controller
	if a == nil || !proof.statusPresent {
		return
	}
	e := proof.evidence
	current, revoked := x.deps.Registry.RecordVerifiedAppAttestPresenter(x.provider, e.Binding.Credential, e.Binding.Account, e.Binding.Endpoint)
	if !current {
		return "presenter_rejected"
	}
	if revoked {
		a.Forget(x.provider)
		x.notify()
		return "credential_revoked"
	}
	if e.RevocationKnown && e.Revoked {
		x.fenceRevokedCredential(e.Binding.Credential)
		return "credential_revoked"
	}
	if verdict.Outcome == "unknown" {
		// Unknown evidence neither replaces a retained signature nor extends its
		// lease. Only a first proof needs the early fresh-assertion retry.
		pending := !e.RevocationKnown || (e.RenewalConfigured && (!e.ReceiptVerified || e.RiskMetric == nil))
		x.retryPending = pending && a.Current(x.provider) == nil
		x.notify()
		return "policy_unknown"
	}
	if verdict.Outcome != "eligible" {
		a.Forget(x.provider)
		if eligibility.PolicyViolation(verdict) {
			x.deps.Registry.MarkUntrusted(x.provider.ID)
		}
		x.notify()
		return "policy_ineligible"
	}
	_, boundMachine := x.provider.GetVerifiedMachineIdentity()
	if !x.ready || boundMachine != e.Binding.Machine {
		var st store.MachineOperationalStore
		if x.deps.Operational != nil {
			st = x.deps.Operational()
		}
		if st == nil {
			x.retryFirstGrant()
			return "identity_store_unavailable"
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		continuity, err := st.ResolveMachineContinuity(ctx, x.provider.ID, x.account, e.Binding.Credential, x.deps.Registry.ProviderIDs())
		if errors.Is(err, store.ErrMachineContinuityUnverified) && x.deps.Inventory != nil {
			observed := x.deps.Inventory.Observation()
			if observed.SessionID != x.provider.ID || observed.AccountID != x.account || observed.VerifiedAppAttestKey != e.Binding.Credential {
				x.retryFirstGrant()
				return "identity_alias_unbound"
			}
			var recoveryStore store.MachineContinuityRecoveryStore
			if x.deps.Recovery != nil {
				recoveryStore = x.deps.Recovery()
			}
			if recoveryStore != nil {
				recovered, recoveryErr := recoveryStore.RecoverLiveAppAttestMachineSession(ctx, x.provider.ID, x.account, e.Binding.Credential, time.Now().UTC())
				if recoveryErr != nil {
					x.retryFirstGrant()
					return "identity_recovery_failed"
				}
				if recovered {
					machine := x.deps.Inventory.CaptureIdentity().ID
					if machine == "" {
						x.retryFirstGrant()
						return "identity_recovery_incomplete"
					}
					e.Binding.Machine, e.Expected.Machine = machine, machine
					if appattest.EvaluateAuthorization(e, time.Now()).Outcome != "eligible" {
						return "identity_recovery_incomplete"
					}
					continuity, err = st.ResolveMachineContinuity(ctx, x.provider.ID, x.account, e.Binding.Credential, x.deps.Registry.ProviderIDs())
					if err == nil {
						if x.deps.Count != nil {
							x.deps.Count("app_attest.inventory.recovered")
						}
						if x.deps.Observe != nil {
							x.deps.Observe("authorization_recovery", "historical_tombstone_reopened")
						}
					}
				}
			}
		}
		if err != nil {
			x.retryFirstGrant()
			if errors.Is(err, store.ErrMachineContinuityUnverified) {
				return "identity_unverified"
			}
			return "identity_lookup_failed"
		}
		if continuity.Machine.ID != e.Binding.Machine {
			return "identity_mismatch"
		}
		if continuity.Previous != nil {
			// Registry applies a historical baseline once, preserving live deltas
			// even when later canonical aliases expose overlapping snapshots.
			if err := x.deps.Registry.MergeVerifiedMachineHistory(ctx, x.provider, continuity.Previous); err != nil {
				x.retryFirstGrant()
				return "identity_restore_failed"
			}
		}
		if !x.deps.Registry.BindVerifiedMachineIdentity(x.provider, x.account, continuity.Machine.ID) {
			x.retryFirstGrant()
			return "identity_bind_failed"
		}
		x.provider.CompleteProviderStateRestore()
		x.ready = true
	}
	// Keep the exact record pointer across the readiness read for Controller CAS.
	record := NewRecord(e, proof.status, proof.session, proof.dropped, proof.baseline)
	a.Remember(x.provider, record)
	var st store.AppAttestReadinessStore
	if x.deps.Readiness != nil {
		st = x.deps.Readiness()
	}
	if st != nil {
		observedAt := time.Now().UTC()
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		state, err := st.GetAppAttestReadiness(ctx, e.Binding.Credential)
		cancel()
		if err == nil {
			_, applied := a.ApplyCurrent(x.provider, record, state, observedAt)
			if applied != "proof_replaced" {
				result = applied
			}
			if applied == "credential_revoked" {
				x.fenceRevokedCredential(e.Binding.Credential)
				return "credential_revoked"
			}
			if result == "grant_rejected" {
				x.retryFirstGrant()
			}
		} else {
			result = "readiness_lookup_failed"
		}
	} else {
		result = "readiness_store_unavailable"
	}
	x.notify()
	return
}

func (x *Identity) retryFirstGrant() {
	if _, granted := x.deps.Registry.ProviderServingAuthorization(x.provider); !granted {
		x.retryPending = true
	}
}

func (x *Identity) fenceRevokedCredential(key string) {
	x.deps.Controller.Forget(x.provider)
	x.deps.Registry.RevokeAppAttestCredential(key)
	x.deps.Registry.DenyAppAttestProvider(x.provider)
	x.notify()
}

func (x *Identity) notify() {
	if x.deps.Notify != nil {
		x.deps.Notify(x.provider)
	}
}

// First-grant retries use one minute, five minutes, then the normal ten-minute
// cadence. A known decision or retained proof resets the early retry sequence.
func (x *Identity) NextAssertionDelay() time.Duration {
	if !x.retryPending {
		x.retryFailures = 0
		return recovery.AssertionInterval
	}
	delay := min(recovery.RetryDelay(x.retryFailures), recovery.AssertionInterval)
	if x.retryFailures < 2 {
		x.retryFailures++
	}
	return delay
}
