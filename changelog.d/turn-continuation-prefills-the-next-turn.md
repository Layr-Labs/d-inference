### Opt-in: prefill the next turn while the Mac is idle

- With the prefill grid on, `DARKBLOOM_CBV2_TURN_CONTINUATION=1` lets a model prefill the start of a conversation's next turn after a text reply ends. The next request of that conversation then reuses state for the tokens it shares with the reply. It is off by default.
- The work runs only while the Mac is idle. Any arriving request cancels it, and it stops by itself after 60 seconds. A request that arrives while it runs waits for it to stop.
- A continuation that is cancelled or runs out of time keeps what it finished in the in-memory recurrent bank only. The complete-checkpoint store keeps nothing from it.
- It reads and writes the prefix cache under the cache scope of the request it follows. Its log line carries counts and a duration, and no tokens or text. It is left out of the prefix-cache savings counter and the reuse telemetry.
- A reply with a tool call, a reply cut by the token limit, a reply ended by a stop sequence, and a request with a response format or media start none. A model without the in-memory recurrent bank or the complete-checkpoint store starts none.
- On the complete-checkpoint store a continuation only extends what its turn left there. When the prefix cache restores less than the last grid position of that turn's prompt, the hidden request is refused before any prefill and its log line says `skipped`. A turn that left no checkpoint at that position starts none, and neither does a turn shorter than the store's minimum checkpoint (1,024 tokens by default).
- A reply that reaches no new position the model keeps starts none. Unless the model has both the in-memory recurrent bank and a message-boundary rule, that is every reply that does not cross a grid multiple.
- The key applies under `start --foreground` only, and setting it turns off the reviewed serving and deadline profiles, as every `DARKBLOOM_CBV2_*` key does. Its effect on follow-up latency has not been measured on this version.
