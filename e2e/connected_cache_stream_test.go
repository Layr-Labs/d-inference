package e2e

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// HTTP deliberately exposes content/tool deltas rather than raw model IDs.
// Keep the SSE bytes, counts, finish and monotonic timings as that evidence.
type connectedStream struct {
	HTTPStatus        int                   `json:"http_status"`
	ProviderID        string                `json:"provider_id"`
	RawSSE            string                `json:"raw_sse"`
	Reasoning         string                `json:"reasoning"`
	Content           string                `json:"content"`
	Tools             map[int]connectedTool `json:"tools,omitempty"`
	Finish            string                `json:"finish_reason"`
	Usage             json.RawMessage       `json:"usage,omitempty"`
	FirstContentMS    float64               `json:"first_content_ms"`
	TotalMS           float64               `json:"total_ms"`
	Done              bool                  `json:"done"`
	CancelledByClient bool                  `json:"cancelled_by_client"`
}
type connectedTool struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Arguments string `json:"arguments"`
}

func (out *connectedStream) acceptSSE(line []byte) (bool, error) {
	if !bytes.HasPrefix(line, []byte("data:")) {
		return false, nil
	}
	data := bytes.TrimSpace(bytes.TrimPrefix(line, []byte("data:")))
	if bytes.Equal(data, []byte("[DONE]")) {
		out.Done = true
		return false, nil
	}
	var event struct {
		Error   json.RawMessage `json:"error"`
		Choices []struct {
			Delta struct {
				Content          string  `json:"content"`
				ReasoningContent *string `json:"reasoning_content"`
				Reasoning        *string `json:"reasoning"`
				ToolCalls        []struct {
					Index    int    `json:"index"`
					ID       string `json:"id"`
					Function struct {
						Name      string `json:"name"`
						Arguments string `json:"arguments"`
					} `json:"function"`
				} `json:"tool_calls"`
			} `json:"delta"`
			Finish *string `json:"finish_reason"`
		} `json:"choices"`
		Usage json.RawMessage `json:"usage"`
	}
	if err := json.Unmarshal(data, &event); err != nil {
		return false, err
	}
	if len(event.Error) > 0 && string(event.Error) != "null" {
		return false, fmt.Errorf("SSE error received")
	}
	if len(event.Usage) > 0 && string(event.Usage) != "null" {
		out.Usage = event.Usage
	}
	content := false
	for _, c := range event.Choices {
		// The coordinator emits compatibility aliases for the same delta.
		// Append it once so reasoning is independent of chunk boundaries.
		reasoning := c.Delta.ReasoningContent
		if reasoning == nil {
			reasoning = c.Delta.Reasoning
		} else if c.Delta.Reasoning != nil && *reasoning != *c.Delta.Reasoning {
			return false, fmt.Errorf("conflicting SSE reasoning aliases")
		}
		if reasoning != nil {
			out.Reasoning += *reasoning
			content = content || *reasoning != ""
		}
		out.Content += c.Delta.Content
		content = content || c.Delta.Content != ""
		if c.Finish != nil {
			out.Finish = *c.Finish
		}
		for _, tc := range c.Delta.ToolCalls {
			content = true
			if out.Tools == nil {
				out.Tools = map[int]connectedTool{}
			}
			tool := out.Tools[tc.Index]
			tool.ID += tc.ID
			tool.Name += tc.Function.Name
			tool.Arguments += tc.Function.Arguments
			out.Tools[tc.Index] = tool
		}
	}
	return content, nil
}

func postConnectedStream(ctx context.Context, url, apiKey string, body []byte, cancelAfterContent bool) (out connectedStream, err error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	start := time.Now()
	defer func() { out.TotalMS = float64(time.Since(start)) / float64(time.Millisecond) }()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		return out, err
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return out, err
	}
	defer resp.Body.Close()
	out.HTTPStatus = resp.StatusCode
	out.ProviderID = resp.Header.Get("X-Provider-Id")
	reader := bufio.NewReaderSize(io.LimitReader(resp.Body, (8<<20)+1), 64<<10)
	var raw bytes.Buffer
	for {
		line, readErr := reader.ReadBytes('\n')
		raw.Write(line)
		out.RawSSE = raw.String()
		if raw.Len() > 8<<20 {
			return out, fmt.Errorf("SSE evidence exceeds bounded 8 MiB")
		}
		if resp.StatusCode != http.StatusOK {
			if readErr != nil {
				return out, fmt.Errorf("HTTP status %d", resp.StatusCode)
			}
			continue
		}
		content, parseErr := out.acceptSSE(line)
		if parseErr != nil {
			return out, parseErr
		}
		if content && out.FirstContentMS == 0 {
			out.FirstContentMS = float64(time.Since(start)) / float64(time.Millisecond)
		}
		if content && cancelAfterContent && out.Finish == "" && !out.Done {
			out.CancelledByClient = true
			cancel()
			return out, nil
		}
		if readErr != nil {
			if readErr != io.EOF {
				return out, readErr
			}
			break
		}
	}
	if !out.Done || out.Finish == "" {
		return out, fmt.Errorf("stream ended without finish and DONE")
	}
	return out, nil
}
