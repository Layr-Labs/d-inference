package api

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
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

	t.Run("R2 CDN URL substituted when set", func(t *testing.T) {
		srv := newTestServerWithR2(t, "https://pub-devxxx.r2.dev", "https://pub-devpkg.r2.dev")
		defer srv.Close()

		body := fetchInstallScript(t, srv.URL)

		if strings.Contains(body, "__DARKBLOOM_R2_CDN_URL__") {
			t.Error("R2 CDN placeholder not substituted")
		}
		if strings.Contains(body, "__DARKBLOOM_R2_SITE_PACKAGES_CDN_URL__") {
			t.Error("R2 site-packages CDN placeholder not substituted")
		}
		if !strings.Contains(body, "https://pub-devxxx.r2.dev") {
			t.Error("dev R2 CDN URL not present after substitution")
		}
		if !strings.Contains(body, "https://pub-devpkg.r2.dev") {
			t.Error("dev R2 site-packages URL not present after substitution")
		}
	})

	t.Run("R2 site-packages CDN defaults to R2 CDN when unset", func(t *testing.T) {
		srv := newTestServerWithR2(t, "https://pub-devxxx.r2.dev", "")
		defer srv.Close()

		body := fetchInstallScript(t, srv.URL)

		if strings.Contains(body, "__DARKBLOOM_R2_SITE_PACKAGES_CDN_URL__") {
			t.Error("R2 site-packages placeholder left unsubstituted when R2 CDN is set")
		}
	})
}

func newTestServerWithR2(t *testing.T, cdnURL, sitePackagesURL string) *httptest.Server {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	st := store.NewMemory("")
	reg := registry.New(logger)
	s := NewServer(reg, st, logger)
	s.SetBaseURL("https://api.dev.darkbloom.xyz")
	s.SetR2CDNURL(cdnURL)
	if sitePackagesURL != "" {
		s.SetR2SitePackagesCDNURL(sitePackagesURL)
	}
	return httptest.NewServer(s.Handler())
}

func newTestServerWithBaseURL(t *testing.T, baseURL string) *httptest.Server {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	st := store.NewMemory("")
	reg := registry.New(logger)
	s := NewServer(reg, st, logger)
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
