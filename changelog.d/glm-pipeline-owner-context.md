### A GLM-5.3-Flash pipeline pair serves your own requests up to 262,144 tokens

- On a pair serving GLM-5.3-Flash in the pipeline, your own requests (the leader's local API and
  `darkbloom cluster local`) may now be up to 262,144 tokens: prompts up to 262,143 tokens and up to 65,536 output
  tokens. Both Macs' memory still admits each one, and a `max_tokens` past what the prompt leaves is cut to fit, as on
  one Mac. Before, the pipeline held every request to 32,768 + 32,768 tokens. Requests through Darkbloom keep
  32,768 + 32,768. Both Macs need this release.
  The pair's reported KV capacity (slot telemetry `kv_bytes_capacity`) now covers that longest request.
