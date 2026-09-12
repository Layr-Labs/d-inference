package e2e

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/stretchr/testify/require"
)

// releasedMetallibName is the Metal shader library shipped beside the
// released executable inside the bundle, per scripts/fetch-v0712-provider.sh
// (it resolves "$EXTRACTED/Darkbloom.app/Contents/MacOS/mlx.metallib").
const releasedMetallibName = "mlx.metallib"

// requirePinnedReleasedProvider is the anti-vacuous-pass check for this
// gate. It proves the lane is running against the exact released v0.7.12
// artifact the compatibility claim is about.
//
// Both halves of the bundle are pinned, because both determine behaviour
// the gate observes. The executable fixes the wire contract; the metallib
// fixes the kernels that produce the tokens, and it is a separate file that
// can be swapped without touching the binary. The fetch script already
// verifies both (BINARY_SHA256 at :38, METALLIB_SHA256 at :51) — checking
// only one here would let a hand-assembled bundle through a gate whose
// entire value is that it cannot be fooled by a local build.
func requirePinnedReleasedProvider(t *testing.T, path string) {
	t.Helper()
	require.NoError(t, verifyPinnedBundle(path,
		pinnedReleasedDigest(t, "BINARY_SHA256"),
		pinnedReleasedDigest(t, "METALLIB_SHA256")),
		"the bundle at DARKBLOOM_PROVIDER_BINARY is not the hash-pinned released "+
			"v0.7.12 artifact; re-fetch it with scripts/fetch-v0712-provider.sh")
}

// verifyPinnedBundle checks both halves of the bundle against their pinned
// digests and returns the first mismatch. It is split out from
// requirePinnedReleasedProvider so every rejection path — including a
// drifted or missing metallib beside a correct executable — is testable
// without a copy of the real released artifact.
func verifyPinnedBundle(binaryPath, wantBinary, wantMetallib string) error {
	info, err := os.Stat(binaryPath)
	if err != nil {
		return fmt.Errorf("released provider binary is unreadable: %w", err)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("released provider binary is not a regular file: %s", binaryPath)
	}
	if info.Mode()&0o111 == 0 {
		return fmt.Errorf("released provider binary is not executable: %s", binaryPath)
	}
	got, err := fileSHA256(binaryPath)
	if err != nil {
		return err
	}
	if got != wantBinary {
		return fmt.Errorf("released provider binary digest %s does not match pinned %s (%s)",
			got, wantBinary, binaryPath)
	}

	metallib := filepath.Join(filepath.Dir(binaryPath), releasedMetallibName)
	metallibInfo, err := os.Stat(metallib)
	if err != nil {
		return fmt.Errorf("released v0.7.12 metallib is missing beside the binary: %w", err)
	}
	if !metallibInfo.Mode().IsRegular() {
		return fmt.Errorf("released v0.7.12 metallib is not a regular file: %s", metallib)
	}
	got, err = fileSHA256(metallib)
	if err != nil {
		return err
	}
	if got != wantMetallib {
		return fmt.Errorf("released v0.7.12 metallib digest %s does not match pinned %s (%s)",
			got, wantMetallib, metallib)
	}
	return nil
}

// pinnedReleasedDigest reads the named <VAR>_SHA256 assignment out of
// scripts/fetch-v0712-provider.sh rather than restating it, so each pin has
// exactly one definition and the test cannot drift away from the fetcher.
func pinnedReleasedDigest(t *testing.T, variable string) string {
	t.Helper()
	root := os.Getenv("DARKBLOOM_REPO_ROOT")
	if root == "" {
		cwd, err := os.Getwd()
		require.NoError(t, err)
		root = filepath.Clean(filepath.Join(cwd, ".."))
	}
	script := filepath.Join(root, "scripts", "fetch-v0712-provider.sh")
	contents, err := os.ReadFile(script)
	require.NoError(t, err,
		"released-provider fetch script is the single source of truth for the %s pin",
		variable)
	for _, line := range strings.Split(string(contents), "\n") {
		value, found := strings.CutPrefix(strings.TrimSpace(line), variable+"=")
		if !found {
			continue
		}
		value = strings.Trim(value, `"'`)
		require.Len(t, value, 64,
			"%s in %s is not a SHA-256 hex digest", variable, script)
		return value
	}
	require.FailNow(t, "no "+variable+" pin found in "+script)
	return ""
}

// Pin verification must reject special files before hashing: opening a FIFO
// can block the compatibility job indefinitely without a provider ever starting.
func TestMixedVersionArtifactRejectsNonRegularInputs(t *testing.T) {
	for _, target := range []string{"darkbloom", releasedMetallibName} {
		for _, kind := range []string{"directory", "fifo"} {
			t.Run(target+"/"+kind, func(t *testing.T) {
				root := t.TempDir()
				binary := filepath.Join(root, "darkbloom")
				contents := []byte("verified fixture")
				digest := sha256.Sum256(contents)
				expected := hex.EncodeToString(digest[:])
				for _, name := range []string{"darkbloom", releasedMetallibName} {
					path := filepath.Join(root, name)
					if name != target {
						require.NoError(t, os.WriteFile(path, contents, 0755))
					} else if kind == "directory" {
						require.NoError(t, os.Mkdir(path, 0755))
					} else {
						require.NoError(t, syscall.Mkfifo(path, 0755))
					}
				}
				require.ErrorContains(t, verifyPinnedBundle(binary, expected, expected), "not a regular file")
			})
		}
	}
}

func TestMixedVersionArtifactRejectsNonExecutableOrWrongBinary(t *testing.T) {
	root := t.TempDir()
	binary := filepath.Join(root, "darkbloom")
	contents := []byte("verified fixture")
	digest := sha256.Sum256(contents)
	expected := hex.EncodeToString(digest[:])
	require.NoError(t, os.WriteFile(binary, contents, 0600))
	require.NoError(t, os.WriteFile(filepath.Join(root, releasedMetallibName), contents, 0600))
	require.ErrorContains(t, verifyPinnedBundle(binary, expected, expected), "not executable")
	require.NoError(t, os.Chmod(binary, 0755))
	require.ErrorContains(t, verifyPinnedBundle(binary, strings.Repeat("0", 64), expected), "binary digest")
	require.NoError(t, verifyPinnedBundle(binary, expected, expected))
}
