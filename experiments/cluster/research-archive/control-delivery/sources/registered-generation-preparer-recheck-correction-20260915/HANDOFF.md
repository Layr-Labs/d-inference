# Prospective agreement preparer input recheck correction

The frozen `prepare_expected.py` compared `snapshot(..., keep=False)` (which includes `raw: None`) with a dictionary omitting `raw`. That always refused unchanged inputs after computing the expected agreement. This correction changes only the expected dictionary to `dict(item, raw=None)`. The frozen `d072d1e0…72f2` comparator, snapshot, comparison arithmetic and evidence requirements remain unchanged.

`runtime.patch` is the exact one-expression delta. `original/prepare_expected.py` preserves the old bytes; `proposed/prepare_expected.py` imports its unchanged dependencies from the original frozen comparator directory. `commands.json` gives the exact environment and argv; select a new `--output` path when reproducing.

Four real CLI CPU checks passed: the original reproducible refusal/no output, corrected expected agreement publication, wrong input pin refusal, and existing-output preservation. No model, compiler, native process, network, candidate or actual generation result was accessed. All 39 original frozen comparator members were revalidated.

`expected-agreement.json` is a prospective packet for the already selected 27B request `20801ced-ca29-4faf-b71a-9ebbe1886a14`, epoch `93604d14-37da-4e80-ad11-9ddf9ff48d1e`, P32/C16/O128, cut32, empty stops and MTP off. It binds unchanged recording native `a7c35b37c2ae2f80c320221ac9931bdd3f87d7e7cd67b2d5cfbc93a8eb043ad6`. Its storage and arithmetic expectations come from separately frozen `qwen27b-expected-generation-identity-20260915`, never a generation candidate. Root must prepare a new packet if any selected identity changes.

Prepared agreement raw SHA256: `474d14971766fbde863afe417352e2e887fad18eccbfbf9c1e6992b1036af324`.

```sh
python3 -B -m unittest -v test_cli.py
```

The agreement does not certify current loaded storage, native execution, numerical correctness or physical qualification. Those remain separate required evidence.
