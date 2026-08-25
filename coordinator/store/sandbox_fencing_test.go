package store

import (
	"context"
	"sort"
	"testing"
	"time"
)

func TestSandboxStoreSerializesHostFencingTokens(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Date(2026, 8, 25, 6, 0, 0, 0, time.UTC)
			hostID := "10000000-0000-0000-0000-000000000201"
			first, firstPrepare := sandboxFencingFixture(
				"20000000-0000-0000-0000-000000000202",
				"30000000-0000-0000-0000-000000000203",
				"40000000-0000-0000-0000-000000000204",
				uniqueID("fencing-first"),
				hostID,
				10,
				now,
			)
			storedFirst, _, _, err := backend.CreateSandbox(
				ctx,
				first,
				firstPrepare,
				SandboxAllocationLimits{
					MaximumActive:     10,
					MaximumPerAccount: 10,
					MaximumPerHost:    10,
				},
			)
			if err != nil {
				t.Fatalf("create first sandbox: %v", err)
			}
			second, secondPrepare := sandboxFencingFixture(
				"50000000-0000-0000-0000-000000000205",
				"60000000-0000-0000-0000-000000000206",
				"70000000-0000-0000-0000-000000000207",
				uniqueID("fencing-second"),
				hostID,
				10,
				now.Add(time.Second),
			)
			storedSecond, _, _, err := backend.CreateSandbox(
				ctx,
				second,
				secondPrepare,
				SandboxAllocationLimits{
					MaximumActive:     10,
					MaximumPerAccount: 10,
					MaximumPerHost:    10,
				},
			)
			if err != nil {
				t.Fatalf("create second sandbox: %v", err)
			}
			if storedFirst.FencingToken != 10 ||
				storedSecond.FencingToken != 11 {
				t.Fatalf(
					"serialized create fences = (%d, %d), want (10, 11)",
					storedFirst.FencingToken,
					storedSecond.FencingToken,
				)
			}
			if _, _, err := backend.ApplySandboxOperationUpdate(
				ctx,
				SandboxOperationUpdate{
					OperationID:  firstPrepare.ID,
					SandboxID:    first.ID,
					Generation:   first.Generation,
					FencingToken: storedFirst.FencingToken,
					State:        SandboxOperationReady,
					UpdatedAt:    now.Add(2 * time.Second),
				},
			); err != nil {
				t.Fatalf("ready first sandbox: %v", err)
			}
			renew := &SandboxOperation{
				ID:                      "80000000-0000-0000-0000-000000000208",
				SandboxID:               first.ID,
				AccountID:               first.AccountID,
				IdempotencyKey:          "90000000-0000-0000-0000-000000000209",
				Kind:                    SandboxOperationKindRenew,
				State:                   SandboxOperationPending,
				Generation:              first.Generation,
				FencingToken:            storedFirst.FencingToken,
				RequestedFencingToken:   storedFirst.FencingToken + 1,
				PreviousSandboxState:    SandboxStateReady,
				RequestedLeaseExpiresAt: now.Add(time.Hour),
				CreatedAt:               now.Add(3 * time.Second),
				UpdatedAt:               now.Add(3 * time.Second),
			}
			_, storedRenew, created, err := backend.BeginSandboxOperation(
				ctx,
				renew,
				SandboxStateReady,
			)
			if err != nil || !created {
				t.Fatalf("begin renewal: created=%v error=%v", created, err)
			}
			if storedRenew.RequestedFencingToken != 12 {
				t.Fatalf(
					"renewal fence = %d, want 12",
					storedRenew.RequestedFencingToken,
				)
			}
		})
	}
}

func TestSandboxStoreConcurrentHostFencingTokens(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Date(2026, 8, 25, 7, 0, 0, 0, time.UTC)
			hostID := "a0000000-0000-0000-0000-000000000211"
			first, firstPrepare := sandboxFencingFixture(
				"b0000000-0000-0000-0000-000000000212",
				"c0000000-0000-0000-0000-000000000213",
				"d0000000-0000-0000-0000-000000000214",
				uniqueID("concurrent-fencing-first"),
				hostID,
				20,
				now,
			)
			second, secondPrepare := sandboxFencingFixture(
				"e0000000-0000-0000-0000-000000000215",
				"f0000000-0000-0000-0000-000000000216",
				"a1000000-0000-0000-0000-000000000217",
				uniqueID("concurrent-fencing-second"),
				hostID,
				20,
				now,
			)
			type result struct {
				token uint64
				err   error
			}
			start := make(chan struct{})
			results := make(chan result, 2)
			create := func(
				sandbox *SandboxRecord,
				operation *SandboxOperation,
			) {
				<-start
				stored, _, _, err := backend.CreateSandbox(
					ctx,
					sandbox,
					operation,
					SandboxAllocationLimits{
						MaximumActive:     10,
						MaximumPerAccount: 10,
						MaximumPerHost:    10,
					},
				)
				if err != nil {
					results <- result{err: err}
					return
				}
				results <- result{token: stored.FencingToken}
			}
			go create(first, firstPrepare)
			go create(second, secondPrepare)
			close(start)

			tokens := make([]uint64, 0, 2)
			for range 2 {
				result := <-results
				if result.err != nil {
					t.Fatalf("concurrent create: %v", result.err)
				}
				tokens = append(tokens, result.token)
			}
			sort.Slice(tokens, func(left, right int) bool {
				return tokens[left] < tokens[right]
			})
			if tokens[0] != 20 || tokens[1] != 21 {
				t.Fatalf("concurrent fencing tokens = %v, want [20 21]", tokens)
			}
		})
	}
}

func sandboxFencingFixture(
	sandboxID string,
	idempotencyKey string,
	operationID string,
	accountID string,
	hostID string,
	minimumFencingToken uint64,
	now time.Time,
) (*SandboxRecord, *SandboxOperation) {
	sandbox := &SandboxRecord{
		ID:                    sandboxID,
		AccountID:             accountID,
		IdempotencyKey:        idempotencyKey,
		HostID:                hostID,
		Generation:            1,
		FencingToken:          minimumFencingToken,
		BaseImageID:           "macos-tahoe-v1",
		CPUCount:              2,
		MemoryBytes:           4 << 30,
		WorkspaceBytes:        25 << 30,
		CommandTimeoutSeconds: 900,
		State:                 SandboxStatePreparing,
		LeaseExpiresAt:        now.Add(30 * time.Minute),
		CreatedAt:             now,
		UpdatedAt:             now,
	}
	operation := &SandboxOperation{
		ID:                      operationID,
		SandboxID:               sandboxID,
		AccountID:               accountID,
		IdempotencyKey:          idempotencyKey,
		Kind:                    SandboxOperationKindPrepare,
		State:                   SandboxOperationPending,
		Generation:              sandbox.Generation,
		FencingToken:            minimumFencingToken,
		RequestedLeaseExpiresAt: sandbox.LeaseExpiresAt,
		CreatedAt:               now,
		UpdatedAt:               now,
	}
	return sandbox, operation
}
