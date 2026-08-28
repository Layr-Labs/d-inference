package testbed

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The provider copies a `--config` file to ~/.config/darkbloom/provider.toml
// when nothing lives there, and Stop is what undoes that copy. If it does not,
// the pinned paged @ 8 lane in .github/workflows/integration.yml leaves a
// stamped config on the host and the `.auto` default-posture smoke that runs
// after it loads paged/B=8 instead of exercising the defaults it exists for.

// migrateConfigSchema, mirrored from provider-swift/Sources/darkbloom/Darkbloom.swift.
// The real one runs at provider startup, over the canonical copy. On a file
// carrying no `config_version` it now ONLY dates the file: v0.8.1 retired the
// value migration for unstamped files because its default (4) is exactly what
// the pre-v0.8.0 releases generated, so there is nothing left to change. The
// 8 -> 4 step keys on `config_version = 1` instead, which the testbed never
// writes.
func stampLikeProvider(t *testing.T, toml string) string {
	t.Helper()
	if strings.Contains(toml, "config_version") {
		t.Fatalf("generated config is already stamped, nothing for the migration to do:\n%s", toml)
	}
	return "config_version = 2\n" + toml
}

// canonicalConfigForTest points canonicalProviderConfigPath at a temp HOME and
// seats `content` there. Returns the path.
func canonicalConfigForTest(t *testing.T, content string) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	path := canonicalProviderConfigPath()
	if path == "" {
		t.Fatal("canonical config path unresolved under a temp HOME")
	}
	if !strings.HasPrefix(path, home) {
		t.Fatalf("canonical path %q escaped the temp HOME %q", path, home)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func exists(t *testing.T, path string) bool {
	t.Helper()
	_, err := os.Stat(path)
	return err == nil
}

// The defect: cleanup compared the canonical file byte-for-byte against what
// the testbed generated, so the config_version stamp the provider prepends on
// first start made the comparison permanently false and the file permanently
// leaked.
func TestCleanupRemovesConfigAfterProviderStampedIt(t *testing.T) {
	t.Setenv("DARKBLOOM_TESTBED_KV_BACKEND", KVBackendPaged)
	t.Setenv("DARKBLOOM_TESTBED_MAX_CONCURRENT", "4")

	generated, err := BuildProviderTOML(DefaultProviderConfig(), 0)
	if err != nil {
		t.Fatal(err)
	}
	if generated == "" {
		t.Fatal("pinned posture generated no config")
	}
	stamped := stampLikeProvider(t, generated)
	if stamped == generated {
		t.Fatal("stamp left the bytes unchanged; this test would pass vacuously")
	}
	path := canonicalConfigForTest(t, stamped)

	removeMigratedTestbedConfig(generated, false)

	if exists(t, path) {
		t.Fatalf("stamped testbed config survived cleanup at %s", path)
	}
}

// The unmigrated case still has to work: a provider that never rewrote the copy
// leaves it byte-identical.
func TestCleanupRemovesUnmigratedConfig(t *testing.T) {
	t.Setenv("DARKBLOOM_TESTBED_KV_BACKEND", KVBackendPaged)
	t.Setenv("DARKBLOOM_TESTBED_MAX_CONCURRENT", "8")

	generated, err := BuildProviderTOML(DefaultProviderConfig(), 0)
	if err != nil {
		t.Fatal(err)
	}
	path := canonicalConfigForTest(t, generated)

	removeMigratedTestbedConfig(generated, false)

	if exists(t, path) {
		t.Fatalf("testbed config survived cleanup at %s", path)
	}
}

// The guard that makes the looser identity check safe: authorship, not absence.
// A config the testbed did not write is never removed, even though it appeared
// while the provider was running and so was absent at launch.
func TestCleanupRefusesConfigTheTestbedDidNotWrite(t *testing.T) {
	t.Setenv("DARKBLOOM_TESTBED_KV_BACKEND", KVBackendPaged)
	t.Setenv("DARKBLOOM_TESTBED_MAX_CONCURRENT", "8")

	generated, err := BuildProviderTOML(DefaultProviderConfig(), 0)
	if err != nil {
		t.Fatal(err)
	}
	operator := "config_version = 1\n\n[provider]\nname = \"darkbloom-mac16-1\"\n" +
		"\n[backend]\nengine_v2_kv_backend = \"paged\"\nengine_v2_max_concurrent = 8\n"
	path := canonicalConfigForTest(t, operator)

	removeMigratedTestbedConfig(generated, false)

	if !exists(t, path) {
		t.Fatalf("cleanup deleted an operator config at %s", path)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != operator {
		t.Fatalf("operator config rewritten:\n%s", got)
	}
}

// And the pre-existence guard still stands on its own: a canonical config that
// was already there at launch is left alone whatever it contains, because the
// provider never copied over it.
func TestCleanupRefusesPreExistingConfig(t *testing.T) {
	t.Setenv("DARKBLOOM_TESTBED_KV_BACKEND", KVBackendPaged)
	t.Setenv("DARKBLOOM_TESTBED_MAX_CONCURRENT", "8")

	generated, err := BuildProviderTOML(DefaultProviderConfig(), 0)
	if err != nil {
		t.Fatal(err)
	}
	path := canonicalConfigForTest(t, stampLikeProvider(t, generated))

	removeMigratedTestbedConfig(generated, true)

	if !exists(t, path) {
		t.Fatalf("cleanup deleted a pre-existing config at %s", path)
	}
}

// The cleanup helper remains a no-op when a caller has no generated config.
func TestCleanupRefusesWhenNoConfigWasGenerated(t *testing.T) {
	path := canonicalConfigForTest(t, "config_version = 1\n\n[provider]\nname = \"op\"\n")

	removeMigratedTestbedConfig("", false)

	if !exists(t, path) {
		t.Fatalf("cleanup deleted a config it never generated at %s", path)
	}
}
