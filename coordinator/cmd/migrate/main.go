// Command migrate applies the coordinator's ordered PostgreSQL migrations.
// Run it as a deployment step before starting a coordinator binary.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	if err := run(ctx, os.Args[1:]); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string) error {
	return runCommand(
		ctx,
		args,
		os.Getenv,
		os.Stdout,
		os.Stderr,
		store.ApplyPostgresMigrations,
	)
}

type migrationApplier func(
	context.Context,
	string,
	store.MigrationOptions,
) (store.MigrationResult, error)

func runCommand(
	ctx context.Context,
	args []string,
	getenv func(string) string,
	stdout io.Writer,
	stderr io.Writer,
	apply migrationApplier,
) error {
	flags := flag.NewFlagSet("migrate", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var (
		databaseURL      string
		lockTimeout      time.Duration
		statementTimeout time.Duration
		adoptLegacy      bool
	)
	flags.StringVar(
		&databaseURL,
		"database-url",
		"",
		"PostgreSQL URL (defaults to EIGENINFERENCE_DATABASE_URL)",
	)
	flags.DurationVar(
		&lockTimeout,
		"lock-timeout",
		store.DefaultMigrationLockTimeout,
		"maximum PostgreSQL/advisory lock wait",
	)
	flags.DurationVar(
		&statementTimeout,
		"statement-timeout",
		store.DefaultMigrationStatementTimeout,
		"maximum duration of each migration statement",
	)
	flags.BoolVar(
		&adoptLegacy,
		"adopt-legacy",
		false,
		"explicitly adopt a matching unversioned Darkbloom database",
	)
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("migrate: unexpected arguments: %v", flags.Args())
	}
	if databaseURL == "" {
		databaseURL = getenv("EIGENINFERENCE_DATABASE_URL")
	}
	if databaseURL == "" {
		return fmt.Errorf("migrate: EIGENINFERENCE_DATABASE_URL or -database-url is required")
	}
	if lockTimeout <= 0 {
		return fmt.Errorf("migrate: -lock-timeout must be positive")
	}
	if statementTimeout <= 0 {
		return fmt.Errorf("migrate: -statement-timeout must be positive")
	}

	result, err := apply(ctx, databaseURL, store.MigrationOptions{
		LockTimeout:      lockTimeout,
		StatementTimeout: statementTimeout,
		AdoptLegacy:      adoptLegacy,
	})
	if err != nil {
		return fmt.Errorf("migrate: %w", err)
	}
	if len(result.Applied) == 0 {
		_, _ = fmt.Fprintf(stdout, "schema already current at version %d\n", result.DatabaseVersion)
		return nil
	}
	_, _ = fmt.Fprintf(
		stdout,
		"applied schema migrations %v; database is now version %d\n",
		result.Applied,
		result.DatabaseVersion,
	)
	return nil
}
