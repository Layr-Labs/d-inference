package postgres_test

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// TestMigrate_NoBootTimeProviderEarningsDedupe is the always-on (no-DB) guard for
// DAR-349: a boot-time `DELETE ... GROUP BY job_id` on the hot provider_earnings
// table once held a relation lock for ~15m and stopped the coordinator from
// binding :8080 (production outage). It must never return to the startup
// migration path: the goose runner and its SQL migrations. Dedupe, if ever
// needed, is an offline job
// (coordinator/store/postgres/migrations/dedupe_provider_earnings.sql).
func TestMigrate_NoBootTimeProviderEarningsDedupe(t *testing.T) {
	sqlFiles, err := filepath.Glob(filepath.Join(migrationSQLDir, "*.sql"))
	if err != nil || len(sqlFiles) == 0 {
		t.Fatalf("list SQL migrations in %s: %v (%d files)", migrationSQLDir, err, len(sqlFiles))
	}
	for _, path := range append([]string{"../../../store/postgres/migrations.go"}, sqlFiles...) {
		src, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		for _, banned := range []string{
			"DELETE FROM provider_earnings WHERE id NOT IN",
			"GROUP BY job_id) AND job_id",
		} {
			if bytes.Contains(src, []byte(banned)) {
				t.Fatalf("DAR-349 regression: boot-time provider_earnings dedupe reintroduced "+
					"(found %q in %s); move destructive cleanup to an offline job", banned, filepath.Base(path))
			}
		}
	}
}
