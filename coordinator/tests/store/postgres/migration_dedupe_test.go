package postgres_test

import (
	"bytes"
	"os"
	"testing"
)

// TestMigrate_NoBootTimeProviderEarningsDedupe is the always-on (no-DB) guard for
// DAR-349: a boot-time `DELETE ... GROUP BY job_id` on the hot provider_earnings
// table once held a relation lock for ~15m and stopped the coordinator from
// binding :8080 (production outage). It must never return to the startup
// migration path. Dedupe, if ever needed, is an offline job
// (coordinator/store/postgres/migrations/dedupe_provider_earnings.sql).
func TestMigrate_NoBootTimeProviderEarningsDedupe(t *testing.T) {
	src, err := os.ReadFile("../../../store/postgres/migrations.go")
	if err != nil {
		t.Fatalf("read migrations.go: %v", err)
	}
	for _, banned := range []string{
		"DELETE FROM provider_earnings WHERE id NOT IN",
		"GROUP BY job_id) AND job_id",
	} {
		if bytes.Contains(src, []byte(banned)) {
			t.Fatalf("DAR-349 regression: boot-time provider_earnings dedupe reintroduced "+
				"(found %q in migrations.go); move destructive cleanup to an offline job", banned)
		}
	}
}
