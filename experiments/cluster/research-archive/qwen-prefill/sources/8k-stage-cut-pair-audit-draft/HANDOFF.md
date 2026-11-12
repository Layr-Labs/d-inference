# Prospective fixed-cut12 8K pair CPU audit

This separate variant validates exactly the registered Qwen3.5 9B workload:
8192 prompt tokens, chunks of 512, one selected output, and the explicit
`0..<12` / `12..<32` plan. Existing frozen oracles and evidence are unchanged.
No new candidate was accessed while drafting or testing this validator.

Run with complete saved output and the actual retained raw prompt:

```sh
python3 -B audit_cut12_pair.py --stdout PATH --prompt PATH --prompt-sha256 HEX64
```

The equivalent API is
`audit_cut12_pair.validate(stdout_path, prompt_path, expected_prompt_sha256)`.
The caller must independently pin the prompt before execution. The established
8192-token natural prompt has SHA256
`ee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997`.
The input tokenizer/prose provenance and source/runtime/resource qualification
remain the launcher's and separate provenance audit's responsibilities.

The first JSONL record must contain the new run's complete full-model reference
with Plan SHA256
`8c3fef079cc82295d70851ef9d9193954afc0d008ad09ce239baaa1a51391fed`.
The second must be the completed one-process pair report for that same reference.
An old 16/16 reference is refused, even if its result values happen to agree.
Neither this adapter nor its fixture relabels old numerical evidence.

## Narrow reuse

- `qwen_long_prefill_reference_cut12_audit.py` preserves every original function
  except `context` and `verify_pins`. The complete source/load/request, sixteen
  commit, final-state, raw BF16/signed-zero, finite argmax/tie and top-fingerprint
  checks remain unchanged.
- `cut12_reference_context.py` replays the already frozen cut12 expected-metadata
  derivation and compares its complete result with the frozen expected JSON. It
  validates exact construction UTF8, parsed transform semantics, complete tensor
  ownership, and finite-schema stage/plan hashes. The metadata facade supplied to
  old consumers contains only fields derived from that control. It never accepts
  a numerical candidate as its own expectation.
- The delegated recorded loader oracle is the frozen short cut12 variant. It
  checks 348/579 active tensors, 2,032,294,848/3,005,746,752 active bytes,
  16,384/8,192 inert bytes and the exact source/local mappings and configurations.
- Final state partitions are explicitly 27/45 components and
  119,980,044/199,966,740 bytes. Every entry is compared with the fresh full
  reference. The disjoint union remains all 72 components and 319,946,784 bytes.
- The v4 wire helper is byte-identical. Sixteen residual metadata/envelope
  records, 32 stage commits and the selected token keep the previous closed
  schemas and hash domains. Candidate logit/state digests are not reconstructed
  candidate numerical bytes.

`mechanical-variant.diff` records the original-to-copy changes;
`check_source.py` checks exact old pins, function AST conservation, wire byte
identity, and the six literal substitutions in the main pair helper. Its output
is `source-delta-check.json`. The native proposal manifest is pinned, including
all 19 proposed Swift source members. Historical source controls remain useful
for unchanged numeric bodies; they do not claim that a new native binary was
built or qualified by this CPU audit.

## CPU checks and interpretation

The suite reuses the full reference mutation tests and pair tests, with a new
fixed-cut group. New negatives include a coherent complete old-half pair,
rehashing a stale reference Plan, moving a whole layer between owners while
preserving the complete union, wrong compact tensor/config identities, and
input mutation after replay. Temporary files and generated numerical/state
records are synthetic. The reference test input is the already pinned natural
prompt; pair fixtures use generated token IDs. Neither is new native evidence.

```sh
python3 -B check_source.py
python3 -B -m unittest -v test_reference test_pair test_cut12
```

The wrapper requires two distinct bounded regular files, final newline, exactly
two parsed JSONL records, a 16 MiB stdout ceiling and a 65,536-byte prompt ceiling.
It checks all core/dependency pins and input bytes before and after replay.
The root must independently pin the wrapper and its manifest before use.

Only the reference exports a full row: CPU reconstruction proves the reported
BF16 byte digest, including signed zeros, and derives finite first-index argmax
and tie count. Eight Int32 offset components are reconstructable. The other 64
state digests, all residual payload digests, native commits/copies, early
arithmetic application and cleanup are source-bound assertions requiring the
separate executable/archive/runtime evidence. Candidate logit metadata/digest
agreement is not raw candidate-byte parity. No throughput, physical transfer,
model quality, process peak or memory safety is qualified.
