// devnet-seed fills an empty DevNet coordinator database with synthetic data:
// accounts, API keys, provider machines and their sessions, usage rows, ledger
// entries and balances. Every value is obviously fake (seed-<n>@example.invalid,
// did:privy:seed-<n>, SEED serial numbers). It refuses to write when the users
// table already has rows, so it cannot add data to a live database.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
)

type options struct {
	accounts            int
	keysPerAccount      int
	providers           int
	sessionsPerProvider int
	requestsPerAccount  int
	balanceMicroUSD     int64
	workers             int
}

func parseOptions(args []string) (options, error) {
	var o options
	f := flag.NewFlagSet("devnet-seed", flag.ContinueOnError)
	f.IntVar(&o.accounts, "accounts", 20, "accounts (users) to create")
	f.IntVar(&o.keysPerAccount, "keys-per-account", 1, "API keys per account")
	f.IntVar(&o.providers, "providers", 5, "provider machines, owned round-robin by the accounts")
	f.IntVar(&o.sessionsPerProvider, "sessions-per-provider", 3, "closed connection sessions per provider machine")
	f.IntVar(&o.requestsPerAccount, "requests-per-account", 10, "inference requests per account (usage row, charge, provider earning)")
	f.Int64Var(&o.balanceMicroUSD, "balance-micro-usd", 5_000_000, "consumer balance left on each account after its requests are charged")
	f.IntVar(&o.workers, "workers", 8, "accounts or providers written in parallel")
	if err := f.Parse(args); err != nil {
		return o, err
	}
	switch {
	case f.NArg() != 0:
		return o, errors.New("unexpected positional arguments")
	case o.accounts < 1:
		return o, errors.New("accounts must be at least 1")
	case o.keysPerAccount < 1 || o.sessionsPerProvider < 1 || o.workers < 1:
		return o, errors.New("keys-per-account, sessions-per-provider and workers must be at least 1")
	case o.providers < 0 || o.requestsPerAccount < 0 || o.balanceMicroUSD < 0:
		return o, errors.New("providers, requests-per-account and balance-micro-usd must not be negative")
	case o.requestsPerAccount > 0 && o.providers == 0:
		return o, errors.New("requests-per-account needs at least one provider")
	}
	return o, nil
}

// requireEmptyDatabase runs before NewPostgres so that a database that already
// holds users is refused before any migration touches it.
func requireEmptyDatabase(ctx context.Context, dsn string) error {
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	defer conn.Close(ctx)
	var usersTableExists bool
	err = conn.QueryRow(ctx, `SELECT to_regclass('users') IS NOT NULL`).Scan(&usersTableExists)
	if err != nil {
		return fmt.Errorf("check users table: %w", err)
	}
	if !usersTableExists {
		return nil
	}
	var hasUsers bool
	if err := conn.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM users)`).Scan(&hasUsers); err != nil {
		return fmt.Errorf("check users table: %w", err)
	}
	if hasUsers {
		return errors.New("refusing to seed: the users table has rows; devnet-seed only fills an empty database")
	}
	return nil
}

func run(ctx context.Context, args []string, out io.Writer) error {
	o, err := parseOptions(args)
	if err != nil {
		return err
	}
	dsn := os.Getenv("EIGENINFERENCE_DATABASE_URL")
	if dsn == "" {
		return errors.New("EIGENINFERENCE_DATABASE_URL is required")
	}
	if err := requireEmptyDatabase(ctx, dsn); err != nil {
		return err
	}
	st, err := store.NewPostgres(ctx, store.Config{DatabaseURL: dsn})
	if err != nil {
		return err
	}
	defer st.Close()
	result, err := seed(ctx, st, o)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(out, "seeded %d accounts, %d API keys, %d providers, %d sessions, %d requests\n",
		result.accounts, result.apiKeys, result.providers, result.sessions, result.requests)
	return err
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "devnet-seed:", err)
		os.Exit(1)
	}
}
