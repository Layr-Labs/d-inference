package main

import (
	"context"
	"net"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestMaintenanceRejectsUnknownArgumentsAndMemoryStore(t *testing.T) {
	t.Setenv("EIGENINFERENCE_DATABASE_URL", "")
	for _, args := range [][]string{{"--unknown"}, {"--migrate-only", "unexpected"}, {"--migrate-only"}} {
		if err := runMaintenanceCommand(args); err == nil {
			t.Fatalf("accepted %q", args)
		}
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
	main()
	os.Exit(0)
}
