package response

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"log"
	"net/http"
	"strings"
)

func (s *Writer) NonStream(
	w http.ResponseWriter,
	r *http.Request,
	pr *registry.PendingRequest,
	firstChunks []string,
	initialError *protocol.InferenceErrorMessage,
) {
	ctx, cancel := context.WithTimeout(r.Context(), InferenceTimeout)
	defer cancel()

	var chunks []string
	for _, firstChunk := range firstChunks {
		if firstChunk != "" {
			chunks = append(chunks, firstChunk)
		}
	}
	if initialError != nil {
		s.deps.Reservation.Refund(pr, "provider_error:"+pr.RequestID)
		s.deps.Feedback.Error(pr.ProviderID, pr, initialError.StatusCode, initialError.Error, initialError.ErrorReason, initialError.TerminalCause, initialError.CoordinatorCause)
		s.deps.Outcomes.ProviderError(pr, *initialError, false)
		s.deps.Errors.WriteProviderError(w, *initialError)
		return
	}

	for {
		select {
		case providerChunk, ok := <-pr.ChunkCh:
			if !ok {
				select {
				case errMsg, ok := <-pr.ErrorCh:
					if ok && errMsg.Error != "" {
						s.deps.Reservation.Refund(pr, "provider_error:"+pr.RequestID)
						s.deps.Feedback.Error(pr.ProviderID, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, errMsg.CoordinatorCause)
						s.deps.Outcomes.ProviderError(pr, errMsg, false)
						s.deps.Errors.WriteProviderError(w, errMsg)
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
							completeUsage, ok := s.awaitNonStreamUsage(ctx, w, pr)
							if !ok {
								return
							}
							if objType == "chat.completion" {
								normalizeCompleteChatResponse(obj, ConsumerModel(pr))
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
								if pr.ConsumerEndpoint == CompletionsEndpoint ||
									pr.ConsumerEndpoint == MessagesEndpoint {
									encoded, err := json.Marshal(obj)
									if err != nil {
										httpresponse.WriteJSON(w, http.StatusBadGateway, httpresponse.ErrorBody("provider_error", "invalid provider response"))
										return
									}
									msg := extractMessage([]string{"data: " + string(encoded)})
									resp := buildGenericEndpointResponse(pr, msg, completeUsage)
									s.deps.Feedback.Success(pr)
									s.Body(w, pr.Profile.Parent(), resp)
									return
								}
								if pr.IsResponsesAPI {
									var chatResp types.ChatCompletionResponse
									b, err := json.Marshal(obj)
									if err != nil {
										log.Printf("WARN: failed to marshal chat response for Responses API conversion: %v", err)
										httpresponse.WriteJSON(w, http.StatusBadGateway, httpresponse.ErrorBody("provider_error", "invalid provider response"))
										return
									}
									if err := json.Unmarshal(b, &chatResp); err != nil {
										log.Printf("WARN: failed to unmarshal chat response into typed struct: %v", err)
										httpresponse.WriteJSON(w, http.StatusBadGateway, httpresponse.ErrorBody("provider_error", "invalid provider response"))
										return
									}
									respObj := chatCompletionToResponses(
										chatResp, ConsumerModel(pr), pr.SESignature,
										pr.ResponseHash, pr.Traits)
									s.deps.Feedback.Success(pr)
									s.Body(w, pr.Profile.Parent(), respObj)
									return
								}
							} else {
								// Native passthrough (object=="response"): the provider
								// echoed the concrete build id; rewrite it to the public
								// alias so the consumer never sees the quant/build.
								sanitizeCacheDetailIntoRawResponsesUsage(obj, completeUsage)
								if pr.PublicModel != "" {
									obj["model"] = ConsumerModel(pr)
								}
							}
							if pr.SESignature != "" {
								obj["se_signature"] = pr.SESignature
								obj["response_hash"] = pr.ResponseHash
							}
							if isChatCompletionsConsumer(pr) {
								attachChatCompletionMetadata(obj, pr)
							}
							s.deps.Feedback.Success(pr)
							s.Body(w, pr.Profile.Parent(), obj)
							return
						}
					}
				}

				// Only reconstructed chat-completions use provider-canonical
				// reasoning_content precedence. Responses and generic endpoints keep
				// the historical reasoning-first extraction contract.
				preferReasoningContent := !pr.IsResponsesAPI &&
					pr.ConsumerEndpoint != CompletionsEndpoint &&
					pr.ConsumerEndpoint != MessagesEndpoint
				msg := extractMessageWithReasoningPolicy(chunks, preferReasoningContent)
				usage, ok := s.awaitNonStreamUsage(ctx, w, pr)
				if !ok {
					return
				}
				var resp any
				if pr.IsResponsesAPI {
					resp = buildResponsesResponse(
						pr.RequestID, ConsumerModel(pr), msg, usage,
						pr.RequestedMaxTokens, pr.SESignature, pr.ResponseHash,
						pr.Traits)
				} else if pr.ConsumerEndpoint == CompletionsEndpoint ||
					pr.ConsumerEndpoint == MessagesEndpoint {
					resp = buildGenericEndpointResponse(pr, msg, usage)
				} else {
					chatResp := buildNonStreamingResponse(pr.RequestID, ConsumerModel(pr), msg, usage, pr.RequestedMaxTokens, pr.SESignature, pr.ResponseHash)
					applyChatCompletionMetadataToResponse(&chatResp, pr)
					resp = chatResp
				}
				s.deps.Feedback.Success(pr)
				s.Body(w, pr.Profile.Parent(), resp)
				return
			}
			chunk := providerChunk.Data
			chunks = append(chunks, chunk)

		case errMsg, ok := <-pr.ErrorCh:
			if !ok {
				continue
			}
			s.deps.Reservation.Refund(pr, "provider_error:"+pr.RequestID)
			s.deps.Feedback.Error(pr.ProviderID, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, errMsg.CoordinatorCause)
			s.deps.Outcomes.ProviderError(pr, errMsg, false)
			s.deps.Errors.WriteProviderError(w, errMsg)
			return

		case <-ctx.Done():
			if errors.Is(ctx.Err(), context.DeadlineExceeded) {
				s.deps.Reservation.Refund(pr, "provider_timeout:"+pr.RequestID)
				s.deps.Outcomes.Timeout(pr, false, "response_timeout_before_response")
				httpresponse.WriteJSON(w, http.StatusGatewayTimeout, httpresponse.ErrorBody("timeout", "request timed out"))
			} else {
				s.deps.Reservation.Refund(pr, "client_gone:"+pr.RequestID)
				s.deps.Outcomes.ClientGone(pr)
			}
			return
		}
	}
}

