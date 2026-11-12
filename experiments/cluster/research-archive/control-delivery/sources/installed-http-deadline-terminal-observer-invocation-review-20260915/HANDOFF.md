# Terminal observer invocation supplement

Frozen observer source/manifest b1a512d3cff519f5ac87afa1183ac21d5b51f0fe11189badb3b360abfecbba03 is unchanged.

The original HANDOFF command needs the observer directory on PYTHONPATH. A direct `python3 -B harness/run.py` gives the harness directory as the first module path; `tokenizer_check.py` imports the parent `client_timeout` module. Root retained an import refusal before main or remote activity, with no physical output directory created.

From the frozen observer directory, use the following prefix with the original bounded arguments and a fresh attempt ID:

```sh
PYTHONPATH="$PWD" /usr/bin/python3 -B harness/run.py --attempt FRESH_ATTEMPT \
  --prompt-file ../installed-http-long-prompts-20260915/fixtures/prompt-8192.txt \
  --declared-prompt-tokens 8192 \
  --rendered-prompt ../installed-http-long-prompts-20260915/fixtures/prompt-8192.rendered.txt \
  --expected-token-ids ../installed-http-long-prompts-20260915/fixtures/prompt-8192.ids.json \
  --client client.py
```

This changes import resolution only; no frozen runtime/helper, inference deadline, 90-second observation bound or cleanup policy changes. Do not reuse physical-1: root subsequently ran it with this prefix and reported a successful 8192-token request (17.007461750 seconds to visible content, 123 EOS output tokens, usage/DONE/EOF). That success is not an observed typed deadline failure; the expected-failure qualification intentionally remains false. This supplement records the parent's execution report and source diagnosis, not an independent physical audit.
