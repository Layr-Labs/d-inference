package postgres_test

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func waitMachineAutopilotLock(t *testing.T, s *postgresFixture, query string, count int) {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()
	for {
		var waiting int
		if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM pg_stat_activity
		 WHERE datname=current_database() AND pid<>pg_backend_pid()
		 AND wait_event_type='Lock' AND query LIKE $1`, "%"+query+"%").Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting == count {
			return
		}
		select {
		case <-ctx.Done():
			t.Fatalf("want %d blocked queries containing %q, got %d", count, query, waiting)
		case <-time.After(time.Millisecond):
		}
	}
}

func TestMachineAutopilotSetterSerializesWithMerge(t *testing.T) {
	for _, first := range []string{"merge", "setter"} {
		t.Run(first+"_first", func(t *testing.T) {
			s := testPostgresStore(t)
			ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
			defer cancel()
			now := time.Now().UTC()
			winner, err := s.ObserveMachine(ctx, store.MachineObservation{SessionID: "winner", AccountID: "owner", SEKey: "winner-se", VerifiedSerial: "winner-serial", At: now})
			if err != nil {
				t.Fatal(err)
			}
			observation := store.MachineObservation{SessionID: "loser", AccountID: "owner", SEKey: "loser-se", At: now}
			loser, err := s.ObserveMachine(ctx, observation)
			if err != nil || loser.ID == winner.ID {
				t.Fatalf("independent machine fixture: %+v %v", loser, err)
			}
			holder, err := s.pool.Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer holder.Rollback(context.Background())
			if _, err := holder.Exec(ctx, "SELECT id FROM darkbloom_machines WHERE id=$1 FOR UPDATE", loser.ID); err != nil {
				t.Fatal(err)
			}
			observation.VerifiedSerial, observation.At = "winner-serial", now.Add(time.Second)
			merged := make(chan error, 1)
			merge := func() {
				got, err := s.ObserveMachine(ctx, observation)
				if err == nil && got.ID != winner.ID {
					err = fmt.Errorf("merge returned %s, want %s", got.ID, winner.ID)
				}
				merged <- err
			}
			type setResult struct {
				setting store.MachineAutopilotSetting
				err     error
			}
			set := make(chan setResult, 1)
			setter := func() {
				setting, err := s.SetMachineAutopilotDesiredMode(ctx, loser.ID, store.MachineAutopilotLive)
				set <- setResult{setting, err}
			}
			// Queue both real UPDATEs at the loser row, in a known order. The
			// later setter must recheck merged_into after the merge commits.
			if first == "merge" {
				go merge()
				waitMachineAutopilotLock(t, s, "SET merged_into=$2", 1)
				go setter()
				waitMachineAutopilotLock(t, s, "SET autopilot_revision=", 1)
			} else {
				go setter()
				waitMachineAutopilotLock(t, s, "SET autopilot_revision=", 1)
				go merge()
				waitMachineAutopilotLock(t, s, "SET merged_into=$2", 1)
			}
			if err := holder.Commit(ctx); err != nil {
				t.Fatal(err)
			}
			if err := <-merged; err != nil {
				t.Fatal(err)
			}
			result := <-set
			if first == "merge" {
				if !errors.Is(result.err, store.ErrNotFound) || result.setting != (store.MachineAutopilotSetting{}) {
					t.Fatalf("setter promoted merged-away ID: %+v %v", result.setting, result.err)
				}
			} else {
				want := store.MachineAutopilotSetting{MachineID: loser.ID, DesiredMode: store.MachineAutopilotLive, Revision: 1}
				if result.err != nil || result.setting != want {
					t.Fatalf("setter before merge: %+v %v, want %+v", result.setting, result.err, want)
				}
			}
			want := []store.MachineAutopilotSetting{{MachineID: winner.ID, DesiredMode: store.MachineAutopilotShadow}}
			if rows, err := s.ListMachineAutopilotSettings(ctx, "", 100); err != nil || !slices.Equal(rows, want) {
				t.Fatalf("merge changed winner policy: %+v %v", rows, err)
			}
			if rows, err := s.LiveMachineAutopilotSettings(ctx); err != nil || len(rows) != 0 {
				t.Fatalf("merge retained live loser: %+v %v", rows, err)
			}
			if _, err := s.SetMachineAutopilotDesiredMode(ctx, loser.ID, store.MachineAutopilotLive); !errors.Is(err, store.ErrNotFound) {
				t.Fatalf("post-merge setter did not return not found: %v", err)
			}
		})
	}
}

func TestMachineAutopilotCanceledSetterWaitingForRowLock(t *testing.T) {
	s := testPostgresStore(t)
	ctx, stop := context.WithTimeout(t.Context(), 10*time.Second)
	defer stop()
	identity, err := s.ObserveMachine(ctx, store.MachineObservation{SessionID: "canceled-setter", At: time.Now().UTC()})
	if err != nil {
		t.Fatal(err)
	}
	holder, err := s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Rollback(context.Background())
	if _, err := holder.Exec(ctx, "SELECT id FROM darkbloom_machines WHERE id=$1 FOR UPDATE", identity.ID); err != nil {
		t.Fatal(err)
	}
	canceled, cancel := context.WithCancel(ctx)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := s.SetMachineAutopilotDesiredMode(canceled, identity.ID, store.MachineAutopilotLive)
		done <- err
	}()
	waitMachineAutopilotLock(t, s, "SET autopilot_revision=", 1)
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("blocked setter cancellation: %v", err)
		}
	case <-ctx.Done():
		t.Fatal("canceled setter remained blocked")
	}
	waitMachineAutopilotLock(t, s, "SET autopilot_revision=", 0)
	if err := holder.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	want := []store.MachineAutopilotSetting{{MachineID: identity.ID, DesiredMode: store.MachineAutopilotShadow}}
	if rows, err := s.ListMachineAutopilotSettings(ctx, "", 100); err != nil || !slices.Equal(rows, want) {
		t.Fatalf("canceled write changed policy: %+v %v", rows, err)
	}
	if got, err := s.SetMachineAutopilotDesiredMode(ctx, identity.ID, store.MachineAutopilotLive); err != nil || got.Revision != 1 {
		t.Fatalf("setter did not recover after cancellation: %+v %v", got, err)
	}
}
