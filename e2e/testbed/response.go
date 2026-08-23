package testbed

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

type responseTiming struct {
	ParseUs      int64 `json:"parse_us"`
	ReserveUs    int64 `json:"reserve_us"`
	MediaFetchUs int64 `json:"media_fetch_us"`
	RouteUs      int64 `json:"route_us"`
	QueueUs      int64 `json:"queue_us"`
	EncryptUs    int64 `json:"encrypt_us"`
	DispatchUs   int64 `json:"dispatch_us"`
	ProviderUs   int64 `json:"provider_us"`
}

func (t responseTiming) TTFT() time.Duration {
	if t.ProviderUs <= 0 {
		return 0
	}
	return time.Duration(t.ProviderUs) * time.Microsecond
}

func decodeResponse(resp *http.Response, requestStart time.Time, streaming bool, result *RequestResult) {
	result.StatusCode = resp.StatusCode

	timing, timingErr := parseResponseTiming(resp.Header.Get("X-Timing"))
	result.ParseUs = timing.ParseUs
	result.ReserveUs = timing.ReserveUs
	result.MediaFetchUs = timing.MediaFetchUs
	result.RouteUs = timing.RouteUs
	result.QueueUs = timing.QueueUs
	result.EncryptUs = timing.EncryptUs
	result.DispatchUs = timing.DispatchUs
	result.ProviderUs = timing.ProviderUs

	body, observedTTFT, readErr := readResponseBody(resp.Body, requestStart, streaming)
	closeErr := resp.Body.Close()
	result.Duration = time.Since(requestStart)
	result.TTFT = observedTTFT
	if result.TTFT <= 0 && timingErr == nil {
		result.TTFT = timing.TTFT()
	}

	var responseErrors []error
	if timingErr != nil {
		responseErrors = append(responseErrors, fmt.Errorf("invalid X-Timing response header: %w", timingErr))
	}
	if readErr != nil {
		responseErrors = append(responseErrors, fmt.Errorf("drain response body: %w", readErr))
	}
	if closeErr != nil {
		responseErrors = append(responseErrors, fmt.Errorf("close response body: %w", closeErr))
	}
	if resp.StatusCode != http.StatusOK {
		responseErrors = append(responseErrors, fmt.Errorf(
			"status %d: %s",
			resp.StatusCode,
			strings.TrimSpace(string(body)),
		))
	}
	if resp.StatusCode == http.StatusOK && streaming && result.TTFT <= 0 && timingErr == nil {
		responseErrors = append(responseErrors, errors.New(
			"streaming response contained no content event and X-Timing had no positive pre-first-chunk duration",
		))
	}
	result.Error = errors.Join(responseErrors...)
}

func parseResponseTiming(header string) (responseTiming, error) {
	if header == "" {
		return responseTiming{}, nil
	}
	var timing responseTiming
	if err := json.Unmarshal([]byte(header), &timing); err != nil {
		return responseTiming{}, fmt.Errorf("decode X-Timing %q: %w", header, err)
	}
	if err := validateTimingValue("parse_us", timing.ParseUs); err != nil {
		return responseTiming{}, err
	}
	if err := validateTimingValue("reserve_us", timing.ReserveUs); err != nil {
		return responseTiming{}, err
	}
	if err := validateTimingValue("media_fetch_us", timing.MediaFetchUs); err != nil {
		return responseTiming{}, err
	}
	if err := validateTimingValue("route_us", timing.RouteUs); err != nil {
		return responseTiming{}, err
	}
	if err := validateTimingValue("queue_us", timing.QueueUs); err != nil {
		return responseTiming{}, err
	}
	if err := validateTimingValue("encrypt_us", timing.EncryptUs); err != nil {
		return responseTiming{}, err
	}
	if err := validateTimingValue("dispatch_us", timing.DispatchUs); err != nil {
		return responseTiming{}, err
	}
	if err := validateTimingValue("provider_us", timing.ProviderUs); err != nil {
		return responseTiming{}, err
	}
	return timing, nil
}

func validateTimingValue(name string, value int64) error {
	if value < 0 {
		return fmt.Errorf("X-Timing %s must be non-negative, got %d", name, value)
	}
	return nil
}

func readResponseBody(body io.Reader, requestStart time.Time, streaming bool) ([]byte, time.Duration, error) {
	if !streaming {
		data, err := io.ReadAll(body)
		return data, 0, err
	}

	reader := bufio.NewReader(body)
	var response bytes.Buffer
	var ttft time.Duration
	for {
		line, err := reader.ReadBytes('\n')
		_, _ = response.Write(line)
		if ttft <= 0 && sseLineHasContent(line) {
			ttft = time.Since(requestStart)
		}
		if err == nil {
			continue
		}
		if errors.Is(err, io.EOF) {
			return response.Bytes(), ttft, nil
		}
		return response.Bytes(), ttft, err
	}
}

func sseLineHasContent(line []byte) bool {
	line = bytes.TrimSpace(line)
	if !bytes.HasPrefix(line, []byte("data:")) {
		return false
	}
	payload := bytes.TrimSpace(bytes.TrimPrefix(line, []byte("data:")))
	if len(payload) == 0 || bytes.Equal(payload, []byte("[DONE]")) {
		return false
	}

	var event map[string]json.RawMessage
	if err := json.Unmarshal(payload, &event); err != nil {
		return false
	}
	return eventHasContent(event)
}

func eventHasContent(event map[string]json.RawMessage) bool {
	for _, key := range []string{
		"content",
		"reasoning",
		"reasoning_content",
		"reasoning_details",
		"refusal",
		"text",
		"tool_calls",
		"function_call",
		"audio",
	} {
		if rawHasContent(event[key]) {
			return true
		}
	}
	for _, key := range []string{"choices", "output"} {
		var nested []map[string]json.RawMessage
		if err := json.Unmarshal(event[key], &nested); err == nil {
			for _, item := range nested {
				if eventHasContent(item) {
					return true
				}
			}
		}
	}
	for _, key := range []string{"delta", "message"} {
		var nested map[string]json.RawMessage
		if err := json.Unmarshal(event[key], &nested); err == nil && eventHasContent(nested) {
			return true
		}
	}
	return false
}

func rawHasContent(raw json.RawMessage) bool {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 ||
		bytes.Equal(raw, []byte("null")) ||
		bytes.Equal(raw, []byte(`""`)) ||
		bytes.Equal(raw, []byte("[]")) ||
		bytes.Equal(raw, []byte("{}")) {
		return false
	}
	if raw[0] != '"' {
		return true
	}
	var value string
	return json.Unmarshal(raw, &value) == nil && value != ""
}
