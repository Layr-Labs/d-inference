package ingress

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestWriteServiceUnavailableSetsRetryAfter(t *testing.T) {
	srv, _ := testController(t)
	w := httptest.NewRecorder()
	srv.writeServiceUnavailable(w, "gpt-oss-20b")

	if w.Code != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want %d", w.Code, http.StatusServiceUnavailable)
	}
	if ra := w.Header().Get("Retry-After"); ra == "" {
		t.Error("Retry-After header missing")
	} else if n, err := strconv.Atoi(ra); err != nil || n < 1 {
		t.Errorf("Retry-After = %q, want positive integer seconds", ra)
	}
	var body struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if body.Error.Code != "service_unavailable" {
		t.Errorf("code = %q, want service_unavailable", body.Error.Code)
	}
}

func TestMaybeFallbackAliasTTFTSwitchesToPrevious(t *testing.T) {
	srv, _ := testController(t)
	publicModel := "public-ttft-alias"
	desired := "desired-ttft-build"
	previous := "previous-ttft-build"
	srv.deps.Registry().SetModelCatalog([]registry.CatalogEntry{
		{ID: desired, SizeGB: 1, MinRAMGB: 24},
		{ID: previous, SizeGB: 1, MinRAMGB: 24},
	})
	srv.deps.Registry().SetModelAliases(map[string]registry.AliasTarget{
		publicModel: {Desired: desired, Previous: previous},
	})

	desiredProvider := registerBuildsProvider(srv, "desired-slow", desired)
	desiredProvider.Mu().Lock()
	desiredProvider.DecodeTPS = 100
	desiredProvider.PrefillTPS = 400
	desiredProvider.BackendCapacity.Slots[0].State = "idle_shutdown"
	desiredProvider.Mu().Unlock()

	previousProvider := registerBuildsProvider(srv, "previous-fast", previous)
	previousProvider.Mu().Lock()
	previousProvider.DecodeTPS = 100
	previousProvider.PrefillTPS = 400
	previousProvider.Mu().Unlock()

	parsed := map[string]any{"model": desired}
	fallbackModel, candidates, rejections, tooLarge, bestTTFT, hasTTFT, switched := srv.maybeFallbackAlias(
		parsed,
		aliasFallbackTTFT,
		publicModel,
		desired,
		100,
		128,
		srv.FirstContentDeadline(desired, 100),
		registry.RequestTraits{},
		false,
		nil,
	)

	if !switched {
		t.Fatalf("switched = false, candidates=%d rejections=%d tooLarge=%d bestTTFT=%v has=%v", candidates, rejections, tooLarge, bestTTFT, hasTTFT)
	}
	if fallbackModel != previous || parsed["model"] != previous {
		t.Fatalf("fallback model = %q parsed=%v, want previous %q", fallbackModel, parsed["model"], previous)
	}
	if candidates != 1 || rejections != 0 || tooLarge != 0 {
		t.Fatalf("capacity = (%d,%d,%d), want (1,0,0)", candidates, rejections, tooLarge)
	}
	if !hasTTFT || bestTTFT > srv.FirstContentDeadline(desired, 100) {
		t.Fatalf("bestTTFT = %v has=%v, want within threshold", bestTTFT, hasTTFT)
	}

	// Alias fallback must consume the logical request's pinned deadline rather
	// than recomputing a fresh full duration for Previous. A deliberately tiny
	// pinned budget therefore blocks the same otherwise-healthy fallback.
	parsed["model"] = desired
	fallbackModel, _, _, _, _, _, switched = srv.maybeFallbackAlias(
		parsed,
		aliasFallbackTTFT,
		publicModel,
		desired,
		100,
		128,
		time.Nanosecond,
		registry.RequestTraits{},
		false,
		nil,
	)
	if switched || fallbackModel != previous || parsed["model"] != desired {
		t.Fatalf("expired pinned deadline restarted on Previous: switched=%v fallback=%q parsed=%v", switched, fallbackModel, parsed)
	}
}

func TestMaybeFallbackAliasTTFTSkipsRejectedPrevious(t *testing.T) {
	srv, _ := testController(t)
	publicModel := "public-ttft-shed-alias"
	desired := "desired-ttft-shed-build"
	previous := "previous-ttft-shed-build"
	setTestRejectedModels(srv, map[string]bool{previous: true})
	srv.deps.Registry().SetModelCatalog([]registry.CatalogEntry{
		{ID: desired, SizeGB: 1, MinRAMGB: 24},
		{ID: previous, SizeGB: 1, MinRAMGB: 24},
	})
	srv.deps.Registry().SetModelAliases(map[string]registry.AliasTarget{
		publicModel: {Desired: desired, Previous: previous},
	})
	registerBuildsProvider(srv, "previous-fast-shed", previous)
	parsed := map[string]any{"model": desired}

	fallbackModel, _, _, _, _, _, switched := srv.maybeFallbackAlias(
		parsed, aliasFallbackTTFT, publicModel, desired, 100, 128, srv.FirstContentDeadline(desired, 100), registry.RequestTraits{}, false, nil)

	if switched || fallbackModel != desired || parsed["model"] != desired {
		t.Fatalf("fallback switched to rejected previous: switched=%v fallback=%q parsed=%v", switched, fallbackModel, parsed)
	}
}

func TestMaybeFallbackAliasCapacitySkipsRejectedPrevious(t *testing.T) {
	srv, _ := testController(t)
	publicModel := "public-capacity-shed-alias"
	desired := "desired-capacity-shed-build"
	previous := "previous-capacity-shed-build"
	setTestRejectedModels(srv, map[string]bool{previous: true})
	srv.deps.Registry().SetModelCatalog([]registry.CatalogEntry{
		{ID: desired, SizeGB: 1, MinRAMGB: 24},
		{ID: previous, SizeGB: 1, MinRAMGB: 24},
	})
	srv.deps.Registry().SetModelAliases(map[string]registry.AliasTarget{
		publicModel: {Desired: desired, Previous: previous},
	})
	registerBuildsProvider(srv, "previous-capacity-shed", previous)
	parsed := map[string]any{"model": desired}

	fallbackModel, _, _, _, _, _, switched := srv.maybeFallbackAlias(
		parsed, aliasFallbackCapacity, publicModel, desired, 100, 128, 0, registry.RequestTraits{}, false, nil)

	if switched || fallbackModel != desired || parsed["model"] != desired {
		t.Fatalf("capacity fallback switched to rejected previous: switched=%v fallback=%q parsed=%v", switched, fallbackModel, parsed)
	}
}
