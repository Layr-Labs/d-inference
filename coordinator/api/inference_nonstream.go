package api

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/registry"

	"github.com/eigeninference/d-inference/coordinator/api/types"
)

// handleNonStreamingResponseWithFirstChunk collects all chunks from the
// provider and assembles them into a single OpenAI-compatible JSON response.
// If firstChunk is non-empty, it is prepended to the collected chunks.
func (s *Server) handleNonStreamingResponseWithFirstChunk(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest, firstChunk string) {
	ctx, cancel := context.WithTimeout(r.Context(), inferenceTimeout)
	defer cancel()

	var chunks []string
	if firstChunk != "" {
		chunks = append(chunks, firstChunk)
	}

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if !ok {
				select {
				case errMsg, ok := <-pr.ErrorCh:
					if ok && errMsg.Error != "" {
						s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
						statusCode := errMsg.StatusCode
						if statusCode == 0 {
							statusCode = http.StatusBadGateway
						}
						writeJSON(w, statusCode, errorResponse("provider_error", errMsg.Error))
						return
					}
				default:
				}
				// The provider forwards the raw backend response as a single
				// chunk. Detect complete responses (object=chat.completion
				// or object=response) and pass through directly — this is
				// format-agnostic and works for chat completions, Responses
				// API, or any future endpoint without parsing.
				if len(chunks) == 1 {
					raw := strings.TrimPrefix(chunks[0], "data: ")
					var obj map[string]any
					if err := json.Unmarshal([]byte(raw), &obj); err == nil {
						objType, _ := obj["object"].(string)
						// Complete responses have object=chat.completion or
						// object=response. Delta chunks have object=chat.completion.chunk.
						if objType == "chat.completion" || objType == "response" {
							select {
							case _, ok := <-pr.CompleteCh:
								if !ok {
									s.refundReservedBalance(pr, "provider_incomplete:"+pr.RequestID)
									writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "provider ended without completion"))
									return
								}
							case <-ctx.Done():
								s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
								writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "timed out waiting for usage info"))
								return
							}
							if objType == "chat.completion" {
								normalizeCompleteChatResponse(obj, pr.Model)
								if pr.IsResponsesAPI {
									var chatResp types.ChatCompletionResponse
									b, err := json.Marshal(obj)
									if err != nil {
										log.Printf("WARN: failed to marshal chat response for Responses API conversion: %v", err)
										writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "invalid provider response"))
										return
									}
									if err := json.Unmarshal(b, &chatResp); err != nil {
										log.Printf("WARN: failed to unmarshal chat response into typed struct: %v", err)
										writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "invalid provider response"))
										return
									}
									respObj := chatCompletionToResponses(chatResp, pr.Model, pr.SESignature, pr.ResponseHash)
									writeJSON(w, http.StatusOK, respObj)
									return
								}
							}
							if pr.SESignature != "" {
								obj["se_signature"] = pr.SESignature
								obj["response_hash"] = pr.ResponseHash
							}
							writeJSON(w, http.StatusOK, obj)
							return
						}
					}
				}

				// Fallback: SSE delta chunks — reconstruct into response.
				msg := extractMessage(chunks)
				select {
				case usage, ok := <-pr.CompleteCh:
					if !ok {
						s.refundReservedBalance(pr, "provider_incomplete:"+pr.RequestID)
						writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "provider ended without completion"))
						return
					}
					var resp any
					if pr.IsResponsesAPI {
						resp = buildResponsesResponse(pr.RequestID, pr.Model, msg, usage, pr.SESignature, pr.ResponseHash)
					} else {
						resp = buildNonStreamingResponse(pr.RequestID, pr.Model, msg, usage, pr.SESignature, pr.ResponseHash)
					}
					writeJSON(w, http.StatusOK, resp)
				case <-ctx.Done():
					s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
					writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "timed out waiting for usage info"))
				}
				return
			}
			chunks = append(chunks, chunk)

		case errMsg, ok := <-pr.ErrorCh:
			if !ok {
				continue
			}
			s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
			statusCode := errMsg.StatusCode
			if statusCode == 0 {
				statusCode = http.StatusBadGateway
			}
			writeJSON(w, statusCode, errorResponse("provider_error", errMsg.Error))
			return

		case <-ctx.Done():
			s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
			writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "request timed out"))
			return
		}
	}
}
