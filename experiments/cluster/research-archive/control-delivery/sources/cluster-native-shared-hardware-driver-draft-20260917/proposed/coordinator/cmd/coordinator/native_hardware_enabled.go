//go:build native_pair_hardware_experiment

package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type nativeHardwareExperiment struct {
	Schema            string                           `json:"schema"`
	Devices           [2]registry.NativeHardwareDevice `json:"devices"`
	Approval          registry.NativeRuntimeApproval   `json:"approval"`
	ListenAddress     string                           `json:"listenAddress"`
	CertificateFile   string                           `json:"certificateFile"`
	CertificateSHA256 string                           `json:"certificateSHA256"`
	KeyFile           string                           `json:"keyFile"`
	ReceiptFile       string                           `json:"receiptFile"`
	configSHA         string
	certificate       tls.Certificate
}

// Exact local startup bytes, never provider-supplied policy or a trust bypass.
// Canonical regular files only. The key is read privately and never logged.
func hardwareRead(path string, limit int64) ([]byte, error) {
	if !filepath.IsAbs(path) {
		return nil, errors.New("hardware path must be absolute")
	}
	resolved, e := filepath.EvalSymlinks(path)
	if e != nil || resolved != path {
		return nil, errors.New("hardware path is not canonical")
	}
	before, e := os.Lstat(path)
	if e != nil || !before.Mode().IsRegular() || before.Size() > limit {
		return nil, errors.New("hardware input bound")
	}
	f, e := os.Open(path)
	if e != nil {
		return nil, e
	}
	defer f.Close()
	opened, e := f.Stat()
	if e != nil || !os.SameFile(before, opened) {
		return nil, errors.New("hardware input changed")
	}
	b, e := io.ReadAll(io.LimitReader(f, limit+1))
	if e != nil || int64(len(b)) > limit {
		return nil, errors.New("hardware input exceeds bound")
	}
	after, e := os.Lstat(path)
	if e != nil || !os.SameFile(opened, after) || int64(len(b)) != after.Size() {
		return nil, errors.New("hardware input changed")
	}
	return b, nil
}
func hardwareDigest(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
func configureNativeHardware(cfg *api.ServerConfig) (*nativeHardwareExperiment, error) {
	path := os.Getenv("DARKBLOOM_PRIVATE_NATIVE_HARDWARE_CONFIG")
	if path == "" {
		return nil, nil
	}
	b, e := hardwareRead(path, 64*1024)
	if e != nil {
		return nil, e
	}
	if hardwareDigest(b) != os.Getenv("DARKBLOOM_PRIVATE_NATIVE_HARDWARE_SHA256") {
		return nil, errors.New("hardware config hash mismatch")
	}
	x := new(nativeHardwareExperiment)
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if e = dec.Decode(x); e != nil {
		return nil, e
	}
	if dec.Decode(new(any)) != io.EOF {
		return nil, errors.New("hardware config trailing data")
	}
	if x.Schema != "native_shared_hardware_coordinator_v1" || x.Devices[0].Serial == "" || x.Devices[1].Serial == "" || x.Devices[0].Serial == x.Devices[1].Serial ||
		x.Approval.Model != "registered_qwen35_9b" || x.Approval.Schedule != 1 ||
		x.Approval.MaximumPlaintext != 131072 || x.Approval.MaximumTransportFrame != 131112 ||
		x.Approval.MaximumRecords != 1024 || x.Approval.MaximumCumulativePlaintext != 16777216 ||
		!time.Now().Add(360*time.Second).Before(x.Approval.NotAfter) || x.Approval.NotAfter.After(time.Now().Add(15*time.Minute)) {
		return nil, errors.New("hardware experiment scope mismatch")
	}
	// No wildcard binding, HTTP downgrade or forwarded-header override is added.
	// Member clients use normal system anchors when their option is nil; an
	// explicit application-scoped pinned CA is still evaluated by SecTrust with
	// the original policies plus this same URL hostname, never accept-all.
	host, port, e := net.SplitHostPort(x.ListenAddress)
	if e != nil || net.ParseIP(host) == nil || net.ParseIP(host).IsUnspecified() || port == "0" {
		return nil, errors.New("hardware TLS address must be explicit")
	}
	cert, e := hardwareRead(x.CertificateFile, 64*1024)
	if e != nil {
		return nil, e
	}
	if hardwareDigest(cert) != x.CertificateSHA256 {
		return nil, errors.New("hardware certificate hash mismatch")
	}
	key, e := hardwareRead(x.KeyFile, 64*1024)
	if e != nil {
		return nil, e
	}
	x.certificate, e = tls.X509KeyPair(cert, key)
	clear(key)
	if e != nil {
		return nil, e
	}
	parent, e := filepath.EvalSymlinks(filepath.Dir(x.ReceiptFile))
	if e != nil || parent != filepath.Dir(x.ReceiptFile) || !filepath.IsAbs(x.ReceiptFile) {
		return nil, errors.New("hardware receipt parent must be canonical")
	}
	if _, e = os.Lstat(x.ReceiptFile); !errors.Is(e, os.ErrNotExist) {
		return nil, errors.New("hardware receipt already exists")
	}
	cfg.NativePairCatalog, e = registry.NewNativeRuntimeCatalog([]registry.NativeRuntimeApproval{x.Approval})
	if e != nil {
		return nil, e
	}
	x.configSHA = hardwareDigest(b)
	return x, nil
}

func serveNativeHardware(x *nativeHardwareExperiment, h *http.Server, s *api.Server, ctx context.Context) error {
	if x == nil {
		return h.ListenAndServe()
	}
	l, e := net.Listen("tcp", x.ListenAddress)
	if e != nil {
		return e
	}
	defer l.Close()
	tlsListener := tls.NewListener(l, &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{x.certificate}})
	// This is the real Server handler on accepted TLS connections (r.TLS),
	// with the ordinary attestation/release/catalog services configured above.
	go func() {
		v, err := s.RunNativeHardwarePair(ctx, x.Devices, x.Approval.ID)
		message := ""
		if err != nil {
			message = err.Error()
		}
		receipt := struct {
			Schema       string                             `json:"schema"`
			ConfigSHA256 string                             `json:"configSHA256"`
			Success      bool                               `json:"success"`
			Error        string                             `json:"error"`
			Observation  registry.NativeHardwareObservation `json:"observation"`
		}{"native_shared_hardware_coordinator_result_v1", x.configSHA, err == nil, message, v}
		b, encodeErr := json.Marshal(receipt)
		if encodeErr != nil || len(b) > 16*1024 {
			return
		}
		f, openErr := os.OpenFile(x.ReceiptFile, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if openErr != nil {
			return
		}
		defer f.Close()
		b = append(b, '\n')
		if n, writeErr := f.Write(b); writeErr != nil || n != len(b) {
			return
		}
		_ = f.Sync()
		// This goroutine never shuts down the server, clears holds or replaces
		// providers. Root keeps it alive through peer receipt and postflight.
	}()
	return h.Serve(tlsListener)
}
