package e2e

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"golang.org/x/crypto/nacl/box"
)

// TestCrossLanguageEncryption verifies that payloads encrypted by the Go
// coordinator can be decrypted by the Rust provider's crypto_box crate.
//
// It builds a minimal Rust decryptor from testdata/decrypt, encrypts a payload
// using the Go e2e package, then shells out to the Rust binary and checks that
// the decrypted output matches the original plaintext.
//
// Skipped automatically when `cargo` is not on PATH.
func TestCrossLanguageEncryption(t *testing.T) {
	if _, err := exec.LookPath("cargo"); err != nil {
		t.Skip("cargo not found — skipping cross-language test")
	}

	// Locate the Rust decryptor crate.
	crateDir := filepath.Join("testdata", "decrypt")
	if _, err := os.Stat(filepath.Join(crateDir, "Cargo.toml")); err != nil {
		t.Fatalf("Rust decryptor crate not found at %s: %v", crateDir, err)
	}

	// Build the Rust decryptor (release mode for speed).
	t.Log("Building Rust decryptor…")
	build := exec.Command("cargo", "build", "--release")
	build.Dir = crateDir
	build.Env = append(os.Environ(), "CARGO_TERM_COLOR=never")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("cargo build failed:\n%s\n%v", out, err)
	}
	t.Log("Rust decryptor built successfully")

	binaryPath := filepath.Join(crateDir, "target", "release", "decrypt-test")
	if _, err := os.Stat(binaryPath); err != nil {
		t.Fatalf("built binary not found at %s: %v", binaryPath, err)
	}

	// Clean up build artifacts when the test finishes.
	t.Cleanup(func() {
		targetDir := filepath.Join(crateDir, "target")
		os.RemoveAll(targetDir)
	})

	// Sub-tests cover different payload types.
	t.Run("JSONPayload", func(t *testing.T) {
		plaintext := []byte(`{"model":"test-model","messages":[{"role":"user","content":"hello from Go"}]}`)
		testCrossDecrypt(t, binaryPath, plaintext)
	})

	t.Run("EmptyPayload", func(t *testing.T) {
		testCrossDecrypt(t, binaryPath, []byte(""))
	})

	t.Run("UnicodePayload", func(t *testing.T) {
		plaintext := []byte(`{"content":"こんにちは世界 🌍 émojis & ünïcödé"}`)
		testCrossDecrypt(t, binaryPath, plaintext)
	})

	t.Run("LargePayload", func(t *testing.T) {
		// 64 KB of repeated text to test chunked encryption.
		payload := bytes.Repeat([]byte("The quick brown fox jumps over the lazy dog. "), 1500)
		testCrossDecrypt(t, binaryPath, payload)
	})

	t.Run("MultipleRoundTrips", func(t *testing.T) {
		// Encrypt the same plaintext multiple times with different sessions.
		// Each should produce different ciphertext but all should decrypt correctly.
		plaintext := []byte("determinism check — same input, different nonces")
		for i := 0; i < 5; i++ {
			testCrossDecrypt(t, binaryPath, plaintext)
		}
	})
}

// testCrossDecrypt encrypts plaintext with Go, decrypts it with Rust, and
// verifies the output matches.
func testCrossDecrypt(t *testing.T, binaryPath string, plaintext []byte) {
	t.Helper()

	// Generate a provider key pair (simulates the provider's long-lived keys).
	providerPub, providerPriv, err := box.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("box.GenerateKey: %v", err)
	}

	// Generate a coordinator ephemeral session (per-request forward secrecy).
	session, err := GenerateSessionKeys()
	if err != nil {
		t.Fatalf("GenerateSessionKeys: %v", err)
	}

	// Encrypt using the Go e2e package.
	encrypted, err := Encrypt(plaintext, *providerPub, session)
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	// Prepare base64 arguments for the Rust decryptor.
	ephPubB64 := encrypted.EphemeralPublicKey
	ciphertextB64 := encrypted.Ciphertext
	privKeyB64 := base64.StdEncoding.EncodeToString(providerPriv[:])

	// Run the Rust decryptor.
	cmd := exec.Command(binaryPath, ephPubB64, ciphertextB64, privKeyB64)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		t.Fatalf("Rust decryptor failed: %v\nstderr: %s", err, stderr.String())
	}

	// Compare output.
	if !bytes.Equal(stdout.Bytes(), plaintext) {
		t.Errorf("plaintext mismatch:\n  Go sent:      %q\n  Rust returned: %q", plaintext, stdout.Bytes())
	}
}
