package store

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

func TestIsTransientWriteError(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"nil", nil, false},
		{"plain row fault", errors.New("injected poison row"), false},
		{"deadline (wrapped)", fmt.Errorf("store: record inference routes: %w", context.DeadlineExceeded), true},
		{"canceled", context.Canceled, true},
		{"eof", fmt.Errorf("conn: %w", io.EOF), true},
		{"unexpected eof", io.ErrUnexpectedEOF, true},
		{"unique violation 23505", &pgconn.PgError{Code: "23505"}, false},
		{"numeric overflow 22003", fmt.Errorf("w: %w", &pgconn.PgError{Code: "22003"}), false},
		{"syntax 42601", &pgconn.PgError{Code: "42601"}, false},
		{"connection failure 08006", &pgconn.PgError{Code: "08006"}, true},
		{"deadlock 40P01", &pgconn.PgError{Code: "40P01"}, true},
		{"too many connections 53300", &pgconn.PgError{Code: "53300"}, true},
		{"admin shutdown 57P01", fmt.Errorf("w: %w", &pgconn.PgError{Code: "57P01"}), true},
		{"connect error", fmt.Errorf("w: %w", &pgconn.ConnectError{}), true},
		{"net timeout", &net.DNSError{Err: "timeout", IsTimeout: true}, true},
		{"closed pool text", errors.New("store: record inference routes (3 rows): closed pool"), true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := IsTransientWriteError(tc.err); got != tc.want {
				t.Fatalf("IsTransientWriteError(%v) = %v, want %v", tc.err, got, tc.want)
			}
		})
	}
}

// TestPostgresRouteWritesAfterPoolCloseAreTransient pins the shutdown case the
// sink relies on: once the pool is closed every route write fails with an
// error the classifier calls transient, so the sink drops the group instead
// of replaying N rows that would each fail the same way.
func TestPostgresRouteWritesAfterPoolCloseAreTransient(t *testing.T) {
	s := tracedPostgresStore(t, &statementCounter{})
	s.pool.Close()

	id := uniqueID("closed")
	records := []*InferenceRouteRecord{
		{RequestID: id + "-1", Attempt: 1, Outcome: "selected"},
		{RequestID: id + "-2", Attempt: 1, Outcome: "selected"},
	}
	if err := s.RecordInferenceRoutes(records); err == nil || !IsTransientWriteError(err) {
		t.Fatalf("batch insert on closed pool: err=%v, want transient", err)
	}
	if err := s.RecordInferenceRoute(records[0]); err == nil || !IsTransientWriteError(err) {
		t.Fatalf("single insert on closed pool: err=%v, want transient", err)
	}
	updates := []InferenceRouteOutcomeUpdate{
		{RequestID: id + "-1", Attempt: 1, Outcome: &InferenceRouteOutcome{FinalStatus: "success"}},
		{RequestID: id + "-2", Attempt: 1, Outcome: &InferenceRouteOutcome{FinalStatus: "success"}},
	}
	if err := s.UpdateInferenceRouteOutcomes(updates); err == nil || !IsTransientWriteError(err) {
		t.Fatalf("batch update on closed pool: err=%v, want transient", err)
	}
	if err := s.UpdateInferenceRouteOutcome(id+"-1", 1, updates[0].Outcome); err == nil || !IsTransientWriteError(err) {
		t.Fatalf("single update on closed pool: err=%v, want transient", err)
	}
}
