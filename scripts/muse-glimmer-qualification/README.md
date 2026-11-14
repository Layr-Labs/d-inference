# Muse Glimmer 30B prompt goldens

`prompt_golden.py` writes and checks
`provider-swift/Tests/ProviderCoreTests/Fixtures/MuseGlimmer/prompt-golden.json`:
for each OpenAI request body, the prompt text and token IDs a reference
renderer produces from the served chat template. Its docstring lists the
request normalization it restates from the provider.

It reads the template and the tokenizer as data. It imports nothing from a
model repository, loads no weights and needs no GPU.

## Requirements

Python 3.11+ with exactly the packages in `prompt-golden-requirements.txt`.
The script refuses any other installed version. Run it with `-I` so the
current directory and user site are not on the import path.

## Inputs

| Argument | File |
|---|---|
| `--model-dir` | A directory holding `tokenizer.json` and `tokenizer_config.json` of `nvidia/Muse-Glimmer-30B-NVFP4` at revision `47818374517751c48c55cde2621594926b1888b6`. Their SHA-256 values are pinned in the script. |
| `--template` | The served template; defaults to the fixture's `chat_template.jinja`. |
| `--published` | Optional: `chat_template.jinja` of `meta-models/Muse-Glimmer-30B` at revision `cec94fcfd6512f2cfe708138c32533b346ea4f69`. The script then checks that the served template is that file with only its date block replaced, and that both render every case alike. |

## Use

```sh
python3 -I scripts/muse-glimmer-qualification/prompt_golden.py \
    --model-dir /path/to/snapshot --check \
    provider-swift/Tests/ProviderCoreTests/Fixtures/MuseGlimmer/prompt-golden.json
```

`--output <file>` writes the corpus instead. After a change to the cases or to
the provider's request normalization, write it again and run
`MuseGlimmerPromptGoldenTests`. For token-ID parity through the provider's own
tokenizer bridge, run that suite with `MUSE_GLIMMER_NVFP4_DIR` set to the same
directory; the test takes about two minutes in a debug build.

# Live capability probes

`live_probe.py` checks, against a live Muse Glimmer endpoint, each request
parameter an OpenRouter listing names: frequency, presence and repetition
penalties, `stop`, `seed`, `n`, streaming usage
(`stream_options.include_usage`), the `length`, `stop` and `tool_calls` finish
reasons, `logprobs` with `top_logprobs`, and the error shapes of refused
requests (each must be a typed 4xx with OpenAI's error object, never a 500).
It records each probe as pass, fail or skip, writes the evidence it saw, and
exits non-zero on any failure. It measures no speed and needs only the
standard library.

```sh
python3 -I scripts/muse-glimmer-qualification/live_probe.py \
    --base-url http://127.0.0.1:<port>/v1 --model muse-glimmer-30b \
    --api-key-env <VARIABLE> --report probe.json
```

The key is read from the named environment variable and never printed. A
parameter whose probe fails stays off the listing.

## Parameters that switch the drafter off

The engine keeps a whole request target-only, with no drafts and no drafter
history, when any of these is set (`mtpHistoryEligible` in
`libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/MTP/EngineLoopV2+MTPPlanning.swift`).
The output is unchanged; only decode throughput falls.

| Request field | Drafter off when |
|---|---|
| `frequency_penalty`, `presence_penalty` | not 0 |
| `repetition_penalty` | not 1 |
| `stop` | any stop string |
| `logprobs` | `true` |
| `logit_bias` | any entry |

`temperature`, `top_p`, `top_k` and `seed` keep the drafter: Muse's DFlash
drafter verifies sampled drafts by target-prefix acceptance
(`MuseGlimmerDFlashDrafter.supportsTargetPrefixAcceptance`). Muse has no
reasoning-budget family, so `reasoning.max_tokens` does not apply. No Muse
request compiles a token constraint today: a forced or required `tool_choice`
is prompt-forced and validated after the call
(`ToolChoiceEnforcementPolicy.forcedStrategy`, `.structuredPostValidation`),
and a JSON `response_format` is prompt-only (`JSONAnswerPolicy.profile`). A
Muse JSON grammar would switch the drafter off as well, unless grammar drafting
(`constrainedSpeculation`) were turned on for Muse; today it is on only for
`eigenlabs/qwen3.8-27b-4bit-mtp` (`SDKFeatureDefaults.grammarMTPBuilds`).

A request that sets any field in the table also stops every other request in
its decode step from drafting. A step drafts only when all its rows are eligible
(`mtpRowsCanSpeculate`), and only a recurrent row-exact target lets an
ineligible row decode beside speculating rows
(`CBv2MTPRoundDriver.ineligibleRowsDecodeBesideSpeculation`). Muse's adapter
(`MuseGlimmerCBv2Adapter`) is neither recurrent nor a request-scoped fallback,
so for Muse the cohort is all or nothing.
