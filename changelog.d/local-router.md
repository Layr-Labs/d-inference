### Local API: this Mac first, then your Macs

- The local API (`start --local`, `--local-endpoint` and a pair's local API) now routes like the iPhone app. A request
  this Mac can't take (it doesn't serve the model, its queue is full, or it is draining) goes on to your other Macs
  (free) with `[local] route = "my-macs"`, and then to the Darkbloom network (billed) with `"my-macs-first"`. Nothing
  leaves this Mac without a saved account key or with `route = "this-mac"`.
- `darkbloom route key` saves the account API key in this Mac's Keychain after one check with Darkbloom
  (`--stdin` to pipe it in, `--remove` to remove it). The key is never printed, logged, or written to a file.
- Tools keep one local URL and the local key. Their own route header is ignored. Answers say who served them
  (`X-Darkbloom-Served-By: this-mac` or `darkbloom`), and the coordinator's errors come back as sent. A balance refusal
  on the network hop says that the network fallback needs a balance.
- `/v1/models` lists this Mac's models, then your Macs' (and the network's with "My Macs first"), each with
  `owned_by` and, when known, `context_length` and `max_output_length`.
- A chat request that names only `max_completion_tokens` is served with that limit, as `max_tokens` is.
- A request this Mac serves takes the same path as before, plus a few microseconds.
