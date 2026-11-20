//go:build native_pair_hardware_experiment

package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Ephemeral CPU fixture certificate only. No enrolled device or trust flag is
// fabricated for the hardware driver. This does not qualify the Swift anchor.
func hardwareModeFixture(t *testing.T) (map[string]any, *x509.CertPool) {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	certificate := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "localhost"}, DNSNames: []string{"localhost"}, NotBefore: now.Add(-time.Minute), NotAfter: now.Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, certificate, certificate, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	private, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: private})
	certPath, keyPath := filepath.Join(root, "certificate.pem"), filepath.Join(root, "key.pem")
	if err = os.WriteFile(certPath, certPEM, 0600); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(keyPath, keyPEM, 0600); err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(certPEM) {
		t.Fatal("fixture certificate")
	}
	fields := map[string]any{"schema": "native_shared_hardware_coordinator_v2", "mode": "trust_only", "listenAddress": "127.0.0.1:51377", "certificateFile": certPath, "certificateSHA256": hardwareDigest(certPEM), "keyFile": keyPath}
	return fields, pool
}

func configureHardwareModeFixture(t *testing.T, fields map[string]any, cfg *api.ServerConfig) (*nativeHardwareExperiment, error) {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	b, err := json.Marshal(fields)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "config.json")
	if err = os.WriteFile(path, b, 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DARKBLOOM_PRIVATE_NATIVE_HARDWARE_CONFIG", path)
	t.Setenv("DARKBLOOM_PRIVATE_NATIVE_HARDWARE_SHA256", hardwareDigest(b))
	return configureNativeHardware(cfg)
}

func TestNativeHardwareTrustOnlyHasNoCatalogAndServesTLS(t *testing.T) {
	fields, pool := hardwareModeFixture(t)
	// Claim a free loopback address for this bounded local fixture only.
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := l.Addr().String()
	if err = l.Close(); err != nil {
		t.Fatal(err)
	}
	fields["listenAddress"] = address
	cfg := new(api.ServerConfig)
	x, err := configureHardwareModeFixture(t, fields, cfg)
	if err != nil || x == nil || cfg.NativePairCatalog != nil {
		t.Fatalf("trust-only configuration: %v", err)
	}
	h := &http.Server{ReadHeaderTimeout: time.Second, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.TLS == nil || !r.TLS.HandshakeComplete {
			http.Error(w, "TLS required", 400)
			return
		}
		_, _ = io.WriteString(w, "control-only")
	})}
	ended := make(chan error, 1)
	// A selector call on the nil real Server would panic. This branch must never
	// create it; only the ordinary TLS handler can run.
	go func() { ended <- serveNativeHardware(x, h, nil, context.Background()) }()
	t.Cleanup(func() {
		_ = h.Close()
		select {
		case err := <-ended:
			if !errors.Is(err, http.ErrServerClosed) {
				t.Errorf("TLS server exit: %v", err)
			}
		case <-time.After(2 * time.Second):
			t.Error("TLS server did not join")
		}
	})
	transport := &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS13, RootCAs: pool, ServerName: "localhost"}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: time.Second}
	deadline := time.Now().Add(2 * time.Second)
	for {
		response, requestErr := client.Get("https://" + address + "/control")
		if requestErr == nil {
			body, readErr := io.ReadAll(io.LimitReader(response.Body, 32))
			_ = response.Body.Close()
			if readErr != nil || response.StatusCode != 200 || string(body) != "control-only" {
				t.Fatal("actual TLS control handler failed")
			}
			break
		}
		if !time.Now().Before(deadline) {
			t.Fatalf("actual TLS control request: %v", requestErr)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestNativeHardwareStartupModesRefuseAmbiguity(t *testing.T) {
	base, _ := hardwareModeFixture(t)
	for _, name := range []string{"missing-mode", "unknown-mode", "old-schema", "devices", "approval", "receipt", "unknown-field", "existing-catalog"} {
		t.Run(name, func(t *testing.T) {
			fields := make(map[string]any, len(base))
			for k, v := range base {
				fields[k] = v
			}
			cfg := new(api.ServerConfig)
			switch name {
			case "missing-mode":
				delete(fields, "mode")
			case "unknown-mode":
				fields["mode"] = "automatic"
			case "old-schema":
				fields["schema"] = "native_shared_hardware_coordinator_v1"
			case "devices":
				fields["devices"] = [2]registry.NativeHardwareDevice{}
			case "approval":
				fields["approval"] = registry.NativeRuntimeApproval{}
			case "receipt":
				fields["receiptFile"] = "/tmp/never-written"
			case "unknown-field":
				fields["allowUntrusted"] = true
			case "existing-catalog":
				cfg.NativePairCatalog, _ = registry.NewNativeRuntimeCatalog(nil)
			}
			before := cfg.NativePairCatalog
			if _, err := configureHardwareModeFixture(t, fields, cfg); err == nil {
				t.Fatal("ambiguous trust-only mode accepted")
			}
			if cfg.NativePairCatalog != before {
				t.Fatal("failed configuration mutated catalog")
			}
		})
	}
}

func TestNativeHardwareOneRequestRetainsCatalogScope(t *testing.T) {
	fields, _ := hardwareModeFixture(t)
	fields["mode"] = "one_request"
	fields["devices"] = [2]registry.NativeHardwareDevice{{Serial: "fixture-rank-0", SEPublicKeySHA256: strings.Repeat("a", 64)}, {Serial: "fixture-rank-1", SEPublicKeySHA256: strings.Repeat("b", 64)}}
	h := [32]byte{1}
	approval := registry.NativeRuntimeApproval{ID: "fixture-only", Model: "registered_qwen35_9b", Generation: 1, PlanSHA256: h, ArtifactSHA256: h, NativeRuntimeSHA256: h, MetallibSHA256: h, ResourceLibrarySHA256: h, CapabilitySHA256: h, ResourcePolicySHA256: h, ProfileSHA256: h, Schedule: 1, MaximumPlaintext: 131072, MaximumTransportFrame: 131112, MaximumRecords: 1024, MaximumCumulativePlaintext: 16777216, AllowedChips: []string{"fixture-chip"}, NotAfter: time.Now().Add(10 * time.Minute)}
	fields["approval"] = approval
	fields["receiptFile"] = filepath.Join(filepath.Dir(fields["certificateFile"].(string)), "future-receipt.json")
	cfg := new(api.ServerConfig)
	x, err := configureHardwareModeFixture(t, fields, cfg)
	if err != nil || x == nil || x.Mode != "one_request" || cfg.NativePairCatalog == nil {
		t.Fatalf("one-request configuration: %v", err)
	}
	approval.MaximumPlaintext++
	fields["approval"] = approval
	if _, err = configureHardwareModeFixture(t, fields, new(api.ServerConfig)); err == nil {
		t.Fatal("changed one-request limits accepted")
	}
}
