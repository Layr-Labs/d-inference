package conformance

// This deliberately small observer is a caller-side chat SSE oracle. It does
// not use dispatch commit, HTTP 200, or the load test's TTFT as success evidence.
import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"
)

const orMaxBody = 256 << 10
const orMaxEvent = 16 << 10

type orUsage struct {
	Prompt     int `json:"prompt_tokens"`
	Completion int `json:"completion_tokens"`
	Total      int `json:"total_tokens"`
}

type orToolFunction struct {
	Name      string `json:"name"`
	Arguments string `json:"arguments"`
}
type orToolDelta struct {
	Index    *int           `json:"index"`
	ID       string         `json:"id"`
	Type     string         `json:"type"`
	Function orToolFunction `json:"function"`
}
type orObservedTool struct {
	Index                     int
	ID, Type, Name, Arguments string
}

type orObservation struct {
	Status       int              `json:"status"`
	RetryAfter   string           `json:"retry_after,omitempty"`
	HeadersNS    *int64           `json:"headers_ns"`
	FirstEventNS *int64           `json:"first_event_ns"`
	SemanticNS   *int64           `json:"semantic_ns"`
	TerminalNS   *int64           `json:"terminal_ns"`
	Terminal     string           `json:"terminal"`
	Events       int              `json:"events"`
	Done         int              `json:"done"`
	Finish       string           `json:"finish"`
	Usage        *orUsage         `json:"usage"`
	ID           string           `json:"-"`
	Model        string           `json:"model"`
	Created      int64            `json:"-"`
	Text         string           `json:"-"`
	Content      string           `json:"-"`
	Reasoning    string           `json:"-"`
	Tools        []orObservedTool `json:"-"`
	ToolError    string           `json:"tool_error,omitempty"`
}

func orStamp(start time.Time) *int64 { n := time.Since(start).Nanoseconds(); return &n }

// The body must support Close unblocking Read (net/http responses and io.Pipe
// do). Cancellation closes it without a detached reader goroutine. We still
// read to EOF after DONE, so trailing payload and read errors cannot pass.
func orObserve(ctx context.Context, resp *http.Response, start time.Time, headersNS *int64) (o orObservation, err error) {
	o.Status, o.RetryAfter = resp.StatusCode, resp.Header.Get("Retry-After")
	o.HeadersNS = headersNS
	o.Terminal = "invalid"
	stop := context.AfterFunc(ctx, func() { _ = resp.Body.Close() })
	defer stop()
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		o.Terminal = "http_error"
		return o, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	if !strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
		return o, errors.New("not SSE")
	}
	limit := &io.LimitedReader{R: resp.Body, N: orMaxBody + 1}
	reader := bufio.NewReader(limit)
	var data []string
	eventBytes := 0
	for {
		if ctx.Err() != nil {
			return o, ctx.Err()
		}
		line, readErr := reader.ReadString('\n')
		eventBytes += len(line)
		if limit.N <= 0 || eventBytes > orMaxEvent {
			return o, errors.New("stream size bound")
		}
		if readErr != nil {
			if !errors.Is(readErr, io.EOF) {
				return o, fmt.Errorf("read stream: %w", readErr)
			}
			if line != "" || eventBytes > 0 || len(data) > 0 {
				return o, errors.New("truncated event")
			}
			break
		}
		line = strings.TrimSuffix(strings.TrimSuffix(line, "\n"), "\r")
		if line == "" {
			if len(data) > 0 {
				if err = o.event(strings.Join(data, "\n"), start); err != nil {
					return o, err
				}
			}
			data = nil
			eventBytes = 0
		} else if strings.HasPrefix(line, "data:") {
			data = append(data, strings.TrimPrefix(strings.TrimPrefix(line, "data:"), " "))
		} else if strings.HasPrefix(line, ":") || strings.HasPrefix(line, "event:") || strings.HasPrefix(line, "id:") || strings.HasPrefix(line, "retry:") {
			// SSE transport fields have no semantic payload.
		} else {
			return o, errors.New("invalid SSE field")
		}
	}
	if ctx.Err() != nil {
		return o, ctx.Err()
	}
	if o.Terminal == "in_band_error" {
		return o, errors.New("in-band provider error")
	}
	if o.Done != 1 {
		return o, errors.New("missing DONE")
	}
	if o.Finish == "" {
		return o, errors.New("missing finish reason")
	}
	if o.SemanticNS == nil {
		return o, errors.New("no semantic output")
	}
	o.Terminal = "success"
	return o, nil
}

