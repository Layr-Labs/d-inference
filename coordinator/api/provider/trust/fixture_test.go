package trust

import (
	"crypto/rand"
	"encoding/base64"
	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/api/releases"
	attestservice "github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"golang.org/x/crypto/nacl/box"
	"io"
	"log/slog"
	"sort"
	"strings"
	"testing"
	"time"
)

func newTrustFixture(t testing.TB, d Dependencies, cfg Config) *Owner {
	t.Helper()
	d.ReadCache = readcache.New()
	d.Access = access.New(d.Store, d.Logger, 64<<10, access.Hooks{})
	d.Observation = observation.New(observation.Dependencies{Store: d.Store, Registry: d.Registry, Logger: d.Logger})
	t.Cleanup(d.Observation.Close)
	var owner *Owner
	d.Releases = releases.New(d.Registry, d.Store, d.Access, d.ReadCache, d.Logger, releases.Hooks{
		BelowMinProviderVersion: func(v string) bool { return owner.BelowMinProviderVersion(v) },
		AppAttest:               func() *attestservice.Service { return owner.AppAttestFeature() },
		AppAttestServing:        func() bool { return owner.AppAttestServing() },
	})
	owner = New(d, cfg)
	t.Cleanup(owner.CloseAuthority)
	t.Cleanup(owner.Close)
	return owner
}
func trustTestOwner(t testing.TB) (*Owner, *memory.MemoryStore) {
	t.Helper()
	logger := quietLogger()
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	return newTrustFixture(t, Dependencies{Registry: registry.New(logger), Store: st, Logger: logger}, Config{}), st
}
func quietLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }
func testPublicKeyB64() string {
	pub, _, err := box.GenerateKey(rand.Reader)
	if err != nil {
		panic(err)
	}
	return base64.StdEncoding.EncodeToString(pub[:])
}
func metricKey(name string, labels []observation.MetricLabel) string {
	if len(labels) == 0 {
		return name
	}
	labels = append([]observation.MetricLabel(nil), labels...)
	sort.SliceStable(labels, func(i, j int) bool { return labels[i].Name < labels[j].Name })
	parts := make([]string, len(labels))
	for i, l := range labels {
		parts[i] = l.Name + "=" + l.Value
	}
	return name + "{" + strings.Join(parts, ",") + "}"
}

func publishTestReleasePolicy(t *testing.T, s *Owner, rows ...store.Release) *releases.PolicyView {
	t.Helper()
	previous, err := s.store.ListReleasesWithError()
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range previous {
		if r.Active {
			if err := s.store.DeleteRelease(r.Version, r.Platform); err != nil {
				t.Fatal(err)
			}
		}
	}
	if len(rows) == 0 && len(previous) == 0 {
		r := store.Release{Version: "0.0.0", Platform: "macos-arm64", BinaryHash: strings.Repeat("f", 64)}
		if err := s.store.SetRelease(&r); err != nil {
			t.Fatal(err)
		}
		if err := s.store.DeleteRelease(r.Version, r.Platform); err != nil {
			t.Fatal(err)
		}
	}
	for _, r := range rows {
		if err := s.store.SetRelease(&r); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.releases.SyncBinaryHashes(); err != nil {
		t.Fatal(err)
	}
	return s.releases.Policy()
}

func makeRoutableProvider(t *testing.T, reg *registry.Registry, id, model string) *registry.Provider {
	t.Helper()
	msg := &protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel:       "Mac15,8",
			ChipName:           "Apple M3 Max",
			MemoryGB:           64,
			MemoryBandwidthGBs: 400,
			CPUCores:           protocol.CPUCores{Total: 16, Performance: 12, Efficiency: 4},
			GPUCores:           40,
		},
		Models: []protocol.ModelInfo{
			{ID: model, SizeBytes: 5_000_000_000, ModelType: "chat", Quantization: "4bit"},
		},
		Backend:                 "mlx-swift",
		PublicKey:               "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
		EncryptedResponseChunks: true,
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess: true,
			TextProxyDisabled:    true,
			SIPEnabled:           true,
			AntiDebugEnabled:     true,
			CoreDumpsDisabled:    true,
			EnvScrubbed:          true,
		},
	}
	p := reg.Register(id, nil, msg)
	// This helper constructs an already registered, routable fixture. Recovery
	// failure cases use their own pending-registration fixtures.
	p.CompleteProviderStateRestore()
	p.Mu().Lock()
	p.TrustLevel = registry.TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.DecodeTPS = 90.0
	p.PrefillTPS = 500.0
	p.SystemMetrics = protocol.SystemMetrics{
		MemoryPressure: 0.1,
		CPUUsage:       0.1,
		ThermalState:   "nominal",
	}
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB:     64,
		GPUMemoryActiveGB: 8,
		Slots: []protocol.BackendSlotCapacity{
			{Model: model, State: "running", NumRunning: 0, NumWaiting: 0},
		},
	}
	p.Mu().Unlock()
	return p
}

func findRoutableProvider(reg *registry.Registry, model string) *registry.Provider {
	pr := &registry.PendingRequest{RequestID: "test-route-probe", Model: model, RequestedMaxTokens: 64}
	p, _ := reg.ReserveProviderEx(model, pr)
	if p != nil {
		p.RemovePending(pr.RequestID)
		reg.SetProviderIdle(p.ID)
	}
	return p
}

// connectProvider dials the WebSocket, sends a register message, and returns
// the connection. It waits briefly for registration to be processed.

func testPrivacyCaps() *protocol.PrivacyCapabilities {
	return &protocol.PrivacyCapabilities{
		TextBackendInprocess: true,
		TextProxyDisabled:    true,
		SIPEnabled:           true,
		AntiDebugEnabled:     true,
		CoreDumpsDisabled:    true,
		EnvScrubbed:          true,
	}
}
