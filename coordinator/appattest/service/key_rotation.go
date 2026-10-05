package service

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (x *Session) keyRotation() *recovery.Rotation {
	if x.rotation == nil {
		x.rotation = recovery.NewRotation(recovery.RotationDependencies{
			Store: func() store.AppAttestKeyRotationStore {
				st, _ := store.As[store.AppAttestKeyRotationStore](x.s.store)
				return st
			},
			Account: x.account, Percent: x.s.config.KeyRotationPercent,
			CanonicalMachine: x.canonicalMachine, Acquire: x.acquireStorage,
			Observe: x.observeKeyRotation,
		})
	}
	return x.rotation
}

func (x *Session) maybeRequestKeyRotation(ctx context.Context, key *store.AppAttestShadowKey) bool {
	return x.keyRotation().Request(ctx, key)
}

func (x *Session) rotationRetryDue(failure string) bool {
	return x.keyRotation().RetryDue(failure, x.expected, x.key)
}

// Resolve canonical inventory before scoping limits; absent inventory falls
// back to the credential's recorded machine, then the account.
func (x *Session) canonicalMachine(ctx context.Context, fallback string) string {
	machine := x.machineID()
	if machine == "" {
		machine = fallback
	}
	if machine == "" {
		return ""
	}
	if lookup, ok := store.As[store.MachineIdentityLookupStore](x.s.store); ok {
		if canonical, err := lookup.CanonicalMachineID(ctx, machine); err == nil && canonical != "" {
			return canonical
		}
	}
	return machine
}

func (x *Session) observeKeyRotation(outcome string) {
	x.s.ddIncr("app_attest.key_rotation", []string{"outcome:" + outcome})
	x.observeSideEffect("rotation", outcome)
}

func (x *Session) observeSideEffect(stage, outcome string) {
	last := x.lastOutcome
	x.observe(stage, outcome, nil)
	x.lastOutcome = last
}
