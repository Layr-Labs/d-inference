package mdm

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// rawCommandMDM is a local stand-in for the MicroMDM raw command endpoint
// (POST /v1/commands/{udid}) and the explicit push endpoint.
type rawCommandMDM struct {
	mu        sync.Mutex
	status    int
	bodies    []string
	auth      []string
	types     []string
	pushes    []string
	delivered chan struct{}
}

func newRawCommandMDM(t *testing.T, status int) (*Client, *rawCommandMDM) {
	t.Helper()
	fake := &rawCommandMDM{status: status, delivered: make(chan struct{}, 4)}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/commands/{udid}", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		user, pass, _ := r.BasicAuth()
		fake.mu.Lock()
		fake.bodies = append(fake.bodies, string(body))
		fake.auth = append(fake.auth, user+":"+pass)
		fake.types = append(fake.types, r.Header.Get("Content-Type"))
		fake.mu.Unlock()
		w.WriteHeader(fake.status)
		if fake.status >= 300 {
			_, _ = w.Write([]byte("queue unavailable"))
		}
		fake.delivered <- struct{}{}
	})
	mux.HandleFunc("GET /push/{udid}", func(w http.ResponseWriter, r *http.Request) {
		fake.mu.Lock()
		fake.pushes = append(fake.pushes, r.PathValue("udid"))
		fake.mu.Unlock()
		w.WriteHeader(http.StatusOK)
	})
	ts := httptest.NewServer(mux)
	t.Cleanup(ts.Close)
	return NewClient(ts.URL, "test-key", slog.New(slog.NewTextHandler(io.Discard, nil))), fake
}

func TestRequestDeviceAttestationDeliversSolicitedResponse(t *testing.T) {
	c, fake := newRawCommandMDM(t, http.StatusCreated)
	const udid = "UDID-ATTEST"

	observed := make(chan string, 1)
	type result struct {
		resp *DeviceAttestationResponse
		err  error
	}
	done := make(chan result, 1)
	go func() {
		resp, err := c.RequestDeviceAttestation(context.Background(), udid, "bm9uY2U=", 5*time.Second,
			func(gotUDID, commandUUID string) {
				if gotUDID == udid {
					observed <- commandUUID
				}
			})
		done <- result{resp, err}
	}()

	var cmd string
	select {
	case cmd = <-observed:
	case <-time.After(5 * time.Second):
		t.Fatal("command was not observed before it was issued")
	}
	select {
	case <-fake.delivered:
	case <-time.After(5 * time.Second):
		t.Fatal("raw command never reached MicroMDM")
	}

	// A response for another command must not satisfy the waiter.
	c.HandleWebhook(buildDeviceAttestationWebhook(udid, "not-the-issued-command"))
	c.HandleWebhook(buildDeviceAttestationWebhook(udid, cmd))

	var got result
	select {
	case got = <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("RequestDeviceAttestation did not return after the solicited webhook")
	}
	if got.err != nil {
		t.Fatalf("RequestDeviceAttestation: %v", got.err)
	}
	if got.resp == nil || got.resp.UDID != udid || len(got.resp.CertChain) != 1 || string(got.resp.CertChain[0]) != "\x01" {
		t.Fatalf("response = %+v", got.resp)
	}

	fake.mu.Lock()
	defer fake.mu.Unlock()
	if len(fake.bodies) != 1 {
		t.Fatalf("raw commands sent = %d, want 1", len(fake.bodies))
	}
	body := fake.bodies[0]
	for _, want := range []string{
		"<string>DeviceInformation</string>",
		"<string>DevicePropertiesAttestation</string>",
		"<key>DeviceAttestationNonce</key>",
		"<data>bm9uY2U=</data>",
		"<string>" + cmd + "</string>",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("command plist is missing %q:\n%s", want, body)
		}
	}
	if fake.auth[0] != "micromdm:test-key" || fake.types[0] != "application/xml" {
		t.Fatalf("auth = %q, content type = %q", fake.auth[0], fake.types[0])
	}
	// The raw endpoint does not push by itself, so the client must.
	if len(fake.pushes) != 1 || fake.pushes[0] != udid {
		t.Fatalf("explicit pushes = %v, want [%s]", fake.pushes, udid)
	}
}

func TestRequestDeviceAttestationWithoutNonceOmitsNonceKey(t *testing.T) {
	c, fake := newRawCommandMDM(t, http.StatusCreated)
	_, err := c.RequestDeviceAttestation(context.Background(), "UDID-NO-NONCE", "", 20*time.Millisecond, nil)
	if err == nil || !strings.Contains(err.Error(), "timeout waiting for DevicePropertiesAttestation") {
		t.Fatalf("err = %v, want a timeout", err)
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if len(fake.bodies) != 1 || strings.Contains(fake.bodies[0], "DeviceAttestationNonce") {
		t.Fatalf("command bodies = %q", fake.bodies)
	}
}

func TestRequestDeviceAttestationFailuresReleaseTheWaiter(t *testing.T) {
	c, fake := newRawCommandMDM(t, http.StatusInternalServerError)
	const udid = "UDID-FAIL"

	_, err := c.RequestDeviceAttestation(context.Background(), udid, "", time.Second, nil)
	if err == nil || !strings.Contains(err.Error(), "status 500") || !strings.Contains(err.Error(), "queue unavailable") {
		t.Fatalf("err = %v, want the MicroMDM status and body", err)
	}
	fake.mu.Lock()
	pushes := len(fake.pushes)
	fake.mu.Unlock()
	if pushes != 0 {
		t.Fatalf("pushed %d times after a failed enqueue", pushes)
	}

	// The waiter was released, so a new request can register. A cancelled
	// context ends the wait with a cancellation error.
	fake.mu.Lock()
	fake.status = http.StatusCreated
	fake.mu.Unlock()
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		<-fake.delivered // the failed request above
		<-fake.delivered // this request
		cancel()
	}()
	_, err = c.RequestDeviceAttestation(ctx, udid, "", time.Minute, nil)
	if err == nil || !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.Canceled", err)
	}

	// While one request waits, a second one for the same device is refused.
	hold, stop := context.WithCancel(context.Background())
	defer stop()
	waiting := make(chan struct{})
	go func() {
		defer close(waiting)
		_, _ = c.RequestDeviceAttestation(hold, udid, "", time.Minute, nil)
	}()
	<-fake.delivered
	_, err = c.RequestDeviceAttestation(context.Background(), udid, "", time.Second, nil)
	if !errors.Is(err, ErrWaiterAlreadyRegistered) {
		t.Fatalf("overlapping request err = %v, want ErrWaiterAlreadyRegistered", err)
	}
	stop()
	<-waiting

	// A client pointed at an unreachable server reports the send failure.
	down := NewClient("http://127.0.0.1:1", "test-key", slog.New(slog.NewTextHandler(io.Discard, nil)))
	if _, err := down.RequestDeviceAttestation(context.Background(), udid, "", time.Second, nil); err == nil ||
		!strings.Contains(err.Error(), "send DeviceInformation with nonce failed") {
		t.Fatalf("unreachable server err = %v", err)
	}
}
