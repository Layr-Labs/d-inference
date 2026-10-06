package postgres_test

import (
	"context"
	"errors"
	"reflect"
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

func TestErasureReturnsCommittedResultAfterCancellation(t *testing.T) {
	for _, step := range []string{"plan", "replace_plan", "confirm", "cancel", "scrub"} {
		t.Run(step, func(t *testing.T) {
			s := testPostgresStore(t)
			ctx := context.Background()
			a := erasurefixture.SeedAccount(t, s)
			now := time.Now().UTC()
			plan, err := s.PlanAccountErasure(ctx, a.AccountID, nil)
			if err != nil {
				t.Fatal(err)
			}
			var prior *store.ErasureRequest
			if step != "plan" {
				prior, err = s.SaveErasurePlan(ctx, a.AccountID, "admin_key", plan.ErasureCounts, nil, "token", now.Add(time.Hour))
				if err != nil {
					t.Fatal(err)
				}
			}
			confirmation := store.ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: a.Email, Actor: "admin_key", Now: now, Grace: time.Hour}
			if step == "cancel" || step == "scrub" {
				if prior, err = s.RequestAccountErasure(ctx, confirmation); err != nil {
					t.Fatal(err)
				}
			}
			traced, interrupted := erasurefixture.CancelAfterCommit(t, s.pool.Config().ConnString())
			var result *store.ErasureRequest
			want := store.ErasurePlanned
			switch step {
			case "plan", "replace_plan":
				result, err = traced.SaveErasurePlan(interrupted, a.AccountID, "replacement_actor", plan.ErasureCounts, nil, "new-token", now.Add(2*time.Hour))
			case "confirm":
				want = store.ErasurePending
				result, err = traced.RequestAccountErasure(interrupted, confirmation)
			case "cancel":
				want = store.ErasureCanceled
				result, err = traced.CancelAccountErasure(interrupted, a.AccountID, "canceling_actor", now)
			case "scrub":
				want = store.ErasureErased
				var scrubbed *store.ErasureResult
				scrubbed, err = traced.ScrubAccount(interrupted, prior.ID, now.Add(2*time.Hour))
				if scrubbed != nil {
					result = scrubbed.Request
					if !slices.Contains(scrubbed.SEKeys, a.SEKey) || !slices.Contains(scrubbed.ProviderIDs, a.ProviderID) {
						t.Errorf("committed result lost runtime cleanup keys: %+v", scrubbed)
					}
				}
			}
			if !errors.Is(interrupted.Err(), context.Canceled) {
				t.Fatal("tracer did not observe a successful COMMIT")
			}
			persisted, _, readErr := s.GetAccountErasure(ctx, a.AccountID)
			if readErr != nil || persisted.State != want {
				t.Fatalf("committed request = %+v, %v; want %s", persisted, readErr, want)
			}
			if err != nil || !reflect.DeepEqual(result, persisted) {
				t.Fatalf("committed result = %+v, %v; want %+v", result, err, persisted)
			}
			if prior != nil && result.ID != prior.ID {
				t.Fatalf("request ID changed: %s -> %s", prior.ID, result.ID)
			}
			if step == "scrub" {
				leased, leaseErr := s.LeaseDueAccountErasures(ctx, now.Add(3*time.Hour), time.Hour, 20)
				if leaseErr != nil || len(leased) != 0 {
					t.Fatalf("erased request should never retry: %v, %v", leased, leaseErr)
				}
			}
		})
	}
}

func TestErasureResultDecodeFailureRollsBackTransition(t *testing.T) {
	for _, step := range []string{"confirm", "cancel"} {
		t.Run(step, func(t *testing.T) {
			s := testPostgresStore(t)
			ctx := context.Background()
			a := erasurefixture.SeedAccount(t, s)
			now := time.Now().UTC()
			plan, err := s.PlanAccountErasure(ctx, a.AccountID, nil)
			if err != nil {
				t.Fatal(err)
			}
			req, err := s.SaveErasurePlan(ctx, a.AccountID, "admin_key", plan.ErasureCounts, nil, "token", now.Add(time.Hour))
			if err != nil {
				t.Fatal(err)
			}
			confirmation := store.ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: a.Email, Now: now, Grace: time.Hour}
			if step == "cancel" {
				if req, err = s.RequestAccountErasure(ctx, confirmation); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := s.pool.Exec(ctx, `UPDATE erasure_requests SET plan = '"invalid summary"'::jsonb WHERE id = $1`, req.ID); err != nil {
				t.Fatal(err)
			}
			var result *store.ErasureRequest
			if step == "confirm" {
				result, err = s.RequestAccountErasure(ctx, confirmation)
			} else {
				result, err = s.CancelAccountErasure(ctx, a.AccountID, "canceling_actor", now)
			}
			if err == nil || result != nil {
				t.Fatalf("invalid summary should return only an error: %+v, %v", result, err)
			}
			var state string
			var deleted bool
			if err := s.pool.QueryRow(ctx, `SELECT r.state, u.deleted_at IS NOT NULL FROM erasure_requests r JOIN users u ON u.account_id = r.account_id WHERE r.id = $1`, req.ID).Scan(&state, &deleted); err != nil {
				t.Fatal(err)
			}
			if state != string(req.State) || deleted != (step == "cancel") {
				t.Fatalf("decode failure committed a partial transition: state=%s deleted=%v; prior=%s", state, deleted, req.State)
			}
		})
	}
}
