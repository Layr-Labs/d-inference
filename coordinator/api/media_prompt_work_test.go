package api

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"image"
	"image/png"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func nativeMediaAccountingServer(t *testing.T) (*Server, string, string) {
	t.Helper()
	config, err := os.ReadFile("../mediawork/testdata/mimo-config.json")
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(config)
	aggregate := sha256.Sum256(digest[:])
	hash := hex.EncodeToString(aggregate[:])
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write(config) }))
	t.Cleanup(origin.Close)
	base, _ := url.Parse(origin.URL)
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = filepath.Walk(root, func(p string, _ os.FileInfo, _ error) error { return os.Chmod(p, 0o700) })
	})
	cache, err := promptcontract.NewArtifactCache(promptcontract.ArtifactCacheConfig{Root: root, BaseURL: base, HTTPClient: origin.Client(), AllowHTTP: true})
	if err != nil {
		t.Fatal(err)
	}
	provisioner, err := promptcontract.NewProvisioner(context.Background(), cache, promptcontract.ProvisionerConfig{MaxConcurrent: 1, MaxModels: 1})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(provisioner.Close)
	s, _ := testServerWithConfig(t, ServerConfig{FirstContentDeadlineBase: 9 * time.Second})
	s.SetPromptArtifactProvisioner(provisioner)
	const model = "native-media-accounting-fixture"
	s.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, WeightHash: hash}})
	err = s.reconcilePromptArtifacts([]store.ModelRegistryRecord{{ModelRegistryEntry: store.ModelRegistryEntry{ID: model}, ActiveVersion: &store.ModelVersion{R2Prefix: "models/fixture", AggregateSHA256: hash}, Files: []store.ModelVersionFile{{Path: "config.json", Role: "config", SizeBytes: int64(len(config)), SHA256: hex.EncodeToString(digest[:])}}}})
	if err != nil {
		t.Fatal(err)
	}
	limit := time.Now().Add(3 * time.Second)
	for time.Now().Before(limit) {
		if status, ok := provisioner.Status(model); ok && status.ArtifactReady && status.MediaProfile != nil {
			return s, model, hash
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("native profile not provisioned")
	return nil, "", ""
}

func mediaAccountingBody(t *testing.T) map[string]any {
	t.Helper()
	var b bytes.Buffer
	if err := png.Encode(&b, image.NewRGBA(image.Rect(0, 0, 1280, 851))); err != nil {
		t.Fatal(err)
	}
	return map[string]any{"messages": []any{map[string]any{"role": "user", "content": []any{map[string]any{"type": "image_url", "image_url": map[string]any{"url": "data:image/png;base64," + base64.StdEncoding.EncodeToString(b.Bytes())}}}}}}
}

func TestNativeMediaAccountingUsesVerifiedCurrentArtifact(t *testing.T) {
	s, model, _ := nativeMediaAccountingServer(t)
	body := mediaAccountingBody(t)
	baseline := estimatePromptTokens(body)
	if baseline != 304 {
		t.Fatal(baseline)
	}
	if got := s.mediaPromptTokens(context.Background(), model, model, body, baseline); got != 1086 {
		t.Fatalf("got%d want1086", got)
	}
	if got := s.mediaPromptTokens(context.Background(), "alias", model, body, baseline); got != baseline {
		t.Fatal("alias inherited concrete accounting")
	}
	s.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, WeightHash: strings.Repeat("f", 64)}})
	if got := s.mediaPromptTokens(context.Background(), model, model, body, baseline); got != baseline {
		t.Fatal("stale artifact profile used")
	}
}

func TestNativeMediaRecountPreservesClockAndExemption(t *testing.T) {
	s, model, _ := nativeMediaAccountingServer(t)
	body := mediaAccountingBody(t)
	r := slaAccountRequest("native-media-caller")
	count, deadline, ok := s.reconcileFetchedMedia(httptest.NewRecorder(), r, model, model, body, 304, 304, 9304*time.Millisecond)
	if !ok || count != 1086 || deadline != 10086*time.Millisecond {
		t.Fatalf("count%d deadline%s ok%v", count, deadline, ok)
	}
	count, deadline, ok = s.reconcileFetchedMedia(httptest.NewRecorder(), r, model, model, body, 304, count, 0)
	if !ok || count != 1086 || deadline != 0 {
		t.Fatal("recount doubled media or armed an exempt deadline")
	}
}

func TestNativeMediaRecountCannotSkipInputQuota(t *testing.T) {
	s, model, _ := nativeMediaAccountingServer(t)
	body := mediaAccountingBody(t)
	r := slaAccountRequest("native-media-caller")
	s.consumerTokenLimiter = ratelimit.NewTokenLimiter(1, 100, 0, 0)
	s.consumerTokenLimiter.Allow("native-media-caller", 100, 0)
	w := httptest.NewRecorder()
	count, deadline, ok := s.reconcileFetchedMedia(w, r, model, model, body, 304, 304, 9304*time.Millisecond)
	if ok || w.Code != http.StatusTooManyRequests || count != 304 || deadline != 9304*time.Millisecond {
		t.Fatalf("quota bypass: %d %s %v HTTP%d", count, deadline, ok, w.Code)
	}
}

func TestNativeMediaUnavailableRecountKeepsPriorEvidence(t *testing.T) {
	s, model, _ := nativeMediaAccountingServer(t)
	body := mediaAccountingBody(t)
	for i := 0; i < cap(mediaMetadataSlots); i++ {
		mediaMetadataSlots <- struct{}{}
	}
	defer func() {
		for i := 0; i < cap(mediaMetadataSlots); i++ {
			<-mediaMetadataSlots
		}
	}()
	count, deadline, ok := s.reconcileFetchedMedia(httptest.NewRecorder(), slaAccountRequest("native-media-caller"), model, model, body, 304, 1086, 10086*time.Millisecond)
	if !ok || count != 1086 || deadline != 10086*time.Millisecond {
		t.Fatal("temporary metadata saturation discarded prior evidence")
	}
}
