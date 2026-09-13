package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"time"
)

const maximumJSONResponseBytes = 3 * 1024 * 1024

type sandboxClient struct {
	config clientConfig
	http   *http.Client
}

func newSandboxClient(config clientConfig) *sandboxClient {
	return &sandboxClient{config: config, http: &http.Client{
		Timeout:       35 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}
}

type remoteError struct {
	status int
	code   string
}

func (e *remoteError) Error() string {
	return fmt.Sprintf("sandbox request failed: %s (HTTP %d)", e.code, e.status)
}

var safeErrorCode = regexp.MustCompile(`^[a-zA-Z0-9_.-]{1,80}$`)

func decodeRemoteError(response *http.Response) error {
	defer response.Body.Close()
	var payload struct {
		Error struct {
			Code string `json:"code"`
			Type string `json:"type"`
		} `json:"error"`
	}
	_ = json.NewDecoder(io.LimitReader(response.Body, 64*1024)).Decode(&payload)
	code := payload.Error.Code
	if code == "" {
		code = payload.Error.Type
	}
	if !safeErrorCode.MatchString(code) {
		code = "http_error"
	}
	// Do not echo arbitrary response bodies or URLs, which could contain
	// credentials or downloaded data. Stable error codes are sufficient here.
	return &remoteError{status: response.StatusCode, code: code}
}

func (c *sandboxClient) request(ctx context.Context, method, path, contentType, idempotencyKey string, body io.Reader) (*http.Response, error) {
	request, err := http.NewRequestWithContext(ctx, method, c.config.baseURL+path, body)
	if err != nil {
		return nil, errors.New("cannot construct sandbox request")
	}
	request.Header.Set("Authorization", "Bearer "+c.config.apiKey)
	if contentType != "" {
		request.Header.Set("Content-Type", contentType)
	}
	if idempotencyKey != "" {
		request.Header.Set("Idempotency-Key", idempotencyKey)
	}
	response, err := c.http.Do(request)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, errors.New("sandbox request could not complete; its outcome may be uncertain")
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, decodeRemoteError(response)
	}
	return response, nil
}

func (c *sandboxClient) jsonRequest(ctx context.Context, method, path, key string, input, output any) error {
	var body io.Reader
	if input != nil {
		encoded, err := json.Marshal(input)
		if err != nil {
			return errors.New("cannot encode sandbox request")
		}
		body = bytes.NewReader(encoded)
	}
	response, err := c.request(ctx, method, path, "application/json", key, body)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	encoded, err := io.ReadAll(io.LimitReader(response.Body, maximumJSONResponseBytes+1))
	if err != nil || len(encoded) > maximumJSONResponseBytes {
		return errors.New("sandbox JSON response exceeds its limit or is incomplete")
	}
	if output == nil {
		return nil
	}
	if err := json.Unmarshal(encoded, output); err != nil {
		return errors.New("invalid sandbox JSON response")
	}
	return nil
}
