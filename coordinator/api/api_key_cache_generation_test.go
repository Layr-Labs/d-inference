package api

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Pause after the real store takes its snapshot, reproducing a slow database
// response that arrives after a concurrent key-management request commits.
type pausedKeyAuthenticationStore struct {
	store.Store
	token   string
	entered chan struct{}
	release chan struct{}
	paused  atomic.Bool
	reads   atomic.Int64
}

func (s *pausedKeyAuthenticationStore) AuthenticateKey(raw string) (*store.APIKey, error) {
	key, err := s.Store.AuthenticateKey(raw)
	if raw == s.token {
		s.reads.Add(1)
		if s.paused.CompareAndSwap(false, true) {
			close(s.entered)
			<-s.release
		}
	}
	return key, err
}

func TestAPIKeyCacheSlowReadCannotOutliveMutation(t *testing.T) {
	for _, tc := range []struct {
		name        string
		method      string
		path        string
		body        string
		disabled    bool
		wantStatus  int
		wantRPM     int64
		wantInitial int
	}{
		{name: "disable", method: http.MethodPatch, path: "/v1/keys/%s", body: `{"disabled":true}`, wantStatus: http.StatusUnauthorized, wantInitial: http.StatusOK},
		{name: "delete", method: http.MethodDelete, path: "/v1/keys/%s", wantStatus: http.StatusUnauthorized, wantInitial: http.StatusOK},
		{name: "rotate", method: http.MethodPost, path: "/v1/keys/%s/rotate", wantStatus: http.StatusUnauthorized, wantInitial: http.StatusOK},
		{name: "legacy revoke", method: http.MethodDelete, path: "/v1/auth/keys", body: `{"key":%q}`, wantStatus: http.StatusUnauthorized, wantInitial: http.StatusOK},
		{name: "restrict limit", method: http.MethodPatch, path: "/v1/keys/%s", body: `{"rpm_limit":5}`, wantStatus: http.StatusOK, wantRPM: 5, wantInitial: http.StatusOK},
		{name: "enable", method: http.MethodPatch, path: "/v1/keys/%s", body: `{"disabled":false}`, disabled: true, wantStatus: http.StatusOK, wantRPM: 100, wantInitial: http.StatusUnauthorized},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv, base := newKeyTestServer(t)
			t.Cleanup(srv.Close)
			user := seedUser(t, base, "acct-cache-generation", "cache@example.com")
			session := privySession(t, srv, base, user)
			rpm := int64(100)
			raw, rec, err := base.CreateAPIKey(user.AccountID, store.APIKeyCreate{RPMLimit: &rpm})
			if err != nil {
				t.Fatal(err)
			}
			if tc.disabled {
				rec.Disabled = true
				if _, err := base.UpdateAPIKey(user.AccountID, rec.ID, *rec); err != nil {
					t.Fatal(err)
				}
			}
			paused := &pausedKeyAuthenticationStore{Store: base, token: raw, entered: make(chan struct{}), release: make(chan struct{})}
			srv.store = paused
			ts := httptest.NewServer(srv.Handler())
			t.Cleanup(ts.Close)
			var releaseOnce sync.Once
			release := func() { releaseOnce.Do(func() { close(paused.release) }) }
			t.Cleanup(release)
			client := ts.Client()
			client.Timeout = 5 * time.Second
			type result struct {
				status int
				body   []byte
				err    error
			}
			call := func(method, path, body, token string) result {
				r, err := http.NewRequest(method, ts.URL+path, strings.NewReader(body))
				if err != nil {
					return result{err: err}
				}
				r.Header.Set("Authorization", "Bearer "+token)
				r.Header.Set("Content-Type", "application/json")
				resp, err := client.Do(r)
				if err != nil {
					return result{err: err}
				}
				defer resp.Body.Close()
				data, err := io.ReadAll(resp.Body)
				return result{status: resp.StatusCode, body: data, err: err}
			}
			initial := make(chan result, 1)
			go func() { initial <- call(http.MethodGet, "/v1/key", "", raw) }()
			select {
			case <-paused.entered:
			case <-time.After(5 * time.Second):
				t.Fatal("authentication never reached its store barrier")
			}

			path, body := tc.path, tc.body
			if strings.Contains(path, "%s") {
				path = fmt.Sprintf(path, rec.ID)
			}
			if strings.Contains(body, "%q") {
				body = fmt.Sprintf(body, raw)
			}
			mutation := call(tc.method, path, body, session)
			if mutation.err != nil || mutation.status != http.StatusOK {
				t.Fatalf("mutation = %d %s, err=%v", mutation.status, mutation.body, mutation.err)
			}
			release()
			// The request whose lookup preceded the mutation may finish with its
			// original result. It must not cache that result for later requests.
			got := <-initial
			if got.err != nil || got.status != tc.wantInitial {
				t.Fatalf("in-flight result = %d %s, err=%v", got.status, got.body, got.err)
			}
			for range 2 {
				got = call(http.MethodGet, "/v1/key", "", raw)
				if got.err != nil || got.status != tc.wantStatus {
					t.Fatalf("after mutation = %d %s, err=%v; want %d", got.status, got.body, got.err, tc.wantStatus)
				}
				if tc.wantRPM > 0 {
					var key types.APIKeyResponse
					if err := json.Unmarshal(got.body, &key); err != nil {
						t.Fatal(err)
					}
					if key.RPMLimit == nil || *key.RPMLimit != tc.wantRPM {
						t.Fatalf("cached RPM = %v, want %d", key.RPMLimit, tc.wantRPM)
					}
				}
			}
			if got := paused.reads.Load(); got != 2 {
				t.Fatalf("store reads = %d, want the paused read plus one refresh", got)
			}
			if tc.name == "rotate" {
				var rotated types.CreateAPIKeyResponse
				if err := json.Unmarshal(mutation.body, &rotated); err != nil {
					t.Fatal(err)
				}
				if got := call(http.MethodGet, "/v1/key", "", rotated.Key); got.err != nil || got.status != http.StatusOK {
					t.Fatalf("rotated key = %d %s, err=%v", got.status, got.body, got.err)
				}
			}
		})
	}
}
