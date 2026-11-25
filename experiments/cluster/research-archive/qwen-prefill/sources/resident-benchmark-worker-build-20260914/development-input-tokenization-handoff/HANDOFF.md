# Development inputs prepared

Created ten distinct, fixed 8192-token development prompts in
`prefill-development-inputs-20260914`. Each subdirectory retains its complete
source text, bounded `prompt-8192.json`, and decoded prefix. `prompt-rows.json`
provides the exact `id`, `prompt_sha256`, and common `origin_sha256` rows for the
paired-study specification. No qualification workload was changed.

Execution: 2026-09-15T02:55:48.463048+00:00 to 2026-09-15T02:55:49.338678+00:00;
exit 0 in 0.875 seconds, empty stderr. Python 3.12.13 and
`tokenizers==0.22.2` were used through the explicitly supplied interpreter.
No MLX or vLLM module was imported; no model, compiler, SSH, or native request ran.
The old retained diagnostic's 8192 IDs and serialized token file reproduced
byte-for-byte before the new prompts were encoded.

The failed original assertion confused tokenizer entries with model capacity.
The pinned tokenizer has 248044 base entries, 248077 including added tokens,
and token IDs 0 through 248076. The native model token-ID upper bound remains
248320. These quantities are recorded separately; tokenizer SHA
`87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4` is unchanged. The actual interpreter SHA is
`01564940172b2811e1f39a4dc90e84c7a26a19cf071bbc5de67e456d82627bec`. Original script bytes and the focused correction
patch are retained here; frozen source recipes were not edited.

| Input | Full-source token count | Retained count |
| --- | ---: | ---: |
| dev01-module-trees | 37112 | 8192 |
| dev02-training-updates | 27185 | 8192 |
| dev03-function-transforms | 48831 | 8192 |
| dev04-compile-export | 44336 | 8192 |
| dev05-spatial-shapes | 32695 | 8192 |
| dev06-randomness-init | 31567 | 8192 |
| dev07-tensor-algebra | 46811 | 8192 |
| dev08-indexing-semantics | 54936 | 8192 |
| dev09-quantized-contracts | 49485 | 8192 |
| dev10-extension-lifetimes | 30216 | 8192 |

All ten raw token files and token sequences are distinct. Files are
35,871–36,990 bytes,
below the 65536-byte input cap; the highest selected ID is
243343. All 34 listed output members were rehashed,
with exact source/prompt/recipe joins. Files are mode 0600 under a mode-0700
destination. Complete source files are retained separately; a decoded prefix
may end inside the final excerpt. All ten prefixes include the full MIT notice.

Key receipts:

- `tokenization.json`: `6f59254c4b28a1021d788f1ad02999488458219cfe73b79c3a4773bb5c2f03f9`
- `prompt-rows.json`: `a10612980b03d18336ecbf5da118b549398bb904565eeb9f6455ce3eb36b3422`
- `execution.json`: `010502a4b2f2e91e650e64e9fea490526b056bc0cd066b6d47a3fa29dfa52a45`
- `output-verification.json`: `f9a2ae0a9c1e8037c65d7fc1e7fc89740380cc0bc39fcac853831be17d055835`

These are development inputs and CPU preparation results. No hardware,
representativeness, numerical parity, throughput, or runtime admission claim is
made. The existing recipe file remains the pinned common origin record.
