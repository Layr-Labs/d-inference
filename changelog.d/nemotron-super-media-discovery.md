### Nemotron Super media discovery guard

Staged Nemotron Super VL checkpoints no longer advertise media capability merely
because their configuration includes a vision tower. Native model support and
end-to-end qualification remain incomplete.

Add an unregistered native text binding with explicit LOAD recheck, bounded
calibrated prefill and request retirement ownership. Synthetic fixtures exercise
text and causal image installation through the real bridge, image cancellation
and retirement, plus live loopback HTTP authentication/SSE/restart. The image
owner binds the installation and separate media/KV reservations. CPU RGB8 PNG
preprocessing rejects unqualified formats. An opt-in image HTTP hook uses existing auth, JSON/SSE framing and cancellation;
it is disabled by default. `DARKBLOOM_NEMOTRON_SUPER_MTP=1` opts the local owner into
greedy text speculation with the embedded MTP head (default off; media is refused
while it is on), verified by one exact captured target window per round
(`DARKBLOOM_NEMOTRON_SUPER_MTP_VERIFICATION=serial` keeps one target step per
draft). Synthetic fixtures show token-exact output and exact rollback in both
modes; full-model acceptance and speed are unmeasured. Full-checkpoint
quality, full image formats and shared-slot publication remain unqualified. Portable fixture
harnesses preserve reproducible continuation and require measured admission
and reservation calibration before enabling serving.

The opt-in Super owner hook now also serves text. Prompts match the reference
chat template and tokenizer byte for byte on a 30-case golden corpus (tool
schemas in request order, tool-call history, images with `<img>` placeholder
spans, reasoning on/off). Reasoning follows the reference `ultra_v3` parser:
`enable_thinking` defaults on and streams `reasoning_content`. Text requests
return validated `tool_calls` and validated `response_format` JSON. Image
requests still refuse tools and structured output; image prompts carry the
reference `<img>`/`</img>` span around each image's placeholders. A request
that arrives while the owner is busy gets 429 before any response starts, and
with speculation installed the hook serves text and refuses images with 400.
Each request's reservation now includes the calibrated prefill workspace.
