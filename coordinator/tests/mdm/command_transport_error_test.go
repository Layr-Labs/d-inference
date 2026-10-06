package mdm_test

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/mdm"
)

// The raw command URL is /v1/commands/<udid>. http.Client puts that URL in a
// transport error, and the MDA verifier logs the error.
const transportErrorUDID = "00008112-0011AABBCCDDEE01"

func mdmClient(url string) *production.Client {
	return production.NewClient(url, "test-key", slog.New(slog.NewTextHandler(io.Discard, nil)))
}

func TestRequestDeviceAttestationErrorOmitsMicroMDMBody(t *testing.T) {
	const bodyMarker = "micromdm-body-marker"
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = io.WriteString(w, bodyMarker+" "+transportErrorUDID)
	}))
	defer ts.Close()

	_, err := mdmClient(ts.URL).RequestDeviceAttestation(context.Background(), transportErrorUDID, "", time.Second, nil)
	if err == nil || !strings.Contains(err.Error(), "status 500") {
		t.Fatalf("err = %v, want the MicroMDM status", err)
	}
	for _, marker := range []string{bodyMarker, transportErrorUDID} {
		if strings.Contains(err.Error(), marker) {
			t.Errorf("error contains %q: %v", marker, err)
		}
	}
}

func TestRequestDeviceAttestationTransportErrorOmitsUDID(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		conn, _, err := w.(http.Hijacker).Hijack()
		if err == nil {
			_ = conn.Close()
		}
	}))
	defer ts.Close()

	_, err := mdmClient(ts.URL).RequestDeviceAttestation(context.Background(), transportErrorUDID, "", time.Second, nil)
	if err == nil || !strings.Contains(err.Error(), "send DeviceInformation with nonce failed") {
		t.Fatalf("err = %v, want the send failure", err)
	}
	if strings.Contains(err.Error(), transportErrorUDID) {
		t.Errorf("transport error contains the UDID: %v", err)
	}
}

// The error keeps its cause, so deadline and net.Error timeout checks still
// classify it.
func TestRequestDeviceAttestationDeadlineKeepsCauseWithoutUDID(t *testing.T) {
	release := make(chan struct{})
	ts := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-release:
		}
	}))
	defer ts.Close()
	defer close(release)

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	_, err := mdmClient(ts.URL).RequestDeviceAttestation(ctx, transportErrorUDID, "", time.Second, nil)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("err = %v, want context.DeadlineExceeded in the chain", err)
	}
	var netErr net.Error
	if !errors.As(err, &netErr) || !netErr.Timeout() {
		t.Fatalf("err = %v, want a net.Error timeout in the chain", err)
	}
	if strings.Contains(err.Error(), transportErrorUDID) {
		t.Errorf("deadline error contains the UDID: %v", err)
	}
}
