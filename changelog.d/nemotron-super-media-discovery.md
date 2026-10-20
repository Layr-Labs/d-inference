### Nemotron Super media discovery guard

Staged Nemotron Super VL checkpoints no longer advertise media capability merely
because their configuration includes a vision tower. Native model support and
end-to-end qualification remain incomplete.

Add an unregistered native text binding with explicit LOAD recheck, bounded
calibrated prefill and request retirement ownership. Synthetic fixtures exercise
text and causal image installation through the real bridge, image cancellation
and retirement, plus live loopback HTTP authentication/SSE/restart. The image
owner binds the installation and separate media/KV reservations. Its CPU
decoder accepts PNG of every colour type and bit depth (byte-exact with the
reference loader) and baseline/progressive JPEG (ImageIO samples within
measured bounds), applies EXIF/XMP orientation as Pillow does, and bounds
declared geometry before allocation; the SDK resize is bitwise equal to CPU
PyTorch on the golden fixtures. Inline images use the `data:image/png;base64,`
or `data:image/jpeg;base64,` label; content selects the format. Image media
reservations include a derived tower and projector working-memory bound for the
largest image. An opt-in image HTTP hook uses existing auth, JSON/SSE framing
and cancellation; it is disabled by default. `DARKBLOOM_NEMOTRON_SUPER_MTP=1`
opts the local owner into greedy text speculation with the embedded MTP head
(default off; media is refused while it is on), verified by one exact captured
target window per round (`DARKBLOOM_NEMOTRON_SUPER_MTP_VERIFICATION=serial`
keeps one target step per draft). Synthetic fixtures show token-exact output and
exact rollback in both modes; full-model acceptance and speed are unmeasured.
Full-checkpoint quality, image formats other than PNG and JPEG and shared-slot
publication remain unqualified. Portable fixture harnesses preserve reproducible
continuation and require measured admission and reservation calibration before
enabling serving.

The opt-in Super owner hook now also serves text. Prompts match the reference
chat template and tokenizer byte for byte on a 30-case golden corpus (tool
schemas in request order, tool-call history, images with `<img>` placeholder
spans, reasoning on/off). Reasoning follows the reference `ultra_v3` parser:
`enable_thinking` defaults on and streams `reasoning_content`. Text requests
return validated `tool_calls` and validated `response_format` JSON. Image
requests still refuse tools and structured output; image prompts carry the
reference `<img>`/`</img>` span around each image's placeholders. A request
that arrives while the owner is busy gets 429 before any response starts, and
with speculation installed image requests run target-only beside speculating
text.
Each request's reservation now includes a decode row; a KV grant too small for
the configured requests fails the load with the minimum grant it needs. `DARKBLOOM_NEMOTRON_SUPER_MAX_CONCURRENT`
(default 1) opts the plain owner into row-exact batched text decode of up to
that many requests, and the speculative owner (rectangular verification) into
up to eight concurrent requests verified in one exact captured window per
round, each committing its own accepted prefix; serial verification stays one
request. `DARKBLOOM_NEMOTRON_SUPER_MTP_DEPTH=auto` lets the engine pick each
step's depth up to three. Synthetic fixtures show token-exact output against
solo plain decode. Prompts prefill in fixed chunks (`DARKBLOOM_NEMOTRON_SUPER_PREFILL_CHUNK`,
default 2048 tokens), at most one chunk per step beside every decode or verify
row, optionally with decode-only steps between chunks
(`DARKBLOOM_NEMOTRON_SUPER_DECODE_STEPS_BETWEEN_CHUNKS`); a request's chunks are
the same as when it is served alone. The prefill activation charge is one
owner-wide lane, reserved before the first request and held until retirement
(the pinned checkpoint charges the SDK's measured whole-chunk bound), instead
of a prefill workspace in every request's reservation.
`DARKBLOOM_PREFIX_CACHE_MEMORY=1` opts the owner into
exact text prefix reuse: a resident recurrent checkpoint bank sized from the KV
grant and the machine (half of what the grant leaves beside every request's
fixed bytes, the prefill lane and one image, and half of what the memory cap
leaves beside the load, at most a quarter of the grant and 16 GiB, none below
1 GiB: 16 GiB for a lone slot on 192 GB and up; or
`DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES`) whose budget is reserved from load until
retirement. The managed slot turns it on whenever that size is
non-zero. Checkpoints sit only at multiples
of the prefill chunk, where a restored request continues a cold prefill bit for
bit on synthetic fixtures; prompts shorter than one chunk restore nothing. On
the speculating owner a checkpoint also holds the assistant's prompt history, so
a restored request speculates exactly as a cold one. An image request reuses
only checkpoints bound to the same evaluated image features at the same
positions.
