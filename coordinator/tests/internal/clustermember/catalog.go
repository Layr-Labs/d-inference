package clustermember

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Approval is one complete entry of an operator approval file for model on the
// given chips (sorted by the caller), with fixed fixture digests.
func Approval(id, model string, chips ...string) map[string]any {
	digest := func(label string) string {
		sum := sha256.Sum256([]byte("cluster-pair-fixture-" + label))
		return hex.EncodeToString(sum[:])
	}
	return map[string]any{
		"id": id, "model": model, "generation": 3,
		"plan_sha256": digest("plan"), "artifact_sha256": digest("artifact"),
		"native_runtime_sha256": digest("native"), "metallib_sha256": digest("metallib"),
		"resource_library_sha256": digest("resources"), "capability_sha256": digest("capability"),
		"resource_policy_sha256": digest("resource-policy"), "profile_sha256": digest("profile"),
		"schedule": 1, "maximum_transport_frame": 4136, "maximum_plaintext": 4096,
		"maximum_records": 64, "maximum_cumulative_plaintext": 262144,
		"allowed_chips": chips, "not_after": time.Now().Add(24 * time.Hour).UTC().Format(time.RFC3339),
	}
}

// CatalogDocument is the approval file content for the given entries.
func CatalogDocument(t testing.TB, approvals ...map[string]any) []byte {
	t.Helper()
	data, err := json.Marshal(map[string]any{"schema": registry.NativeRuntimeCatalogSchema, "approvals": approvals})
	if err != nil {
		t.Fatal(err)
	}
	return data
}

// CatalogFile writes an operator approval file and returns its absolute path.
func CatalogFile(t testing.TB, approvals ...map[string]any) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "cluster-pair-catalog.json")
	if err := os.WriteFile(path, CatalogDocument(t, approvals...), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// PolicySHA256 is the commitment a member installed for approval id: the
// value it registers as cluster_membership.policy_sha256.
func PolicySHA256(t testing.TB, document []byte, id string) string {
	t.Helper()
	catalog, err := registry.ParseNativeRuntimeCatalog(document)
	if err != nil {
		t.Fatal(err)
	}
	policy, ok := catalog.PolicySHA256(id)
	if !ok {
		t.Fatalf("approval %q is not in the catalog", id)
	}
	return policy
}
