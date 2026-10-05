package operations_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/api/operations/exportconfig"
)

func TestResolveStateExportRootPrecedence_DAR70(t *testing.T) {
	// Default when nothing is set.
	t.Setenv(exportconfig.RootEnv, "")
	t.Setenv("USER_PERSISTENT_DATA_PATH", "")
	if got := exportconfig.Root(); got != "/mnt/disks/userdata" {
		t.Fatalf("default = %q, want /mnt/disks/userdata", got)
	}
	// USER_PERSISTENT_DATA_PATH wins over the hardcoded default.
	t.Setenv("USER_PERSISTENT_DATA_PATH", "/persist")
	if got := exportconfig.Root(); got != "/persist" {
		t.Fatalf("with USER_PERSISTENT_DATA_PATH = %q, want /persist", got)
	}
	// Explicit override wins over everything.
	t.Setenv(exportconfig.RootEnv, "/explicit")
	if got := exportconfig.Root(); got != "/explicit" {
		t.Fatalf("with override = %q, want /explicit", got)
	}
}
