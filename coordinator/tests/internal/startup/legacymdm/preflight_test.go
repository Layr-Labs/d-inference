package legacymdm_test

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	command "github.com/eigeninference/d-inference/coordinator/internal/command/coordinator"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testdb"
	"github.com/jackc/pgx/v5"
)

func TestMain(m *testing.M) { testdb.Main(m) }

func TestInvalidProductionTrustFailsBeforeMigrations(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL is required for an isolated PostgreSQL startup test")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	db, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close(context.Background())
	assertEmptySchema := func(t *testing.T) {
		t.Helper()
		var count int
		if err := db.QueryRow(ctx, "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'").Scan(&count); err != nil {
			t.Fatal(err)
		}
		if count != 0 {
			t.Fatalf("startup changed the empty database: %d public tables (including any goose history)", count)
		}
	}
	assertEmptySchema(t)

	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, deployment, serving, proofEnvironment, rollout, allowMemory string
	}{
		{"serving disabled", "production", "false", "production", "100", "false"},
		{"wrong proof environment", "production", "true", "development", "100", "false"},
		{"partial rollout", "production", "true", "production", "99", "false"},
		{"malformed rollout", "production", "true", "production", "invalid", "false"},
		{"default deployment is production", "", "false", "production", "100", "false"},
		{"database overrides memory opt-in", "production", "false", "production", "100", "true"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cmd := exec.CommandContext(ctx, binary, "-test.run=^TestProductionTrustPreflightProcess$")
			// Do not inherit credentials or operational settings from the test runner.
			cmd.Env = []string{
				"PRODUCTION_TRUST_PREFLIGHT_PROCESS=1",
				"EIGENINFERENCE_DATABASE_URL=" + dsn,
				"EIGENINFERENCE_DEPLOYMENT_ENVIRONMENT=" + tc.deployment,
				"EIGENINFERENCE_ALLOW_MEMORY_STORE=" + tc.allowMemory,
				"EIGENINFERENCE_APP_ATTEST_SERVING=" + tc.serving,
				"EIGENINFERENCE_APP_ATTEST_ENVIRONMENT=" + tc.proofEnvironment,
				"EIGENINFERENCE_APP_ATTEST_ROLLOUT_PERCENT=" + tc.rollout,
				"EIGENINFERENCE_PROMPT_SIDECAR_ENABLED=false",
			}
			output, err := cmd.CombinedOutput()
			assertEmptySchema(t)
			var exit *exec.ExitError
			if !errors.As(err, &exit) || exit.ExitCode() != 1 {
				t.Fatalf("startup exit = %v, want 1\n%s", err, output)
			}
			if !strings.Contains(string(output), "invalid configuration") || !strings.Contains(string(output), "app_attest: legacy MDM freeze requires") {
				t.Fatalf("startup did not fail at trust configuration preflight:\n%s", output)
			}
		})
	}
}

func TestProductionTrustPreflightProcess(t *testing.T) {
	if os.Getenv("PRODUCTION_TRUST_PREFLIGHT_PROCESS") != "1" {
		return
	}
	os.Args = []string{"coordinator"}
	command.Main()
	os.Exit(0)
}
