package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestSandboxStoreFailedRenewalPreservesAuthority(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Date(2026, 8, 25, 3, 0, 0, 0, time.UTC)
			accountID := uniqueID("failed-renewal")
			sandbox := &SandboxRecord{
				ID:                    "10000000-0000-0000-0000-000000000101",
				AccountID:             accountID,
				IdempotencyKey:        "20000000-0000-0000-0000-000000000102",
				HostID:                "30000000-0000-0000-0000-000000000103",
				Generation:            1,
				FencingToken:          10,
				BaseImageID:           "macos-tahoe-v1",
				CPUCount:              4,
				MemoryBytes:           8 << 30,
				WorkspaceBytes:        25 << 30,
				CommandTimeoutSeconds: 900,
				State:                 SandboxStatePreparing,
				LeaseExpiresAt:        now.Add(30 * time.Minute),
				CreatedAt:             now,
				UpdatedAt:             now,
			}
			prepare := &SandboxOperation{
				ID:                      "40000000-0000-0000-0000-000000000104",
				SandboxID:               sandbox.ID,
				AccountID:               sandbox.AccountID,
				IdempotencyKey:          sandbox.IdempotencyKey,
				Kind:                    SandboxOperationKindPrepare,
				State:                   SandboxOperationPending,
				Generation:              sandbox.Generation,
				FencingToken:            sandbox.FencingToken,
				RequestedLeaseExpiresAt: sandbox.LeaseExpiresAt,
				CreatedAt:               now,
				UpdatedAt:               now,
			}
			if _, _, _, err := backend.CreateSandbox(
				ctx,
				sandbox,
				prepare,
				SandboxAllocationLimits{
					MaximumActive:     2,
					MaximumPerAccount: 2,
					MaximumPerHost:    2,
				},
			); err != nil {
				t.Fatalf("create sandbox: %v", err)
			}
			if _, _, err := backend.ApplySandboxOperationUpdate(
				ctx,
				SandboxOperationUpdate{
					OperationID:  prepare.ID,
					SandboxID:    sandbox.ID,
					Generation:   sandbox.Generation,
					FencingToken: sandbox.FencingToken,
					State:        SandboxOperationReady,
					UpdatedAt:    now.Add(time.Second),
				},
			); err != nil {
				t.Fatalf("ready sandbox: %v", err)
			}

			renew := &SandboxOperation{
				ID:                      "50000000-0000-0000-0000-000000000105",
				SandboxID:               sandbox.ID,
				AccountID:               sandbox.AccountID,
				IdempotencyKey:          "60000000-0000-0000-0000-000000000106",
				Kind:                    SandboxOperationKindRenew,
				State:                   SandboxOperationPending,
				Generation:              sandbox.Generation,
				FencingToken:            sandbox.FencingToken,
				RequestedFencingToken:   sandbox.FencingToken + 1,
				PreviousSandboxState:    SandboxStateReady,
				RequestedLeaseExpiresAt: now.Add(time.Hour),
				CreatedAt:               now.Add(2 * time.Second),
				UpdatedAt:               now.Add(2 * time.Second),
			}
			if _, _, created, err := backend.BeginSandboxOperation(
				ctx,
				renew,
				SandboxStateReady,
			); err != nil || !created {
				t.Fatalf("begin renewal: created=%v error=%v", created, err)
			}
			failure := SandboxOperationUpdate{
				OperationID:  renew.ID,
				SandboxID:    sandbox.ID,
				Generation:   sandbox.Generation,
				FencingToken: sandbox.FencingToken + 1,
				State:        SandboxOperationFailed,
				ErrorCode:    "renew_rejected",
				UpdatedAt:    now.Add(3 * time.Second),
			}
			if _, _, err := backend.ApplySandboxOperationUpdate(
				ctx,
				failure,
			); !errors.Is(err, ErrSandboxConflict) {
				t.Fatalf("failed renewal advanced authority: %v", err)
			}

			failure.FencingToken = sandbox.FencingToken
			storedSandbox, storedOperation, err :=
				backend.ApplySandboxOperationUpdate(ctx, failure)
			if err != nil {
				t.Fatalf("persist failed renewal: %v", err)
			}
			if storedSandbox.FencingToken != sandbox.FencingToken ||
				!storedSandbox.LeaseExpiresAt.Equal(sandbox.LeaseExpiresAt) ||
				storedSandbox.State != SandboxStateReady ||
				storedSandbox.ErrorCode != failure.ErrorCode ||
				storedOperation.State != SandboxOperationFailed {
				t.Fatalf(
					"failed renewal changed authority: sandbox=%+v operation=%+v",
					storedSandbox,
					storedOperation,
				)
			}
		})
	}
}

func TestLegacyPendingRenewalAcceptsObservedAdvancingAuthority(t *testing.T) {
	now := time.Date(2026, 8, 25, 3, 30, 0, 0, time.UTC)
	sandbox := &SandboxRecord{
		ID:             "70000000-0000-0000-0000-000000000107",
		Generation:     1,
		FencingToken:   10,
		State:          SandboxStateReady,
		LeaseExpiresAt: now.Add(30 * time.Minute),
	}
	operation := &SandboxOperation{
		ID:                      "80000000-0000-0000-0000-000000000108",
		SandboxID:               sandbox.ID,
		Kind:                    SandboxOperationKindRenew,
		State:                   SandboxOperationPending,
		Generation:              sandbox.Generation,
		FencingToken:            sandbox.FencingToken,
		PreviousSandboxState:    sandbox.State,
		RequestedLeaseExpiresAt: now.Add(time.Hour),
	}
	renewedExpiry := operation.RequestedLeaseExpiresAt
	if err := applySandboxOperationTransition(
		sandbox,
		operation,
		SandboxOperationUpdate{
			OperationID:    operation.ID,
			SandboxID:      sandbox.ID,
			Generation:     sandbox.Generation,
			FencingToken:   12,
			State:          SandboxOperationReady,
			LeaseExpiresAt: &renewedExpiry,
			UpdatedAt:      now.Add(time.Second),
		},
	); err != nil {
		t.Fatalf("apply legacy renewal observation: %v", err)
	}
	if sandbox.FencingToken != 12 ||
		!sandbox.LeaseExpiresAt.Equal(renewedExpiry) ||
		operation.State != SandboxOperationReady {
		t.Fatalf("legacy renewal result sandbox=%+v operation=%+v", sandbox, operation)
	}
}
