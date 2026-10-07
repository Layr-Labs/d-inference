package api_test

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api"
)

func TestEmbeddedInstallerMatchesCanonicalSource(t *testing.T) {
	const installScriptPlaceholder = "__DARKBLOOM_COORD_URL__"
	srv, _ := testServerWithConfig(t, production.ServerConfig{BaseURL: installScriptPlaceholder})
	response := httptest.NewRecorder()
	srv.Handler().ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/install.sh", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("installer response = %d", response.Code)
	}
	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("resolve test source path")
	}
	canonicalPath := filepath.Join(filepath.Dir(currentFile), "..", "..", "..", "scripts", "install.sh")
	canonical, err := os.ReadFile(canonicalPath)
	if err != nil {
		t.Fatalf("read canonical installer: %v", err)
	}
	if !bytes.Equal(canonical, response.Body.Bytes()) {
		t.Fatal("embedded installer drifted from scripts/install.sh; run scripts/sync-install-embed.sh")
	}
	if count := bytes.Count(canonical, []byte(installScriptPlaceholder)); count != 1 {
		t.Fatalf("canonical installer contains %d coordinator placeholders, want exactly 1", count)
	}
}
