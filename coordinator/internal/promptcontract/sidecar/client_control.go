package sidecar

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
)

var (
	ErrPreloadRejected = errors.New("prompt sidecar preload rejected")
	// ErrContinuityUnsupported means the sidecar reported that it has no
	// continuity endpoint. Only this error permits the replacing preload.
	ErrContinuityUnsupported = errors.New("prompt sidecar continuity endpoint unsupported")
	// ErrContinuityProtocol means a continuity response cannot be trusted: its
	// marker, its report or its endpoint-absence body is missing or malformed.
	ErrContinuityProtocol = errors.New("prompt sidecar continuity protocol invalid")
)

const (
	replacingPreloadPath  = "/v1/preload" // Closes every member while the new set loads.
	continuityPreloadPath = "/v2/preload" // Keeps acknowledged members of the new set usable.
)

// Ready checks readiness over the health-only connection pool. A 503 is an
// expected not-ready result, not an overload and not a liveness failure. Runtime
// readiness alone does not acknowledge every member of a requested preload set.
func (c *Client) Ready(ctx context.Context) (bool, error) {
	response, err := c.healthGet(ctx, "/ready")
	if err != nil {
		return false, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusServiceUnavailable {
		return false, fmt.Errorf("%w: readiness HTTP %d", ErrSidecarUnavailable, response.StatusCode)
	}
	var status ReadinessStatus
	if err := decodeBoundedJSON(response.Body, c.config.MaxResponseBytes, &status); err != nil {
		return false, fmt.Errorf("%w: readiness: %v", ErrSidecarUnavailable, err)
	}
	return response.StatusCode == http.StatusOK && status.Ready, nil
}

// MaxPreloadIDs is the largest contract set Preload accepts. The preload
// controller never publishes a verified set larger than this capacity.
func (c *Client) MaxPreloadIDs() int {
	if c == nil {
		return 0
	}
	return c.config.MaxPreloadIDs
}

// Preload loads the exact, ordered active contract set. A degraded 200 report
// is returned unchanged to the caller. Its Ready field still means every
// submitted member succeeded, not that the runtime has no usable subset.
func (c *Client) Preload(ctx context.Context, contractIDs []string) (PreloadReport, error) {
	return c.preloadAt(ctx, contractIDs, replacingPreloadPath)
}

// PreloadContinuous loads the same set through the continuity endpoint. Only a
// sidecar that reports the endpoint absent is retried through Preload, and only
// while requireContinuity is false: a negotiated child must never silently
// downgrade to the destructive replacing preload.
func (c *Client) PreloadContinuous(ctx context.Context, contractIDs []string, requireContinuity bool) (PreloadReport, error) {
	report, err := c.preloadAt(ctx, contractIDs, continuityPreloadPath)
	if errors.Is(err, ErrContinuityUnsupported) && !requireContinuity {
		return c.Preload(ctx, contractIDs)
	}
	if err == nil && report.ContinuityVersion != 1 {
		return PreloadReport{}, ErrContinuityProtocol
	}
	return report, err
}

func (c *Client) preloadAt(ctx context.Context, contractIDs []string, endpoint string) (PreloadReport, error) {
	if c == nil || len(contractIDs) == 0 || len(contractIDs) > c.config.MaxPreloadIDs {
		return PreloadReport{}, ErrPreloadRejected
	}
	seen := make(map[string]struct{}, len(contractIDs))
	for _, contractID := range contractIDs {
		if !ValidHash(contractID) {
			return PreloadReport{}, ErrPreloadRejected
		}
		if _, exists := seen[contractID]; exists {
			return PreloadReport{}, ErrPreloadRejected
		}
		seen[contractID] = struct{}{}
	}
	body, err := json.Marshal(struct {
		PromptContractIDs []string `json:"prompt_contract_ids"`
	}{PromptContractIDs: contractIDs})
	if err != nil || int64(len(body)) > c.config.MaxRequestBytes {
		return PreloadReport{}, ErrPreloadRejected
	}
	requestContext, cancel := context.WithTimeout(ctx, c.config.PreloadTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(
		requestContext, http.MethodPost, "http://promptsidecar"+endpoint, bytes.NewReader(body),
	)
	if err != nil {
		return PreloadReport{}, fmt.Errorf("%w: %v", ErrSidecarUnavailable, err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := c.controlHTTP.Do(request)
	if err != nil {
		if isTimeoutError(err) {
			c.preloadTimeouts.Add(1)
		}
		return PreloadReport{}, fmt.Errorf("%w: %v", ErrSidecarUnavailable, err)
	}
	defer response.Body.Close()
	continuity := endpoint == continuityPreloadPath
	if continuity && response.StatusCode == http.StatusNotFound {
		if continuityEndpointAbsent(response.Body) {
			return PreloadReport{}, ErrContinuityUnsupported
		}
		return PreloadReport{}, ErrContinuityProtocol
	}
	if response.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
		return PreloadReport{}, fmt.Errorf("%w: HTTP %d", ErrPreloadRejected, response.StatusCode)
	}
	var report PreloadReport
	if err := decodeBoundedJSON(response.Body, c.config.MaxResponseBytes, &report); err != nil {
		if continuity {
			return PreloadReport{}, fmt.Errorf("%w: %w", ErrContinuityProtocol, err)
		}
		return PreloadReport{}, fmt.Errorf("%w: %v", ErrPreloadRejected, err)
	}
	if err := validatePreloadReport(contractIDs, report); err != nil {
		if continuity {
			return PreloadReport{}, fmt.Errorf("%w: %w", ErrContinuityProtocol, err)
		}
		return PreloadReport{}, err
	}
	c.storeMetrics(report.Metrics)
	return report, nil
}

// continuityEndpointAbsent recognizes only the sidecar's own not_found error
// and the Go standard library's default 404 body. Any other 404 is a protocol
// failure, never grounds for the replacing fallback.
func continuityEndpointAbsent(body io.Reader) bool {
	raw, err := io.ReadAll(io.LimitReader(body, 4096))
	if err != nil {
		return false
	}
	var rejection struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	return (json.Unmarshal(raw, &rejection) == nil && rejection.Error.Code == "not_found") ||
		string(raw) == "404 page not found\n"
}

// Metrics refreshes the cached bounded aggregate through the health pool. It
// is intended for a background controller, never for a Prometheus callback.
func (c *Client) Metrics(ctx context.Context) (SidecarStatus, error) {
	response, err := c.healthGet(ctx, "/metrics")
	if err != nil {
		return SidecarStatus{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return SidecarStatus{}, fmt.Errorf("%w: metrics HTTP %d", ErrSidecarUnavailable, response.StatusCode)
	}
	var status SidecarStatus
	if err := decodeBoundedJSON(response.Body, c.config.MaxResponseBytes, &status); err != nil {
		return SidecarStatus{}, fmt.Errorf("%w: metrics: %v", ErrSidecarUnavailable, err)
	}
	if (status.Status != "ok" && status.Status != "starting" && status.Status != "degraded") ||
		status.Ready != (status.Status == "ok") ||
		status.LoadedContracts < 0 || status.LoadingContracts < 0 || status.MaxLoadedContracts <= 0 ||
		status.PlanningPermitsAvailable < 0 || status.MaxPlanningConcurrency <= 0 ||
		status.LoadedContracts > status.MaxLoadedContracts ||
		status.PlanningPermitsAvailable > status.MaxPlanningConcurrency {
		return SidecarStatus{}, ErrPreloadRejected
	}
	c.storeMetrics(status.Metrics)
	return status, nil
}

func (c *Client) healthGet(ctx context.Context, path string) (*http.Response, error) {
	requestContext, cancel := context.WithTimeout(ctx, c.config.HealthTimeout)
	request, err := http.NewRequestWithContext(requestContext, http.MethodGet, "http://promptsidecar"+path, nil)
	if err != nil {
		cancel()
		return nil, fmt.Errorf("%w: %v", ErrSidecarUnavailable, err)
	}
	response, err := c.healthHTTP.Do(request)
	if err != nil {
		cancel()
		if isTimeoutError(err) {
			c.healthTimeouts.Add(1)
		}
		return nil, fmt.Errorf("%w: %v", ErrSidecarUnavailable, err)
	}
	response.Body = &cancelOnCloseReadCloser{ReadCloser: response.Body, cancel: cancel}
	return response, nil
}

type cancelOnCloseReadCloser struct {
	io.ReadCloser
	cancel context.CancelFunc
}

func (r *cancelOnCloseReadCloser) Close() error {
	err := r.ReadCloser.Close()
	r.cancel()
	return err
}

func decodeBoundedJSON(reader io.Reader, maximum int64, target any) error {
	encoded, err := io.ReadAll(io.LimitReader(reader, maximum+1))
	if err != nil {
		return err
	}
	if int64(len(encoded)) > maximum {
		return ErrPlanTooLarge
	}
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return ErrInvalidPlan
	}
	return nil
}

func validatePreloadReport(requested []string, report PreloadReport) error {
	if report.Status != "ready" && report.Status != "degraded" {
		return ErrPreloadRejected
	}
	if report.Requested != len(requested) || len(report.Results) != len(requested) ||
		report.Warm < 0 || report.Cold < 0 || report.Failed < 0 ||
		report.Warm+report.Cold+report.Failed != report.Requested ||
		report.Ready != (report.Failed == 0) {
		return ErrPreloadRejected
	}
	var warm, cold, failed int
	for index, result := range report.Results {
		if result.PromptContractID != requested[index] {
			return ErrPreloadRejected
		}
		switch result.Status {
		case "warm":
			warm++
		case "cold":
			cold++
		case "failed":
			failed++
		default:
			return ErrPreloadRejected
		}
	}
	if warm != report.Warm || cold != report.Cold || failed != report.Failed {
		return ErrPreloadRejected
	}
	return nil
}

func (c *Client) storeMetrics(metrics SidecarMetrics) {
	c.metricsMu.Lock()
	c.metrics = cloneSidecarMetrics(metrics)
	c.metricsMu.Unlock()
}

func (c *Client) SidecarMetrics() SidecarMetrics {
	if c == nil {
		return SidecarMetrics{}
	}
	c.metricsMu.RLock()
	metrics := cloneSidecarMetrics(c.metrics)
	c.metricsMu.RUnlock()
	return metrics
}

func cloneSidecarMetrics(metrics SidecarMetrics) SidecarMetrics {
	metrics.Plans.LatencyUS.Buckets = append(
		[]SidecarLatencyBucket(nil), metrics.Plans.LatencyUS.Buckets...,
	)
	metrics.ContractLoads.ColdLatencyUS.Buckets = append(
		[]SidecarLatencyBucket(nil), metrics.ContractLoads.ColdLatencyUS.Buckets...,
	)
	return metrics
}
