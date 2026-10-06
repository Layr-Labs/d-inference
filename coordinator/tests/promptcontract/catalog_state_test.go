package promptcontract_test

import (
	"errors"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/catalog"
	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/identity"
)

func TestProvisionCatalogFencesLateArtifactResults(t *testing.T) {
	state := catalog.New()
	contract := strings.Repeat("a", 64)
	old := state.Replace([]catalog.Status{{ModelID: "model", PromptContractID: contract}})
	current := state.Replace([]catalog.Status{{ModelID: "model", PromptContractID: contract}})
	state.Record(old, "model", "stale-path", nil, nil)
	status, ok := state.Status("model")
	if !ok || status.ArtifactReady || status.Path != "" || state.Snapshot().Counts.Pending != 1 {
		t.Fatalf("obsolete result crossed generation fence: %+v", status)
	}
	state.Record(current, "model", "verified-path", nil, nil)
	if snapshot := state.Snapshot(); snapshot.Generation != current || snapshot.Counts.Ready != 1 || len(snapshot.ContractIDs) != 1 {
		t.Fatalf("current result failed to publish: %+v", snapshot)
	}
	if _, err := state.Reconcile([]identity.Manifest{{ModelID: "bad"}}, 8); !errors.Is(err, identity.ErrInvalidArtifact) {
		t.Fatalf("invalid replacement was not rejected: %v", err)
	}
	state.Record(current, "model", "late-path", nil, nil)
	if _, ok := state.Status("model"); ok {
		t.Fatal("late work resurrected a rejected catalog")
	}
	if snapshot := state.Snapshot(); snapshot.Generation != current+1 || snapshot.Counts.Failed != 1 || len(snapshot.ContractIDs) != 0 {
		t.Fatalf("rejected catalog reopened: %+v", snapshot)
	}
}

func TestCatalogBoundedStatusError(t *testing.T) {
	if got := catalog.BoundedStatusError("  spaced  "); got != "spaced" {
		t.Fatalf("trimmed = %q", got)
	}
	// 512 bytes is the shared operational-status bound.
	long := strings.Repeat("x", 522)
	if got := catalog.BoundedStatusError(long); len(got) != 512 {
		t.Fatalf("bounded length = %d", len(got))
	}
}
