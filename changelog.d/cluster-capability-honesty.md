### Two-Mac cluster capability honesty

- A cluster member registers image and video input only when its pair's placed mode serves media (GLM-5.3-Flash and Qwen3.8 27B in tensor parallel), so the coordinator no longer routes media to a pipeline pair that answers text only; a pair registered for media serves only while both Macs report the media contract.
- `darkbloom cluster status` and the pair's `/metrics` report MTP on for GLM-5.3-Flash in tensor parallel, which always decodes with its NextN head (depth 2); they said "MTP off".
- A content part of an unknown type (`input_file`, `input_video`, `refusal`, ...) is refused with HTTP 400 naming the type on the local API of one Mac and of a pair, and with the closed invalid-request error on coordinator requests, instead of being answered from the remaining text.
- With images or video, GLM-5.3-Flash refuses `reasoning.exclude`/`include_reasoning: false` and `response_format` JSON with the same fixed message on one Mac and on a pair, before any media decode.
- A `response_format` answer cut off by `max_tokens` (a reasoning model can think through the whole budget) now returns 422 saying so, instead of "Internal inference failure."