func (o *orObservation) event(data string, start time.Time) error {
	o.Events++
	if o.Events > 256 {
		return errors.New("event count bound")
	}
	if o.FirstEventNS == nil {
		o.FirstEventNS = orStamp(start)
	}
	if o.Done != 0 {
		return errors.New("event after DONE")
	}
	if data == "[DONE]" {
		o.Done++
		o.TerminalNS = orStamp(start)
		return nil
	}
	if !utf8.ValidString(data) {
		return errors.New("invalid UTF-8")
	}
	var ev struct {
		ID      string          `json:"id"`
		Object  string          `json:"object"`
		Created int64           `json:"created"`
		Model   string          `json:"model"`
		Error   json.RawMessage `json:"error"`
		Choices []struct {
			Index *int `json:"index"`
			Delta struct {
				Content          string        `json:"content"`
				Reasoning        string        `json:"reasoning"`
				ReasoningContent string        `json:"reasoning_content"`
				Refusal          string        `json:"refusal"`
				Tools            []orToolDelta `json:"tool_calls"`
			} `json:"delta"`
			Finish *string `json:"finish_reason"`
		} `json:"choices"`
		Usage *orUsage `json:"usage"`
	}
	if err := json.Unmarshal([]byte(data), &ev); err != nil {
		return fmt.Errorf("invalid JSON event: %w", err)
	}
	if len(ev.Error) > 0 && string(ev.Error) != "null" {
		o.Terminal = "in_band_error"
		o.TerminalNS = orStamp(start)
		return nil
	}
	if o.Terminal == "in_band_error" {
		return errors.New("payload after error")
	}
	if ev.ID == "" || ev.Model == "" || ev.Created <= 0 || ev.Object != "chat.completion.chunk" || ev.Choices == nil {
		return errors.New("invalid chat chunk shape")
	}
	if o.ID == "" {
		o.ID = ev.ID
		o.Model = ev.Model
		o.Created = ev.Created
	} else if o.ID != ev.ID || o.Model != ev.Model || o.Created != ev.Created {
		return errors.New("unstable stream identity")
	}
	if len(ev.Choices) > 1 {
		return errors.New("fixture expects at most one choice per event")
	}
	for _, c := range ev.Choices {
		if c.Index == nil || *c.Index != 0 {
			return errors.New("fixture expects choice zero")
		}
		text := c.Delta.Content + c.Delta.Reasoning + c.Delta.ReasoningContent + c.Delta.Refusal
		// Refusal text counts as delivered semantics, but never as a correct model answer.
		o.Content += c.Delta.Content + c.Delta.Refusal
		o.Reasoning += c.Delta.Reasoning + c.Delta.ReasoningContent
		for _, tool := range c.Delta.Tools {
			if o.Finish != "" {
				return errors.New("tool delta after finish")
			}
			if err := o.accumulateTool(tool); err != nil {
				return err
			}
			text += tool.Function.Name + tool.Function.Arguments
		}
		if text != "" {
			if o.Finish != "" {
				return errors.New("semantic output after finish")
			}
			if o.SemanticNS == nil {
				o.SemanticNS = orStamp(start)
			}
			o.Text += text
		}
		if c.Finish != nil && *c.Finish != "" {
			if o.Finish != "" {
				return errors.New("duplicate finish")
			}
			o.Finish = *c.Finish
		}
	}
	if ev.Usage != nil {
		if o.Usage != nil || ev.Usage.Prompt < 0 || ev.Usage.Completion < 0 || ev.Usage.Total != ev.Usage.Prompt+ev.Usage.Completion {
			return errors.New("invalid or duplicate usage")
		}
		o.Usage = ev.Usage
	}
	return nil
}

// Shape/identity faults are retained separately from generic transport validity:
// a task oracle must reject incomplete or inconsistent calls, while H0 can still
// observe legacy semantic deltas. Resource bounds always fail the transport.
func (o *orObservation) accumulateTool(d orToolDelta) error {
	problem := func(code string) {
		if o.ToolError == "" {
			o.ToolError = code
		}
	}
	if d.Index == nil {
		problem("missing_tool_index")
		return nil
	}
	if *d.Index < 0 || *d.Index >= 8 {
		problem("invalid_tool_index")
		return nil
	}
	if len(d.ID) > 256 || len(d.Type) > 32 {
		return errors.New("tool metadata bound")
	}
	var call *orObservedTool
	for i := range o.Tools {
		if o.Tools[i].Index == *d.Index {
			call = &o.Tools[i]
			break
		}
	}
	if call == nil {
		if len(o.Tools) >= 8 {
			return errors.New("tool count bound")
		}
		o.Tools = append(o.Tools, orObservedTool{Index: *d.Index})
		call = &o.Tools[len(o.Tools)-1]
	}
	if d.ID != "" {
		if call.ID != "" && call.ID != d.ID {
			problem("changed_call_id")
		}
		for _, other := range o.Tools {
			if other.Index != call.Index && other.ID == d.ID {
				problem("duplicate_call_id")
			}
		}
		call.ID = d.ID
	}
	if d.Type != "" {
		if call.Type != "" && call.Type != d.Type {
			problem("changed_tool_type")
		}
		call.Type = d.Type
	}
	call.Name += d.Function.Name
	call.Arguments += d.Function.Arguments
	if len(call.Name) > 256 || len(call.Arguments) > orMaxEvent {
		return errors.New("tool payload bound")
	}
	return nil
}
