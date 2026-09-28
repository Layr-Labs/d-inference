# Ten development reading workloads

The ten files in `prompts/` contain distinct real code/documentation tasks and
100–178 KB of source text each. They are development inputs, separate from the
qualification workload. No representative-workload, numerical, throughput or
hardware claim is made. Tokenization and model execution have **not** run.

| ID | Task | Source focus |
| --- | --- | --- |
| dev01-module-trees | Understand and extract invariants | Module traversal, parameter trees, freeze/update tests |
| dev02-training-updates | Compare state transitions | Optimizers, schedules, losses and update tests |
| dev03-function-transforms | Trace control and find test gaps | Autodiff, vectorization and transform tests |
| dev04-compile-export | Reason about compatibility | Tracing, compilation, export/import and cache behavior |
| dev05-spatial-shapes | Extract and reason about shapes | Convolution, transpose, pooling and upsampling |
| dev06-randomness-init | Review reproducibility contracts | Keys, distributions, initialization and dropout |
| dev07-tensor-algebra | Read algorithms and design checks | Einsum, linear algebra and Fourier transforms |
| dev08-indexing-semantics | Triage a behavioral bug | Basic/advanced indexing, assignment and array tests |
| dev09-quantized-contracts | Extract cross-layer contracts | Quantized layers, packed operands and matrix tests |
| dev10-extension-lifetimes | Read technical interfaces | Custom operations, lazy evaluation, ownership and scheduling |

All 68 source files are disjoint across tasks. They come from the locally
retained MLX upstream commit
`ce45c52505c8158ea48d2a54e8caae05efd86bfe`, preceding the fork's local merges,
not the current local inference/CBv2 implementation. Each raw file is copied
once and kept intact between named boundaries. Prompts retain the task first,
Apple/upstream attribution, and the complete MIT notice. `LICENSE-MLX.txt` is
the exact `LICENSE` from that same commit. Source hashes and paths in
`recipes.json` refer to raw Git blobs (`git show COMMIT:PATH`), not today's
working-tree versions. The local history, upstream README and source notices
establish the recorded provenance; no network publication check was performed.

`recipes.json` records every origin's raw SHA-256, byte count, task instruction,
raw-prompt SHA-256 and tokenizer metadata. Its raw SHA-256 is
`94869a94f623ce7cf969061a57efd3e98bc5486cba1c35f13823b4e17262c443`;
that complete recipe file can serve as the common `origin_sha256` for these ten
development inputs. The source scan found no later project additions, local
user paths or credential-shaped material in the selected blobs, and no
additional per-file license notice.

For the root's later tokenization, reuse the **encoding settings**, not the old
`long-prefill-input-20260914/preparation.py`: that script generates repeated
paragraphs and targets its fixed existing output folder. Its receipt identifies
`tokenizers==0.22.2`, Python 3.12.13, no chat template, no added special tokens,
and vocabulary size 248320. The existing local
`models/Qwen3.5-9B/tokenizer.json` still hashes to
`87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4`;
only hashing was performed here. Exact absolute metadata/script/tokenizer paths
are in the recipe.

In a new output directory, verify the recipe/source/tokenizer pins, encode each
raw prompt, and require at least 8192 tokens. Retain exactly the first 8192 IDs,
the decoded prefix and raw/ID/origin hashes using the existing bounded format.
The final file excerpt may be partial; the task explicitly permits this and
requires marking absent evidence. Never pad by repeating content. Require ten
distinct resulting ID sequences and preserve these full raw sources. Until
that step passes, these remain ten source-complete proposals, not ten verified
8192-token inputs. No existing workload or qualification artifact was changed.
