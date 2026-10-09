package observation_test

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type contentWriteObserver func(http.ResponseWriter, []byte, int, int, error)

func TestGeneratedContentWriteEvidence(t *testing.T) {
	for name, observe := range map[string]contentWriteObserver{
		"json": production.MarkJSONContentWrite,
		"sse":  production.MarkSSEContentWrite,
	} {
		for _, tc := range []struct {
			name    string
			body    string
			short   bool
			err     error
			buffer  bool
			recover bool
			want    bool
		}{
			{name: "content", body: `{"choices":[{"delta":{"content":"hello"}}]}`, want: true},
			{name: "role only", body: `{"choices":[{"delta":{"role":"assistant"}}]}`},
			{name: "malformed", body: `{"choices":[`},
			{name: "short", body: `{"choices":[{"delta":{"content":"hello"}}]}`, short: true},
			{name: "full with error", body: `{"choices":[{"delta":{"content":"hello"}}]}`, err: errors.New("write failed")},
			{name: "plaintext buffer", body: `{"choices":[{"delta":{"content":"hello"}}]}`, buffer: true},
			{name: "content after short write", body: `{"choices":[{"delta":{"content":"hello"}}]}`, short: true, recover: true, want: true},
		} {
			t.Run(name+"/"+tc.name, func(t *testing.T) {
				st := memory.NewMemory(store.Config{})
				o := production.New(production.Dependencies{Store: st, Logger: quietLogger()})
				t.Cleanup(o.Close)
				o.ObserveRequestOutcome(func(w http.ResponseWriter, r *http.Request) {
					body := []byte(tc.body)
					if name == "sse" {
						body = []byte("data: " + tc.body + "\n\n")
					}
					if tc.buffer {
						w = plaintextBuffer{w}
					}
					n := len(body)
					if tc.short {
						n--
					}
					observe(w, body, n, len(body), tc.err)
					if tc.recover {
						observe(w, body, len(body), len(body), nil)
					}
				})(httptest.NewRecorder(), httptest.NewRequest("POST", "/v1/chat/completions", nil))
				o.CloseProfilesAndOutcomes()
				rows, err := st.RequestOutcomes(context.Background(), time.Time{}, time.Now().Add(time.Second), 10)
				if err != nil || len(rows) != 1 {
					t.Fatalf("outcomes: %v, %v", rows, err)
				}
				if got := rows[0].ContentWriteCompleted; got != tc.want {
					t.Fatalf("content_write_completed = %v, want %v", got, tc.want)
				}
			})
		}
	}
}

type plaintextBuffer struct{ http.ResponseWriter }

func (plaintextBuffer) BuffersPlaintext() {}

// Once delivery is confirmed, later tokens must not allocate JSON maps or SSE
// line slices. Run through the real outcome middleware rather than a fake
// classifier so this also guards the request-local latch.
func TestGeneratedContentWriteDoesNotReparseAfterDelivery(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	o := production.New(production.Dependencies{Store: st, Logger: quietLogger()})
	t.Cleanup(o.Close)
	jsonBody := []byte(`{"choices":[{"delta":{"content":"hello"}}]}`)
	sseBody := append(append([]byte("data: "), jsonBody...), '\n', '\n')
	o.ObserveRequestOutcome(func(w http.ResponseWriter, r *http.Request) {
		production.MarkJSONContentWrite(w, jsonBody, len(jsonBody), len(jsonBody), nil)
		allocs := testing.AllocsPerRun(100, func() {
			production.MarkJSONContentWrite(w, jsonBody, len(jsonBody), len(jsonBody), nil)
			production.MarkSSEContentWrite(w, sseBody, len(sseBody), len(sseBody), nil)
		})
		if allocs != 0 {
			t.Errorf("confirmed content observation allocated %g times, want zero", allocs)
		}
	})(httptest.NewRecorder(), httptest.NewRequest("POST", "/v1/chat/completions", nil))
}
