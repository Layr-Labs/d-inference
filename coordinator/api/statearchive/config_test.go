package statearchive

import "testing"

// resolveStateExportRoot precedence:
// EIGENINFERENCE_STATE_EXPORT_ROOT -> USER_PERSISTENT_DATA_PATH -> /mnt/disks/userdata.
func TestResolveStateExportRootPrecedence_DAR70(t *testing.T) {
	// Default when nothing is set.
	t.Setenv(envStateExportRoot, "")
	t.Setenv("USER_PERSISTENT_DATA_PATH", "")
	if got := resolveStateExportRoot(); got != "/mnt/disks/userdata" {
		t.Fatalf("default = %q, want /mnt/disks/userdata", got)
	}
	// USER_PERSISTENT_DATA_PATH wins over the hardcoded default.
	t.Setenv("USER_PERSISTENT_DATA_PATH", "/persist")
	if got := resolveStateExportRoot(); got != "/persist" {
		t.Fatalf("with USER_PERSISTENT_DATA_PATH = %q, want /persist", got)
	}
	// Explicit override wins over everything.
	t.Setenv(envStateExportRoot, "/explicit")
	if got := resolveStateExportRoot(); got != "/explicit" {
		t.Fatalf("with override = %q, want /explicit", got)
	}
}
