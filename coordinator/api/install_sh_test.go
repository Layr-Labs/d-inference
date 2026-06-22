package api

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestInstallScriptTemplating verifies the coordinator substitutes
// __DARKBLOOM_COORD_URL__ with its configured baseURL at serve time.
// This test exists so dev and prod coordinators can serve the same embedded
// install.sh source while providers end up talking to the right environment.
func TestInstallScriptTemplating(t *testing.T) {
	t.Run("uses baseURL when set", func(t *testing.T) {
		srv := newTestServerWithBaseURL(t, "https://api.dev.darkbloom.xyz")
		defer srv.Close()

		body := fetchInstallScript(t, srv.URL)

		if strings.Contains(body, "__DARKBLOOM_COORD_URL__") {
			t.Error("install.sh still contains placeholder after serve-time substitution")
		}
		if !strings.Contains(body, `COORD_URL:-https://api.dev.darkbloom.xyz`) {
			t.Errorf("install.sh does not reference configured baseURL; got first 400 chars:\n%s", headOf(body, 400))
		}
	})

	t.Run("derives from request host when baseURL unset", func(t *testing.T) {
		srv := newTestServerWithBaseURL(t, "")
		defer srv.Close()

		body := fetchInstallScript(t, srv.URL)

		if strings.Contains(body, "__DARKBLOOM_COORD_URL__") {
			t.Error("install.sh placeholder left unsubstituted when baseURL empty")
		}
		if !strings.Contains(body, srv.URL) {
			t.Errorf("install.sh does not reference request host %q; got first 400 chars:\n%s", srv.URL, headOf(body, 400))
		}
	})

	t.Run("trailing slash in baseURL is stripped", func(t *testing.T) {
		srv := newTestServerWithBaseURL(t, "https://api.dev.darkbloom.xyz/")
		defer srv.Close()

		body := fetchInstallScript(t, srv.URL)

		if strings.Contains(body, "darkbloom.dev//") {
			t.Error("trailing slash in baseURL was not stripped; would produce double-slash URLs")
		}
	})

	// Post-Swift-cutover (v0.5.0+): install.sh no longer references R2
	// placeholders directly. Model weights are downloaded by `darkbloom
	// models download` from the public R2 CDN; the Python runtime tarball
	// is gone entirely. The R2 placeholder constants in server.go were
	// dropped along with these tests.
	t.Run("install.sh has no leftover R2 placeholders", func(t *testing.T) {
		srv := newTestServerWithBaseURL(t, "https://api.dev.darkbloom.xyz")
		defer srv.Close()

		body := fetchInstallScript(t, srv.URL)

		if strings.Contains(body, "__DARKBLOOM_R2_CDN_URL__") {
			t.Error("install.sh still references __DARKBLOOM_R2_CDN_URL__ -- handler dropped substitution")
		}
		if strings.Contains(body, "__DARKBLOOM_R2_SITE_PACKAGES_CDN_URL__") {
			t.Error("install.sh still references __DARKBLOOM_R2_SITE_PACKAGES_CDN_URL__ -- handler dropped substitution")
		}
	})

	t.Run("install.sh installs the Swift bundle, not the Python runtime", func(t *testing.T) {
		srv := newTestServerWithBaseURL(t, "https://api.dev.darkbloom.xyz")
		defer srv.Close()

		body := fetchInstallScript(t, srv.URL)

		// Swift cutover invariants -- install.sh must not download Python
		// or the vllm-mlx site-packages tarball.
		bannedSubstrings := []string{
			"vllm-mlx",
			"vllm_mlx",
			"PBS_PYTHON_VERSION",
			"python-build-standalone",
			"eigeninference-site-packages",
			"eigeninference-python-macos-arm64",
			"site-packages",
		}
		for _, b := range bannedSubstrings {
			if strings.Contains(body, b) {
				t.Errorf("install.sh contains forbidden Python-era reference %q -- Swift cutover regressed", b)
			}
		}

		// Positive assertions: the Swift bundle is installed and metallib
		// is verified.
		if !strings.Contains(body, "mlx.metallib") {
			t.Error("install.sh does not handle mlx.metallib")
		}
		if !strings.Contains(body, "eigeninference-enclave") {
			t.Error("install.sh does not install the Secure Enclave helper")
		}
	})
}

// TestInstallScriptNoDrift asserts that coordinator/api/install.sh and
// scripts/install.sh are byte-for-byte identical after normalizing the single
// intentional difference: the COORD_URL default line. In coordinator/api/install.sh
// that line carries __DARKBLOOM_COORD_URL__ (substituted at serve time); in
// scripts/install.sh it carries https://api.darkbloom.dev (direct-fetch default).
// If someone edits one copy without the other this test fails.
func TestInstallScriptNoDrift(t *testing.T) {
	// Locate scripts/install.sh relative to this source file. runtime.Caller
	// gives us the absolute path of the test file; walk up two directories to
	// the repo root, then descend into scripts/.
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller(0) failed — cannot locate test source file")
	}
	// thisFile: .../coordinator/api/install_sh_test.go
	// repoRoot: .../
	repoRoot := filepath.Join(filepath.Dir(thisFile), "..", "..")
	scriptsSrc := filepath.Join(repoRoot, "scripts", "install.sh")

	scriptsSrcBytes, err := os.ReadFile(scriptsSrc)
	if err != nil {
		if os.IsNotExist(err) {
			t.Skipf("scripts/install.sh not found at %s (vendored layout?); skipping drift check", scriptsSrc)
		}
		t.Fatalf("read scripts/install.sh: %v", err)
	}

	// installScript is the embedded coordinator/api/install.sh (package-level var).
	embedded := string(installScript)
	scriptsRef := string(scriptsSrcBytes)

	// The one intentional difference between the two copies is the COORD_URL
	// default — the placeholder (__DARKBLOOM_COORD_URL__) in the embedded copy
	// vs. the prod URL in scripts/install.sh. Collapse whatever the default is to
	// a single token so the equality check ignores it (and so this test won't
	// silently stop normalizing if the prod default ever changes).
	coordURLDefault := regexp.MustCompile(`COORD_URL="\$\{COORD_URL:-[^}]*\}"`)
	normalize := func(s string) string {
		return coordURLDefault.ReplaceAllString(s, `COORD_URL="__NORMALIZED__"`)
	}

	embeddedNorm := normalize(embedded)
	scriptsNorm := normalize(scriptsRef)

	if embeddedNorm != scriptsNorm {
		t.Errorf("coordinator/api/install.sh has drifted from scripts/install.sh\n" +
			"Run: diff scripts/install.sh coordinator/api/install.sh\n" +
			"The only intentional difference is the COORD_URL default line.\n" +
			"Sync both copies before committing.")
	}
}

func newTestServerWithBaseURL(t *testing.T, baseURL string) *httptest.Server {
	t.Helper()
	logger := slog.New(slog.DiscardHandler)
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	s := NewServer(reg, st, ServerConfig{}, logger)
	if baseURL != "" {
		s.SetBaseURL(baseURL)
	}
	return httptest.NewServer(s.Handler())
}

func fetchInstallScript(t *testing.T, base string) string {
	t.Helper()
	resp, err := http.Get(base + "/install.sh")
	if err != nil {
		t.Fatalf("GET /install.sh: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /install.sh: status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	return string(body)
}

func headOf(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}
