package mediafetch

// fetch.go owns the hardened outbound HTTP path: a dedicated one-shot client
// whose every dial runs the SSRF Control hook (ssrf.go), redirect re-validation,
// size-capped reads, and the typed error classification the API layer maps to
// consumer-facing responses.

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"

	mediapolicy "github.com/eigeninference/d-inference/coordinator/internal/mediafetch/policy"
	readbudget "github.com/eigeninference/d-inference/coordinator/internal/mediafetch/readbudget"
	mediarefs "github.com/eigeninference/d-inference/coordinator/internal/mediafetch/references"
)

// fetchOne downloads one media URL under the SSRF policy and size cap, validates
// the content structurally (allowlist, declared-kind match, pixel cap), and
// returns the bytes plus sniffed MIME type. The per-fetch timeout is applied via
// ctx so it is independent of the request TTFT deadline.
func (r *Resolver) fetchOne(ctx context.Context, ref mediarefs.Ref, maxBytes int64, totalBudget *readbudget.Budget) (*mediapolicy.Media, error) {
	u, err := url.Parse(strings.TrimSpace(ref.URL))
	if err != nil {
		return nil, &mediapolicy.Error{Status: http.StatusBadRequest, Code: "invalid_media_url",
			Public: "a media URL could not be parsed", Internal: "URL parse failed"}
	}
	if err := mediapolicy.ValidateURL(u, r.cfg); err != nil {
		return nil, classifyURLError(err)
	}

	fetchCtx, cancel := context.WithTimeout(ctx, r.cfg.FetchTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(fetchCtx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, &mediapolicy.Error{Status: http.StatusBadRequest, Code: "invalid_media_url",
			Public: "a media URL could not be requested", Internal: "request construction failed"}
	}
	req.Header.Set("Accept", "image/*,video/*")
	req.Header.Set("Accept-Encoding", "identity") // belt-and-suspenders with DisableCompression
	req.Header.Set("User-Agent", "darkbloom-coordinator-mediafetch")

	resp, err := r.client.Do(req)
	if err != nil {
		return nil, classifyFetchError(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, &mediapolicy.Error{Status: http.StatusBadGateway, Code: "media_fetch_failed",
			Public:   "a media URL could not be retrieved",
			Internal: fmt.Sprintf("upstream returned HTTP %d", resp.StatusCode)}
	}

	// Pre-check the declared length to reject obvious oversize before reading.
	if resp.ContentLength > maxBytes {
		return nil, &mediapolicy.Error{Status: http.StatusRequestEntityTooLarge, Code: "media_too_large",
			Public:   "a media file exceeds the maximum allowed size",
			Internal: fmt.Sprintf("Content-Length %d > cap %d", resp.ContentLength, maxBytes)}
	}

	// Read at most maxBytes+1 so we can detect overflow without buffering more —
	// the LimitReader (not the header) is the enforced cap.
	// Layer the per-file reader under the SHARED per-request budget. The shared
	// budget allows only MaxTotalBytes+1 bytes across all concurrent fetches, so
	// four 8 MiB responses can never transiently retain 32 MiB before the 10 MiB
	// aggregate check notices. The +1 byte distinguishes exactly-at-cap EOF from
	// overflow without buffering more than one byte past the aggregate limit.
	data, err := io.ReadAll(totalBudget.Reader(io.LimitReader(resp.Body, maxBytes+1)))
	if err != nil {
		if errors.Is(err, readbudget.ErrExceeded) {
			return nil, &mediapolicy.Error{Status: http.StatusRequestEntityTooLarge, Code: "media_too_large",
				Public:   "combined media exceeds the maximum allowed size for one request",
				Internal: fmt.Sprintf("aggregate body exceeded cap %d", totalBudget.Limit())}
		}
		return nil, classifyFetchError(err)
	}
	if int64(len(data)) > maxBytes {
		return nil, &mediapolicy.Error{Status: http.StatusRequestEntityTooLarge, Code: "media_too_large",
			Public:   "a media file exceeds the maximum allowed size",
			Internal: fmt.Sprintf("response body exceeded cap %d", maxBytes)}
	}
	if len(data) == 0 {
		return nil, &mediapolicy.Error{Status: http.StatusBadGateway, Code: "media_fetch_failed",
			Public: "a media URL returned an empty body", Internal: "upstream returned an empty body"}
	}

	mime, err := r.cfg.ValidateMedia(ref.Kind, data)
	if err != nil {
		return nil, err
	}
	return &mediapolicy.Media{MIME: mime, Data: data}, nil
}

// classifyURLError maps a pre-flight validateURL failure to a typed Error.
func classifyURLError(err error) *mediapolicy.Error {
	switch {
	case errors.Is(err, mediapolicy.ErrBlockedScheme):
		return &mediapolicy.Error{Status: http.StatusBadRequest, Code: "media_invalid_scheme",
			Public: "media URLs must use http or https", Internal: "URL scheme blocked"}
	case errors.Is(err, mediapolicy.ErrBlockedHost):
		return &mediapolicy.Error{Status: http.StatusForbidden, Code: "media_blocked",
			Public: "a media URL host is not allowed", Internal: "URL host or port blocked"}
	default:
		return &mediapolicy.Error{Status: http.StatusBadRequest, Code: "invalid_media_url",
			Public: "a media URL is invalid", Internal: "URL validation failed"}
	}
}

// classifyFetchError maps a client.Do / read failure to a typed Error: SSRF
// blocks → 403, timeouts → 408, everything else → 502. NEITHER the consumer
// message NOR Internal may echo the URL, host, query or the wrapped error:
// presigned media URLs carry secrets and callers log Error(). Internal is a
// fixed, non-sensitive cause string — keep it that way.
func classifyFetchError(err error) error {
	switch {
	case errors.Is(err, context.Canceled):
		return context.Canceled
	case errors.Is(err, mediapolicy.ErrBlockedIP):
		return &mediapolicy.Error{Status: http.StatusForbidden, Code: "media_blocked",
			Public: "a media URL resolves to a disallowed address", Internal: "resolved address blocked"}
	case errors.Is(err, mediapolicy.ErrBlockedScheme):
		return &mediapolicy.Error{Status: http.StatusBadRequest, Code: "media_invalid_scheme",
			Public: "media URLs must use http or https", Internal: "redirect scheme blocked"}
	case errors.Is(err, mediapolicy.ErrBlockedHost):
		return &mediapolicy.Error{Status: http.StatusForbidden, Code: "media_blocked",
			Public: "a media URL host is not allowed", Internal: "redirect host or port blocked"}
	case errors.Is(err, context.DeadlineExceeded) || isTimeout(err):
		return &mediapolicy.Error{Status: http.StatusRequestTimeout, Code: "media_fetch_timeout",
			Public: "a media URL took too long to fetch", Internal: "fetch deadline exceeded"}
	default:
		return &mediapolicy.Error{Status: http.StatusBadGateway, Code: "media_fetch_failed",
			Public: "a media URL could not be retrieved", Internal: "network request failed"}
	}
}

// isTimeout unwraps net.Error timeouts (e.g. *url.Error wrapping a dial timeout).
func isTimeout(err error) bool {
	var ne net.Error
	return errors.As(err, &ne) && ne.Timeout()
}
