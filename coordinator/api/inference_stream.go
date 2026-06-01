package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// handleStreamingResponseWithFirstChunk streams SSE chunks to the consumer.
// If firstChunk is non-empty, it is written before reading further chunks
// from the channel. This allows the dispatch loop to "peek" at the first
// chunk for retry decisions without losing it.
func (s *Server) handleStreamingResponseWithFirstChunk(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest, firstChunk string) {
	if pr.IsResponsesAPI {
		s.handleResponsesStreamingResponseWithFirstChunk(w, r, pr, firstChunk)
		return
	}

	flusher, ok := w.(http.Flusher)
	if !ok {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "streaming not supported"))
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	// X-Request-ID is set by the logging middleware to the trace ID. The
	// internal pr.RequestID is the per-attempt provider job UUID and may
	// change across retries — exposing it as X-Request-ID would diverge
	// from the access log. Surface the provider job UUID under its own
	// header for callers who need to correlate to provider-side logs.
	w.Header().Set("X-Inference-Job-ID", pr.RequestID)
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	// Detect Responses API format to skip appending chat-completions-style
	// termination events (SE signature chunk + [DONE]).
	sawResponsesAPI := false

	// Write the first chunk that was already consumed during dispatch.
	if firstChunk != "" {
		if strings.Contains(firstChunk, `"response.created"`) || strings.Contains(firstChunk, `"response.output_text.delta"`) {
			sawResponsesAPI = true
		}
		if !sawResponsesAPI {
			firstChunk = normalizeSSEChunk(firstChunk)
		}
		fmt.Fprintf(w, "%s\n\n", firstChunk)
		flusher.Flush()
	}

	// Use a timer that resets on each chunk so long-running generations
	// (e.g. chain-of-thought models) don't hit a global timeout.
	timer := time.NewTimer(inferenceTimeout)
	defer timer.Stop()

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if !ok {
				select {
				case errMsg, ok := <-pr.ErrorCh:
					if ok && errMsg.Error != "" {
						s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
						errData, _ := json.Marshal(map[string]any{
							"error": map[string]any{
								"message": errMsg.Error,
								"type":    "provider_error",
							},
						})
						fmt.Fprintf(w, "data: %s\n\n", errData)
						flusher.Flush()
						return
					}
				default:
				}
				if s.refundReservedBalance(pr, "provider_incomplete:"+pr.RequestID) {
					fmt.Fprintf(w, "data: {\"error\":{\"message\":\"provider ended without completion\",\"type\":\"provider_error\"}}\n\n")
					flusher.Flush()
					return
				}
				// Channel closed — inference complete.
				// For Responses API streams, the provider already sent
				// "response.completed" as the terminal event. Adding
				// extra chunks would break SDK parsers.
				if !sawResponsesAPI {
					// Chat completions format: append SE signature + [DONE].
					if pr.SESignature != "" {
						sigEvent, _ := json.Marshal(map[string]any{
							"choices":       []any{},
							"se_signature":  pr.SESignature,
							"response_hash": pr.ResponseHash,
						})
						fmt.Fprintf(w, "data: %s\n\n", sigEvent)
						flusher.Flush()
					}
					fmt.Fprint(w, "data: [DONE]\n\n")
					flusher.Flush()
				}
				return
			}
			if !sawResponsesAPI {
				if strings.Contains(chunk, `"response.created"`) || strings.Contains(chunk, `"response.output_text.delta"`) {
					sawResponsesAPI = true
				}
			}
			if !sawResponsesAPI {
				chunk = normalizeSSEChunk(chunk)
			}
			fmt.Fprintf(w, "%s\n\n", chunk)
			flusher.Flush()

			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(inferenceTimeout)

		case errMsg, ok := <-pr.ErrorCh:
			if !ok {
				continue
			}
			s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
			errData, _ := json.Marshal(map[string]any{
				"error": map[string]any{
					"message": errMsg.Error,
					"type":    "provider_error",
				},
			})
			fmt.Fprintf(w, "data: %s\n\n", errData)
			flusher.Flush()
			return

		case <-timer.C:
			s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
			fmt.Fprintf(w, "data: {\"error\":{\"message\":\"request timed out\",\"type\":\"timeout\"}}\n\n")
			flusher.Flush()
			return

		case <-r.Context().Done():
			return
		}
	}
}

func writeResponsesSSE(w http.ResponseWriter, flusher http.Flusher, event map[string]any) {
	data, err := json.Marshal(event)
	if err != nil {
		return
	}
	fmt.Fprintf(w, "data: %s\n\n", data)
	flusher.Flush()
}

