package store

import (
	"errors"
	"strings"

	"github.com/jackc/pgx/v5/pgconn"
)

// IsPermanentFinancialError identifies errors that cannot recover by replaying
// the same immutable financial command.
func IsPermanentFinancialError(err error) bool {
	if errors.Is(err, ErrInsufficientBalance) ||
		errors.Is(err, ErrFinancialOperationConflict) {
		return true
	}
	var postgres *pgconn.PgError
	if !errors.As(err, &postgres) {
		return false
	}
	return strings.HasPrefix(postgres.Code, "22") || // data exception
		strings.HasPrefix(postgres.Code, "23") || // integrity constraint
		strings.HasPrefix(postgres.Code, "42") // schema/syntax mismatch
}