// awaitNonStreamUsage applies the shared completion contract after raw-body
// detection or delta reconstruction. A body alone cannot establish completion.
func (s *Writer) awaitNonStreamUsage(ctx context.Context, w http.ResponseWriter, pr *registry.PendingRequest) (protocol.UsageInfo, bool) {
	select {
	case usage, ok := <-pr.CompleteCh:
		if ok {
			return usage, true
		}
		s.deps.Reservation.Refund(pr, "provider_incomplete:"+pr.RequestID)
		s.deps.Outcomes.Incomplete(pr, false)
		httpresponse.WriteJSON(w, http.StatusBadGateway, httpresponse.ErrorBody("provider_error", "provider ended without completion"))
	case <-ctx.Done():
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			s.deps.Reservation.Refund(pr, "provider_timeout:"+pr.RequestID)
			s.deps.Outcomes.Timeout(pr, false, "usage_timeout_before_response")
			httpresponse.WriteJSON(w, http.StatusGatewayTimeout, httpresponse.ErrorBody("timeout", "timed out waiting for usage info"))
		} else {
			s.deps.Reservation.Refund(pr, "client_gone:"+pr.RequestID)
			s.deps.Outcomes.ClientGone(pr)
		}
	}
	return protocol.UsageInfo{}, false
}
