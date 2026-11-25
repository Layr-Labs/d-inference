# Installed HTTP content client

One explicit authenticated `/v1/chat/completions` request from this development
Mac. Python 3.9+, standard library. This package makes no request until invoked.
It is a private qualification client, not a product component or benchmark suite.

```sh
/usr/bin/python3 client.py \
  --endpoint http://LEADER_TAILSCALE_NAME:8000/v1/chat/completions \
  --model EXACT_INSTALLED_PUBLIC_MODEL_ID \
  --prompt-file prompts/short.txt \
  --token-file /absolute/private/token-file \
  --output /absolute/new-results/short \
  --timeout 120
```

Use `prompts/medium.txt` and a new output directory for the second invocation.
Both supplied prompts are development diagnostics, not representative workloads.
Their actual templated token counts are taken from reported terminal usage;
neither file is labelled an exact-token workload. For a separately prepared 8K
case, use its own prompt file and optional `--declared-prompt-tokens 8192`.
That declaration remains distinct from reported usage, including when a failed
stream has no usage. No retry or failed-sample replacement is performed.

The token file must be a regular, nonsymlink, current-user-owned 0600 file,
16–4096 visible ASCII bytes with an optional final LF. Its contents are used only
for the Authorization header; no token environment variable, argument value or
credential hash is emitted. The token-file path is an argument, not its contents.
The output directory is new and 0700; request, raw response, arrival log and receipt
are exclusive 0600 files. No auth headers or arbitrary exception messages are
recorded. An echoed literal credential refuses further capture and records an
explicit partial-capture failure. Keep this private output as it contains the
prompt and response. The client does not follow redirects or use an implicit URL.

The fixed request is one user message, `max_tokens:128`, `stream:true`,
`stream_options:{include_usage:true}`, `temperature:0`, `top_p:1`, `top_k:0`,
`repetition_penalty:1`, `presence_penalty:0`, `frequency_penalty:0`,
`enable_thinking:false`, and `reasoning_parser:"qwen3"`. These fields are traced
through the current local decoder and scheduler in `source-review.json`.
No unsupported field is used to imply acceptance. EOS can yield fewer than 128
tokens; the actual count and finish reason remain recorded.

The clock starts immediately before HTTP POST and includes connection/TLS and
complete SSE event receipt. Primary `measurement.ttft_ns` is the first nonempty
`delta.content`; role-only, usage, keepalive and reasoning events do not start it.
Reasoning and earliest-text timestamps are separate. A complete 128-token
reasoning-only response has status `no_content`, retains usage/finish, and cannot
pass the content SLA. Finish, usage and `[DONE]` plus HTTP body completion are
required; malformed/truncated streams and events after `[DONE]` fail.

`content_sla` compares first content against `10 s + 1 ms × prompt tokens` on the
client clock, separately for reported and optional declared counts. This includes
the network and differs from the server's receipt-origin deadline. A complete
response arriving late is `content_deadline_missed`, retained and exit 1; HTTP
errors, absolute-timeout misses, malformed captures and no-content outcomes also
exit 1. Only `completed` exits 0. No raw text fragment count is called a token
count; no engine TPS or model correctness claim is derived. `/apply-template`
uses `additionalContext:nil` and does not establish the same thinking-disabled
template count, so this client does not use it to qualify counts.

The one absolute timeout (default 120 seconds, maximum 300) covers connect,
headers and body, including trickles. Capture is limited to 8 MiB and 4096 lines,
with the inherited 1 MiB line limit; HTTP error bodies retain up to 64 KiB.
Final local capture verification and receipt publication follow the request
alarm; root must separately bound the whole client process (for example, 135
seconds for a 120-second request).
No cancellation mode is exposed: disconnect/EOF does not prove native retirement,
authenticated lease ACK or journal clearance. Root must retain installed CLI and
both owner lifecycle/postflight evidence separately, including after any failure.

Run only the model-free tests with:

```sh
/usr/bin/python3 -W error::ResourceWarning -m unittest -v test_client
```

Thirteen tests passed in `checks-2` using local fake HTTP or in-memory responses.
They verify controls, first content versus reasoning, reasoning-only 128 output,
exact 8K deadline miss retention, token privacy, truncation, late buffered records,
missing/invalid usage, timeout trickles, response/connection cleanup and interrupt
precedence. Their fabricated timing is not performance evidence. `checks-1`
retains the earlier ten-test pass with a ResourceWarning; explicit response close
fixed that partial-response ownership gap before the final run.
