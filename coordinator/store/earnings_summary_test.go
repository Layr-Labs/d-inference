package store

import (
	"context"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type failingEarningsSummaryRow struct {
	err error
}

func (r failingEarningsSummaryRow) Scan(...any) error {
	return r.err
}

func TestScanEarningsSummaryDistinguishesNotFoundFromOperationalError(t *testing.T) {
	if _, err := scanEarningsSummary(failingEarningsSummaryRow{err: pgx.ErrNoRows}); !errors.Is(err, ErrNotFound) {
		t.Fatalf("no-row error = %v, want ErrNotFound", err)
	}

	operationalErr := errors.New("database read failed")
	if _, err := scanEarningsSummary(failingEarningsSummaryRow{err: operationalErr}); !errors.Is(err, operationalErr) {
		t.Fatalf("operational error = %v, want wrapped source error", err)
	} else if errors.Is(err, ErrNotFound) {
		t.Fatalf("operational error was collapsed to ErrNotFound: %v", err)
	}
}

func TestEarningsSummaryMissingContract(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			if _, err := s.GetAccountEarningsSummary(uniqueID("missing-account")); !errors.Is(err, ErrNotFound) {
				t.Fatalf("account summary error = %v, want ErrNotFound", err)
			}
			if _, err := s.GetProviderEarningsSummary(uniqueID("missing-provider")); !errors.Is(err, ErrNotFound) {
				t.Fatalf("provider summary error = %v, want ErrNotFound", err)
			}
		})
	}
}

func TestPostgresEarningsSummaryClosedPoolFailsOperationally(t *testing.T) {
	pool, err := pgxpool.New(context.Background(), "postgres://test:test@127.0.0.1:1/test")
	if err != nil {
		t.Fatalf("create pool: %v", err)
	}
	pool.Close()
	s := &PostgresStore{pool: pool}

	for name, read := range map[string]func() (ProviderEarningsSummary, error){
		"account":  func() (ProviderEarningsSummary, error) { return s.GetAccountEarningsSummary("account") },
		"provider": func() (ProviderEarningsSummary, error) { return s.GetProviderEarningsSummary("provider") },
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := read(); err == nil {
				t.Fatal("closed pool read unexpectedly succeeded")
			} else if errors.Is(err, ErrNotFound) {
				t.Fatalf("closed pool error was collapsed to ErrNotFound: %v", err)
			}
		})
	}
}
