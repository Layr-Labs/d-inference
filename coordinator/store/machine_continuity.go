package store

import (
	"bytes"
	"context"
	"errors"
	"time"
)

// MachineOperationalStore resolves history only after the caller has verified a
// fresh, account- and endpoint-bound App Attest assertion and recorded its alias
// with ObserveMachine. Persisted identity is not a serving authorization: the
// caller must still bind the result to the live connection and enforce expiry.
// Neither lookup argument is a serial, caller-selected machine ID or ledger key.
type MachineOperationalStore interface {
	ResolveMachineContinuity(ctx context.Context, sessionID, authenticatedAccount, verifiedAppAttestKey string, excludeProviderIDs []string) (MachineContinuity, error)
}

// MachineContinuityRecoveryStore repairs only a historical backfill tombstone
// that raced a live provider session. The caller must first durably verify a
// fresh assertion and validate its exact current connection, account and
// endpoint. Recovery grants no serving permission; the strict continuity read
// and all authorization checks still follow.
type MachineContinuityRecoveryStore interface {
	RecoverLiveAppAttestMachineSession(ctx context.Context, sessionID, authenticatedAccount, verifiedAppAttestKey string, now time.Time) (bool, error)
}

type MachineContinuity struct {
	Machine  MachineIdentity
	Previous *ProviderRecord
}

// ErrMachineContinuityUnverified includes missing, disconnected, cross-account,
// unassociated and revoked credentials. Callers must not fall back to a serial
// lookup or authorize serving when this error (or any storage error) is returned.
var ErrMachineContinuityUnverified = errors.New("machine_continuity_unverified")

func appAttestMachineAlias(account, key string) machineAlias {
	return (MachineObservation{AccountID: account, VerifiedAppAttestKey: key}).aliases()[0]
}

func cloneMachineHistory(p *ProviderRecord) *ProviderRecord {
	if p == nil {
		return nil
	}
	cp := *p
	cp.Hardware = bytes.Clone(p.Hardware)
	cp.Models = bytes.Clone(p.Models)
	cp.AttestationResult = bytes.Clone(p.AttestationResult)
	cp.MDACertChain = bytes.Clone(p.MDACertChain)
	cp.LifetimeStats = bytes.Clone(p.LifetimeStats)
	cp.LastSessionStats = bytes.Clone(p.LastSessionStats)
	if p.Location != nil {
		loc := *p.Location
		cp.Location = &loc
	}
	if p.LastChallengeVerified != nil {
		at := *p.LastChallengeVerified
		cp.LastChallengeVerified = &at
	}
	return &cp
}

var (
	_ MachineOperationalStore        = (*MemoryStore)(nil)
	_ MachineOperationalStore        = (*PostgresStore)(nil)
	_ MachineContinuityRecoveryStore = (*MemoryStore)(nil)
	_ MachineContinuityRecoveryStore = (*PostgresStore)(nil)
)
