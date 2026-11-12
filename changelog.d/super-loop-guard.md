### Nemotron 3.5 Super answers that repeat themselves verbatim stop early too

- Super's text requests now get the loop guard the other models have: an answer that starts repeating one block word for word stops about 2,000 repeated tokens in, as `finish_reason: "length"` with its usage, and is paid as usual. Super's requests take the owner's own route, which passed no guard before.
- The same rules apply: never within the first 4,096 tokens; never for a JSON answer, a forced tool call, a tool call once it starts, or a request with images or video. `DARKBLOOM_LOOP_GUARD=0` turns it off for Super too.
