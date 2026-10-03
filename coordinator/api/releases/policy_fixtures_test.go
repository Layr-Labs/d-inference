package releases

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

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

func buildReleaseBundleForTest(t *testing.T, binary []byte) ([]byte, string, string) {
	t.Helper()

	return buildReleaseBundleWithEntryForTest(t, "bin/darkbloom", tar.TypeReg, binary, "")
}
func buildReleaseBundleWithEntryForTest(t *testing.T, name string, typeflag byte, binary []byte, linkname string) ([]byte, string, string) {
	t.Helper()

	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)

	header := &tar.Header{
		Name:     name,
		Mode:     0o755,
		Typeflag: typeflag,
		Linkname: linkname,
	}
	if typeflag == tar.TypeReg || typeflag == tar.TypeRegA {
		header.Size = int64(len(binary))
	}
	if err := tw.WriteHeader(header); err != nil {
		t.Fatalf("write tar header: %v", err)
	}
	if len(binary) > 0 {
		if _, err := tw.Write(binary); err != nil {
			t.Fatalf("write binary: %v", err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatalf("close tar: %v", err)
	}
	if err := gz.Close(); err != nil {
		t.Fatalf("close gzip: %v", err)
	}

	return buf.Bytes(), sha256HexBytesForReleaseTest(binary), sha256HexBytesForReleaseTest(buf.Bytes())
}

var trHashA = strings.Repeat("a", 64)
var trHashB = strings.Repeat("b", 64)
var trHashC = strings.Repeat("c", 64)

func trBoolPtr(v bool) *bool { return &v }
func sha256HexBytesForReleaseTest(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
func quietLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }
func releaseOwnerFixture(reg *registry.Registry, st store.Store, logger *slog.Logger) *Owner {
	auth := access.New(st, logger, 64<<10, access.Hooks{})
	auth.SetAdminKey("admin-key")
	auth.SetReleaseKey("release-key")
	return New(reg, st, auth, readcache.New(), logger, Hooks{})
}
func releaseRequest(handler http.HandlerFunc, method, target, auth, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, target, strings.NewReader(body))
	r.Header.Set("Authorization", auth)
	w := httptest.NewRecorder()
	handler(w, r)
	return w
}