func (s *Server) handleResponsesStreamingResponseWithFirstChunk(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest, firstChunk string) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "streaming not supported"))
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Inference-Job-ID", pr.RequestID)
	w.WriteHeader(http.StatusOK)

	responseID := "resp_" + strings.ReplaceAll(pr.RequestID, "-", "")
	createdAt := time.Now().Unix()
	writeResponsesSSE(w, flusher, map[string]any{
		"type": "response.created",
		"response": map[string]any{
			"id":           responseID,
			"created_at":   createdAt,
			"model":        pr.Model,
			"service_tier": nil,
		},
	})

	chunks := make([]string, 0, 16)
	if firstChunk != "" {
		chunks = append(chunks, firstChunk)
	}

	timer := time.NewTimer(inferenceTimeout)
	defer timer.Stop()

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if !ok {
				var usage protocol.UsageInfo
				completed := false
				select {
				case u, ok := <-pr.CompleteCh:
					if ok {
						usage = u
						completed = true
					}
				default:
				}
				if !completed && s.refundReservedBalance(pr, "provider_incomplete:"+pr.RequestID) {
					writeResponsesSSE(w, flusher, map[string]any{
						"type":            "error",
						"sequence_number": 0,
						"error": map[string]any{
							"type":    "provider_error",
							"code":    "provider_error",
							"message": "provider ended without completion",
							"param":   nil,
						},
					})
					return
				}
				msg := extractMessage(chunks)
				writeResponsesStreamOutput(w, flusher, pr, responseID, createdAt, msg, usage)
				return
			}
			chunks = append(chunks, chunk)
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(inferenceTimeout)

		case errMsg, ok := <-pr.ErrorCh:
			if !ok {
				continue
			}
			s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
			writeResponsesSSE(w, flusher, map[string]any{
				"type":            "error",
				"sequence_number": 0,
				"error": map[string]any{
					"type":    "provider_error",
					"code":    "provider_error",
					"message": errMsg.Error,
					"param":   nil,
				},
			})
			return

		case <-timer.C:
			s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
			writeResponsesSSE(w, flusher, map[string]any{
				"type":            "error",
				"sequence_number": 0,
				"error": map[string]any{
					"type":    "timeout",
					"code":    "timeout",
					"message": "request timed out",
					"param":   nil,
				},
			})
			return

		case <-r.Context().Done():
			return
		}
	}
}

func writeResponsesStreamOutput(w http.ResponseWriter, flusher http.Flusher, pr *registry.PendingRequest, responseID string, createdAt int64, msg extractedMessage, usage protocol.UsageInfo) {
	outputIndex := 0
	if msg.Reasoning != "" {
		itemID := responseItemID("rs", pr.RequestID, outputIndex)
		writeResponsesSSE(w, flusher, map[string]any{
			"type":         "response.output_item.added",
			"output_index": outputIndex,
			"item": map[string]any{
				"type":              "reasoning",
				"id":                itemID,
				"encrypted_content": nil,
			},
		})
		writeResponsesSSE(w, flusher, map[string]any{
			"type":          "response.reasoning_summary_part.added",
			"item_id":       itemID,
			"summary_index": 0,
		})
		writeResponsesSSE(w, flusher, map[string]any{
			"type":          "response.reasoning_summary_text.delta",
			"item_id":       itemID,
			"summary_index": 0,
			"delta":         msg.Reasoning,
		})
		writeResponsesSSE(w, flusher, map[string]any{
			"type":          "response.reasoning_summary_part.done",
			"item_id":       itemID,
			"summary_index": 0,
		})
		writeResponsesSSE(w, flusher, map[string]any{
			"type":         "response.output_item.done",
			"output_index": outputIndex,
			"item": map[string]any{
				"type":              "reasoning",
				"id":                itemID,
				"encrypted_content": nil,
			},
		})
		outputIndex++
	}

	if msg.Content != "" || len(msg.ToolCalls) == 0 {
		itemID := responseItemID("msg", pr.RequestID, outputIndex)
		writeResponsesSSE(w, flusher, map[string]any{
			"type":         "response.output_item.added",
			"output_index": outputIndex,
			"item": map[string]any{
				"type":  "message",
				"id":    itemID,
				"phase": nil,
			},
		})
		if msg.Content != "" {
			writeResponsesSSE(w, flusher, map[string]any{
				"type":         "response.output_text.delta",
				"item_id":      itemID,
				"output_index": outputIndex,
				"delta":        msg.Content,
			})
		}
		writeResponsesSSE(w, flusher, map[string]any{
			"type":         "response.output_item.done",
			"output_index": outputIndex,
			"item": map[string]any{
				"type":  "message",
				"id":    itemID,
				"phase": nil,
			},
		})
		outputIndex++
	}

	for _, tc := range msg.ToolCalls {
		fn, _ := tc["function"].(map[string]any)
		callID, _ := tc["id"].(string)
		if callID == "" {
			callID = responseItemID("call", pr.RequestID, outputIndex)
		}
		name, _ := fn["name"].(string)
		args, _ := fn["arguments"].(string)
		itemID := responseItemID("fc", pr.RequestID, outputIndex)
		writeResponsesSSE(w, flusher, map[string]any{
			"type":         "response.output_item.added",
			"output_index": outputIndex,
			"item": map[string]any{
				"type":      "function_call",
				"id":        itemID,
				"call_id":   callID,
				"name":      name,
				"arguments": "",
			},
		})
		if args != "" {
			writeResponsesSSE(w, flusher, map[string]any{
				"type":         "response.function_call_arguments.delta",
				"item_id":      itemID,
				"output_index": outputIndex,
				"delta":        args,
			})
		}
		writeResponsesSSE(w, flusher, map[string]any{
			"type":         "response.output_item.done",
			"output_index": outputIndex,
			"item": map[string]any{
				"type":      "function_call",
				"id":        itemID,
				"call_id":   callID,
				"name":      name,
				"arguments": args,
				"status":    "completed",
			},
		})
		outputIndex++
	}

	reasoningTokens := uint64(0)
	if msg.Reasoning != "" {
		reasoningTokens = uint64(usage.CompletionTokens)
	}
	writeResponsesSSE(w, flusher, map[string]any{
		"type": "response.completed",
		"response": map[string]any{
			"id":                 responseID,
			"created_at":         createdAt,
			"model":              pr.Model,
			"incomplete_details": nil,
			"usage":              buildResponsesUsage(uint64(usage.PromptTokens), uint64(usage.CompletionTokens), reasoningTokens),
			"service_tier":       nil,
		},
	})
}
