package access

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestRateLimitMetrics_ConsumerRejectionEmitsCounter(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	srv := New(st, logger, 0, Hooks{})
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetRateObservation(ddClient.Incr, nil)
	srv.SetRateLimiter(ratelimit.New(ratelimit.Config{RPS: 0.001, Burst: 1}))
	handler := srv.RateLimitConsumer(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	ctx := WithConsumer(context.Background(), "acct-ratelimit-test")
	rec := httptest.NewRecorder()
	handler(rec, httptest.NewRequest("POST", "/test", nil).WithContext(ctx))
	if rec.Code != http.StatusOK {
		t.Fatalf("first request got %d, want 200", rec.Code)
	}
	rec = httptest.NewRecorder()
	handler(rec, httptest.NewRequest("POST", "/test", nil).WithContext(ctx))
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("second request got %d, want 429", rec.Code)
	}
	_ = ddClient.Statsd.Flush()
	packets := collector.drain()
	if !hasMetric(packets, "ratelimit.rejections") {
		t.Errorf("missing ratelimit.rejections metric; got packets: %v", packets)
	}
	if !hasMetric(packets, "tier:consumer") {
		t.Errorf("missing tier:consumer tag; got packets: %v", packets)
	}
}

func TestRateLimitMetrics_FinancialTierTag(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	srv := New(st, logger, 0, Hooks{})
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetRateObservation(ddClient.Incr, nil)
	srv.SetFinancialRateLimiter(ratelimit.New(ratelimit.Config{RPS: 0.001, Burst: 1}))
	handler := srv.RateLimitFinancial(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	ctx := WithConsumer(context.Background(), "acct-fin-test")
	rec := httptest.NewRecorder()
	handler(rec, httptest.NewRequest("POST", "/test", nil).WithContext(ctx))
	rec = httptest.NewRecorder()
	handler(rec, httptest.NewRequest("POST", "/test", nil).WithContext(ctx))
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("got %d, want 429", rec.Code)
	}
	_ = ddClient.Statsd.Flush()
	packets := collector.drain()
	if !hasMetric(packets, "tier:financial") {
		t.Errorf("missing tier:financial tag; got packets: %v", packets)
	}
}
