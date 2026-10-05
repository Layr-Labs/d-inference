package promptcontract_test

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	identity "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/identity"
	sidecar "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

// Select existing identities, never rename/relabel assets to satisfy a test.
// The actual sidecar independently verifies all artifact hashes before preload.
func admissionFixtureContracts(root string, models []string) ([]string, error) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, err
	}
	selected := map[string]string{}
	for _, entry := range entries {
		if !entry.IsDir() || !sidecar.ValidHash(entry.Name()) {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(root, entry.Name(), identity.MetadataFile))
		if err != nil {
			return nil, err
		}
		var m identity.Metadata
		if err = json.Unmarshal(raw, &m); err != nil {
			return nil, err
		}
		wanted := false
		for _, model := range models {
			if m.ModelID == model {
				wanted = true
			}
		}
		if !wanted {
			continue
		}
		id, err := identity.ContractID(m.Artifacts, m.Versions)
		if err != nil || m.SchemaVersion != 1 || m.Versions != identity.CurrentVersions() || id != m.PromptContractID || id != entry.Name() {
			return nil, fmt.Errorf("fixture %s has stale or mismatched contract identity", m.ModelID)
		}
		if selected[m.ModelID] != "" {
			return nil, fmt.Errorf("ambiguous fixture model %s", m.ModelID)
		}
		selected[m.ModelID] = id
	}
	ids := make([]string, len(models))
	for i, model := range models {
		ids[i] = selected[model]
		if ids[i] == "" {
			return nil, fmt.Errorf("missing current fixture for %s", model)
		}
	}
	return ids, nil
}
func TestAdmissionFixtureIdentityRejectsStaleAndMismatchedMetadata(t *testing.T) {
	for _, kind := range []string{"current", "stale", "wrong-id"} {
		t.Run(kind, func(t *testing.T) {
			artifacts := []identity.Artifact{{Path: "config.json", Role: "config", SizeBytes: 2, SHA256: strings.Repeat("a", 64)}}
			id, err := identity.ContractID(artifacts, identity.CurrentVersions())
			if err != nil {
				t.Fatal(err)
			}
			m := identity.Metadata{SchemaVersion: 1, ModelID: "fixture", PromptContractID: id, Artifacts: artifacts, Versions: identity.CurrentVersions()}
			if kind == "stale" {
				m.Versions.Normalization = "darkbloom-request-normalization-v6"
			}
			if kind == "wrong-id" {
				m.PromptContractID = strings.Repeat("b", 64)
			}
			root := t.TempDir()
			if err = os.Mkdir(filepath.Join(root, id), 0700); err != nil {
				t.Fatal(err)
			}
			raw, _ := json.Marshal(m)
			if err = os.WriteFile(filepath.Join(root, id, identity.MetadataFile), raw, 0600); err != nil {
				t.Fatal(err)
			}
			ids, err := admissionFixtureContracts(root, []string{"fixture"})
			if kind == "current" {
				if err != nil || len(ids) != 1 || ids[0] != id {
					t.Fatal(ids, err)
				}
			} else if err == nil {
				t.Fatal("bad metadata accepted")
			}
		})
	}
}
