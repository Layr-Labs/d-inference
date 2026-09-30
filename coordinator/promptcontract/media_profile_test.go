package promptcontract

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"testing"
)

func TestNativeMediaProfileRequiresVerifiedConfiguration(t *testing.T) {
	data, err := os.ReadFile("../mediawork/testdata/mimo-config.json")
	if err != nil {
		t.Fatal(err)
	}
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write(data) }))
	defer origin.Close()
	base, _ := url.Parse(origin.URL)
	cache, err := NewArtifactCache(ArtifactCacheConfig{Root: readOnlyTempRoot(t), BaseURL: base, HTTPClient: origin.Client(), AllowHTTP: true})
	if err != nil {
		t.Fatal(err)
	}
	manifest := fixtureNestedManifest("config.json", data)
	manifest.Files[0].Role = "config"
	path, err := cache.Ensure(context.Background(), manifest)
	if err != nil {
		t.Fatal(err)
	}
	if profile := cache.mediaProfile(manifest); profile == nil {
		t.Fatal("verified native profile unavailable")
	}
	config := filepath.Join(path, "config.json")
	if err := os.Chmod(config, 0o600); err != nil {
		t.Fatal(err)
	}
	tampered := append([]byte(nil), data...)
	tampered[len(tampered)-1] = ' '
	if err := os.WriteFile(config, tampered, 0o400); err != nil {
		t.Fatal(err)
	}
	if cache.mediaProfile(manifest) != nil {
		t.Fatal("tampered config granted metadata accounting")
	}
	if err := os.WriteFile(config, data, 0o400); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(config, 0o400); err != nil {
		t.Fatal(err)
	}
	manifest.Files[0].Role = "tokenizer"
	if cache.mediaProfile(manifest) != nil {
		t.Fatal("unbound config role granted accounting")
	}
}
