package promptcontract

import "testing"

func TestDefaultArtifactRootUsesPhysicalPersistentPath(t *testing.T) {
	t.Setenv("EIGENINFERENCE_PROMPT_SIDECAR_ARTIFACT_ROOT", "")

	config := ReadSupervisorConfig()
	if config.ArtifactRoot != "/mnt/disks/userdata/prompt-contracts" {
		t.Fatalf("artifact root = %q", config.ArtifactRoot)
	}
}
