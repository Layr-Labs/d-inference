// Package backoff schedules capacity retries from fleet backlog and coordinator
// routing distress, never from receive, parsing or media-fetch latency.
package backoff

import (
	"fmt"
	"math"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

const MaxDistressRetryAfter = 60

type Policy struct {
	registry    *registry.Registry
	observation *observation.Owner
	mu          sync.Mutex
	routeEWMAMs float64
}

func (p *Policy) Bind(reg *registry.Registry, obs *observation.Owner) {
	p.registry, p.observation = reg, obs
}

func RouteAnchor(t *registry.RequestTiming) time.Time {
	if t == nil {
		return time.Time{}
	}
	if !t.MediaFetchedAt.IsZero() {
		return t.MediaFetchedAt
	}
	return t.ReservedAt
}

func (p *Policy) NoteRouteLatency(d time.Duration) {
	ms := float64(d) / float64(time.Millisecond)
	if ms < 0 {
		return
	}
	p.mu.Lock()
	if p.routeEWMAMs == 0 {
		p.routeEWMAMs = ms
	} else {
		p.routeEWMAMs = 0.2*ms + 0.8*p.routeEWMAMs
	}
	p.mu.Unlock()
}

func (p *Policy) RouteEWMAMs() float64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.routeEWMAMs
}

func (p *Policy) Estimate(model string) int {
	estimate := 2
	if queueDepth := p.registry.Queue().QueueSize(model); queueDepth > 0 {
		estimate = queueDepth * 3
		if estimate < 2 {
			estimate = 2
		}
		if estimate > 30 {
			estimate = 30
		}
	}
	if ewmaMs := p.RouteEWMAMs(); ewmaMs > 1000.0 {
		scaled := int(math.Ceil(ewmaMs/1000)) * 5
		if scaled > MaxDistressRetryAfter {
			scaled = MaxDistressRetryAfter
		}
		if scaled > estimate {
			estimate = scaled
		}
	}
	return estimate
}

func (p *Policy) TTFTRetryAfter(model string, bestTTFT, threshold time.Duration) int {
	seconds := int(math.Ceil((bestTTFT - threshold).Seconds()))
	if base := p.Estimate(model); seconds < base {
		seconds = base
	}
	if seconds < 2 {
		seconds = 2
	}
	if seconds > 30 {
		seconds = 30
	}
	return seconds
}

func (p *Policy) TTFTTooSlow(w http.ResponseWriter, model, publicModel string, bestTTFT, threshold time.Duration) {
	retryAfter := p.TTFTRetryAfter(model, bestTTFT, threshold)
	w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
	p.observation.Incr("routing.decisions", []string{"model:" + model, "model_type:" + p.registry.ModelType(model), "outcome:ttft_429"})
	httpx.WriteJSON(w, http.StatusTooManyRequests, httpx.ErrorResponse("rate_limit_exceeded", TTFTMessage(publicModel, bestTTFT, threshold, retryAfter), httpx.WithCode("rate_limit_exceeded")))
}

func TTFTMessage(publicModel string, bestTTFT, threshold time.Duration, retryAfter int) string {
	return fmt.Sprintf("all providers for model %q are above the %ds TTFT target (best estimate %.1fs); retry after %ds", publicModel, int(math.Ceil(threshold.Seconds())), bestTTFT.Seconds(), retryAfter)
}

func (p *Policy) Unavailable(w http.ResponseWriter, model string) {
	w.Header().Set("Retry-After", strconv.Itoa(p.Estimate(model)))
	httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("service_unavailable", "service temporarily unavailable \u2014 please retry"))
}
