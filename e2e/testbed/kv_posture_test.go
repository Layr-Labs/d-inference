package testbed

import (
	"bytes"
	"context"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The integration lane pins an explicit paged posture so that a paged failure
// REFUSES (EngineV2KVBackendPolicy.degradesPagedFailure is false for .paged)
// instead of degrading the system under test to contiguous behind a green run.
// These tests defend the two things that pinning depends on: the posture
// actually reaches the provider, and it is legible in the log either way.

func TestGatePostureRendersBothBackendAndCap(t *testing.T) {
	t.Setenv("DARKBLOOM_TESTBED_KV_BACKEND", KVBackendPaged)
	t.Setenv("DARKBLOOM_TESTBED_MAX_CONCURRENT", "8")

	got, err := BuildProviderTOML(DefaultProviderConfig(), 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		`engine_v2_kv_backend = "paged"`,
		`engine_v2_max_concurrent = 8`,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("generated TOML missing %q:\n%s", want, got)
		}
	}
}

// Naming a backend and NOT a cap is the trap the CI lane exists to avoid: the
// generated TOML moves the provider onto its config-decoder defaults, and that
// path reads engine_v2_max_concurrent as 4 rather than the 8 the v0.8.0 flip
// put in the memberwise init. Paged at B=4 is 0.98x of contiguous where B=8 is
// 1.17x, so this combination has all of paged's cost and none of its benefit.
// Pinned so that anyone changing it has to decide deliberately.
func TestBackendWithoutCapEmitsNoCapAndInheritsTheDecoderDefault(t *testing.T) {
	t.Setenv("DARKBLOOM_TESTBED_KV_BACKEND", KVBackendPaged)
	t.Setenv("DARKBLOOM_TESTBED_MAX_CONCURRENT", "")

	got, err := BuildProviderTOML(DefaultProviderConfig(), 0)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got, `engine_v2_kv_backend = "paged"`) {
		t.Fatalf("backend not selected:\n%s", got)
	}
	if strings.Contains(got, "engine_v2_max_concurrent") {
		t.Fatalf("cap must not be synthesized when unset:\n%s", got)
	}
}

// A typo in the cap used to be swallowed, which seated the suite at the
// decoder's 4 and still passed. The knob stopped being optional when it became
// the difference between measuring paged and measuring nothing.
func TestMalformedCapFailsInsteadOfSeatingTheDefault(t *testing.T) {
	t.Setenv("DARKBLOOM_TESTBED_MAX_CONCURRENT", "8x")

	if _, err := ResolveMaxConcurrent(0); err == nil {
		t.Fatal("malformed DARKBLOOM_TESTBED_MAX_CONCURRENT resolved silently")
	}
	if _, err := BuildProviderTOML(DefaultProviderConfig(), 0); err == nil {
		t.Fatal("malformed cap did not fail config generation")
	}
}

func TestDescribeKVPostureNamesProvenance(t *testing.T) {
	t.Setenv("DARKBLOOM_TESTBED_KV_BACKEND", KVBackendPaged)
	t.Setenv("DARKBLOOM_TESTBED_MAX_CONCURRENT", "8")

	env := DescribeKVPosture(DefaultProviderConfig())
	if !strings.Contains(env, "env DARKBLOOM_TESTBED_KV_BACKEND") {
		t.Fatalf("env-sourced backend not attributed: %s", env)
	}

	suite := DefaultProviderConfig()
	suite.KVBackend = KVBackendContiguous
	suite.MaxConcurrent = 2
	if got := DescribeKVPosture(suite); !strings.Contains(got, "contiguous (suite)") {
		t.Fatalf("suite-sourced backend must win over env: %s", got)
	}

	t.Setenv("DARKBLOOM_TESTBED_KV_BACKEND", "")
	t.Setenv("DARKBLOOM_TESTBED_MAX_CONCURRENT", "")
	if got := DescribeKVPosture(DefaultProviderConfig()); !strings.Contains(
		got, "kv_backend=provider default") {
		t.Fatalf("unpinned posture must say so: %s", got)
	}

	// The kill switch degrades paged without refusing, so it is the one hole
	// an explicit selection leaves open and must be readable in the same line.
	t.Setenv("DARKBLOOM_CBV2_PAGED_KV", "0")
	if got := DescribeKVPosture(DefaultProviderConfig()); !strings.Contains(
		got, "DARKBLOOM_CBV2_PAGED_KV=0") {
		t.Fatalf("kill-switch state not surfaced: %s", got)
	}
}

// The posture log used to live inside the "a config file was written" branch,
// so the one run whose backend nobody chose was also the one run that logged
// no backend at all. That is the shape of the defect this lane fixes.
func TestPostureLoggedWhenNoConfigIsWritten(t *testing.T) {
	t.Setenv("DARKBLOOM_TESTBED_KV_BACKEND", "")
	t.Setenv("DARKBLOOM_TESTBED_MAX_CONCURRENT", "")

	stub := filepath.Join(t.TempDir(), "stub-provider")
	if err := os.WriteFile(stub, []byte("#!/bin/sh\nsleep 5\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DARKBLOOM_PROVIDER_BINARY", stub)

	var log bytes.Buffer
	p := &Provider{
		StateDir: t.TempDir(),
		Logger:   slog.New(slog.NewTextHandler(&log, nil)),
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := p.Start(ctx, "http://127.0.0.1:1/ws/provider", DefaultProviderConfig()); err != nil {
		t.Fatal(err)
	}
	p.Stop()

	if got := log.String(); !strings.Contains(got, "provider KV posture") ||
		!strings.Contains(got, "kv_backend=provider default") {
		t.Fatalf("default launch logged no KV posture:\n%s", got)
	}
	if p.generatedConfig != "" {
		t.Fatalf("default launch wrote a config: %q", p.generatedConfig)
	}
}
