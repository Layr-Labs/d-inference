package testbed

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type UserPool struct {
	users []UserAccount
	next  atomic.Int64
}

func NewUserPool(users []UserAccount) *UserPool {
	return &UserPool{users: users}
}

func (up *UserPool) Next() UserAccount {
	idx := int(up.next.Add(1)-1) % len(up.users)
	return up.users[idx]
}

func (up *UserPool) Count() int {
	return len(up.users)
}

type ModelSelector struct {
	models []string
	next   atomic.Int64
}

func NewModelSelector(modelIDs []string) *ModelSelector {
	return &ModelSelector{models: modelIDs}
}

func (ms *ModelSelector) Next() string {
	if len(ms.models) == 0 {
		return ""
	}
	idx := int(ms.next.Add(1)-1) % len(ms.models)
	return ms.models[idx]
}

type LoadGenerator struct {
	Suite              *Suite
	Config             RequestConfig
	Auth               string
	UserPool           *UserPool
	ModelSelector      *ModelSelector
	userIndexByAccount map[string]int
}

func NewLoadGenerator(suite *Suite, cfg RequestConfig) *LoadGenerator {
	lg := &LoadGenerator{
		Suite:              suite,
		Config:             cfg,
		Auth:               "testbed-admin-key",
		userIndexByAccount: make(map[string]int, len(suite.Users)),
	}
	for i, user := range suite.Users {
		lg.userIndexByAccount[user.AccountID] = i
	}
	if len(suite.Users) > 0 {
		lg.UserPool = NewUserPool(suite.Users)
	}
	if len(suite.Config.AllModelIDs()) > 0 {
		lg.ModelSelector = NewModelSelector(suite.Config.AllModelIDs())
	}
	return lg
}

func (lg *LoadGenerator) WithAuth(apiKey string) *LoadGenerator {
	lg.Auth = apiKey
	return lg
}

func (lg *LoadGenerator) WithUserPool(pool *UserPool) *LoadGenerator {
	lg.UserPool = pool
	return lg
}

func (lg *LoadGenerator) WithModelSelector(selector *ModelSelector) *LoadGenerator {
	lg.ModelSelector = selector
	return lg
}

func (lg *LoadGenerator) Run() (*LoadResult, error) {
	result := &LoadResult{
		TotalRequests:     lg.Config.TotalRequests,
		ExpectedSuccesses: lg.Config.ExpectedSuccesses,
		MinimumSuccesses:  lg.Config.MinimumSuccesses,
	}
	if err := validateRequestConfig(lg.Config); err != nil {
		return result, err
	}

	start := time.Now()
	client := &http.Client{Timeout: 300 * time.Second}
	sem := make(chan struct{}, lg.Config.Concurrency)
	var wg sync.WaitGroup
	wg.Add(lg.Config.TotalRequests)

	requestResults := make([]RequestResult, lg.Config.TotalRequests)

	for i := range lg.Config.TotalRequests {
		sem <- struct{}{}
		go func(idx int) {
			defer wg.Done()
			defer func() { <-sem }()

			reqStart := time.Now()
			modelID := lg.Config.ModelID
			if modelID == "" && lg.ModelSelector != nil {
				modelID = lg.ModelSelector.Next()
			}
			if modelID == "" {
				modelID = lg.Suite.PrimaryModelID()
			}

			auth := lg.Auth
			userIndex := -1
			if lg.UserPool != nil {
				user := lg.UserPool.Next()
				auth = user.APIKey
				if idx, ok := lg.userIndexByAccount[user.AccountID]; ok {
					userIndex = idx
				}
			}

			rr := RequestResult{Index: idx, UserIndex: userIndex, ModelID: modelID}
			prompt := fmt.Sprintf("What is %d+%d? Answer with just the number.", idx, idx+1)
			if padding := lg.Config.PromptBytes - len(prompt); padding > 0 {
				prompt += strings.Repeat(" ", padding)
			}

			bodyJSON, err := json.Marshal(map[string]any{
				"model":       modelID,
				"messages":    []map[string]string{{"role": "user", "content": prompt}},
				"stream":      lg.Config.Streaming,
				"max_tokens":  lg.Config.MaxTokens,
				"temperature": lg.Config.Temperature,
			})
			if err != nil {
				rr.Error = fmt.Errorf("encode request body: %w", err)
				rr.Duration = time.Since(reqStart)
				requestResults[idx] = rr
				return
			}

			req, err := http.NewRequestWithContext(
				lg.Suite.Ctx,
				http.MethodPost,
				lg.Suite.Coordinator.BaseURL()+"/v1/chat/completions",
				bytes.NewReader(bodyJSON),
			)
			if err != nil {
				rr.Error = fmt.Errorf("create request: %w", err)
				rr.Duration = time.Since(reqStart)
				requestResults[idx] = rr
				return
			}
			req.Header.Set("Authorization", "Bearer "+auth)
			req.Header.Set("Content-Type", "application/json")

			resp, err := client.Do(req)
			if err != nil {
				rr.Error = fmt.Errorf("send request: %w", err)
				rr.Duration = time.Since(reqStart)
				requestResults[idx] = rr
				return
			}
			decodeResponse(resp, reqStart, lg.Config.Streaming, &rr)
			requestResults[idx] = rr
		}(i)
	}

	wg.Wait()

	result.aggregate(requestResults, time.Since(start))
	return result, result.thresholdError()
}

func validateRequestConfig(cfg RequestConfig) error {
	switch {
	case cfg.TotalRequests <= 0:
		return fmt.Errorf("total requests must be positive, got %d", cfg.TotalRequests)
	case cfg.Concurrency <= 0:
		return fmt.Errorf("concurrency must be positive, got %d", cfg.Concurrency)
	case cfg.ExpectedSuccesses <= 0:
		return fmt.Errorf("expected successes must be positive, got %d", cfg.ExpectedSuccesses)
	case cfg.ExpectedSuccesses > cfg.TotalRequests:
		return fmt.Errorf(
			"expected successes %d exceed total requests %d",
			cfg.ExpectedSuccesses,
			cfg.TotalRequests,
		)
	case cfg.MinimumSuccesses <= 0:
		return fmt.Errorf("minimum successes must be positive, got %d", cfg.MinimumSuccesses)
	case cfg.MinimumSuccesses > cfg.ExpectedSuccesses:
		return fmt.Errorf(
			"minimum successes %d exceed expected successes %d",
			cfg.MinimumSuccesses,
			cfg.ExpectedSuccesses,
		)
	default:
		return nil
	}
}
