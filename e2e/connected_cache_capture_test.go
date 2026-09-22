package e2e

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestIntegrationConnectedCapturePreservesEveryReturnPath(t *testing.T) {
	complete := "data: {\"choices\":[{\"delta\":{\"content\":\"answer\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]"
	for _, test := range []struct {
		name, body, failure string
		status              int
	}{
		{"complete without final newline", complete, "", http.StatusOK},
		{"malformed JSON", "data: invalid\n", "invalid character", http.StatusOK},
		{"provider error", "data: {\"error\":{\"message\":\"failed\"}}\n", "SSE error", http.StatusOK},
		{"missing done", strings.TrimSuffix(complete, "data: [DONE]"), "without finish and DONE", http.StatusOK},
		{"missing finish", "data: [DONE]\n", "without finish and DONE", http.StatusOK},
		{"HTTP error", "bounded failure body", "HTTP status 503", http.StatusServiceUnavailable},
	} {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("X-Provider-Id", "fixture-provider")
				w.WriteHeader(test.status)
				_, _ = io.WriteString(w, test.body)
			}))
			defer server.Close()
			out, err := postConnectedStream(context.Background(), server.URL, "fixture-key", []byte(`{}`), false)
			if test.failure == "" {
				require.NoError(t, err)
			} else {
				require.ErrorContains(t, err, test.failure)
			}
			require.Equal(t, test.body, out.RawSSE, "partial evidence must survive every return path")
			require.Equal(t, test.status, out.HTTPStatus)
			require.Equal(t, "fixture-provider", out.ProviderID)
			require.Positive(t, out.TotalMS)
			if test.failure == "" {
				require.Equal(t, "answer", out.Content)
				require.Equal(t, "stop", out.Finish)
				require.True(t, out.Done)
				require.Positive(t, out.FirstContentMS)
			}
		})
	}
}

func TestIntegrationConnectedCaptureBoundsEvidence(t *testing.T) {
	body := strings.Repeat("x", (8<<20)+2)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, body) }))
	defer server.Close()
	out, err := postConnectedStream(context.Background(), server.URL, "fixture-key", []byte(`{}`), false)
	require.ErrorContains(t, err, "bounded 8 MiB")
	require.Equal(t, body[:(8<<20)+1], out.RawSSE)
}

func TestIntegrationConnectedCaptureRetainsCancelledPrefix(t *testing.T) {
	line := "data: {\"choices\":[{\"delta\":{\"content\":\"first\"}}]}\n"
	closed := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, line)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
		close(closed)
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := postConnectedStream(ctx, server.URL, "fixture-key", []byte(`{}`), true)
	require.NoError(t, err)
	require.Equal(t, line, out.RawSSE)
	require.Equal(t, "first", out.Content)
	require.True(t, out.CancelledByClient)
	require.False(t, out.Done)
	require.Empty(t, out.Finish)
	select {
	case <-closed:
	case <-ctx.Done():
		t.Fatal("cancelled response did not close its owned HTTP request")
	}
}

// CPU capture overhead only; these comments carry no model/tokenizer work.
func BenchmarkConnectedCapture(b *testing.B) {
	for _, lines := range []int{64, 256} {
		b.Run(fmt.Sprint(lines), func(b *testing.B) {
			body := strings.Repeat(":"+strings.Repeat("x", 4094)+"\n", lines) + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\ndata: [DONE]\n"
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, body) }))
			defer server.Close()
			b.ReportAllocs()
			b.SetBytes(int64(len(body)))
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				out, err := postConnectedStream(context.Background(), server.URL, "fixture-key", []byte(`{}`), false)
				if err != nil || len(out.RawSSE) != len(body) {
					b.Fatalf("capture: %v", err)
				}
			}
		})
	}
}

func TestIntegrationConnectedCapturePreservesTruncatedRead(t *testing.T) {
	body := "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", fmt.Sprint(len(body)+100))
		_, _ = io.WriteString(w, body)
	}))
	defer server.Close()
	out, err := postConnectedStream(context.Background(), server.URL, "fixture-key", []byte(`{}`), false)
	require.ErrorIs(t, err, io.ErrUnexpectedEOF)
	require.Equal(t, body, out.RawSSE)
	require.Equal(t, "partial", out.Content)
	require.False(t, out.Done)
}
