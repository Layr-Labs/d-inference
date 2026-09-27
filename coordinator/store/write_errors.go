package store

import (
	"context"
	"errors"
	"io"
	"net"
	"strings"

	"github.com/jackc/pgx/v5/pgconn"
)

// IsTransientWriteError reports whether a store write failed for a reason
// that is NOT about the rows being written: the statement deadline expired,
// the connection or pool is gone, or the server refused for resource,
// shutdown, or concurrency reasons. Callers that batch best-effort writes use
// it to choose between replaying the rows one by one (a row fault —
// constraint, type, or syntax error — worth isolating so one poison row does
// not discard its neighbours) and dropping the whole group (the store is
// unavailable, so N replays would just be N more timeouts).
func IsTransientWriteError(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		return true
	}
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return true
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		// SQLSTATE classes: 08 connection exception, 40 transaction rollback
		// (deadlock / serialization), 53 insufficient resources, 57 operator
		// intervention (admin shutdown, cannot connect now). Every other class
		// — 22 data, 23 integrity, 42 syntax/access, ... — describes the rows.
		if len(pgErr.Code) >= 2 {
			switch pgErr.Code[:2] {
			case "08", "40", "53", "57":
				return true
			}
		}
		return false
	}
	var connErr *pgconn.ConnectError
	if errors.As(err, &connErr) {
		return true
	}
	if pgconn.Timeout(err) {
		return true
	}
	var netErr net.Error
	if errors.As(err, &netErr) {
		return true
	}
	// pgxpool surfaces puddle.ErrClosedPool ("closed pool") once the pool is
	// closed; the sentinel lives in an indirect dependency, so match its text.
	return strings.Contains(err.Error(), "closed pool")
}
