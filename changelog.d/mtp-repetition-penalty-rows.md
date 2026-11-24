### Requests with a repetition penalty draft on the MTP builds

On the catalog Qwen 3.5/3.6 builds, Gemma 4 26B QAT and Inkling 2 Mini, requests
with a `repetition_penalty` other than 1 now draft, as requests with a presence
or frequency penalty already do. Before, they decoded without the drafter on
every model. Each draft position is penalized exactly as ordinary decoding
would after sampling the drafts before it (the same repetition window over
prompt, output and those drafts), and these rows accept a draft only
when it equals the model's own sample, so output is the same as with the
drafter off. `DARKBLOOM_MTP_REPETITION_PENALTY_ROWS=0` turns them off again.
