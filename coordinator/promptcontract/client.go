package promptcontract

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	DefaultSocketPath       = "/run/darkbloom/promptsidecar.sock"
	DefaultRequestTimeout   = time.Second
	DefaultHealthTimeout    = 250 * time.Millisecond
	DefaultPreloadTimeout   = 2 * time.Minute
	DefaultMaxRequestBytes  = 4 << 20
	DefaultMaxResponseBytes = 1 << 20
	DefaultMaxTokens        = 1_048_576
	DefaultMaxPreloadIDs    = 128
)

var (
	ErrSidecarUnavailable = errors.New("prompt sidecar unavailable")
	ErrInvalidPlan        = errors.New("prompt sidecar returned an invalid plan")
	ErrPlanTooLarge       = errors.New("prompt sidecar payload exceeded its bound")
	ErrDynamicContract    = errors.New("prompt contract depends on dynamic time")
)

type Endpoint string

const (
	EndpointChatCompletions Endpoint = "chat_completions"
	EndpointCompletions     Endpoint = "completions"
	EndpointResponses       Endpoint = "responses"
	EndpointMessages        Endpoint = "messages"
)

type PlanInput struct {
	PromptContractID string
	ScopeID          string
	Endpoint         Endpoint
	Body             json.RawMessage
}

type Boundary struct {
	TokenCount uint32 `json:"token_count"`
	ChainHash  string `json:"chain_hash"`
}

type Plan struct {
	Participating         bool       `json:"-"`
	PromptContractID      string     `json:"prompt_contract_id"`
	PromptTokenCount      uint32     `json:"prompt_token_count"`
	BlockBoundaries       []Boundary `json:"block_boundaries"`
	LastCompleteBlockHash *string    `json:"last_complete_block_hash,omitempty"`
}

type ClientConfig struct {
	SocketPath       string
	RequestTimeout   time.Duration
	HealthTimeout    time.Duration
	PreloadTimeout   time.Duration
	MaxRequestBytes  int64
	MaxResponseBytes int64
	MaxTokens        int
	MaxPreloadIDs    int
}

type Client struct {
	config           ClientConfig
	planHTTP         *http.Client
	healthHTTP       *http.Client
	controlHTTP      *http.Client
	planTransport    *http.Transport
	healthTransport  *http.Transport
	controlTransport *http.Transport
	planTimeouts     atomic.Uint64
	healthTimeouts   atomic.Uint64
	preloadTimeouts  atomic.Uint64
	overloads        atomic.Uint64
	metricsMu        sync.RWMutex
	metrics          SidecarMetrics
}

type ClientStats struct {
	Timeouts        uint64
	HealthTimeouts  uint64
	PreloadTimeouts uint64
	Overloads       uint64
}

func NewClient(config ClientConfig) *Client {
	if config.SocketPath == "" {
		config.SocketPath = DefaultSocketPath
	}
	if config.RequestTimeout <= 0 {
		config.RequestTimeout = DefaultRequestTimeout
	}
	if config.HealthTimeout <= 0 {
		config.HealthTimeout = DefaultHealthTimeout
	}
	if config.PreloadTimeout <= 0 {
		config.PreloadTimeout = DefaultPreloadTimeout
	}
	if config.MaxRequestBytes <= 0 {
		config.MaxRequestBytes = DefaultMaxRequestBytes
	}
	if config.MaxResponseBytes <= 0 {
		config.MaxResponseBytes = DefaultMaxResponseBytes
	}
	if config.MaxTokens <= 0 {
		config.MaxTokens = DefaultMaxTokens
	}
	if config.MaxPreloadIDs <= 0 {
		config.MaxPreloadIDs = DefaultMaxPreloadIDs
	}
	planTransport := newUnixTransport(config.SocketPath, config.RequestTimeout, 16)
	healthTransport := newUnixTransport(config.SocketPath, config.HealthTimeout, 2)
	controlTransport := newUnixTransport(config.SocketPath, config.PreloadTimeout, 2)
	return &Client{
		config:           config,
		planHTTP:         &http.Client{Transport: planTransport},
		healthHTTP:       &http.Client{Transport: healthTransport},
		controlHTTP:      &http.Client{Transport: controlTransport},
		planTransport:    planTransport,
		healthTransport:  healthTransport,
		controlTransport: controlTransport,
	}
}

func newUnixTransport(socketPath string, timeout time.Duration, maxConnections int) *http.Transport {
	dialer := &net.Dialer{Timeout: timeout, KeepAlive: 30 * time.Second}
	return &http.Transport{
		DisableCompression:    true,
		ForceAttemptHTTP2:     false,
		MaxIdleConns:          maxConnections,
		MaxIdleConnsPerHost:   maxConnections,
		MaxConnsPerHost:       maxConnections,
		IdleConnTimeout:       90 * time.Second,
		ResponseHeaderTimeout: timeout,
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			if err := validateSocket(socketPath); err != nil {
				return nil, err
			}
			return dialer.DialContext(ctx, "unix", socketPath)
		},
	}
}

func (c *Client) Close() {
	if c == nil {
		return
	}
	c.planTransport.CloseIdleConnections()
	c.healthTransport.CloseIdleConnections()
	c.controlTransport.CloseIdleConnections()
}

func (c *Client) Stats() ClientStats {
	if c == nil {
		return ClientStats{}
	}
	return ClientStats{
		Timeouts:        c.planTimeouts.Load(),
		HealthTimeouts:  c.healthTimeouts.Load(),
		PreloadTimeouts: c.preloadTimeouts.Load(),
		Overloads:       c.overloads.Load(),
	}
}

