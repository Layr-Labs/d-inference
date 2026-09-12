package api

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Server) handleNonStreamingResponseWithFirstChunkAndError(
	w http.ResponseWriter,
	r *http.Request,
	pr *registry.PendingRequest,
	firstChunks []string,
	initialError *protocol.InferenceErrorMessage,
) {
	ctx, cancel := context.WithTimeout(r.Context(), inferenceTimeout)
	defer cancel()

	var chunks []string
	for _, firstChunk := range firstChunks {
		if firstChunk != "" {
			chunks = append(chunks, firstChunk)
		}
	}
	if initialError != nil {
		s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
		s.noteInferenceError(pr.ProviderID, pr, initialError.StatusCode, initialError.Error, initialError.ErrorReason, initialError.TerminalCause, initialError.CoordinatorCause)
		s.updateInferenceRouteOutcomeForPending(pr, preResponseProviderErrorOutcome(pr, *initialError))
		s.writeGenericProviderError(w, *initialError)
		return
	}

	for {
		select {
		case providerChunk, ok := <-pr.ChunkCh:
			if !ok {
				select {
				case errMsg, ok := <-pr.ErrorCh:
					if ok && errMsg.Error != "" {
						s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
						s.noteInferenceError(pr.ProviderID, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, errMsg.CoordinatorCause)
						s.updateInferenceRouteOutcomeForPending(pr, preResponseProviderErrorOutcome(pr, errMsg))
						s.writeGenericProviderError(w, errMsg)
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
							var completeUsage protocol.UsageInfo
							select {
							case u, ok := <-pr.CompleteCh:
								if !ok {
									s.refundReservedBalance(pr, "provider_incomplete:"+pr.RequestID)
									s.updateInferenceRouteOutcomeForPending(pr, preResponseProviderIncompleteOutcome(pr))
									writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "provider ended without completion"))
									return
								}
								completeUsage = u
							case <-ctx.Done():
								if errors.Is(ctx.Err(), context.DeadlineExceeded) {
									s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
									s.updateInferenceRouteOutcomeForPending(pr, preResponseTimeoutOutcome(pr, "usage_timeout_before_response"))
									writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "timed out waiting for usage info"))
								} else {
									s.refundReservedBalance(pr, "client_gone:"+pr.RequestID)
									s.updateInferenceRouteOutcomeForPending(pr, clientGoneBeforeResponseOutcome(pr))
								}
								return
							}
							if objType == "chat.completion" {
								normalizeCompleteChatResponse(obj, consumerModel(pr))
								// The provider engine reports "stop" even when generation
								// hit the max-tokens bound — correct it from the
								// authoritative token counts.
								rewriteRawFinishReason(obj, completeUsage, pr.RequestedMaxTokens)
								// Keep the passthrough path consistent with the
								// SSE-reconstruction path: surface the provider's
								// accurate reasoning-token count if its raw usage
								// object didn't already carry one.
								injectReasoningDetailIntoRawUsage(obj, completeUsage)
								injectCacheDetailIntoRawUsage(obj, completeUsage)
								if pr.ConsumerEndpoint == completionsEndpoint ||
									pr.ConsumerEndpoint == messagesEndpoint {
									encoded, err := json.Marshal(obj)
									if err != nil {
										writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "invalid provider response"))
										return
									}
									msg := extractMessage([]string{"data: " + string(encoded)})
									resp := buildGenericEndpointResponse(pr, msg, completeUsage)
									s.noteInferenceSuccess(pr)
									writeNonStreamBody(w, pr.Profile.Parent(), resp)
									return
								}
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
									respObj := chatCompletionToResponses(
										chatResp, consumerModel(pr), pr.SESignature,
										pr.ResponseHash, pr.Traits)
									s.noteInferenceSuccess(pr)
									writeNonStreamBody(w, pr.Profile.Parent(), respObj)
									return
								}
							} else {
								// Native passthrough (object=="response"): the provider
								// echoed the concrete build id; rewrite it to the public
								// alias so the consumer never sees the quant/build.
								sanitizeCacheDetailIntoRawResponsesUsage(obj, completeUsage)
								if pr.PublicModel != "" {
									obj["model"] = consumerModel(pr)
								}
							}
							if pr.SESignature != "" {
								obj["se_signature"] = pr.SESignature
								obj["response_hash"] = pr.ResponseHash
							}
							if isChatCompletionsConsumer(pr) {
								attachChatCompletionMetadata(obj, pr)
							}
							s.noteInferenceSuccess(pr)
							writeNonStreamBody(w, pr.Profile.Parent(), obj)
							return
						}
					}
				}

				// Only reconstructed chat-completions use provider-canonical
				// reasoning_content precedence. Responses and generic endpoints keep
				// the historical reasoning-first extraction contract.
				preferReasoningContent := !pr.IsResponsesAPI &&
					pr.ConsumerEndpoint != completionsEndpoint &&
					pr.ConsumerEndpoint != messagesEndpoint
				msg := extractMessageWithReasoningPolicy(chunks, preferReasoningContent)
				select {
				case usage, ok := <-pr.CompleteCh:
					if !ok {
						s.refundReservedBalance(pr, "provider_incomplete:"+pr.RequestID)
						s.updateInferenceRouteOutcomeForPending(pr, preResponseProviderIncompleteOutcome(pr))
						writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "provider ended without completion"))
						return
					}
					var resp any
					if pr.IsResponsesAPI {
						resp = buildResponsesResponse(
							pr.RequestID, consumerModel(pr), msg, usage,
							pr.RequestedMaxTokens, pr.SESignature, pr.ResponseHash,
							pr.Traits)
					} else if pr.ConsumerEndpoint == completionsEndpoint ||
						pr.ConsumerEndpoint == messagesEndpoint {
						resp = buildGenericEndpointResponse(pr, msg, usage)
					} else {
						chatResp := buildNonStreamingResponse(pr.RequestID, consumerModel(pr), msg, usage, pr.RequestedMaxTokens, pr.SESignature, pr.ResponseHash)
						applyChatCompletionMetadataToResponse(&chatResp, pr)
						resp = chatResp
					}
					s.noteInferenceSuccess(pr)
					writeNonStreamBody(w, pr.Profile.Parent(), resp)
				case <-ctx.Done():
					if errors.Is(ctx.Err(), context.DeadlineExceeded) {
						s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
						s.updateInferenceRouteOutcomeForPending(pr, preResponseTimeoutOutcome(pr, "usage_timeout_before_response"))
						writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "timed out waiting for usage info"))
					} else {
						s.refundReservedBalance(pr, "client_gone:"+pr.RequestID)
						s.updateInferenceRouteOutcomeForPending(pr, clientGoneBeforeResponseOutcome(pr))
					}
				}
				return
			}
			chunk := providerChunk.Data
			chunks = append(chunks, chunk)

		case errMsg, ok := <-pr.ErrorCh:
			if !ok {
				continue
			}
			s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
			s.noteInferenceError(pr.ProviderID, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, errMsg.CoordinatorCause)
			s.updateInferenceRouteOutcomeForPending(pr, preResponseProviderErrorOutcome(pr, errMsg))
			s.writeGenericProviderError(w, errMsg)
			return

		case <-ctx.Done():
			if errors.Is(ctx.Err(), context.DeadlineExceeded) {
				s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
				s.updateInferenceRouteOutcomeForPending(pr, preResponseTimeoutOutcome(pr, "response_timeout_before_response"))
				writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "request timed out"))
			} else {
				s.refundReservedBalance(pr, "client_gone:"+pr.RequestID)
				s.updateInferenceRouteOutcomeForPending(pr, clientGoneBeforeResponseOutcome(pr))
			}
			return
		}
	}
}
