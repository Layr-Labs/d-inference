package api

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestAdminScriptHardwarePolicySetSendsBreakGlass(t *testing.T) {
	workingDirectory, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(
		workingDirectory, "..", "..", "scripts", "admin.sh")
	fakeBin := t.TempDir()
	fakeCurl := filepath.Join(fakeBin, "curl")
	if err := os.WriteFile(fakeCurl, []byte(`#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-d" ]; then
        shift
        printf '%s\n' "$1"
        exit 0
    fi
    shift
done
exit 1
`), 0o755); err != nil {
		t.Fatal(err)
	}

	command := exec.Command(
		script,
		"hardware-policy", "set",
		"disabled", "0", "0", "0", "7",
		"incident rollback", "--break-glass",
	)
	command.Env = append(
		os.Environ(),
		"PATH="+fakeBin+string(os.PathListSeparator)+os.Getenv("PATH"),
		"EIGENINFERENCE_ADMIN_KEY=test-admin-key",
		"EIGENINFERENCE_COORDINATOR_URL=https://coordinator.example.test",
		"HOME="+t.TempDir(),
	)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("admin script failed: %v\n%s", err, output)
	}

	var body struct {
		Mode                   string `json:"mode"`
		ExpectedCurrentVersion int64  `json:"expected_current_version"`
		Reason                 string `json:"reason"`
		BreakGlass             bool   `json:"break_glass"`
	}
	if err := json.Unmarshal(output, &body); err != nil {
		t.Fatalf("decode admin request body: %v\n%s", err, output)
	}
	if body.Mode != "disabled" ||
		body.ExpectedCurrentVersion != 7 ||
		body.Reason != "incident rollback" ||
		!body.BreakGlass {
		t.Fatalf("admin policy request = %+v", body)
	}
}
