"""Pydantic models matching the OpenAI response format.

These types mirror the OpenAI API response schema so that DGInf responses
can be used interchangeably with OpenAI client responses. Additional fields
(provider_attested, provider_trust_level) carry DGInf-specific attestation
metadata that the OpenAI API does not provide.

All models use Pydantic v2 for validation and serialization.
"""

from __future__ import annotations

from pydantic import BaseModel, Field


# ── Chat messages ───────────────────────────────────────────────────────────

class ChatMessage(BaseModel):
    """A complete chat message with role and content.

    Used in non-streaming responses where the full message is available.
    """
    role: str
    content: str | None = None


class DeltaMessage(BaseModel):
    """Partial message used in streaming chunks.

    In streaming mode, each chunk contains a delta with only the new
    content since the last chunk. The role is only present in the first
    chunk; subsequent chunks only have content.
    """

    role: str | None = None
    content: str | None = None


# ── Choices ─────────────────────────────────────────────────────────────────

class Choice(BaseModel):
    """A single completion choice in a non-streaming response.

    The finish_reason indicates why generation stopped: "stop" for natural
    completion, "length" for max_tokens reached, etc.
    """
    index: int
    message: ChatMessage
    finish_reason: str | None = None


class StreamChoice(BaseModel):
    """A single completion choice in a streaming chunk.

    Contains a delta (partial message) rather than a complete message.
    The finish_reason is None for intermediate chunks and set on the
    final chunk (typically "stop").
    """
    index: int
    delta: DeltaMessage
    finish_reason: str | None = None


# ── Usage ───────────────────────────────────────────────────────────────────

class Usage(BaseModel):
    """Token usage statistics for a completed inference request.

    Used for billing calculations. The coordinator charges based on
    completion_tokens (output tokens) at the configured per-model rate.
    """
    prompt_tokens: int
    completion_tokens: int
    total_tokens: int


# ── Chat completion (non-streaming) ────────────────────────────────────────

class ChatCompletion(BaseModel):
    """Complete chat completion response (non-streaming).

    Mirrors the OpenAI ChatCompletion response format with additional
    DGInf-specific fields for provider attestation status.

    The provider_attested and provider_trust_level fields are populated
    from HTTP response headers set by the coordinator, giving consumers
    visibility into the security properties of the provider that served
    their request.
    """
    id: str
    object: str = "chat.completion"
    created: int
    model: str
    choices: list[Choice]
    usage: Usage | None = None
    # DGInf attestation fields (populated from response headers, not present in body)
    provider_attested: bool | None = None
    provider_trust_level: str | None = None


# ── Chat completion chunk (streaming) ──────────────────────────────────────

class ChatCompletionChunk(BaseModel):
    """A single chunk in a streaming chat completion response.

    Streaming responses consist of a sequence of these chunks, each
    containing a partial delta. The stream terminates with a "[DONE]"
    SSE sentinel (not represented as a chunk object).
    """
    id: str
    object: str = "chat.completion.chunk"
    created: int
    model: str
    choices: list[StreamChoice]


# ── Models ──────────────────────────────────────────────────────────────────

class ModelMetadata(BaseModel):
    """Extended metadata for models including trust and attestation info.

    This metadata is DGInf-specific and not present in OpenAI's API.
    It helps consumers understand the security properties of the providers
    serving each model.

    Attributes:
        model_type: Architecture type (e.g., "qwen2", "llama").
        quantization: Quantization level (e.g., "4bit", "8bit", "bf16").
        provider_count: Number of providers currently serving this model.
        attested_providers: Number of providers with verified attestations.
        trust_level: Highest trust level among providers for this model
            ("none", "self_signed", or "hardware").
    """

    model_type: str | None = None
    quantization: str | None = None
    provider_count: int | None = None
    attested_providers: int | None = None
    trust_level: str | None = None


class Model(BaseModel):
    """A single model entry in the models listing.

    Mirrors the OpenAI Model object format with an additional metadata
    field for DGInf-specific attestation information.
    """
    id: str
    object: str = "model"
    created: int = 0
    owned_by: str = ""
    metadata: ModelMetadata | None = None


class ModelList(BaseModel):
    """Response from the /v1/models endpoint.

    Contains a list of all models available across connected providers.
    """
    object: str = "list"
    data: list[Model] = Field(default_factory=list)
