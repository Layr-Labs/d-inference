package coordinator_test

import (
	"context"
	"net"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	command "github.com/eigeninference/d-inference/coordinator/internal/command/coordinator"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/pressly/goose/v3/lock"
)

func TestMaintenanceRejectsUnknownArgumentsAndMemoryStore(t *testing.T) {
	t.Setenv("EIGENINFERENCE_DATABASE_URL", "")
	for _, args := range [][]string{{"--unknown"}, {"--migrate-only", "unexpected"}, {"--migrate-only"}} {
		if err := command.Maintenance(args); err == nil {
			t.Fatalf("accepted %q", args)
		}
	}
}

func TestMaintenanceRejectsInvalidTimeoutsBeforeDatabase(t *testing.T) {
	t.Setenv("EIGENINFERENCE_DATABASE_URL", "://invalid")
	for _, name := range []string{"EIGENINFERENCE_MIGRATION_TIMEOUT", "EIGENINFERENCE_CONCURRENT_INDEX_LOCK_TIMEOUT"} {
		for _, value := range []string{"", "invalid", "0s", "-1s"} {
			t.Run(name+"/"+value, func(t *testing.T) {
				t.Setenv("EIGENINFERENCE_MIGRATION_TIMEOUT", "15m")
				t.Setenv("EIGENINFERENCE_CONCURRENT_INDEX_LOCK_TIMEOUT", "1m")
				t.Setenv(name, value)
				if err := command.Maintenance([]string{"--migrate-only"}); err == nil || !strings.Contains(err.Error(), name) {
					t.Fatalf("Maintenance() = %v, want %s validation error", err, name)
				}
			})
		}
	}
}

func TestMaintenanceUsesConfiguredDeadline(t *testing.T) {
	db := os.Getenv("DATABASE_URL")
	if db == "" {
		t.Skip("DATABASE_URL not set")
	}
	t.Setenv("EIGENINFERENCE_DATABASE_URL", db)
	t.Setenv("EIGENINFERENCE_MIGRATION_TIMEOUT", "200ms")
	t.Setenv("EIGENINFERENCE_CONCURRENT_INDEX_LOCK_TIMEOUT", "1m")
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, db)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	holder, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Release()
	if _, err := holder.Exec(ctx, "SELECT pg_advisory_lock($1)", lock.DefaultLockID); err != nil {
		t.Fatal(err)
	}
	defer holder.Exec(ctx, "SELECT pg_advisory_unlock($1)", lock.DefaultLockID)
	started := time.Now()
	err = command.Maintenance([]string{"--migrate-only"})
	if err == nil || !strings.Contains(err.Error(), "context deadline exceeded") {
		t.Fatalf("blocked maintenance = %v, want deadline exceeded", err)
	}
	if elapsed := time.Since(started); elapsed < 150*time.Millisecond || elapsed > 3*time.Second {
		t.Fatalf("configured 200ms deadline took %s", elapsed)
	}
	if _, err := holder.Exec(ctx, "SELECT pg_advisory_unlock($1)", lock.DefaultLockID); err != nil {
		t.Fatal(err)
	}
	t.Setenv("EIGENINFERENCE_MIGRATION_TIMEOUT", "30s")
	if err := command.Maintenance([]string{"--migrate-only"}); err != nil {
		t.Fatalf("maintenance after releasing lock and extending deadline: %v", err)
	}
}

// Execute the real main entrypoint in a child, with a throwaway DB supplied by
// the integration runner. Occupy the HTTP port and supply an admin key: success
// plus absence of that key proves maintenance returns before serving/seeding.
func TestMaintenanceProcessDoesNotServeOrSeedAdmin(t *testing.T) {
	db := os.Getenv("DATABASE_URL")
	if db == "" {
		t.Skip("DATABASE_URL not set")
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	_, port, _ := net.SplitHostPort(listener.Addr().String())
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestMaintenanceHelperProcess$")
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + t.TempDir(), "FAST_STARTUP_TEST_HELPER=1",
		"EIGENINFERENCE_DATABASE_URL=" + db, "EIGENINFERENCE_ADMIN_KEY=maintenance-must-not-seed",
		"EIGENINFERENCE_DEPLOYMENT_ENVIRONMENT=invalid-deployment",
		"EIGENINFERENCE_APP_ATTEST_SERVING=false", "EIGENINFERENCE_APP_ATTEST_ROLLOUT_PERCENT=0",
		"EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_ONLY=invalid-billing",
		"EIGENINFERENCE_PORT=" + port}
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("maintenance child: %v\n%s", err, output)
	}
	if !strings.Contains(string(output), "coordinator migrations complete") || strings.Contains(string(output), "using PostgreSQL store") {
		t.Fatalf("unexpected startup path: %s", output)
	}
	pool, err := pgxpool.New(ctx, db)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM api_keys WHERE key_hash=encode(sha256('maintenance-must-not-seed'::bytea),'hex')`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("admin key seeded: %d %v", n, err)
	}
}

func TestMaintenanceHelperProcess(t *testing.T) {
	if os.Getenv("FAST_STARTUP_TEST_HELPER") != "1" {
		return
	}
	os.Args = []string{"coordinator", "--migrate-only"}
	command.Main()
	os.Exit(0)
}
