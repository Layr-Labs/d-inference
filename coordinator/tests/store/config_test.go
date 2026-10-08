package store_test

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/postgres"
)

func TestMigrationConfigDefaultsAndOverrides(t *testing.T) {
	t.Setenv("EIGENINFERENCE_ALLOW_MEMORY_STORE", "true")
	for _, name := range []string{"EIGENINFERENCE_MIGRATION_TIMEOUT", "EIGENINFERENCE_CONCURRENT_INDEX_LOCK_TIMEOUT"} {
		t.Setenv(name, "")
		if err := os.Unsetenv(name); err != nil {
			t.Fatal(err)
		}
	}
	cfg := store.ReadConfig()
	if err := cfg.Check(); err != nil {
		t.Fatal(err)
	}
	if cfg.MigrationTimeout != 15*time.Minute || cfg.ConcurrentIndexLockTimeout != time.Minute {
		t.Fatalf("default durations: migration=%s concurrent=%s", cfg.MigrationTimeout, cfg.ConcurrentIndexLockTimeout)
	}
	t.Setenv("EIGENINFERENCE_MIGRATION_TIMEOUT", "45m")
	t.Setenv("EIGENINFERENCE_CONCURRENT_INDEX_LOCK_TIMEOUT", "1250ms")
	cfg = store.ReadConfig()
	if err := cfg.Check(); err != nil {
		t.Fatal(err)
	}
	if cfg.MigrationTimeout != 45*time.Minute || cfg.ConcurrentIndexLockTimeout != 1250*time.Millisecond {
		t.Fatalf("configured durations: migration=%s concurrent=%s", cfg.MigrationTimeout, cfg.ConcurrentIndexLockTimeout)
	}
}

func TestMigrationConfigRejectsInvalidEnvironmentBeforeDatabase(t *testing.T) {
	// A malformed URL would fail parsing if validation did not run first.
	t.Setenv("EIGENINFERENCE_DATABASE_URL", "://invalid")
	for _, name := range []string{"EIGENINFERENCE_MIGRATION_TIMEOUT", "EIGENINFERENCE_CONCURRENT_INDEX_LOCK_TIMEOUT"} {
		values := []string{"", "nope", "0", "0s", "-1s", "999999999999999h"}
		if strings.Contains(name, "CONCURRENT") {
			values = append(values, "1ns", "999us", "2147483648ms")
		}
		for _, value := range values {
			t.Run(name+"/"+value, func(t *testing.T) {
				t.Setenv("EIGENINFERENCE_MIGRATION_TIMEOUT", "15m")
				t.Setenv("EIGENINFERENCE_CONCURRENT_INDEX_LOCK_TIMEOUT", "1m")
				t.Setenv(name, value)
				cfg := store.ReadConfig()
				if err := cfg.Check(); err == nil || !strings.Contains(err.Error(), name) {
					t.Fatalf("Check() = %v, want %s validation error", err, name)
				}
				if s, err := postgres.NewPostgres(context.Background(), cfg); err == nil || !strings.Contains(err.Error(), name) {
					if s != nil {
						s.Close()
					}
					t.Fatalf("NewPostgres() = %v, want config error before database parsing", err)
				}
			})
		}
	}
}

func TestMigrationConfigProgrammaticBoundaries(t *testing.T) {
	for _, tc := range []struct {
		name       string
		migration  time.Duration
		concurrent time.Duration
		valid      bool
	}{
		{name: "zero defaults", valid: true},
		{name: "minimum", migration: time.Nanosecond, concurrent: time.Millisecond, valid: true},
		{name: "maximum lock", concurrent: 2147483647 * time.Millisecond, valid: true},
		{name: "negative migration", migration: -time.Nanosecond},
		{name: "negative lock", concurrent: -time.Second},
		{name: "submillisecond lock", concurrent: time.Millisecond - time.Nanosecond},
		{name: "overflow lock", concurrent: 2147483648 * time.Millisecond},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := store.Config{AllowMemoryStore: true, MigrationTimeout: tc.migration, ConcurrentIndexLockTimeout: tc.concurrent}
			if err := cfg.Check(); (err == nil) != tc.valid {
				t.Fatalf("Check() = %v, want valid=%v", err, tc.valid)
			}
		})
	}
}
