### Local API: this Mac first, then your Macs

- The local API (`start --local`, `--local-endpoint` and a pair's local API) now routes like the iPhone app. A request
  this Mac can't take (it doesn't serve the model, its queue is full, or it is draining) goes on to your other Macs
  (free) with `[local] route = "my-macs"`. With `"my-macs-first"` it goes to your Macs first and then the Darkbloom
  network (billed), without waiting on a busy Mac of yours; at a zero balance, it goes to your Macs only. Nothing
  leaves this Mac without a saved account key, with `route = "this-mac"`, or with `--no-auth`.
- `darkbloom route key` saves the account API key in this Mac's Keychain after one check with Darkbloom
  (`--stdin` to pipe it in, `--remove` to remove it). The key is never printed, logged, or written to a file.
- Tools keep one local URL and the local key. Their own route header is ignored. Answers say who served them
  (`X-Darkbloom-Served-By: this-mac` or `darkbloom`), and the coordinator's errors come back as sent. A balance refusal
  on the network route says that the network fallback needs a balance. A client that disconnects mid-stream stops the
  request at the coordinator too.
- `/v1/models` lists this Mac's models, then your Macs' (and the network's with "My Macs first"), each once, with
  `owned_by` and, when known, `context_length` and `max_output_length`. This Mac's models now say
  `owned_by: "this-mac"` instead of `"local"`. A model this Mac serves is listed once, under its own id, even when your
  Macs list it under its public alias, and a request for that alias is answered by this Mac.
- A chat request that names only `max_completion_tokens` is served with that limit, as `max_tokens` is.
- A request this Mac serves takes the same path as before, plus a few microseconds.
