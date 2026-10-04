package store_test

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
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
			if got := store.IsTransientWriteError(tc.err); got != tc.want {
				t.Fatalf("IsTransientWriteError(%v) = %v, want %v", tc.err, got, tc.want)
			}
		})
	}
}
