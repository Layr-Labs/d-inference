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
