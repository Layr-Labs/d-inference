### Qwen tensor-parallel pairs serve concurrent requests from their first load

- The guided cluster setup now saves a width for a Qwen tensor-parallel pair:
  the widest of 8, 6, 4 and 2 concurrent requests that both Macs admit now under
  that width's complete load quote. The pair serves that many requests at once
  from its first load. Before, it served one: a local pair widened only after a
  burst, through a drained reload that the burst waited for, and a pair served
  through Darkbloom never widened.
- On two idle Macs, Qwen3.8-27B without the speculative assistant saves 8 from
  48 GB a Mac (4 at 32 or 36 GB). With the assistant, which serves local
  clusters only, it saves 8 from 96 GB a Mac and less on smaller Macs. When no
  width fits, the setup serves one request at a time as before.
- Memory safety is unchanged: both Macs still reserve the saved width's whole
  quote at load and admit each request alone. A local pair planned narrower
  still widens under queued demand; a pair saved at 8 is never reloaded for it.
- A pair served through Darkbloom keeps its saved width beside its approval. No
  approval, registration or committed-start digest changes. Existing setups keep
  their saved bytes and their one-request width until they are planned again,
  as after an update.
