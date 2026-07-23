package promptcontract

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
)

var ErrPreloadRejected = errors.New("prompt sidecar preload rejected")

type ReadinessStatus struct {
	Status string `json:"status"`
	Ready  bool   `json:"ready"`
}

type PreloadResult struct {
	PromptContractID string `json:"prompt_contract_id"`
	Status           string `json:"status"`
}

type PreloadReport struct {
	Status    string          `json:"status"`
	Ready     bool            `json:"ready"`
	Requested int             `json:"requested"`
	Warm      int             `json:"warm"`
	Cold      int             `json:"cold"`
	Failed    int             `json:"failed"`
	Results   []PreloadResult `json:"results"`
	Metrics   SidecarMetrics  `json:"metrics"`
}

type SidecarStatus struct {
	Status                   string         `json:"status"`
	Ready                    bool           `json:"ready"`
	LoadedContracts          int            `json:"loaded_contracts"`
	LoadingContracts         int            `json:"loading_contracts"`
	MaxLoadedContracts       int            `json:"max_loaded_contracts"`
	PlanningPermitsAvailable int            `json:"planning_permits_available"`
	MaxPlanningConcurrency   int            `json:"max_planning_concurrency"`
	Metrics                  SidecarMetrics `json:"metrics"`
}

type SidecarMetrics struct {
	Plans         SidecarPlanMetrics     `json:"plans"`
	ContractLoads SidecarContractMetrics `json:"contract_loads"`
	Preloads      SidecarPreloadMetrics  `json:"preloads"`
}

type SidecarPlanMetrics struct {
	Started    uint64                 `json:"started"`
	Succeeded  uint64                 `json:"succeeded"`
	ColdOnly   uint64                 `json:"cold_only"`
	Failed     uint64                 `json:"failed"`
	AtCapacity uint64                 `json:"at_capacity"`
	NotReady   uint64                 `json:"not_ready"`
	TimedOut   uint64                 `json:"timed_out"`
	LatencyUS  SidecarLatencySnapshot `json:"latency_us"`
}

type SidecarContractMetrics struct {
	Cold          uint64                 `json:"cold"`
	Warm          uint64                 `json:"warm"`
	Waited        uint64                 `json:"waited"`
	Failed        uint64                 `json:"failed"`
	ColdLatencyUS SidecarLatencySnapshot `json:"cold_latency_us"`
}

type SidecarPreloadMetrics struct {
	Runs      uint64 `json:"runs"`
	Failed    uint64 `json:"failed"`
	Contracts uint64 `json:"contracts"`
}

type SidecarLatencySnapshot struct {
	Count   uint64                 `json:"count"`
	TotalUS uint64                 `json:"total_us"`
	MaxUS   uint64                 `json:"max_us"`
	Buckets []SidecarLatencyBucket `json:"buckets"`
}

type SidecarLatencyBucket struct {
	LessThanOrEqualUS *uint64 `json:"less_than_or_equal_us,omitempty"`
	CumulativeCount   uint64  `json:"cumulative_count"`
}

// Ready checks readiness over the health-only connection pool. A 503 is an
// expected not-ready result, not an overload and not a liveness failure.
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

// Preload loads the exact, ordered active contract set. A degraded 200 report
// is returned to the caller so it can keep cache routing gated without killing
// or restarting an otherwise-live child.
func (c *Client) Preload(ctx context.Context, contractIDs []string) (PreloadReport, error) {
	if c == nil || len(contractIDs) == 0 || len(contractIDs) > c.config.MaxPreloadIDs {
		return PreloadReport{}, ErrPreloadRejected
	}
	seen := make(map[string]struct{}, len(contractIDs))
	for _, contractID := range contractIDs {
		if !validHash(contractID) {
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
		requestContext, http.MethodPost, "http://promptsidecar/v1/preload", bytes.NewReader(body),
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
	if response.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
		return PreloadReport{}, fmt.Errorf("%w: HTTP %d", ErrPreloadRejected, response.StatusCode)
	}
	var report PreloadReport
	if err := decodeBoundedJSON(response.Body, c.config.MaxResponseBytes, &report); err != nil {
		return PreloadReport{}, fmt.Errorf("%w: %v", ErrPreloadRejected, err)
	}
	if err := validatePreloadReport(contractIDs, report); err != nil {
		return PreloadReport{}, err
	}
	c.storeMetrics(report.Metrics)
	return report, nil
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
