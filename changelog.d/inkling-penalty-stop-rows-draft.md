### Inkling 2 Mini drafts on penalty and stop-string requests

Inkling 2 Mini's DSpark drafter now also drafts for requests with a presence
or frequency penalty or with `stop` strings, as the catalog Qwen 3.5/3.6
builds and Gemma 4 26B QAT already do. Before, such requests decoded without
the drafter. Each draft position is scored with the request's penalties over
its confirmed output plus the earlier drafts, and penalty rows accept exactly.
A stop string ends the row at its first match, through the same answer-channel
stop scope as ordinary decoding. A repetition penalty, logprobs, `logit_bias`
or a constraint still keeps a request on the drafter-off path.
`DARKBLOOM_MTP_PENALTY_ROWS=0` and `DARKBLOOM_MTP_STOP_STRING_ROWS=0` turn the
new rows off again.
