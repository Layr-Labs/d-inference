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
	"sync/atomic"
	"time"
)

const (
	DefaultSocketPath       = "/run/darkbloom/promptsidecar.sock"
	DefaultRequestTimeout   = time.Second
	DefaultMaxRequestBytes  = 4 << 20
	DefaultMaxResponseBytes = 1 << 20
	DefaultMaxTokens        = 1_048_576
)

var (
	ErrSidecarUnavailable = errors.New("prompt sidecar unavailable")
	ErrInvalidPlan        = errors.New("prompt sidecar returned an invalid plan")
	ErrPlanTooLarge       = errors.New("prompt sidecar payload exceeded its bound")
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
	MaxRequestBytes  int64
	MaxResponseBytes int64
	MaxTokens        int
}

type Client struct {
	config    ClientConfig
	http      *http.Client
	transport *http.Transport
	timeouts  atomic.Uint64
	overloads atomic.Uint64
}

type ClientStats struct {
	Timeouts  uint64
	Overloads uint64
}

func NewClient(config ClientConfig) *Client {
	if config.SocketPath == "" {
		config.SocketPath = DefaultSocketPath
	}
	if config.RequestTimeout <= 0 {
		config.RequestTimeout = DefaultRequestTimeout
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
	dialer := &net.Dialer{Timeout: config.RequestTimeout, KeepAlive: 30 * time.Second}
	transport := &http.Transport{
		DisableCompression:    true,
		ForceAttemptHTTP2:     false,
		MaxIdleConns:          8,
		MaxIdleConnsPerHost:   8,
		MaxConnsPerHost:       16,
		IdleConnTimeout:       90 * time.Second,
		ResponseHeaderTimeout: config.RequestTimeout,
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			if err := validateSocket(config.SocketPath); err != nil {
				return nil, err
			}
			return dialer.DialContext(ctx, "unix", config.SocketPath)
		},
	}
	return &Client{
		config:    config,
		http:      &http.Client{Transport: transport},
		transport: transport,
	}
}

func (c *Client) Close() {
	c.transport.CloseIdleConnections()
}

func (c *Client) Stats() ClientStats {
	if c == nil {
		return ClientStats{}
	}
	return ClientStats{
		Timeouts:  c.timeouts.Load(),
		Overloads: c.overloads.Load(),
	}
}

func (c *Client) Health(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, c.config.RequestTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://promptsidecar/health", nil)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrSidecarUnavailable, err)
	}
	response, err := c.http.Do(request)
	if err != nil {
		c.recordTransportError(err)
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
	response, err := c.http.Do(request)
	if err != nil {
		c.recordTransportError(err)
		return Plan{}, fmt.Errorf("%w: %v", ErrSidecarUnavailable, err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		if response.StatusCode == http.StatusServiceUnavailable {
			c.overloads.Add(1)
		}
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
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

func (c *Client) recordTransportError(err error) {
	if errors.Is(err, context.DeadlineExceeded) {
		c.timeouts.Add(1)
	} else if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
		c.timeouts.Add(1)
	}
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
