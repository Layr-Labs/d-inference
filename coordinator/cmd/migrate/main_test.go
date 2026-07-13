package main

import (
	"bytes"
	"context"
	"fmt"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
)

func TestRunCommandValidatesArguments(t *testing.T) {
	neverApply := func(
		context.Context,
		string,
		store.MigrationOptions,
	) (store.MigrationResult, error) {
		t.Fatal("migration applier called for invalid arguments")
		return store.MigrationResult{}, nil
	}
	for _, test := range []struct {
		name string
		args []string
		want string
	}{
		{name: "missing database", want: "DATABASE_URL"},
		{name: "unexpected positional", args: []string{"extra"}, want: "unexpected arguments"},
		{name: "zero lock timeout", args: []string{"-database-url=x", "-lock-timeout=0"}, want: "lock-timeout must be positive"},
		{name: "zero statement timeout", args: []string{"-database-url=x", "-statement-timeout=0"}, want: "statement-timeout must be positive"},
		{name: "invalid duration", args: []string{"-lock-timeout=never"}, want: "invalid value"},
	} {
		t.Run(test.name, func(t *testing.T) {
			var stderr bytes.Buffer
			err := runCommand(
				context.Background(),
				test.args,
				func(string) string { return "" },
				&bytes.Buffer{},
				&stderr,
				neverApply,
			)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want substring %q (stderr %q)", err, test.want, stderr.String())
			}
		})
	}
}

func TestRunCommandPassesOptionsAndReportsResult(t *testing.T) {
	var (
		gotURL     string
		gotOptions store.MigrationOptions
		stdout     bytes.Buffer
	)
	apply := func(
		_ context.Context,
		databaseURL string,
		options store.MigrationOptions,
	) (store.MigrationResult, error) {
		gotURL = databaseURL
		gotOptions = options
		return store.MigrationResult{DatabaseVersion: 2, Applied: []int64{1, 2}}, nil
	}
	err := runCommand(
		context.Background(),
		[]string{"-lock-timeout=3s", "-statement-timeout=4m", "-adopt-legacy"},
		func(key string) string {
			if key == "EIGENINFERENCE_DATABASE_URL" {
				return "postgres://from-environment"
			}
			return ""
		},
		&stdout,
		&bytes.Buffer{},
		apply,
	)
	if err != nil {
		t.Fatal(err)
	}
	if gotURL != "postgres://from-environment" {
		t.Fatalf("database URL = %q", gotURL)
	}
	if gotOptions.LockTimeout != 3*time.Second || gotOptions.StatementTimeout != 4*time.Minute {
		t.Fatalf("options = %+v", gotOptions)
	}
	if !gotOptions.AdoptLegacy {
		t.Fatal("-adopt-legacy was not passed to the migration runner")
	}
	if !strings.Contains(stdout.String(), "applied schema migrations [1 2]") {
		t.Fatalf("stdout = %q", stdout.String())
	}
}

func TestRunCommandPostgresSmoke(t *testing.T) {
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx := context.Background()
	admin, err := pgx.Connect(ctx, databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = admin.Close(context.Background()) })

	database := fmt.Sprintf("darkbloom_migrate_cli_test_%d", time.Now().UnixNano())
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+pgx.Identifier{database}.Sanitize()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = admin.Exec(
			context.Background(),
			"DROP DATABASE IF EXISTS "+pgx.Identifier{database}.Sanitize()+" WITH (FORCE)",
		)
	})
	isolatedURL, err := withDatabase(databaseURL, database)
	if err != nil {
		t.Fatal(err)
	}

	var first bytes.Buffer
	if err := runCommand(
		ctx,
		[]string{"-database-url=" + isolatedURL},
		func(string) string { return "" },
		&first,
		&bytes.Buffer{},
		store.ApplyPostgresMigrations,
	); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(first.String(), "database is now version 7") {
		t.Fatalf("first run output = %q", first.String())
	}

	var second bytes.Buffer
	if err := runCommand(
		ctx,
		[]string{"-database-url=" + isolatedURL},
		func(string) string { return "" },
		&second,
		&bytes.Buffer{},
		store.ApplyPostgresMigrations,
	); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(second.String(), "already current at version 7") {
		t.Fatalf("second run output = %q", second.String())
	}
}

func withDatabase(databaseURL, database string) (string, error) {
	parsed, err := url.Parse(databaseURL)
	if err == nil && (parsed.Scheme == "postgres" || parsed.Scheme == "postgresql") {
		parsed.Path = "/" + database
		return parsed.String(), nil
	}
	if strings.TrimSpace(databaseURL) == "" {
		return "", fmt.Errorf("empty database URL")
	}
	return "", fmt.Errorf("database URL must use postgres or postgresql scheme")
}