func (c *Client) Health(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, c.config.HealthTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://promptsidecar/health", nil)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrSidecarUnavailable, err)
	}
	response, err := c.healthHTTP.Do(request)
	if err != nil {
		if isTimeoutError(err) {
			c.healthTimeouts.Add(1)
		}
		return fmt.Errorf("%w: %v", ErrSidecarUnavailable, err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		if response.StatusCode == http.StatusServiceUnavailable {
			c.overloads.Add(1)
		}
		return fmt.Errorf("%w: HTTP %d", ErrSidecarUnavailable, response.StatusCode)
	}
	_, err = io.Copy(io.Discard, io.LimitReader(response.Body, 1024))
	if err != nil {
		return fmt.Errorf("%w: %v", ErrSidecarUnavailable, err)
	}
	return nil
}

func (c *Client) Plan(ctx context.Context, input PlanInput) (Plan, error) {
	if !validHash(input.PromptContractID) ||
		input.ScopeID == "" ||
		len(input.ScopeID) > 256 ||
		!validEndpoint(input.Endpoint) ||
		len(input.Body) == 0 ||
		!json.Valid(input.Body) {
		return Plan{}, ErrInvalidPlan
	}
	requestBody, err := json.Marshal(struct {
		PromptContractID string          `json:"prompt_contract_id"`
		ScopeID          string          `json:"scope_id"`
		Endpoint         Endpoint        `json:"endpoint"`
		Body             json.RawMessage `json:"body"`
	}{
		PromptContractID: input.PromptContractID,
		ScopeID:          input.ScopeID,
		Endpoint:         input.Endpoint,
		Body:             input.Body,
	})
	if err != nil {
		return Plan{}, fmt.Errorf("%w: %v", ErrInvalidPlan, err)
	}
	if int64(len(requestBody)) > c.config.MaxRequestBytes {
		return Plan{}, ErrPlanTooLarge
	}
	ctx, cancel := context.WithTimeout(ctx, c.config.RequestTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		"http://promptsidecar/v1/plan",
		bytes.NewReader(requestBody),
	)
	if err != nil {
		return Plan{}, fmt.Errorf("%w: %v", ErrSidecarUnavailable, err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := c.planHTTP.Do(request)
	if err != nil {
		if isTimeoutError(err) {
			c.planTimeouts.Add(1)
		}
		return Plan{}, fmt.Errorf("%w: %v", ErrSidecarUnavailable, err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		if response.StatusCode == http.StatusServiceUnavailable {
			c.overloads.Add(1)
		}
		encoded, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		var sidecarError struct {
			Error struct {
				Code string `json:"code"`
			} `json:"error"`
		}
		if response.StatusCode == http.StatusUnprocessableEntity &&
			json.Unmarshal(encoded, &sidecarError) == nil &&
			sidecarError.Error.Code == "dynamic_time" {
			return Plan{}, fmt.Errorf("%w: HTTP %d", ErrDynamicContract, response.StatusCode)
		}
		return Plan{}, fmt.Errorf("%w: HTTP %d", ErrSidecarUnavailable, response.StatusCode)
	}
	encoded, err := io.ReadAll(io.LimitReader(response.Body, c.config.MaxResponseBytes+1))
	if err != nil {
		return Plan{}, fmt.Errorf("%w: %v", ErrSidecarUnavailable, err)
	}
	if int64(len(encoded)) > c.config.MaxResponseBytes {
		return Plan{}, ErrPlanTooLarge
	}
	var plan Plan
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&plan); err != nil {
		return Plan{}, ErrInvalidPlan
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return Plan{}, ErrInvalidPlan
	}
	if err := c.validatePlan(input, plan); err != nil {
		return Plan{}, err
	}
	plan.Participating = true
	return plan, nil
}

func isTimeoutError(err error) bool {
	if errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	netErr, ok := err.(net.Error)
	return ok && netErr.Timeout()
}

func (c *Client) PlanFailCold(ctx context.Context, input PlanInput) Plan {
	plan, err := c.Plan(ctx, input)
	if err != nil {
		return Plan{}
	}
	return plan
}

func (c *Client) validatePlan(input PlanInput, plan Plan) error {
	if plan.PromptContractID != input.PromptContractID ||
		uint64(plan.PromptTokenCount) > uint64(c.config.MaxTokens) {
		return ErrInvalidPlan
	}
	expectedBoundaries := 0
	if plan.PromptTokenCount > 0 {
		expectedBoundaries = int((plan.PromptTokenCount - 1) / BlockSize)
	}
	if len(plan.BlockBoundaries) != expectedBoundaries {
		return ErrInvalidPlan
	}
	for index, boundary := range plan.BlockBoundaries {
		if boundary.TokenCount != uint32(index+1)*BlockSize || !validHash(boundary.ChainHash) {
			return ErrInvalidPlan
		}
	}
	if expectedBoundaries == 0 {
		if plan.LastCompleteBlockHash != nil {
			return ErrInvalidPlan
		}
	} else if plan.LastCompleteBlockHash == nil ||
		*plan.LastCompleteBlockHash != plan.BlockBoundaries[expectedBoundaries-1].ChainHash {
		return ErrInvalidPlan
	}
	return nil
}

func validEndpoint(endpoint Endpoint) bool {
	switch endpoint {
	case EndpointChatCompletions, EndpointCompletions, EndpointResponses, EndpointMessages:
		return true
	default:
		return false
	}
}

func validateSocket(socketPath string) error {
	info, err := os.Lstat(socketPath)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrSidecarUnavailable, err)
	}
	if info.Mode()&os.ModeSocket == 0 || info.Mode().Perm() != 0o600 {
		return ErrSidecarUnavailable
	}
	return nil
}

func validHash(value string) bool {
	if len(value) != sha256HexLength {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil && value == strings.ToLower(value)
}

const sha256HexLength = 64
