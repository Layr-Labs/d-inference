# Changelog

Unreleased changes live in [`changelog.d/`](changelog.d/README.md). Ordinary
pull requests add one fragment; release preparation alone updates this file.

Version sections identify source included in published tags, not coordinator
or console deployment, feature activation, model promotion or hardware
qualification. Sections marked historical retain the original candidate's
qualification, opt-in and deployment limits rather than claiming activation.

## v0.10.13 — candidate (unpublished)

Prepared on 2026-11-14; tagging and publication are separate steps.

### Upgrade and rollout notes

**Highlights**

Plain-language summary of provider 0.10.13. The full technical changelog, the pull requests and the build's
verification details are on this page too.

- Gemma 4 no longer gets stuck repeating a thought: when its reasoning starts to loop, it stops thinking and answers.
- That answer now starts even when the Mac is busy with other requests, instead of timing out in the queue.
- When the Mac is full, that answer takes the stopped request's place instead of being turned away.
- Qwen 3.5 and 3.6 can do the same when their operator turns it on.
- For Qwen 3.5 9B and 35B it is now on by default.
- Nemotron 3.5 Super can do the same when its operator turns it on; it is off by default until it has been measured.
- When you set up a two-Mac pair, the second Mac no longer says "Stopped" while the first Mac downloads the model.
- GLM-5.3-Flash no longer turns requests away on an idle Mac after a run of long prompts: memory kept from finished requests is given back when a new one needs it.
- GLM-5.3-Flash and MiMo no longer turn long requests away on an idle Mac because a short one ran just before: the time a long prompt needs is no longer guessed from a few-token prompt.
- Qwen 3.5 9B gets its default presence penalty back, so fewer of its answers run on to their token limit.
- GPT-OSS answers that ask for JSON output are no longer lost: an answer the model marks as JSON reaches you instead of an empty reply.
- GPT-OSS honours `tool_choice` `required` and a named tool: the answer is a call to a tool (or to that tool).
- An answer that reaches its token limit ends cleanly as `length`, including a tool call cut off at the limit.
- Qwen 3.5, 3.6 and 3.8 no longer lose a tool call because their thinking mentioned a tool.
- On request, tools and tool results reach the model exactly as Hugging Face Transformers renders them.
- A Mac notices a dead link to Darkbloom within seconds and reconnects at once.
- Earlier thoughts that a client sends back as `reasoning` or `thinking` reach the model again.
- `parallel_tool_calls: false` returns the first tool call instead of failing the answer.
- Gemma 4 keeps a text value such as `01000` as written instead of turning it into a number.
- A GLM-5.3 answer that mentions a tool tag in passing no longer fails.
- Answers about images and videos that repeat themselves word for word stop early too.
- Optional: GLM-5.3 can return a JSON answer that misses the requested schema instead of an error, for the caller to judge.
- Gemma 4 answers in exactly the JSON format you ask for.
- Qwen tool calls marked strict always match their schemas.
- Bonsai 2 27B and Nemotron 3.5 Lightning answer in exactly the JSON format you ask for.
- Qwen JSON answers follow schemas written with Pydantic, OpenAI or zod.
- GPT-OSS no longer runs out of tokens repeating its reasoning on tool requests: it stops and answers or calls a tool.
- Security: the link between the two Macs of a pair is protected; both Macs need 0.10.13 to pair.
- Two-Mac pairs keep their link key in the Mac's Keychain instead of a file.
- Security: each Mac of a two-Mac pair proves its identity on the link.
- GPT-OSS stops repeating its reasoning and answers on ordinary requests too.
- GPT-OSS no longer drops the text it writes before a tool call.
- Qwen answers no longer show a stray </think>.
- Nemotron Super answers two image requests at once.
- Qwen 3.8 strict tool and JSON answers decode faster.
- Gemma 4 tool calls give numbers where the tool asks for numbers.
- Hardened tool-call constraints for complex schemas.
- Security: stricter updater version checks.
- Clearer security information when pairing two Macs.
- Security: hardened request parsing.
- Security: tighter resource limits on queued requests.
- Steadier memory use when the settings are re-read.
- Gemma 4 no longer leaks a reopened thought into its answer.
- Nemotron Super and MiMo honour a reasoning token budget and still answer.

- **A Gemma 4 thought that repeats itself verbatim now ends in an answer:** the loop guard closes the thought and the model answers in the same response (at most 8,192 tokens, within the request's budget), instead of ending as `length` with no answer. A loop in the answer still ends as `length`. Gemma 4 only; never with logprobs or on a pair; `DARKBLOOM_LOOP_EXIT_THINKING=0` turns it off (#2040).
- **Setting up a pair no longer says "Stopped" while the leading Mac downloads:** the joining Mac ends its screen only on a stop someone asked for, and such a stop now ends the leading Mac's start at once, also during the download or the load (#2042).
- **Faster recovery from a dead coordinator link:** the provider pings every 2 s and treats the link as dead after 6 s without a frame, so a link that died silently (for example on a coordinator restart) is noticed in 6 to 8 s instead of up to 40 s, and the first reconnect after a long session starts at once (#2047).
- **Qwen 3.5 9B keeps its model card's presence penalty:** a request that sends no `presence_penalty` gets 1.5 again, as on the other Qwen 3.5/3.6 builds. Provider 0.10.12 dropped it, and the 9B's answers then ran on to `max_tokens` about three times as often; its JSON answers that ran out failed about twice as often. A request's own value still wins. Those requests decode without MTP, as on 0.10.11. `DARKBLOOM_QWEN35_9B_PRESENCE_PENALTY=0` restores 0.10.12's default (#2051).
- **Gemma 4 keeps a string argument as written:** an unquoted `01000`, `1.10` or a long id for a string parameter stays text instead of turning into a number, and a `strict` tool no longer fails the call partway through the stream (#2050).
- **A past turn's reasoning sent back as `reasoning` or `thinking` reaches the model:** clients that echo OpenRouter's `reasoning` field (or `thinking`) no longer lose the earlier thoughts that Qwen, Bonsai 2, MiMo and Gemma replay; the first non-null of `reasoning_content`, `thinking` and `reasoning` wins (#2048).
- **`parallel_tool_calls: false` returns the first tool call** instead of failing the response when the model makes a second one, streamed or not, on every model, as OpenAI and vLLM do (#2049).
- **A stray `<tool_call>` no longer fails a GLM-5.3-Flash response:** a tag the model only mentioned or drafted in its thought is returned as text instead of a 500; the calls are the well-formed frames that end the response. Required and named `tool_choice` still fail closed. `DARKBLOOM_GLM_TOOL_TEXT_FALLBACK=0` restores the 500 (#2052).
- **An answer cut at `max_tokens` ends as `length`, not as an error:** a JSON answer or tool call the limit cuts off now ends normally with `finish_reason: "length"` and its usage (a cut call is left unclosed so no client can run it), and a `strict` call that fails the provider's check once a stream has started returns as generated. `DARKBLOOM_LENGTH_FINISH_AT_LIMIT=0` and `DARKBLOOM_STRICT_CALLS_AS_GENERATED=0` restore each refusal (#2053).
- **The loop guard covers image and video requests:** a media answer that repeats one block verbatim ends as `length` instead of running to its output cap, and Gemma 4's repeating thought on a media request ends in an answer. On OpenRouter's VGI-Bench rerun, 117 of 257 Gemma video answers had run to the cap (#2054).
- **Qwen 3.5 and 3.6 can end a repeating thought in an answer, as Gemma 4 does (off by default):** `DARKBLOOM_LOOP_EXIT_THINKING=gemma4,gemma4_text,qwen3_5_moe` turns it on for the Qwen 3.5/3.6 35B models (adding `qwen3_5` covers the 9B and Qwen 3.8 27B). When the loop guard stops a verbatim loop inside the thought, the provider ends the thought as Qwen's template does (`</think>`) and the model answers in the same response, instead of ending as `length` with no answer. It is off by default because the A/B found too few Qwen thought loops to show that they answer. Never with logprobs or on a pair. For Gemma 4's exit (#2040), a stop string that ends the answer is now reported as the matched stop sequence (#2046).
- **Qwen 3.5, 3.6 and 3.8 parse tool calls after the thinking:** a thought that mentions `<tool_call>` no longer turns the real call into text, and a call written inside the thinking is no longer executed; a stray thought before a forced call is returned as `reasoning_content` instead of failing the request (#2057).
- **Tool JSON as Transformers renders it, on request:** a chat request with `"_darkbloom_template_json": "transformers"` shows Qwen 3.5/3.6/3.8, Bonsai 2, MiMo, GLM-5.3 and GPT-OSS their tools, calls and results exactly as Hugging Face renders them; every request that does not ask renders the same bytes as before (#2058).
- **GPT-OSS JSON answers are no longer lost:** an answer that opens with Harmony header attributes, as in `<|channel|>final <|constrain|>json<|message|>`, now arrives as `content` instead of an empty reply; everything else in a GPT-OSS response is byte-identical (#2063).
- **GLM JSON answers: an optional release of schema misses.** By default a GLM-5.3-Flash JSON answer that misses the caller's schema is still refused with a 422; `DARKBLOOM_GLM_JSON_SCHEMA_MISS=release` exposes it instead when the model stopped by itself, so the caller's validator judges it (#2065).
- **GPT-OSS honours `tool_choice` `required` and a named function:** the model reasons first, at the request's `reasoning_effort`, then writes only a call to a declared function with arguments that match its schema, arriving as `tool_calls` (before, these requests were refused with 400 `tool_choice_unsupported`). The coordinator sends them only to Macs on this release, never to a pair. `DARKBLOOM_GPTOSS_FORCED_TOOLS=off` turns it off (#2045).
- **GLM-5.3-Flash and MiMo no longer refuse long prompts because of a short prompt's speed:** an idle Mac priced every prompt's prefill from the last cold prompt it ran, whatever its size. A few-token prompt reads as 9-140 tokens per second (its fixed setup) on GLM Macs that read long prompts at 1,400-2,000, so they refused nearly every longer request as `deadline_unreachable` (1,300 of the 1,452 requests of OpenRouter's Tau2 run on GLM) and never measured one. A prompt of up to 4,096 tokens may now raise that estimate but never lower it, and an idle Mac with no recent calibration or longer-prompt reading prices prefill at no less than its own calibration. GLM and MiMo only. `DARKBLOOM_TTFT_NATIVE_PREFILL_EVIDENCE=0` restores 0.10.12's behaviour (#2072).
- **GLM-5.3-Flash no longer refuses requests on an idle Mac whose KV pool kept its free memory:** the pool now returns its free segments before retrying a refused lone request (waiting up to 10 s while the previous request's prefix checkpoint is published) and after 30 s idle. On 0.10.12 the pool kept every segment and each prefix-cache restore added more, until a request arriving at an idle 256 GB Mac failed as `capacity_busy` right after admission (about 3,960 a day), which also put the Mac into the coordinator's capacity cooldown. GLM only. `DARKBLOOM_NATIVE_SEGMENT_RELEASE=0` restores 0.10.12's behaviour (#2060).
- **Nemotron 3.5 Super can end a repeating thought in an answer (off by default):** `DARKBLOOM_LOOP_EXIT_THINKING=gemma4,gemma4_text,nemotron_h_omni` turns it on. When the loop guard stops a verbatim loop inside Super's thought, the provider ends the thought (`</think>`, as Super's template does) and the model answers within the same request, instead of ending as `length` with no answer. Off by default until its A/B. Never with logprobs, media or on a pair (#2061).
- **A GPT-OSS analysis that repeats itself now ends in an answer or a tool call** on requests that declare tools: the provider closes the analysis and the model writes its final answer or call in the same response (on 126 Tau2 airline turns, turns with nothing fell from 74 to 38). `DARKBLOOM_LOOP_EXIT_THINKING=gemma4,gemma4_text` turns it off for GPT-OSS (#2070).
- **Strict Qwen tool calls always match their schemas:** on one Mac, a call to a function declared `strict: true` is constrained while it is sampled, so it can no longer miss its schema and fail the response partway. On by default for Qwen 3.8 27B, Qwen 3.6 35B and Qwen 3.5 35B (Qwen 3.5 9B when a Mac opts in). While such an answer decodes, drafting pauses on that Mac, so a lone strict answer on Qwen 3.8 decodes at about 50 instead of 120 tokens per second. Schemas the grammar can't hold exactly are served as before. `DARKBLOOM_STRICT_TOOL_GRAMMAR=off` turns it off on a Mac (#2069).
- **Gemma 4 JSON answers follow the requested format:** with a JSON `response_format` the answer after the thought is exactly one JSON value of that format, with no code fences or extra text, including schemas written with `$defs`/`$ref` or optional fields (100 of 100 valid in our test, up from 87). Requests the grammar doesn't cover and pairs are answered as before. `DARKBLOOM_GEMMA_JSON_ANSWERS=off` turns it off (#2071).
- **Valid JSON answers on Bonsai 2 27B and Nemotron 3.5 Lightning:** a JSON `response_format` request whose answer starts without a thought is sampled under the same grammar the Qwen 3.5 family uses, so the answer is one JSON value of the requested schema. `DARKBLOOM_JSON_ANSWER_GRAMMAR=qwen` keeps the grammar to Qwen (#2075).
- **Qwen JSON answers follow Pydantic, OpenAI and zod schemas:** schemas with nested models (`$defs`/`$ref`), optional fields or value limits are now constrained too: the structure, types, enums and required keys are enforced, and a value limit the grammar can't hold is left to the caller; never a refusal. A long JSON answer decodes without drafting, so alone it is slower (about 52 instead of 123 tokens per second on Qwen 3.8). `DARKBLOOM_QWEN_JSON_SCHEMA_REWRITE=off` restores today's behaviour (#2084).
- **Two-Mac pairs: the link between the Macs is secured (security fix).** Each connection between the two Macs of a pair now uses its own fresh keys, so traffic on the link can't be read with the pairing secret alone. **A pair links only when both Macs run 0.10.13:** a pair with one Mac on 0.10.12 doesn't form until both have updated (pairs update together; there is no mixed-version pair and no downgrade path for the link) (#2096).
- **GPT-OSS without tools too:** a looping analysis on a request without tools (or with `tool_choice: "none"`) now ends by opening the final answer, instead of ending as `length` with an empty answer. `DARKBLOOM_GPTOSS_FINAL_EXIT=0` keeps the exit to requests with tools (#2088).
- **A looping thought's answer no longer times out on a busy Mac:** when the loop guard ends a thought, the answer's continuation is now admitted ahead of the requests waiting in the engine's queue. With more requests than slots it used to wait behind them and end as `length` after the engine's 120 s admission lease, with no answer (21 of 29 Gemma 4 exits on the 0.10.13 DevNet build at 12 requests on 8 slots). `DARKBLOOM_LOOP_EXIT_THINKING=0` still turns the exit off (#2100).
- **Gemma 4 prompt contract 2, dormant until a coordinator switch-on:** a Mac can render the prompt vLLM-served endpoints render (so `usage.prompt_tokens` matches theirs: OpenRouter's "−1 prompt token" notice), but only for a coordinator request that asks for it. No request asks yet; until the coordinator switches it on, every request renders exactly as before. `DARKBLOOM_GEMMA_PROMPT_CONTRACT_V2=off` stops advertising it (#2098).
- **A looping thought's answer is no longer refused on a full Mac:** the answer's continuation now takes the stopped request's place in the Mac's serving allowance. Work waiting for a slot used to take that place first, and the continuation was refused, ending `length` with no answer (2 of 7 Gemma 4 exits in a GPU check at 16 requests on 8 slots; 0 of 6 with this change). `DARKBLOOM_LOOP_EXIT_THINKING=0` still turns the exit off (#2115).
- **Qwen drafting around protected spans:** on Qwen 3.8 27B strict tool and JSON requests, the ordinary reasoning and text may draft (MTP) again while tool frames, arguments and JSON values stay under the grammar. `DARKBLOOM_CONSTRAINT_SPANS=0` turns it off (#2101).
- **native reasoning budgets for Nemotron Super and MiMo:** a request's positive `reasoning.max_tokens` closes the thought at that many tokens and the answer continues within the same total output limit, on Nemotron Super and MiMo V2.6. `DARKBLOOM_NATIVE_REASONING_BUDGET=0` turns it off (#2099).
- **Gemma quoted numeric tool arguments:** a Gemma 4 argument the model quotes is read as a number when the parameter's schema clearly asks for a number; ambiguous schemas keep the text, and strict calls are still checked. `DARKBLOOM_GEMMA_SCHEMA_COERCION=0` turns it off (#2090).
- **Off by default — Qwen forced tool calls keep the caller's thinking setting:** with `DARKBLOOM_QWEN_FORCED_TOOL_THINKING=1` on a Mac, a Qwen request with `tool_choice` required or named keeps the thinking setting it asked for, and the reasoning is split off before the call is checked. Unset keeps 0.10.12's behaviour (#2091).
- **GPT-OSS commentary before a tool call reaches the content:** GPT-OSS commentary written before a tool call and addressed to no tool is returned as `content` instead of being dropped, streamed or not. `DARKBLOOM_GPTOSS_COMMENTARY_CONTENT=0` turns it off (#2092).
- **Qwen stray `</think>` markers are absorbed:** a stray `</think>` outside a thought no longer leaks into a Qwen answer; markers inside tool arguments stay literal. `DARKBLOOM_QWEN_ABSORB_STRAY_THINK_CLOSE=0` turns it off (#2093).
- **Nemotron Super decodes two image requests at once:** a Super Mac serving at least three requests may decode two image requests at the same time (image preparation stays one at a time; video stays exclusive). `DARKBLOOM_NEMOTRON_SUPER_CONCURRENT_IMAGES=0` turns it off (#2094).
- **Gemma reopened thought channels:** a Gemma 4 thought the model reopens later in its answer goes to `reasoning_content` instead of the answer, and stray channel-close markers are absorbed; tool arguments are never re-routed. `DARKBLOOM_GEMMA_REOPENED_THOUGHTS=0` turns it off (#2089).
- **Hardened Gemma forced tool-call constraints** (#2111).
- **Updater version checks (security)** (#2117).
- **Clearer pairing security information** (#2129).
- **Hardened inbound request handling (security)** (#2130).
- **Resource limits on queued coordinator requests (security)** (#2135).
- **Configuration parsing no longer accumulates memory** (#2138).
- **Two-Mac pairs: the link key moves to the Keychain (security).** After a restart the pair links once someone has logged in to the Mac (`darkbloom cluster status` says so); a rollback to 0.10.12 through the updater keeps the pair working (#2137).
- **Qwen 3.5 9B and 35B now end a repeating thought in an answer by default, as Gemma 4 and GPT-OSS do:** when the loop guard stops a verbatim loop inside the thought, the provider closes it as Qwen's template does (`\n</think>\n\n`) and the model answers in the same response, instead of ending as `length` with no answer. On GPQA's looping questions (OpenRouter's settings, temperature 0.5) the 35B answered 14 of 27 such thoughts (6 right) and the 9B 11 of 29 (3 right); the others looped again and still end as `length`. Requests where the guard does not fire are unchanged. Only these two builds: Qwen 3.6, Qwen 3.8 27B and any other build keep `length` unless `DARKBLOOM_LOOP_EXIT_THINKING` names them (`…,qwen3_5_moe,qwen3.6`); `DARKBLOOM_LOOP_EXIT_THINKING=gemma4,gemma4_text,gpt_oss` turns Qwen's off (#2125).
- **Off by default — GLM-5.3-Flash JSON answers under a grammar:** with `DARKBLOOM_GLM_JSON_ANSWERS=1` on a Mac, GLM's JSON `response_format` answers are sampled under the JSON grammar; unset keeps 0.10.12's path (#2114).
- **Two-Mac pairs: each Mac proves its identity on the link (security).** Every connection between the two Macs of a pair now also checks that each Mac holds the key its pair pinned. Both Macs must run 0.10.13 to link; after a restart, the pair links once someone has logged in to the Mac (#2146).
- **Rollout:** a patch release over 0.10.12 with only the fixes below; nothing else from `dev` rides. Pairs: both Macs must run the same version, and a pair on 0.10.12 updates itself. `darkbloom update --rollback` puts back 0.10.12.
- The registration keeps 0.10.12's fields and cluster runtime facts; `libs/mlx` (72dffa2d), `libs/mlx-swift` (b1c94d29) and the Xcode 27.2 toolchain are unchanged, so `mlx.metallib` is unchanged.
- The 49 entries below are the pending fragments rendered verbatim, except where the release notes reword one; CI-only entries change no provider behaviour.
- **Known issue:** A two-Mac pair that serves only you and is updated by hand on both Macs can stay stopped after the update (an older race between the update re-plan and the restart, not new in 0.10.13): run `darkbloom cluster local` (or `darkbloom start`) on the leading Mac to start it again. Pairs that serve through Darkbloom update at their slot and are not affected.
- **Known limitation (since 0.10.0, unchanged in 0.10.13):** Nemotron 3.5 Super is served only by the provider daemon: `darkbloom start --local --here` (the standalone server) skips it ("it loads only in the provider daemon"). To use Super on your own Mac only, run the daemon with its local endpoint instead (`darkbloom start --foreground --local-endpoint`).

### A pair being set up is no longer called stopped while the leading Mac downloads

- During `darkbloom cluster` setup, the Mac that joined ended its screen about 20 s into the leading Mac's download (or a long copy) of the chosen model with "Stopped (by `darkbloom cluster stop` on one of the Macs): the pair isn't starting any more", though nobody had stopped anything and the leading Mac's start went on (0.10.9 to 0.10.12). It took the leading Mac's status, which reads "Stopped" until both Macs' parts start, for a stop. The leading Mac now counts each stop someone asks for (`darkbloom cluster stop` on either Mac, and `darkbloom stop` or `darkbloom restart` once the pair runs) and its status carries the count; the Mac that joined ends only on a stop asked since the start began, and then at once instead of 20 s later. A leading Mac on an older build sends no count, so the Mac that joined follows its start to the end.
- On the leading Mac, such a stop now ends the start at once too: during the model's download or copy (what arrived stays, and the next start goes on from there; before, both Macs were started once it finished), while both Macs load the model (before, a ✗ with Retry after 15 minutes), and at the test (before, "✓ Serving" or "the test failed"). The registration no longer starts again a pair stopped during the test. The pair's own stops (the registration's restart, the cluster service's restart for a changed approval) no longer end the leading Mac's wait for the coordinator with that line.

### Cluster link: each Mac proves its identity

- Every connection between the two Macs of a pair now also checks that each Mac holds the key its pair pinned (security). Details will be published after the fleet has updated.
- After a restart, the pair links once someone has logged in to the Mac; it resumes by itself.

### Cluster link: fresh keys for every connection

- The link between the two Macs of a cluster pair now uses fresh keys for every connection, from an X25519 key agreement made in memory on both Macs and authenticated with the pairing's key. This covers everything the link carries (worker commands including prompts, outputs, bootstrap rounds, leases, status), for `darkbloom cluster local` / `start --local --distributed` and coordinator-formed pairs. Every reconnect makes new keys.
- The link handshake is now version 3, with no fallback: a Mac still on an older release cannot join its pair until both Macs run this release (the pair's update cycle updates both); the refusal reads `protocolVersionMismatch`.

### Cluster pairing: the link key in the Keychain

- A two-Mac pairing's link key is now kept in this Mac's Keychain; an earlier release's copy moves there at the first start of this release.
- After a restart, the pair links once someone has logged in to the Mac; `darkbloom cluster status` says so, and the pair resumes by itself after the login.
- Rolling back to 0.10.12 with `darkbloom update --rollback` (or an automatic rollback) keeps the pair working; a 0.10.12 installed by hand asks to pair the Macs again.

### Clearer pairing security information

- `darkbloom cluster pair` labels the other Mac's security details as what that Mac reports, not as verified facts.

### Faster recovery from a dead coordinator link

- **The provider now finds a silent coordinator link in 6 to 8 s and reconnects at once:** it pings every 2 s and declares the link dead when no frame (pong, ping or message) comes in for more than 6 s. Before, a link that died with no reset and no close frame, for example on a coordinator node restart, took up to 40 s to notice.
- After a session that stayed open for 60 s or more, the first reconnect waits 0 to 0.25 s instead of 0.5 to 1 s; repeated failures still back off as before.
- A busy stream never trips the bound, because every inbound frame counts. A Mac that slept for 30 s or more reconnects once at wake, as before; a shorter delay of the ping timer is not counted as missed pongs.

### Resource limits on queued coordinator requests (security)

- The provider bounds the coordinator requests it holds while they wait for admission; ordinary serving never reaches the bound. Details will be published after the fleet has updated.

### Gemma 4 keeps a string parameter's unquoted `01000` as "01000"

- Gemma 4 sometimes writes a string argument without its quote marker. Every such value was read as JSON, so a string parameter's `01000` reached the client as the number 1000, `1.10` as 1.1, `007` as 7 and a 20-digit id as an inexact number, and a `strict` tool failed the call partway through the stream.
- Such a value is now read by its parameter's type, at any depth, as vLLM does: a parameter that takes a string keeps the text the model wrote, and number, integer and boolean parameters read it as before. The type is the one Gemma is shown: a parameter declared without a type (or as `{}`) is shown as a string and a union as its first member's type, so an unquoted `5` there now stays "5" where vLLM, reading the declared schema, returns 5; both are valid for the declared schema, except for an `enum` that mixes types on a parameter shown as a string (untyped, or a union that lists the string first, as `Literal["a", 1]` declares it), where an unquoted `1` now reads "1". A value in quote markers stays a string even for an integer parameter, as before. The SDK pin moves to mlx-swift-lm main with this change.

### Gemma 4 JSON answers follow the requested format

- A Gemma 4 26B request with a JSON `response_format` (`json_object`, or `json_schema` within the provider's supported subset) is now sampled under a grammar: after the model's thought, if any, the answer is exactly one JSON value of the requested format, with no code fences, surrounding prose or trailing text. Schemas as Pydantic, OpenAI's strict mode or zod write them (`$defs`/`$ref`, optional fields as `anyOf` with null, `$schema`) are enforced as written; a `json_schema` the grammar still does not cover is held to a JSON object when its root is an object. The thought is unchanged.
- Requests the grammar does not cover (tools, a `tool_choice` other than `auto` without tools, `stop` sequences, images, other schemas) and cluster pairs are answered as before; an answer cut at `max_tokens` still ends as `length`, never as an error. `DARKBLOOM_GEMMA_JSON_ANSWERS=off` turns the grammar off on a Mac.

### Gemma 4 prompt contract 2 (vLLM's prompt), dormant until the coordinator asks

- A provider now registers Gemma 4 prompt contract 2 and renders it for a coordinator request that asks for it: the system message, and list-shaped user content, as the chat template's text parts, which end in a space before the system turn closes. For system and user content that is the prompt vLLM-served endpoints render, so `usage.prompt_tokens` and the prompt the model reads then match theirs (OpenRouter's GPQA prompt: 88 tokens, not 87). Assistant and tool content renders as before.
- No request asks yet: the coordinator asks only for models it switches on, and only for requests it planned and counted with contract 2. Until then every request renders exactly as before, as do the local API, media requests and other models. `DARKBLOOM_GEMMA_PROMPT_CONTRACT_V2=off` stops advertising contract 2 on a Mac.

### Gemma quoted numeric tool arguments

Adopt the SDK parser fix, on by default since 0.10.13 (measured on Gemma 4 26B in its ON state; the parser is shared by every Gemma 4 size). `DARKBLOOM_GEMMA_SCHEMA_COERCION=0` restores 0.10.12's strings (the LaunchAgent forwards the switch to the installed service). Numeric marker strings become numbers at frame close only when the parameter schema unambiguously requests a numeric type. Potentially converted values stay withheld from argument deltas until the completed parse; unsupported or ambiguous schemas preserve their quoted text. The provider still validates strict calls.

### Gemma reopened thought channels

On by default since 0.10.13 (measured on Gemma 4 26B QAT in its ON state; the change is in text parsing, the same for every Gemma build). A Gemma 4 thought the model reopens later in its answer goes to `reasoning_content` instead of the answer, and stray channel-close markers are absorbed. The collected path shares the streaming state machine. Native, JSON and escape-quoted tool argument data stays opaque to channel routing. The same parsing also changes four ordinary cases slightly: an empty thought adds no reasoning text; a bare `thought` prefix is stripped from streamed answers; collected answers keep text that precedes the first thought and absorb a close with no opener; and `<turn|>`/`<eos>` before any channel are dropped. `DARKBLOOM_GEMMA_REOPENED_THOUGHTS=0 darkbloom start` restores 0.10.12's parsing (the LaunchAgent forwards it; for a foreground process, set `=0`).

### Hardened Gemma forced tool-call constraints

- Gemma 4's constraint for a required or named `tool_choice` is built within tighter resource limits for complex tool schemas.

### GLM-5.3-Flash JSON answers can be grammar-constrained

- With `DARKBLOOM_GLM_JSON_ANSWERS=1`, a GLM-5.3-Flash request with a JSON `response_format` (and no tools) is sampled under the same JSON grammar as Qwen, Bonsai and Lightning answers: the answer is one JSON value of the requested schema, so a missing required key, an invented key or a wrong type can no longer be generated (about 7 % of GLM's answers missed under batching, each a 422 after the streamed reasoning).
- Requests the grammar does not cover keep today's prompt-steered, checked answer; a cluster pair is never constrained. The provider's MLX runtime now accepts token constraints on GLM's native engine.
- A constrained GLM request decodes without speculative drafting (MTP), and so does a request sharing a two-request decode step with it (GLM drafts with at most two); it also reuses no cached prompt prefix of another JSON request.

### GLM JSON answers: an optional release of schema misses

- A GLM-5.3-Flash JSON `response_format` answer is checked before it is exposed. One whose JSON value misses the caller's schema has been refused with a 422 after the streamed reasoning; it still is by default.
- `DARKBLOOM_GLM_JSON_SCHEMA_MISS=release` exposes that value instead when the model stopped by itself (fences and surrounding prose removed), so the caller's own validator judges it. Output with no complete JSON value, and output cut at `max_tokens`, are handled as before. It applies to streamed responses, which every coordinator request is; a non-streamed local API request still gets the service's own schema check.

### GLM no longer fails requests on idle Macs whose KV pool kept its free memory

- GLM's native paged KV pool kept every segment it ever committed until it was
  unloaded, and each prefix-cache restore attached more. On a 256 GB M5 Ultra
  that free memory stayed charged until a request arriving at an idle Mac could
  not reserve its fixed memory and first step's scratch beside it and failed as
  `capacity_busy` right after admission (about 3,960 GLM requests a day), which
  also put the Mac into the coordinator's capacity cooldown.
- The SDK now returns the pool's free segments before retrying such a request,
  and after the engine has been idle 30 seconds; a request that arrives while
  the previous one is still publishing its prefix checkpoint waits up to 10
  seconds for it instead of failing. `DARKBLOOM_NATIVE_SEGMENT_RELEASE` sets the
  idle seconds, and any value that is not a positive number below a day (`0`,
  `off`) restores the former behavior; it is forwarded to the launchd provider
  job.

### A stray `<tool_call>` no longer fails a GLM-5.3-Flash response

- GLM's tool parser reads a response from its first `<tool_call>` to the end as one batch of calls, and on `auto` tool requests that includes the model's reasoning. A tag the model only mentioned or a call it drafted in its thought, or a text answer that mentions the tag, failed the whole response with a 500 (`native GLM tool output is invalid`).
- Such output is now text instead of a failure, as vLLM's and SGLang's GLM parsers never fail a response on tool syntax, with a stricter rule for what is still a call: the calls are the frames that end the response, when all of them are well-formed; everything before them is text, which the service's reasoning parser splits at `</think>`. A frame inside or after another frame's arguments, or after arguments that break the parser's grammar, is never a call. Output with no such calls (a malformed or cut-off final call, a malformed call among the final ones, text after the calls) is all text, and so is output cut off at `max_tokens` whose tool suffix does not parse. No call is completed or salvaged.
- Still a 500, as before: output whose released text would hold a think marker from inside a tool frame (the reasoning parser would read it as the end of the thought), and a tool suffix over the parser's 1 MiB bound. Output the parser cannot read safely, such as a thought that spells out the tags in order (`<tool_call>`, `<arg_key>`, `<arg_value>`) or a refused call with quotes before the final calls, recovers no call: it is text, or still a 500 when the thought's `</think>` comes after it. Required and named `tool_choice` still fail closed (422). `DARKBLOOM_GLM_TOOL_TEXT_FALLBACK=0` restores the 500 for every unparsed suffix; `darkbloom start` passes it to the launchd provider.

### GPT-OSS commentary before a tool call reaches the content

- GPT-OSS: a recipientless commentary preamble (Harmony's short message before a tool call) now reaches `content`, streamed and collected, instead of being dropped. Tool calls are unchanged: a recipient before or after the channel marker stays a call, and incomplete, oversized, non-assistant and body-embedded commentary headers pass as before. On by default; `DARKBLOOM_GPTOSS_COMMENTARY_CONTENT=0` restores the 0.10.12 behavior.

### GPT-OSS answers under a `final` header with attributes reach the client

- GPT-OSS can open its answer with Harmony header attributes, as in `<|channel|>final <|constrain|>json<|message|>`, typically for JSON answers. The provider's Harmony split kept only an exact `final` header, so such an answer was dropped and the client got empty `content`. It now arrives as `content`, as any other answer does.
- Nothing else in a well-formed GPT-OSS response changes: reasoning, tool calls, preambles and plain answers are byte-identical.

### GPT-OSS honors `tool_choice` "required" and a named function

- A GPT-OSS 20B request with `tool_choice` `"required"` or `{"type": "function", "function": {"name": …}}` was refused (400 `tool_choice_unsupported` from the coordinator). It is now served: the model reasons first, at the request's `reasoning_effort`, then the provider lets it write only a call to a declared function (the named one, or any declared one for `required`), with arguments that match that function's schema. The reasoning arrives as `reasoning_content` and the call as `tool_calls`, with `finish_reason` `tool_calls`.
- One call per response: GPT-OSS's format ends the response at its first call, so `parallel_tool_calls` changes nothing.
- The reasoning before a forced call ends at 16,384 tokens, whatever `max_tokens` allows: a model still reasoning then writes its call, so a reasoning loop no longer runs to the context limit.
- A named function that is not declared is still a 400, and a schema outside the forced-choice subset (for example `$ref` or `anyOf`) is still refused, as for the other models, before any generation. `auto` and `none` are unchanged.
- The Mac advertises the capability for `gpt-oss-20b`, and the coordinator routes these requests only to Macs on this release or later, never to a cluster pair. `DARKBLOOM_GPTOSS_FORCED_TOOLS=off` (or `false`, `0`, `none`, `no`, `disabled`) turns it off on a Mac (it also reaches a provider started by `darkbloom start`).

### Grammar-aware MTP

- Adopt SDK #409: constrained rows draft with MTP and every committed position is verified under the row's grammar. On by default since 0.10.13 for the measured Qwen 3.8 27B build only (`EigenLabs/Qwen3.8-27B-4bit-mtp`), where constraint spans are on (measured together); Gemma 4 and Super keep target-only constrained rows unless `DARKBLOOM_CBV2_MTP_GRAMMAR=1`. `DARKBLOOM_CBV2_MTP_GRAMMAR=0` (or `DARKBLOOM_CONSTRAINT_SPANS=0`) restores 0.10.12's target-only constrained rows. Forwarded by the LaunchAgent.

### A past turn's reasoning sent back as `reasoning` or `thinking` reaches the model

- A client that sends an earlier assistant turn back as OpenRouter returned it carries that turn's thought in `reasoning`; some clients use `thinking`. The provider read only `reasoning_content`, so the thought was dropped: Qwen 3.8, Bonsai 2 27B and MiMo, whose templates replay every earlier thought, saw an empty thought on each of those turns, and Qwen 3.5/3.6 and Gemma 4 lost the thoughts of the tool calls since the last user message.
- Darkbloom requests and the local API now read such a turn's `thinking` or `reasoning` as its `reasoning_content`, as Hugging Face's chat template rendering does: the first non-null of `reasoning_content`, `thinking` and `reasoning` wins. An empty or non-string value changes nothing.

### Hardened inbound request handling (security)

- The provider applies stricter limits when it parses inbound requests and tool schemas. Ordinary requests are unaffected. Details will be published after the fleet has updated.

### Valid JSON answers on Bonsai 2 27B and Nemotron 3.5 Lightning

- A tool-free JSON `response_format` request on Bonsai 2 27B or on Nemotron 3.5 Lightning, on one Mac, whose prompt
  starts in the answer (thinking off, the JSON default on Bonsai), is now sampled under the JSON-answer grammar the
  Qwen 3.5 family already uses: for schemas inside the constrained subset the answer is one JSON value of the
  requested schema (no extra or missing keys, no raw newline inside a string). On our checks, Lightning answers with
  thinking off missed the schema 8 times in 72 before and 0 times after.
- Requests whose prompt opens a thought (Lightning's default), requests served by a cluster pair, and the Bonsai 2 9B
  keep today's prompt-only steering.
- Like Qwen's, these answers decode without MTP (a Lightning row sharing their decode step stops speculating
  meanwhile), and the provider checks them when generation ends: an answer that misses the schema at a natural stop
  is the typed `422` (`tool_noncompliance`); one cut at `max_tokens` ends as a normal `length` finish with its
  content as generated.
- The grammar keeps an answer inside the schema, not on topic: a model that wants a forbidden key may keep writing the
  string it is in until `max_tokens`.
- `DARKBLOOM_JSON_ANSWER_GRAMMAR=qwen` (or `0`/`off`) keeps the grammar to the Qwen types.

### An answer cut at max_tokens ends as length, not as an error

- When generation stops at the request's `max_tokens` (or this Mac's limit) during a `response_format` answer or a tool call, the response now ends normally with `finish_reason: "length"` and its usage, instead of a `tool_noncompliance` error. Before, a streaming client got an error frame partway through the answer, which OpenRouter counts as a failed response, and a coordinator request without `stream` got a 422.
- What was generated stays as generated: a streamed call stays open with its arguments so far, left unclosed so no client can run a cut call; a JSON answer leaves as written (Qwen, Flint, Super; GLM's normalized when it already holds a whole value); and of the calls held until the end, each one that no longer passes its checks is left out. On the Mac's own API, a request without `stream` whose cut `response_format` content is not one JSON value still gets the 422 that says `max_tokens` cut it off.
- A `strict` tool call (`tool_choice` `auto`) that fails the provider's own check now returns as generated, as a non-strict one does since 0.10.12, once a streaming response has started. Before anything was sent, and for a request without `stream`, it is still refused, so the request can go to another Mac. Forced choices, `none` and `parallel_tool_calls: false` keep their checks.
- `DARKBLOOM_LENGTH_FINISH_AT_LIMIT=0` and `DARKBLOOM_STRICT_CALLS_AS_GENERATED=0` (or `off`, `false`, `no`) restore each refusal; both reach a provider started by `darkbloom start` (launchd). Telemetry `tool_constraint_cut` (by outcome) and `tool_constraint_strict_as_generated` count what replaced the refusals.
- With or without the switches, a tool-call refusal at the end of an answer now comes before the last text the model produced instead of after it, so a refusal with nothing else sent stays one the request can be retried on another Mac.

### A looping thought's answer no longer times out on a busy Mac

- When the loop guard ends a thought (Gemma 4 by default; Qwen 3.5/3.6, Nemotron 3.5 Super and GPT-OSS when their exit applies), the answer's continuation is now admitted ahead of the requests waiting in the engine's queue. On a Mac with more requests than slots it used to queue behind them and end `length` after the engine's 120 s admission lease, with no answer: 21 of 29 Gemma exits on 0.10.13's DevNet build at 12-on-8 concurrency. `DARKBLOOM_LOOP_EXIT_THINKING=0` still turns the exit off.

### A looping thought's answer keeps its place on a full Mac

- When the loop guard ends a thought, the answer's continuation now takes the stopped request's place in the Mac's serving allowance. On a full Mac, work waiting for a slot took that place first and the continuation was refused, ending `length` with no answer: 2 of 7 Gemma exits in a GPU check at 16-on-8 concurrency. Other requests still wait for a free place.
- Under memory pressure the engine evicts an ordinary running request before a continuation (that request recomputes its work so far).
- `DARKBLOOM_LOOP_EXIT_THINKING=0` still turns the exit off.

### A GPT-OSS analysis that repeats itself now ends in an answer on requests without tools too

- When the loop guard stops a verbatim loop inside GPT-OSS's analysis on a request without tools (or with `tool_choice: "none"`), the provider ends the analysis and opens the final channel (`<|end|><|start|>assistant<|channel|>final<|message|>`), and the model writes its answer in the same response, instead of ending as `length` with an empty answer. Left to pick its next channel (the exit for requests with tools), the model reopened its analysis and looped again on every GPQA question that looped.
- On GPQA Diamond in OpenRouter's request shape (`reasoning_effort: high`, temperature 0, 66 questions), unanswered questions fell from 39 to 0 and accuracy rose from 35 % to 58 %. Requests where the guard does not fire are unchanged (token-identical when sent one at a time).
- The request's stop strings apply to the answer from its first token. The usage counts every token produced, as one completion. A loop in the answer still ends as `length`.
- On by default. `DARKBLOOM_GPTOSS_FINAL_EXIT=0` keeps the exit to requests with tools; `DARKBLOOM_LOOP_EXIT_THINKING=gemma4,gemma4_text` turns GPT-OSS's exit off altogether.

### A GPT-OSS analysis that repeats itself verbatim now ends in an answer or a tool call

- As for Gemma 4: when the loop guard stops a verbatim loop inside GPT-OSS's Harmony analysis channel, the request no longer ends as `length` with no answer and no tool call. The provider ends the analysis message (`<|end|>`) and starts the next assistant message (`<|start|>assistant`), as the model does after its own analysis, and the model writes its `final` answer or its tool call in the same response. The usage counts every token produced, as one completion. A loop after that still ends as `length`.
- In OpenRouter's Tau2-Bench airline run on 0.10.12 (`reasoning_effort: high`, temperature 0), 27 % of GPT-OSS's turns ended that way, at 4,097 tokens with nothing but reasoning.
- On by default for `gpt_oss` requests that declare tools, the shape of Tau2's turns: on a GPU A/B of 126 Tau2-Bench airline turns at `reasoning_effort: high`, temperature 0, the turns that ended with nothing fell from 74 to 38 (calls 31 → 46, replies 21 → 35), and 7 more got a retryable memory-admission 503 after their retries (the same build needed such retries with the exit off too). Without tools the model mostly opened a new analysis after the exit and looped again, so those requests keep the `length` stop. Never with logprobs or on a cluster pair. `DARKBLOOM_LOOP_EXIT_THINKING=gemma4,gemma4_text` (a list without `gpt_oss`) or `0` restores the `length` stop for GPT-OSS.

### A Qwen 3.5 thought that repeats itself now ends in an answer

- When the loop guard stops a verbatim loop inside a Qwen 3.5 9B or Qwen 3.5 35B thought, the provider now closes the thought as the model's template does (`\n</think>\n\n`), and the model writes its answer in the same response, instead of ending as `length` with no answer. Gemma 4 and GPT-OSS already did this.
- On GPQA Diamond at OpenRouter's settings (temperature 0.5), on the questions whose thoughts loop: Qwen 3.5 35B answered 14 of the 27 thoughts the guard ended (6 right) and the 9B 11 of 29 (3 right); the others looped again in the answer and still end as `length`. Requests where the guard does not fire are unchanged (token-identical when sent one at a time).
- The request's stop strings apply to the answer from its first token. The usage counts every token produced, as one completion. A loop in the answer still ends as `length`.
- On by default for these two builds only. Qwen 3.6, Qwen 3.8 27B and any other build of these model families keep `length` until their own A/B, whatever list a Mac sets, unless the list also names the build (`…,qwen3_5_moe,qwen3.6`). `DARKBLOOM_LOOP_EXIT_THINKING=gemma4,gemma4_text,gpt_oss` turns Qwen's exit off.
- A request whose strict tool calls the provider constrains to their schemas keeps today's `length` stop: the answer after the thought would be written without that constraint.

### A Qwen 3.5 or 3.6 thought that repeats itself verbatim can end in an answer (off by default)

- Once turned on, as for Gemma 4 in 0.10.13: when the loop guard stops a verbatim loop inside a Qwen 3.5 or 3.6 35B thought, the request no longer ends as `length` with no answer. The provider ends the thought as Qwen's template does (`\n</think>\n\n`), and the model writes its answer in the same response. The usage counts every token produced, as one completion. A loop in the answer still ends as `length`.
- Since 0.10.12, 0.16 % (Qwen 3.6 35B) and 0.83 % (Qwen 3.5 35B) of GPQA-shaped requests ended that way with no answer.
- Off by default: the A/B on Qwen 3.5/3.6 35B found too few thought loops to show rescues (Qwen 3.6 never looped in 198 greedy GPQA draws; Qwen 3.5 35B looped 3 times, once on the candidate, whose answer looped again). `DARKBLOOM_LOOP_EXIT_THINKING=gemma4,gemma4_text,qwen3_5_moe` turns it on for the 35B models; `…,qwen3_5` adds the 9B and Qwen 3.8 27B; `0` turns all of it off. Never with logprobs or on a cluster pair.
- Client stop strings apply to the answer from its first token, and a stop string that ends the answer is reported as the matched stop sequence (Gemma 4's too).

### A Nemotron 3.5 Super thought that repeats itself verbatim can end in an answer (off by default)

- Once turned on, as for Gemma 4 in 0.10.13 (and the Qwen 3.5/3.6 35B models, when listed): when the loop guard stops a verbatim loop inside Super's thought, the request no longer ends as `length` with no answer. The provider ends the thought (`</think>`, as Super's template does), and the model writes its answer in the same response. The usage counts every token produced, as one completion. A loop in the answer still ends as `length`.
- Since 0.10.12, 3.0 % of GPQA-shaped Super requests ended that way with no answer.
- Off by default until its A/B: `DARKBLOOM_LOOP_EXIT_THINKING=gemma4,gemma4_text,nemotron_h_omni` turns it on beside Gemma 4's (the default); adding `qwen3_5_moe` turns on the Qwen 3.5/3.6 35B models' too; `0` turns all of them off. Never with logprobs, media or on a cluster pair.

### A Gemma 4 thought that repeats itself verbatim now ends in an answer

- When the loop guard stops a verbatim loop inside Gemma 4's thought, the request no longer ends as `length` with no answer. The provider ends the thought (`<channel|>`), and the model writes its answer in the same response. The client sees the thought close and the answer start. The usage counts every token produced, as one completion. A loop in the answer still ends as `length`, as in 0.10.12.
- The answer gets what is left of the request's output budget, at most 8,192 tokens. If it cannot start (under 256 tokens left, the stopped row not released within 5 s, a full Mac, a cancel), the request ends as `length`, as before; if it fails after its first token, the answer ends there as `length`.
- Gemma 4 only (`gemma4`, `gemma4_text`). Never with logprobs or on a cluster pair. `DARKBLOOM_LOOP_EXIT_THINKING=0` turns it off.
- `DARKBLOOM_LOOP_EXIT_THINKING` and 0.10.12's `DARKBLOOM_LOOP_GUARD` now reach a provider started by `darkbloom start` (launchd). Before, both worked only in the foreground or with `--local`.

### The loop guard covers image and video requests

- Image and video requests on one Mac to Gemma 4, Qwen 3.5/3.6/3.8, Qwen
  Flash-Next and GLM-5.3 now get the text path's loop guard: a media answer
  that repeats one block verbatim ends as `length` instead of running to its
  output cap. MiMo's and Super's media and the pairs' media routes are
  unchanged.
- For Gemma 4, a repeating thought on an image or video request ends the
  thought and the model answers, over the same media input (exit-thinking).
- On OpenRouter's VGI-Bench rerun of 11-13, 117 of 257 served Gemma video
  answers ran to the 117,8xx-token cap, 116 of them with at most 71 tokens
  outside the thought; the median served answer was 110K tokens long (27
  minutes).

### GLM-5.3-Flash and MiMo Macs no longer refuse long prompts because of a short prompt's speed

- An idle GLM or MiMo Mac priced every prompt's prefill from its last short prompts. A prompt of a few tokens takes about as long as its fixed setup, so it read as 9-140 tokens per second on GLM Macs that read long prompts at 1,400-2,000; the Macs then refused nearly every longer request as `deadline_unreachable` (1,300 of the 1,452 requests of OpenRouter's Tau2 run on GLM), and a refusal measures nothing, so the estimate never recovered.
- A prompt of at most 4,096 tokens may now raise that estimate but never lower it, and readings from prompts of up to 1,024 tokens no longer lower the estimate for a prompt of their size either. An idle GLM or MiMo Mac with no calibration or longer-prompt reading in the last two minutes prices prefill at no less than its own calibration, instead of re-measuring with a short prompt. A fresh slow reading from a longer prompt, or a busy Mac, still prices below it.
- Other models are unchanged. `DARKBLOOM_TTFT_NATIVE_PREFILL_EVIDENCE=0` restores the previous estimate (it reaches a provider started by `darkbloom start`).

### Native reasoning budgets for Nemotron Super and MiMo

- Add native reasoning budgets for supported local Nemotron Super and MiMo routes. Positive `reasoning.max_tokens` now reaches the SDK sampler, closes the thought at its token limit and continues the answer within the original total output ceiling. Unsupported routes and conflicting thinking-off controls remain refused. On by default since 0.10.13 for Nemotron 3.5 Super and MiMo V2.6 (each measured in its ON state); `DARKBLOOM_NATIVE_REASONING_BUDGET=0` restores 0.10.12 for every family. A Super cluster pair cannot hold a budget: there the request is refused at the engine bridge (unsupported output control) instead of by the prompt contract.

### `parallel_tool_calls: false` returns the first tool call instead of failing the response

- With `parallel_tool_calls: false`, a model that made a second call failed the whole response: a streamed answer ended in an error after its first call had already been sent, and a complete answer was a 422. Under automatic tool choice the prompt does not ask for a single call (only a GLM pair's prompt does), so these were requests the provider should have served.
- The response now carries the first call, as OpenAI and vLLM return it, and the calls the model makes after it are dropped, streamed or not, on every model, Nemotron Super's path included. A later frame that does not parse keeps the existing rule for malformed output: GLM, MiMo, Flint and Nemotron Super fail the response, as for any malformed frame, and a frame that never reads as a call (an undeclared name on Qwen or Gemma) stays text.

### Qwen constraint spans

- Add `DARKBLOOM_CONSTRAINT_SPANS` support for eligible Qwen strict-auto tool requests and JSON reasoning, on by default since 0.10.13 for the measured Qwen 3.8 27B build only (`EigenLabs/Qwen3.8-27B-4bit-mtp`, measured there in its ON state; every other build stays off unless set to `1`; `0` restores 0.10.12). Ordinary reasoning and content may draft; tool framing/arguments and JSON values remain protected. Text after a completed call may draft again.
- Forward the flag into the installed provider service. Preserve existing grammar admission, masks, engine eligibility and off behavior. No full-model speedup is claimed.

### Qwen forced tool calls can keep the caller's thinking setting

- Added opt-in `DARKBLOOM_QWEN_FORCED_TOOL_THINKING` for qwen forced-call thinking. Forced required/named tool requests retain the caller’s resolved thinking setting. Nested reasoning.enabled takes precedence over enable_thinking and effort. The existing native router separates reasoning before validating a trailing tool call. Default-off behavior is unchanged.

### Qwen JSON answers follow Pydantic, OpenAI and zod schemas

- A Qwen 3.5, 3.6 or 3.8 request whose `json_schema` the JSON-answer grammar used to decline is now constrained: Pydantic's nested models (`$defs`/`$ref`), `Optional` fields (`anyOf` with null), `$schema`, and value limits such as `minimum`, `maximum`, `pattern`, `format`, length or item bounds and map-typed `additionalProperties`. A schema that can be rewritten into the grammar exactly is enforced as written; otherwise the structure, types, enums and required keys are enforced and the value limits are left to the model (the provider never refuses a streamed answer for them); an object schema the grammar still cannot shape is held to a JSON object. These answers used to be unconstrained and sometimes came back fenced.
- `DARKBLOOM_QWEN_JSON_SCHEMA_REWRITE=off` restores declining these schemas to prompt-only steering.

### Qwen 3.5, 3.6 and 3.8 parse tool calls after the thinking

- On Qwen 3.8, Qwen 3.6, Qwen 3.5 35B and Qwen 3.5 9B, tool calls were parsed before the thinking was split off. A
  thought that mentioned `<tool_call>` once (for example "I'll wrap it in `<tool_call>` tags") made the response's real
  call come back as text, with no call; a call the model wrote out inside its thinking was executed. The thinking is
  now split off first, as on Bonsai 2, Nemotron 3.5 Lightning and MiMo: tool syntax in the thinking stays in
  `reasoning_content`, and the calls after it arrive as `tool_calls`.
- A call the model writes at the very end of a thought it never closes (a known Qwen 3.5 habit) still arrives as a
  call, once the output ends, and its text also stays in `reasoning_content`. A call followed by more thinking or by
  the end of the thinking does not, nor does an earlier call that text separates from the last one, nor any call in a
  thought the token limit cut off.
- `auto` calls still stream while they are generated, and requests without tools are unchanged. Forced calls
  (`required` or a named function) still run with thinking off; a stray thought the model writes before one is now
  returned as `reasoning_content` instead of failing the request.
- A local `stream: false` response for these requests keeps the whitespace around its content and reasoning, as the
  streamed response does.

### Qwen stray </think> markers are absorbed

- Qwen with thinking off: a stray `</think>` in the answer no longer leaks into `content`. A complete stray close outside a thought is absorbed by native channel splitting, as on Nemotron 3.5; a closed-thought prompt selects that route for Qwen streams that had none (no tools, or a Qwen type outside the reasoning-before-tools split), on text and media paths; Qwen3-VL keeps its route. Partial markers at the end of a stream and markers inside tool arguments stay literal, and a missing or disabled reasoning parser gets no inferred thought state. On by default; `DARKBLOOM_QWEN_ABSORB_STRAY_THINK_CLOSE=0` restores the 0.10.12 behavior.

### Strict Qwen tool calls always match their schemas

- On Qwen 3.8 27B, Qwen 3.6 35B and Qwen 3.5 9B and 35B, a tool call to a function declared `strict: true` could miss the caller's schema (a quoted number, a wrong enum value, a missing required argument, a value inside a `$ref` definition of the wrong JSON type); the provider checks such a call when it closes, after the answer started streaming, and the response then failed partway. On one Mac the provider now constrains these calls while they are sampled, by default on Qwen 3.8 27B, Qwen 3.6 35B and Qwen 3.5 35B, and on Qwen 3.5 9B when the Mac opts in (`DARKBLOOM_STRICT_TOOL_GRAMMAR=on`): only a declared function, its declared parameters (each at most once, every required one), and values of the declared types and enums can be written, in the template's call format. Reasoning and text around the calls stay free (ordinary text, the reasoning and call markers and the end of the answer; other special tokens such as `<|im_start|>` are not sampled), text that only mentions `<tool_call>` stays text, and the choice whether to call, the prompt and the streamed call deltas are unchanged. With `parallel_tool_calls: false` an answer opens at most one call.
- It applies to `tool_choice` `auto` (or absent) requests that declare at least one `strict` function; every call of such a request is held to its schema, as the check already holds it. Local `$ref`/`$defs` are inlined, `anyOf` of a type and `null` is supported, and a request whose schemas use a keyword the grammar cannot hold exactly (`pattern`, `minimum`, `minLength`, unions of several types, recursive references, ...) is served unconstrained, as before, never refused. Cluster pairs keep the previous behavior.
- As with constrained JSON answers, MTP drafting stops while a constrained answer is decoding: it drafts nothing itself, and on these models no other answer decoding beside it on the same Mac drafts either. Qwen 3.8 and Qwen 3.5 9B draft while up to 8 answers decode at once, so their decode slows while a strict-tool answer is running (on Qwen 3.8 a lone strict answer decodes at about 50 instead of 120 tokens per second; with two or more answers decoding the Mac barely drafts anyway, and at four the answers beside a constrained one decode about 13 % slower): Qwen 3.8 takes the grammar by default because strict calls that missed their schemas were its main remaining failure on OpenRouter, the 9B only when a Mac opts in. Qwen 3.6 and 3.5 35B, whose cards set a presence penalty, do not draft anyway unless a request sets `presence_penalty: 0`.
- The coordinator can turn it off for a model on every Mac at once by forwarding the model's tools without `strict` (`EIGENINFERENCE_STRICT_TOOLS_UNMARK_MODELS`); those calls are then also not checked against their schemas, and it does not reach a request body above 4 MiB or a Mac with `DARKBLOOM_STRICT_TOOL_GRAMMAR_ALL_TOOLS=on`. `DARKBLOOM_STRICT_TOOL_GRAMMAR=off` turns it off on a Mac, `on` turns it on for every one of the four builds, and a list of model types or model-id parts (`qwen3.8-27b,qwen3_5_moe`) picks the builds. `DARKBLOOM_STRICT_TOOL_GRAMMAR_ALL_TOOLS=on` also constrains the calls of requests without `strict` functions. Both reach a provider started by `darkbloom start`.

### Qwen 3.5 9B keeps its model card's presence penalty

- Provider 0.10.12 dropped the default `presence_penalty` of 1.5 from the catalog `Qwen3.5-9B` for requests that send none. In production its answers with `max_tokens` of 8,192 or more then ran to the limit about three times as often (5.5 % against 1.7 % on 0.10.11), and JSON `response_format` answers ran out and failed about twice as often (51 % against 23 % in the same 10-minute windows). 0.10.13 restores the model card's 1.5 for those requests, as on the other catalog Qwen 3.5/3.6 builds.
- A request that sends its own `presence_penalty` is unchanged. With `presence_penalty` 0 the 9B still speculates under exact MTP acceptance. A penalty row does not speculate but still donates prefix-cache checkpoints.
- `DARKBLOOM_QWEN35_9B_PRESENCE_PENALTY=0` (or `off`) restores 0.10.12's default. `darkbloom start` passes it to the launchd job. A coordinator registry `presence_penalty` arrives as the request's own value and wins, so while the registry sets one for the 9B the switch changes only local requests; rolling routed traffic back also needs the registry value removed or set to 0.

### SDK feature defaults

- Add provider defaults for feature switches the SDK reads (`SDKFeatureDefaults`). An unset switch follows the release's default, which is on only where it was measured in its ON state: per exact model id for constraint spans and grammar-aware MTP (grammar only where spans are on), per family for native reasoning budgets, process-wide for the Gemma parser switch. An operator value always wins; `<KEY>=0` restores 0.10.12 on every model. Injected defaults are recorded in `DARKBLOOM_SDK_DEFAULTS_INJECTED` and never written into a service plist, so an installed service follows the running release. `darkbloom start` (and `benchmark`, on stderr) prints `SDK feature defaults on: …`. Nothing is on by default unless its switch is listed.

### Concurrent Nemotron Super images

- Nemotron Super serves two image requests at once on owners serving at least three requests (the managed slot serves up to eight). Vision preparation stays serial; native decode runs concurrently. Each full media reservation stays charged through settlement, and video stays exclusive with other media.
- On by default; `DARKBLOOM_NEMOTRON_SUPER_CONCURRENT_IMAGES=0` (forwarded by the LaunchAgent) restores the 0.10.12 single-media admission.

### Configuration parsing no longer accumulates memory

- Reading the provider's configuration file no longer leaves memory behind each time; the provider uses a fixed copy of its TOML library.

### Tool JSON as Transformers renders it, on request

A chat request that carries `"_darkbloom_template_json": "transformers"` now
shows Qwen 3.5, 3.6 and 3.8, Ternary Bonsai 2, MiMo v2.6, GLM-5.3 and GPT-OSS
their tool declarations, earlier tool calls and tool results exactly as Hugging
Face Transformers renders their chat templates: members in the order the client
sent them, `", "` and `": "` separators, non-ASCII text and `/` as written,
`null` arguments and `strict` kept, and Python `True`/`None` where a template
prints a value with `string`. Before, they read sorted, compact JSON with
escaped non-ASCII text and without `null` arguments: on the Tau2 airline
prompts 523 to 666 tokens fewer than the reference. Nemotron 3.5 Lightning
takes the order. A request from the network asks only when the coordinator did
not plan it for its prompt cache, so a planned request always renders the
prompt of its plan. On the local API, `DARKBLOOM_TEMPLATE_JSON=transformers`
asks for every chat request. Media requests, batch requests, `/v1/responses`
and every request that does not ask render the same bytes as before;
`DARKBLOOM_TEMPLATE_JSON_LEGACY=1` turns it off.

### Updater version checks (security)

- The self-updater checks a release's version more strictly before it installs it. Details will be published after the fleet has updated.

## v0.10.12

Published 2026-11-12 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.10.12)).

### Upgrade and rollout notes

**Highlights**

Plain-language summary of provider 0.10.12. The full technical changelog, the pull requests and the build's
verification details are on this page too.

**Two-Mac pairs**
- Setting up a two-Mac pair is simpler, and a stopped pair starts again in its last mode.
- A pair only takes requests whose first word it can deliver in time.
- If one Mac of a pair drops out, the next request gets a clear error right away instead of hanging.
- A pair Mac that runs short of memory ends only that request; the pair keeps serving.
- A two-Mac pair that serves only you now restarts into the new version on its own after an update.
- Gemma 4 pipeline pairs serve the model's full 262K context.
- Gemma 4 tensor-parallel pairs serve 2 requests at once where memory allows; GLM-5.3 pairs serve as many as both Macs' memory holds.

**Speed and stability**
- Drafting models (Qwen 3.5 9B, Nemotron Lightning, Qwen 3.8) no longer run out of GPU resources under load.
- Long busy stretches no longer slow a Mac down (the 9B keeps 65 tokens/s after 15 busy minutes, where 0.10.11 fell to 9).
- Faster prompt reading and generation for Gemma 4; a faster first word for Qwen 3.5.
- Saving a prompt's cache no longer holds up the answer.

**Models**
- **Bonsai 2 27B reads prompts about 6.5x faster on a single Mac** (back to its pre-0.10.5 speed).
- Bonsai 2 27B generates at full speed again when two requests share a Mac.
- Gemma 4 26B (QAT) drafts with exact acceptance, so it falls into fewer reasoning loops; Gemma 4 also reasons with `tool_choice: none` and accepts deadline text while reading images.
- Qwen 3.8 drafts with exact acceptance on a single Mac; the Qwen 3.5 9B drafts and caches again; Qwen 3.5/3.6 cache hits are back.
- Nemotron Lightning uses plain decoding.
- Nemotron Super answers with JSON, tools and its settings alongside images and video, takes WebP, GIF and BMP images, and its prompt cache gives exactly the same answers.
- Nemotron Super: an image that arrives while the Mac is still answering another image waits up to 3 seconds for it, when its deadline allows, instead of bouncing to another Mac.
- GLM-5.3 answers in JSON with an image or video on one Mac, and an idle GLM Mac no longer looks full.
- MiMo: a slow step no longer disables MiMo for good, and a stalled MiMo engine stops taking requests.
- All models: answers that repeat themselves word for word stop early; `tool_choice: auto` returns tool calls as generated; nullable tool parameters accept `null`.

**Requests and refusals**
- A Mac tells the coordinator why it refused a request.
- Requests sent together are no longer wrongly refused as "memory" on a warm Mac.
- A Mac that can't hold an image or video right now says so clearly (`media_memory_unavailable`), and that refusal no longer makes the Mac look full.
- A request no longer waits forever behind the Mac's idle speed test, and stopping no longer waits for requests the coordinator abandoned.
- A Mac whose old, slow speed reading keeps making it refuse re-checks its speed with one short idle test (at most once per model every 2 minutes; never on battery; `DARKBLOOM_TTFT_REFUSAL_PROBE=off` turns it off).
- Models you selected reload automatically.

**The Darkbloom app and command line**
- `darkbloom start` serves Darkbloom and your local API without asking; `darkbloom local` serves only you.
- `darkbloom status` shows answers in progress, which early-ended requests are paid, and whether fan control is on; `status`, `doctor` and `verify` keep an older denial visible.
- `darkbloom status` also lists answers in progress on a Mac that serves only you.
- The models catalog and recommendations name the models this Mac could add, based on Macs with the same chip.
- A restart after an update no longer rolls the update back, and the watchdog restarts a provider job that macOS lost.
- Opt-in: answer before the cache save finishes.

- 0.10.12 makes two-Mac pairs sturdier and wider: a pair keeps serving when one of its Macs runs short of memory, a Gemma 4 pair's pipeline serves the model's whole context, and Gemma 4 and GLM-5.3-Flash pairs in tensor parallel serve more than one request at once where both Macs' memory holds them. The toolchain (Xcode 27.2, macOS 27.2 SDK), `libs/mlx` and `libs/mlx-swift` are 0.10.11's, so the GPU kernels (`mlx.metallib`) are unchanged; `libs/mlx-swift-lm` (Swift model code) moves to `ad8a5860e5`.
- **Behaviour changes to read first:**
  - **`darkbloom start` no longer asks how this Mac serves.** On a Mac with no saved choice it serves the Darkbloom network and this Mac's local API (Both), and Darkbloom keeps serving while you use the Mac; it saves that choice (`[local] mode = "both"`, `me_first = false`). Saved choices are never rewritten, so a Mac set to "Both, me first" keeps pausing. `darkbloom local` serves only you. Scripts and the desktop app's Start without its local API take the same default where nothing is saved (#2008).
  - **`darkbloom cluster` is simpler:** it no longer asks how the pair serves (always through Darkbloom, with the leading Mac's local API beside it, never pausing for new setups), picks tensor parallel or pipeline by itself for a new model (a pair's own model keeps its last mode, also when a stopped pair starts again; #2013), ends on one line ("✓ Serving <model> on both Macs", details in `darkbloom status`), and on a terminal waits for "Press Enter to exit." `darkbloom cluster local` still asks, for a pair only you use (#2007).
  - **Bonsai 2 27B on a single Mac reads prompts batched again, fast** (about 620 tokens per second on an M5 Max instead of about 100; 0.10.5 to 0.10.11 ran every prompt row through the one-row kernel). Two requests decoding together on a single Mac run per-row again, at full speed (#2028); prompts and three or more requests stay batched, and an answer can still depend on the requests beside it, as in 0.10.11. Pairs keep the per-row exact arithmetic, so both Macs compute the same bytes (#2022).
  - **Qwen3.5-9B has no default presence penalty and drafts with exact MTP acceptance:** its requests speculate and cache their prompts again; in the 0.10.12 gate it ran away on none of 31 draws under exact acceptance (13 of 31 under typical). The 35B Qwen builds keep the card's 1.5. A request's own `presence_penalty` still wins (#1961, back in with the SDK's shared-event fix, #2021).
  - **A pair keeps serving when one Mac runs short of memory partway through a request, in every pair mode** (tensor parallel and pipeline; Qwen 3.8 27B, Gemma 4, GLM-5.3-Flash, MiMo V2.6, GPT-OSS). That request alone ends, on both Macs, with one Mac's memory 503 (`request_exceeds_node_budget`); the next request is served. Before, the pair's worker exited and the pair was down for about a minute (0.10.11's known issue D6). Proven on the M5 Ultra pair with the real memory check.
  - **A Gemma 4 pair's pipeline serves the model's whole context** again: prompts up to 262,143 tokens and answers up to 32,768, as in tensor parallel and on one Mac (0.10.11 capped it at 65,536). Each Mac's memory check still decides, request by request, whether a long one fits now.
  - **More requests at once on a pair:** a Gemma 4 26B (QAT 4-bit) pair in tensor parallel serves 2 requests at once, and a GLM-5.3-Flash pair in tensor parallel the widest of 8, 6, 4 or 2 that both Macs hold beside the model (it said 8 on any two Macs before). Each Mac reserves that width when the model loads; if the memory isn't there at that moment, a GLM pair loads with fewer and takes more requests as memory allows.
  - **A pair takes the requests whose first token it can deliver in time, and only those.** Once a pair had measured how fast it reads prompts, 0.10.11 could turn away every Darkbloom request as "deadline unreachable". It now estimates each request's first token from its own measured speed and the prompts it is still reading.
  - **Typed refusals:** a pair's API that is starting or stopping answers every request, the first included, with a 503 `pair_api_unavailable` and `Retry-After: 10`; an image or video sent to a model that doesn't take it is refused with `unsupported_media`; a video or audio decode fault is a retryable 503 with the reason `media_memory_unavailable`, which no longer marks the Mac's token budget as full.
  - **Updates and the watchdog:** a `darkbloom restart` (or `stop` then `start`) you run in the first 10 minutes after an update no longer counts as a failed start, so it can't roll the update back; a crash, a hang or a reboot still counts. The watchdog brings back a provider job that launchd lost while it was enabled, and says in `~/.darkbloom/watchdog.log` when something restarts the provider so often that a new release is never promoted.
  - **Selected models come back by themselves:** a model you selected that didn't fit at start, or that an Autopilot operation unloaded, is retried when memory frees, never by evicting another selected model. Ten minutes after it began waiting, a model outside your selection that keeps it out only by serving Darkbloom requests finishes its requests and is unloaded. `darkbloom stop`, `restart` and `start` no longer need `--force` when a model's unload never finishes.
- **A GLM-5.3-Flash Mac no longer reads as full while it serves nothing:** its heartbeat reports only the requests it holds, not the memory its engine keeps for reuse (which grew to 90–99 % and turned most GLM requests away from idle Macs), and a request waiting behind another's prompt counts once (#1964).
- **Nemotron Super with images and video** serves JSON output (`json_object`, `json_schema`), tools and `tool_choice`, as with text, and takes WebP, GIF and BMP under any image label; other formats are refused as `unsupported_media` (#1922, #1962). The coordinator sends media with JSON or tools only to Super Macs on 0.10.12.
- **No more stuck MiMo requests behind the idle speed check:** a request that arrives during the check stops waiting when cancelled, and after 30 s is refused as busy so Darkbloom sends it elsewhere; while the check is overdue the model reads `crashed` and gets no new requests (#1966). `darkbloom stop`, `restart` and `update` no longer wait out requests the coordinator already cancelled (at most 30 s after the cancel) (#1968).
- **A MiMo slot whose engine stops stepping stops taking requests (#1967):** an engine whose native work failed reads `crashed` at once, and a native MiMo slot whose queue holds work with nothing running reads `crashed` after 30 s, so Darkbloom routes around it and the slot is retired.
- **Gemma 4 26B QAT drafts with exact MTP acceptance** by default: each committed token is the model's own draw, so its outputs follow the model's distribution (exact in distribution, not bit-identical to decoding without MTP), at a speed cost of about 0–4 %. Only the catalog `gemma-4-26b-qat-4bit` changes; every other model keeps its rule, and `mtp_acceptance_by_model` with `"gemma-4-26b-qat-4bit" = "typical"` restores the old one (#1974).
- **An answer that repeats itself word for word stops early, as `length`:** after about 2,000 repeated tokens instead of running to its output limit (up to 131,072 tokens), so the Mac is free sooner; only exact repetition counts, never in an answer's first 4,096 tokens, and tool calls and JSON answers are never cut. On by default, Nemotron Super's text requests included; `DARKBLOOM_LOOP_GUARD=0` turns it off (#2005, #2020; window 16).
- **GLM-5.3-Flash answers a JSON `response_format` with an image or video on one Mac**, as its text JSON mode does; before, every such request was a 400 (#2009). A pair still refuses it.
- **Qwen 3.5/3.6 requests that can't speculate cache their prompts again** (a penalty, a `stop` string, logprobs, `logit_bias` or a token constraint): they record the MTP head's prompt history and save the same prefix checkpoints a speculating request saves, so the 35B builds, which keep the card's penalty, cache again (#1965 with mlx-swift-lm #398; window 8b: exact, memory accounted and capped).
- **Nemotron 3.5 Lightning serves plain decode under `mtp_mode = "auto"`:** its MTP head sped up only a lone request and halved decode beside a second one; plain decode keeps production's throughput (#1969, window 7).
- **A Mac whose old, slow speed reading keeps making it refuse re-checks its speed:** after three refusals in a row that only the stale reading explains, it runs one short idle test of its own (at most once per model every 2 minutes, never on battery) and prices the next request from the new reading, instead of refusing for up to 30 minutes. No customer request is risked: none is admitted without a time estimate. `DARKBLOOM_TTFT_REFUSAL_PROBE=0` turns it off (#2024, #1956 reworked).
- **`darkbloom status` lists the answers in progress on a Mac that serves only you** (`darkbloom start --local`), as on a Mac that serves Darkbloom; a pair that serves only on its local API still lists none (#2030).
- **A two-Mac pair that serves only you restarts into the new version on its own after an update:** the first part started from the newer release restarts the pair's cluster service once, before it takes a request (before, the service kept the earlier release until the next login) (#2033).
- **Nemotron Super: an image that arrives as the previous image finishes waits for its cleanup** (up to 1 s) instead of being refused with 429 `queue_full` and sent to another Mac. Super's slot serves up to 8 requests at once; only images go one at a time. Memory use is unchanged (#2029).
- **Nemotron Super: an image that arrives while another image's answer is streaming waits for the slot** (up to 3 s, and never past the time its first token needs), instead of being refused and sent to another Mac. Only one request waits at a time and it reserves no memory, so two images are never in memory at once; text never waits (#2035).
- **Drafting models no longer use up Metal shared events while several requests decode:** each decode step of two or more requests together left one event alive, and after roughly 15–50 minutes of such a stretch the provider could abort (`Failed to create Metal shared event`). This hit Qwen 3.8 by default, the Qwen 3.5/3.6 builds with `presence_penalty: 0`, Lightning and Qwen4 Flash-Next. Tokens and drafts are unchanged (mlx-swift-lm #404, #2021).
- **Paged decode stays fast on a busy Mac:** freed KV pages no longer scatter new requests' pages over many segments, so decode keeps one attention pass per layer instead of slowing to 0.30–0.40× its fresh speed a few minutes into a busy run (the 9B in production); outputs are unchanged (mlx-swift-lm #403, #2021).
- **A Gemma 4 pipeline checks its whole number of requests at load:** a setup that saves several requests at once (2, 4 or 8) serves that many only if each Mac holds them all beside the model, and refuses the load otherwise; one without a saved number serves one at a time (it served four unchecked). Pipelines set up by `darkbloom cluster` keep one chunk of lookahead and one request at a time (#1937 via #2015).
- **Small local requests sent together are no longer refused as "memory" on a warm Mac:** at the fallback width (heat or Low Power Mode) a streamed request waiting for its first token counted twice, so the third or fourth of four got a 503 with most memory free (#2018).
- **A media request this Mac's memory can't hold now is refused as `media_memory_unavailable`** (it was `capacity_busy`), so Darkbloom sends it to another Mac without counting this Mac as full (#2019).
- **`darkbloom status` shows the answers in progress:** model, running time, output tokens, current speed and a short request hash (never the prompt or answer); `--json` has the same list. A Mac writing long answers no longer looks hung (#2017).
- **A refused request tells the coordinator why:** the `inference_error` frame carries `refusal_reason` and a fixed `refusal_message` (no request text; the requester's error is unchanged), and Qwen tool conversations name the check that refused them (#2016).
- **A stream that stores its prompt's checkpoint no longer waits for row-by-row coding:** the SSD checkpoint export reads rows in batches and codes them on up to four cores, so the end of a stream (and its terminal) comes much sooner; the checkpoint bytes are unchanged (#1971, window 7).
- **Gemma 4's MTP assistant upgrade no longer races the serving engine:** attaching the assistant to a model that already serves reuses the KV types observed at load instead of running a forward, which could crash the provider ("Attempting to eval an array without a primitive") when a request arrived during the upgrade (#1985, window 8b).
- **A long MiMo prefill no longer trips the engine watchdog:** a native MiMo step may run up to 120 s (the engine's prefill progress lease) before the watchdog seals the engine, instead of 30 s, so slower Macs (M3 Ultras take three to four times an M5 Ultra's 15.6 s at 170k tokens) finish long prompts; a step that never returns is still caught (#1989; window 8c: sealed at the limit under a 5 s override, a 170k prefill with no crash, identical output).
- **`darkbloom status` lists early-ended requests by cause, paid or unpaid** (#1980). The causes are exact once the coordinator sends the reason, which it does from the coordinator update of 11-11. One known gap until platform #792 ships: an owner's own request stopped mid-answer shows as "paid".
- **Nemotron Super's prompt cache restores exactly:** it saves native-precision prefix checkpoints, so an answer from a cached prompt is the answer the same prompt gets without the cache; checkpoint files are about 15 % larger, and older Super checkpoints are skipped and age out within 30 minutes (#2002; window 11: 3/3 prompts exact).
- **Qwen 3.8 27B drafts with exact MTP acceptance on single Macs** (#1999): its outputs follow the model's distribution (exact in distribution, not bit-identical to decoding without MTP). It costs about 4–5 % decode speed while a Mac serves one Qwen 3.8 request at a time and nothing with several; pairs are unchanged (they were already exact). `mtp_acceptance_by_model` with `"EigenLabs/Qwen3.8-27B-4bit-mtp" = "typical"` restores the old rule (window 8d: acceptance 0.73 vs 0.89–0.90, text matches MTP-off, no loops).
- **Gemma 4 no longer turns away text requests while an image request is being answered;** it still waits while the image is read in (mlx-swift-lm #402; window 12: text beside a decoding image admitted 16/16 within its deadline).
- **Tool calls under `tool_choice: auto` come back as the model wrote them**, as with OpenAI, instead of failing the request; strict, required and named tools are still checked. A refusal's error frame names the check that failed (`tool_check`) (#2003; window 13).
- **Faster first tokens and tool calls (the SDK, `libs/mlx-swift-lm` `093563be11`):** a Gemma 4 prompt's cold first token is about 7 % sooner on M5 Macs, with exactly the same output (row-mapped NAX prefill, on by default; `DARKBLOOM_GEMMA4_NAX_ROW_MAP=0` turns it off); a Qwen 3.5-family first token is 10–12 % sooner under MTP for requests that send `presence_penalty: 0`; a tool parameter declared nullable now takes `null`. An opt-in early response before the SSD checkpoint write finishes ships off by default (`DARKBLOOM_PREFIX_CACHE_SSD_TERMINAL_BEFORE_PUBLICATION=1`).
- **Smaller changes:** `darkbloom models catalog` ends by naming up to three models this Mac could select but hasn't downloaded, with their size (print only; `--json` unchanged; #1957); a pair's planner can't run out of stack (planning runs on its own 16 MiB thread); a pair's leading Mac backs off (30 s up to 10 min) while the other Mac is away and starts at once when it answers; `darkbloom status` says whether fan control is on, and keeps an older authorization denial visible (as do `doctor` and `verify`); truer words on a paired Mac after `cluster leave` and in `doctor`, and the split question names each mode's context; Gemma 4 reasons with `tool_choice` `none`; the desktop app recommends models from what Macs with the same chip earn.
- **Known issues (none blocks this release):**
  - On a Mac of 48 GB or less, a very long Gemma 4 pipeline request can get the memory 503 partway through its prompt (past about 190,000 tokens at 48 GB, about 85,000 at 36 GB), for that request alone.
  - A GLM-5.3-Flash tensor-parallel request that ends at its first token for memory can leave its prompt's stored prefix on the other Mac until it is evicted; it is never served stale.
  - After `darkbloom update --rollback` to 0.10.11, a Gemma 4 or GLM pair set up on 0.10.12 must run `darkbloom cluster` again: 0.10.11 can't read the saved width.
- Pair owners: both Macs of a pair must run the same version; a pair on 0.10.11 updates itself at its slot, or at once with `darkbloom update` on each Mac. `darkbloom update --rollback` puts back 0.10.11.
- Pairs still on 0.10.10 stop serving through Darkbloom once 0.10.12 registers, until they update (0.10.12 and 0.10.11 hold 24 pair approvals each, the coordinator keeps 64).
- The registration keeps 0.10.11's fields; its cluster runtime facts change where the modes do: Gemma 4's pipeline qualification serves the whole context again, and the tensor-parallel widths follow each Mac's memory. Deploy the coordinator that ships with 0.10.12 first.
- The 68 entries below are the pending fragments rendered verbatim, except where the release notes reword one; CI-only entries change no provider behaviour.

### `status`, `doctor` and `verify` keep an older denial visible

- A provider's last coordinator authorization was shown only while it was at most 10 seconds old. An App Attest lease already stayed visible until it expires, but an older `none` (a denial) or `legacy` report vanished from `darkbloom status`, `doctor` and `verify`, so a Mac the coordinator had denied could look healthy. Such a report now stays visible as dated history: `Last reported authorization: received 10m ago; not a fresh dispatch grant. …` in `status`, and a `last reported authorization` line in `doctor` and `verify`, INFO for legacy and WARN for a denial.
- History never stands in for a current grant or the public proofs: it offers no MDM removal or migration, and `doctor` and `verify` still run the trust and public attestation checks after it. `darkbloom verify` now fails on a WARN or FAIL line, not on an INFO line.

### Bonsai 2 27B processes prompts at full speed again on a single Mac

- Since provider 0.10.5, a single Mac ran every prompt row of Bonsai 2 27B through the one-row kernel. That kept each row's arithmetic identical to decode, but made prompt processing 2.3 to 6 times slower than in 0.10.4: about 100 tokens per second on an M5 Max instead of 620, and about 76 to 96 instead of 220 on M1 to M4 Macs. Image and tool prompts of 1,000 to 2,000 tokens or more then missed their first-token deadline, and OpenRouter saw 429s.
- Now a single Mac processes a Bonsai 2 27B prompt with one batched matrix multiply per projection again, as in 0.10.4 (TF32 on M5, FP32 elsewhere). Prompt rows are no longer bit-identical to the decode arithmetic, as before 0.10.5. A request decoding alone is unchanged. When several Bonsai 2 27B requests decode at once on one Mac, a request's exact output can depend on the requests decoding beside it, as in 0.10.11; two requests decoding together run per-row at full speed (see the next entry).
- Pairs keep the per-row arithmetic for prompt and decode rows, because both Macs must compute the same bytes. Their arithmetic receipt (`bonsai-fp32-row-arithmetic-v2`) is unchanged.
- `libs/mlx-swift` moves to `1b3520fe94` (Layr-Labs/mlx-swift#70, on the fork's `release/provider-0.10.12` = the previous pin `c633d221d6`). Only Swift sources change there, so `mlx.metallib` is unchanged.

### Two Bonsai 2 27B requests decoding together run at full speed again on a single Mac

- With prompts batched again (#2022), a single Mac also ran each decode step of several Bonsai 2 27B requests as one batched matrix multiply. At two requests on an M5 Ultra that was 9.5 % slower than 0.10.11's one-row kernel (71.1 against 78.6 tokens per second, steady state).
- Now two requests decoding together on a single Mac are computed row by row again, as 0.10.11 computed them on every Mac, and run at full speed again (78.6 tokens per second on the M5 Ultra). Prompts and decode steps of three or more requests stay batched: batched prompts are 6 to 7 times faster than 0.10.11 at 1K to 8K tokens, and from three requests batched decode is as fast or faster (116.0 against 107.3 tokens per second at four).
- A request's exact output can still depend on the requests decoding beside it, as in 0.10.11. Pairs are unchanged.
- `libs/mlx-swift` moves to `b1c94d29c5`, the merge of Layr-Labs/mlx-swift#71 into the fork's `release/provider-0.10.12`. Only Swift sources change there, so `mlx.metallib` is unchanged.

### A stream that stores its prompt's checkpoint no longer waits for row-by-row coding

- When a request's prompt checkpoint is written to the SSD prefix tier at a quantized checkpoint precision (`balanced`, the default), the response's terminal waits until the checkpoint is written. Writing it read the checkpoint's attention rows one row at a time and coded each on one CPU core. On GLM-5.3-Flash every read also rechecked the native binding, so on an M5 Ultra the stream stayed open 63 s after a 200k-token prompt's last token and 17 s after a 57k-token one; in production on 0.10.11, Gemma 4 26B requests with 4–32k-token prompts waited a median 1.2–1.6 s, GPT-OSS 20B 8–32k 1.7 s and GLM-5.3-Flash ≥ 128k 51 s, and the Mac kept the request's memory reserved meanwhile.
- The export now reads a head's rows in batches of up to 256 KiB, codes each batch on up to four cores (a quarter of the Mac's active cores) and rotates eight lanes at a time. The checkpoint's bytes are unchanged, so restores and their answers are exactly as before. CPU coding cost per 512-wide row falls from about 3 µs to about 0.6 µs on an M5 Ultra.

### CI: a Darkbloom Sandbox without the Darkbloom cache uses no Actions cache

- On a Darkbloom Sandbox that the plane gave no Darkbloom cache, `actions/cache` read and wrote GitHub's own Actions cache through the gateway. A `master` push on 2026-11-05 (job 127018716621) saved `.git`, a 1.69 GiB Swift build, the SwiftPM repositories and a Metal library to the `refs/heads/master` scope; `dev` pushes on 2026-11-07 and 2026-11-09 saved `.git` to `refs/heads/dev`.
- Each routed job that uses a cache now first runs `Choose this job's Actions cache`. On a runner named `darkbloom-*` without `DARKBLOOM_CACHE_URL` it sets `CI_ACTIONS_CACHE=off`, and every `actions/cache` step and `actions/setup-node` cache then skips. Darkbloom jobs with the plane's cache, Blacksmith and GitHub-hosted jobs, and the Blacksmith-only release workflows keep their caches.
- A restored `.git` is now discarded, before any git command reads it, if it is not a directory, holds a symbolic link or any hook but git's samples (also in `.git/modules`), or has a config that sets `core.fsmonitor` or `core.hooksPath` or includes another file. This holds on every runner.

### CI: every Cluster GPU Tests shard asks Darkbloom first

- Each of the 3 Cluster GPU Tests shards now asks the Darkbloom plane for a sandbox on a lane of its own (`test-cluster-gpu-1`, `test-cluster-gpu-2`, `test-cluster-gpu-3`; 4x24 while sizes are on). Each falls back alone to `blacksmith-12vcpu-macos-27` when the plane does not grant it. A lane routes only when the approval's `lanes` names it; on 2026-11-10 it named `test-cluster-gpu-1` and `test-cluster-gpu-2` but not `test-cluster-gpu-3`.
- Shard 2 no longer needs 42 GiB. The paged verify/prefill attention bench (`paged-verify-bench`) bounds MLX's freed-buffer cache to 1 GiB, as a ready Qwen tensor-parallel rank does. Before, the cache kept every prompt chunk's attention temporaries, and the bench's process reached 34.26 GiB. The bench also prints its peak active memory and cache size for each run.
- A full CI run now asks for 15 macOS jobs instead of 14. The GPU lanes come last in the lane table, so the `DARKBLOOM_MACOS_LANES` cap drops them first.

### CI: the MiMo audio codec download resumes instead of starting over

- The provider's last unit-test shard downloads the 1.87 GB pinned MiMo audio codec when the runner's Darkbloom cache has no copy, which happens on some runners and not others. curl's own retries restarted every attempt from the first byte, so on a link of about 2 MB/s no 900 s attempt finished: CI run 43132089921 got 1.60 and 1.79 GB and failed after 30 minutes, and other pull requests' runs hung in the same step until cancelled.
- `scripts/prepare-mimo-audio-fixtures.py` now makes up to eight attempts per file, each resuming the partial file (`--continue-at -`), with a growing pause between them. Each attempt ends after at most 900 s and never past 45 minutes from the first, so the step gives up within 45 minutes. A server that ignores the range request makes the next attempt start over, and a file whose digest is wrong is deleted, so no later run resumes it. The same script prepares the codec in the release build's qualification lane. `scripts/test-prepare-mimo-audio-fixtures.py` checks this offline.

### CI: the cluster qualification checks build with the job's selected Xcode

- `libs/darkbloom-cluster-worker/Tests/QualificationChecks/run.sh` now uses the Xcode and SDK the job's toolchain step selected (`PROVIDER_SDKROOT`), so it no longer fails on a runner whose default developer directory is the command-line tools (`SDK "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk" cannot be located`). Local runs keep `xcrun`'s own selection. CI only; no provider behaviour changes.

### Provider CI: smaller job sizes for the cluster runtime shards

- The cluster runtime tests that drove the shards' memory now run with MLX's freed-buffer cache bounded: 4 GiB for the GLM-5.3 paged KV, row invariance, depth invariance and window census tests and Qwen's prefix-depth test, 1 GiB for the Gemma 4 paged synthetic stages and the GLM-5.3 prefix SSD restore. MLX's default cache kept every prefill frame's temporaries, which no later request reuses. The bound changes no result, no assertion and no shard's time.
- Peak used memory: Cluster Runtime Tests shard 2 from 26.51 to 14.64 GiB, shard 3 from 13.21 to 10.71, shard 5 from 15.33 to 11.48 (the largest sample before and after).
- While `DARKBLOOM_JOB_SHAPES` is `on`, the lane of runtime shards 2 and 3 (`test-cluster-2`) asks for 4x24 instead of 12x32, and the lane of shards 4 and 5 (`test-cluster-3`) for 4x16 instead of 4x24. The other lanes keep their sizes; `docs/developer/build.md` (Job sizes) has each job's sampled memory from 20 full dev runs.

### CI: the desktop review package asks Darkbloom first

- The manually dispatched Desktop App job that builds the unsigned macOS review package (`unsigned-desktop-review`) now asks the Darkbloom plane for a sandbox Mac on lane `desktop-package`. It falls back to `blacksmith-12vcpu-macos-27` when the plane does not grant it.
- The job is renamed from `review-package` to `desktop-package`, so that its lane has the job's name, as the lane of every unsharded routed job does.
- Pull requests and pushes do not ask for this lane: the job runs only on manual dispatch.

### Simpler two-Mac cluster setup

- The first Mac's last line while it waits is set apart and stressed: "→ Now run `darkbloom cluster` on the other Mac" (`darkbloom cluster local` names its own command).
- `darkbloom cluster` no longer asks how the pair serves: it always serves through Darkbloom with the leading Mac's local API beside it, and Darkbloom keeps serving while you use that API: once the pair switches, starts or is shown serving, the leading Mac saves `[local] mode = "both"` and, where no `me_first` is saved, `me_first = false` (a run that changes nothing saves nothing; a pair already serving Both with the pause on keeps it until its next start, and the screen says so). To have Darkbloom pause for you again, set `[local] me_first = true` on the leading Mac and run `darkbloom restart`. A pair saved as Only me or as the Darkbloom network alone switches when `darkbloom cluster` runs and says so in one line; `darkbloom start`, an update or a restart never changes how a pair serves. "Change how the pair serves" is gone from the menu; `darkbloom cluster local` stays the local-only command.
- Where a pair can't serve through Darkbloom (no login, no approval), the screen says "To use the pair just for yourself, run `darkbloom cluster local`." instead of offering "Serve locally only".
- `darkbloom cluster` chooses tensor parallel or pipeline by itself for a new model: tensor parallel unless it can't run on these Macs or this pair measured it slower. A pair's own model keeps the mode it last served in, also when a stopped pair starts again. The model list no longer shows modes. `darkbloom cluster local` still asks, with the same choice tagged Recommended and preselected (the pair's own model preselects the mode it last served in).
- A start ends on one standout line, "✓ Serving <model> on both Macs" (locally: "…, on your local API at http://localhost:<port>"), and "`darkbloom status` for details", the same on both Macs. The pair's card (log, login, commands) is in `darkbloom status`.
- On an interactive terminal, both Macs end with "Press Enter to exit." (q and Esc too); `NO_COLOR`, `TERM=dumb`, pipes, `CI` and runs without a terminal never wait, and the screen's lock is released first, so another `darkbloom cluster` or `start` isn't refused. The pair keeps serving.

### A two-Mac pair takes the requests whose first token it can deliver in time, and only those

- Once a pair had measured how fast it reads a prompt, it turned away every Darkbloom request as "deadline unreachable", even one it could serve at once. Darkbloom sends a first-content deadline with every request, and the pair estimated no first token at all.
- Now the pair estimates each request's first token from its own measured prompt speed, behind the prompts it is still reading for the requests it already holds, since it reads them one after another. It takes a request whose first token comes in time and turns one away at once when it would not, so Darkbloom sends it to another Mac. Before, eight long prompts arriving together were all taken, and the last waited about a minute for its first token.

### A pair's first answer after the other Mac's part stops is its typed 503, at once

- When the part of the pair on the Mac that runs the pair's API stops or starts again (a stop, a restart, an update, a
  crash) while that Mac stays on the cable, every request, the first one included, now gets a `503` with `code`
  `pair_api_unavailable` and `Retry-After: 10` at once, on that Mac and through the other Mac's port alike. Before, the
  first ones got `{"error":{"type":"invalid_request_error","message":"Provider capacity is temporarily unavailable."}}`
  with no code, once after 19 seconds. The pair's API now answers "The pair's API takes no requests right now: the pair
  is starting or stopping. Requests resume when it serves, …" while its pair doesn't serve, never holding a request until
  it does, and a request made during the pair's warm-up request is refused at once instead of waiting for it.
- Both `503`s a pair's other Mac answers (`pair_mac_unreachable` and `pair_api_unavailable`), and the pair's API's own,
  now end the same way: "…, or run `darkbloom stop`, then `darkbloom start --solo`, to serve this Mac alone (`darkbloom
  start --solo` by itself is refused while this Mac's part of the pair holds its serving lock: up to 15 minutes after
  the other Mac last answered over the cable)."
- Through the other Mac's port, a key it can't judge (another key in the local key format, such as the leading Mac's
  own, which works through it while that Mac is there) gets the same `503` without the other Mac's name, instead of a
  `401`. A missing key, one without `Bearer`, or one that isn't a local key still gets the `401`.
- While the pair's API on the leading Mac starts again, the other Mac's port stays up and answers those `503`s, instead
  of refusing connections until that API is back, and its `darkbloom status`, `darkbloom local` and `darkbloom doctor`
  say "Local API: http://127.0.0.1:<port>/v1 on this Mac answers 503 for now." with the `503`'s words, instead of "not
  listening on this Mac yet".
- A local request waiting for one of the pair's lanes when a stop or an update begins gets the same `503`, instead of a
  `429`. A request without a key that reaches the pair's API while it stops gets the API's `401`, instead of a `503`.

### A pair's leading Mac starts its part less often while the other Mac is away

- While the other Mac of a pair doesn't answer (asleep, off, its cable out), the leading Mac keeps its part ready for 10 minutes so the pair re-forms when that Mac is back. Its part can't form the pair meanwhile, and each start reads its share of the model and registers with the coordinator again. A part that ended was started again every 30 seconds (every 48 seconds for a MiMo leader whose other Mac slept). It now waits twice as long as the last time, from 30 seconds up to 10 minutes (30 seconds, then 1, 2 and 4 minutes), and starts at once when the other Mac answers. While the other Mac answers, a part that keeps ending starts again as before (6, 12, 24, then every 30 seconds).
- `darkbloom cluster status` on the leading Mac says when, under the line that it waits for the other Mac: ``This Mac's part starts again in 4 min, or as soon as the other Mac answers: while the other Mac is away, each start waits twice as long as the last, up to 10 min.``

### A pair's cluster service runs the installed release after `darkbloom update`

- A pair that serves only on its local API (or a Mac whose cluster service
  serves alone) kept its cluster service on the earlier release after
  `darkbloom update` on both Macs: the service's supervisor does not drain
  such a pair for an update, so it never restarted into the installed
  release, and `darkbloom restart` restarted only the pair's parts (0.10.12
  W1). The parts ran the installed release; the service's own changes, and
  the version it reports to the other Mac, waited for the next login.
- Now the first part the service starts from a newer installed release
  restarts the service's launchd job once, before it takes a request: the
  pair stops on that Mac and starts again on the installed release, as after
  a login. Only for the build's own job, only when its supervisor runs an
  older release than the part, and once per release in 6 hours; the part's
  log says so (`cluster part: this Mac's cluster service still runs …`). It
  runs in the parts of this release, so it also covers the update to it.

### A stopped pair keeps its last mode on restart

- `darkbloom cluster local`, and `darkbloom start` in a terminal on a pair that serves locally, preselect the mode the pair's own model last served in when its mode question comes up, so Enter starts a stopped pipeline pair as a pipeline again instead of switching it to tensor parallel. The **Recommended** tag stays on the automatic rule's pick; when the last mode is the recommended one, nothing changes. `darkbloom cluster local <its model>` starts the pair's own model in that mode too; a new model still gets the automatic rule.

### Three deadline refusals on a stale prefill estimate re-measure the Mac

- A `deadline_unreachable` refusal admits nothing, so it measures nothing. An idle Mac with no calibration anchor, whose prefill measurement was slow and is now older than 120 seconds, could go on refusing from it for up to 30 minutes.
- After three refusals in a row that the stale estimate explains, the provider re-runs its idle calibration probe once: one uncached 512-token request of its own, alone, only while the Mac is idle, at nominal posture and on AC power. Any customer request preempts it. Its measurement replaces the estimate and the anchor, and the next request is priced from it. A loaded model probes at most once every 120 seconds.
- It never runs on battery, with or without Low Power Mode; a full streak waits for AC power. The startup calibration is unchanged.
- Only refusals the stale estimate explains count: the Mac was idle, the projection priced nothing but that request's prompt, the estimate was older than 120 seconds with no fresher measurement for that prompt size, it was below the calibration anchor if there is one, and the request still had at least 5 seconds left. Refusals at a fresh rate, late retries, refusals beside other work or for memory or capacity, reviewed calibrations, native-media requests and native block engines (which keep their own recovery probe) don't count.
- A customer request is never admitted without a time projection because of these refusals, so none is admitted that is already out of time. The provider logs one line when the probe starts (`Deadline refusals: <model> re-measures stale prefill evidence with one idle probe …`).
- No wire field changes. `DARKBLOOM_TTFT_REFUSAL_PROBE=0` turns the probe off on its own, and `DARKBLOOM_TTFT_ADMISSION_FIXES=0` turns it off with the other estimator corrections. Both reach the launchd provider job.

### Recommended models from Macs with the same chip

The desktop app's "Recommended for your Mac" now ranks models by what Macs with
the same chip earned per day from each model over the last 24 hours (the typical
Mac first, then the average), when the coordinator publishes those figures in
`/v1/stats` `model_earnings[].by_chip`. Network-wide 7-day totals favor models
that many fast Macs serve, which can pay a slower Mac nothing. Without per-chip
figures, or when they cover no model this Mac can serve, the ranking falls back
to network totals as before.

### Stopping no longer waits for requests the coordinator abandoned

- Before, `darkbloom stop`, `restart` and `update` waited for every accepted request to finish, including requests the coordinator had already cancelled because their client left or their first token was late. A request stuck behind a stalled engine never finished, so the drain timed out after its full deadline and asked for `--force`.
- Now a request the coordinator cancelled counts for at most 30 s after the cancel. Its answer has nobody to go to; if its task has not ended by then, the drain stops waiting for it. Memory and eviction still treat it as in flight until it ends, and a native MiMo slot still retires only after its last request.

### A Gemma Mac decoding an image request accepts deadline text again

- A Gemma 4 Mac refused every text request with a first-content deadline (`deadline_unreachable`, profile reason `multimodal_work`) while an image or video request was anywhere in its engine, including the image's whole decode, which is about 98 % of its time there. On OpenRouter this was 0.9–1.8 M refused attempts a day on 11-08..11-10, almost all on M5 Macs, and 16–59 K requests a day ended as 429s.
- The SDK now refuses only while the image request still has prompt work (until it has sampled from its whole prompt). After that its decode is priced like any other decode row, so the text request is admitted when its first token fits the deadline. Image requests themselves, other models' media (all causal) and text-only engines are unchanged.

### Gemma reasons with `tool_choice` `none`

- A Gemma 4 request with `tool_choice` `none` and reasoning on could not open its thought: the sampler that keeps tool calls out also masked Gemma's reasoning delimiters, `<|channel>` and `<channel|>`. Such a request now reasons and answers as it does without `tool_choice`; before, it could repeat until it hit its output limit. Tool-call markers stay refused, and required or named `tool_choice` is unchanged.

### A Gemma 4 pair's pipeline serves the model's whole context

- A Gemma 4 26B pair in the pipeline now accepts prompts up to 262,143 tokens and up to 32,768 output tokens within 262,144, as in tensor parallel and on one Mac. Before, its pipeline served the 32,768 + 32,768-token request (65,536 tokens). A pipeline Mac whose memory refuses a running request ends only that request. Each Mac's memory gate still decides, request by request, whether a longer one fits now. With lanes (a setup that prefills serially), the gate decides when the request starts, and a long request can still be refused partway through its prompt when the Mac runs short.

### A Gemma 4 pipeline checks its whole number of requests at load, and serves one at a time without one

- A Gemma 4 pipeline set up by `darkbloom cluster` still reads each prompt with one chunk of lookahead and serves one
  request at a time. Serving several at once needs it to read each prompt one chunk at a time, and on two M5 Ultras a
  long prompt alone then started its answer about 1.9 times later, so the setup keeps the lookahead.
- A pipeline whose setup saves one-chunk-at-a-time reading and a number of requests at once (2, 4 or 8) serves that
  many. Each Mac now checks at load that the whole number fits beside the model, each request charged its whole state
  at the standard request (32,768 prompt plus 32,768 output tokens), and refuses the load if it does not: "Resident
  load refused: N requests at once, each of C context tokens, do not fit on rank R now". Before, the load checked one
  request. A Qwen 3.5 or Gemma 4 pipeline widened automatically on a local pair is checked the same way.
- A pipeline set up to read prompts a chunk at a time without a saved number now serves one request at a time. Before,
  it served four, which nothing had checked its memory for.
- Each request still gets exactly the tokens it gets alone. A request cancelled or refused for memory ends alone, and
  the others keep running.

### Gemma 4 tensor parallel serves 2 requests at once where both Macs' memory holds them

- A Gemma 4 26B pair in tensor parallel served one request at a time. Through Darkbloom, every request beyond the
  one it served was turned away as "at capacity".
- Now the setup sizes the QAT 4-bit pair the way it sizes Qwen 3.8 27B's tensor parallel: it serves 2 requests at
  once where both Macs can hold them now beside the model. Each request after the first is charged everything one
  request holds at the standard request (32,768 prompt plus 32,768 output tokens), about 2.6 GB on each Mac, and each
  Mac reserves that width when the model loads, the planner counting that reservation while the model is read.
- Why 2: on two M5 Ultras every request got its own tokens at 2, 4 and 8 at once, but each request was served fastest
  at 2 (77 tok/s each and 95.5 in all, against 48.5 and 96.2 at 4). The 8-bit model still serves one request at a
  time; nothing has qualified its lanes yet.
- The setup screen and the number the pair reports to Darkbloom are the same width. Where only one request fits,
  the pair saves no width and serves one request at a time, as before.
- Each request still gets exactly the tokens it gets alone. A request cancelled or refused for memory ends alone,
  and the others keep running.

### Gemma 4 compiled feed-forward dispatch

Adopt the native SDK's shape-specialized feed-forward graph for eligible Gemma 4
GPU decode and verification rows. A matched single-request M5 Max endpoint
comparison with 8K cached context measured a further 2.5–3.2% decode-proxy gain
over the prior dispatch change. Parameter updates, eager fallbacks and existing
attention, MTP, admission, prefix-cache and SSD-write behavior are preserved.
Broader concurrency and other-chip gains remain unqualified.

### Gemma 4 native dispatch efficiency

- Adopt the SDK's shared dense GeGLU reuse for eligible Gemma 4 models, preserving numerical expressions, parameter contracts, paged attention, prefix caching and SSD write policy. Gemma 4's decode command-buffer limits are unchanged by this entry.
- An initial warm 8K, single-request endpoint screen on one M5 Max measured a 3.5–3.9% decode-proxy improvement with matching outputs, together with an earlier scoped command-buffer limit that has since been replaced, so the gain is not attributed to the GeGLU change alone. Broader concurrency, prefill, clustering and other hardware remain unmeasured; memory and admission safeguards are unchanged.

### Gemma 4 row-mapped NAX prefill

Adopt the native SDK's shared plain-greedy metadata shortcut and guarded Gemma 4
row-mapped NAX prefill route, enabled by default within its existing hardware,
shape and evaluation guards. Exact `DARKBLOOM_GEMMA4_NAX_ROW_MAP=0` restores the
original graph, with the override forwarded when creating a LaunchAgent job.
Same-app M5 Max comparisons in both orders measured 6–7% lower cold HTTP time to first generated
frame for uncached 4K/8K single requests, with exact paired outputs. A longer
warm decode control was neutral. These are not additive speedups or concurrency,
other-chip or clustering claims; attention, MTP, admission, prefix caching and
SSD-write policies are unchanged.

### A GLM-5.3-Flash Mac no longer reads as full while it serves nothing

- A GLM-5.3-Flash Mac's heartbeat now reports as used only the requests it holds, as its own admission charges them. It used to report the memory its engine keeps after every request and reuses for the next, which grew to 90–99 % of the budget, so Darkbloom turned most GLM requests away while the Mac sat idle. A GLM Mac can now take as many requests at once as its memory admits.
- A GLM request waiting for another's prompt to finish is now counted once. It was counted twice on this Mac's own API, so a 256 GB M5 Ultra took two long requests at once instead of three.

### GLM-5.3-Flash answers a JSON format with an image or video on one Mac

- A GLM-5.3-Flash Mac now serves a JSON `response_format` (`json_object` or `json_schema`) together with image or video input. Before, it refused every such request with HTTP 400 `Invalid inference request.` (failure code `invalid_request`) before any media work.
- It works as GLM's text JSON mode does: the instruction renders in the media prompt, reasoning streams on its own channel, and the answer is withheld until generation ends, then checked and exposed once. An answer that isn't the JSON asked for is a 422 with no content.
- Still refused with 400: a required or named `tool_choice` with image or video input, and a JSON format with image or video input on a cluster pair (the pair's media routes don't withhold the answer).
- Darkbloom's coordinator answers these requests itself, without dispatching, for Macs on earlier provider versions.

### GLM-5.3-Flash tensor parallel serves as many requests at once as both Macs' memory holds

- A GLM-5.3-Flash pair in tensor parallel served up to eight requests at once on any two Macs. Its load checked
  memory for one request only, so a pair with room for fewer still told Darkbloom eight.
- Now the setup sizes GLM the way it sizes Gemma 4 26B and Qwen 3.8 27B in tensor parallel. It saves the widest of 8,
  6, 4 or 2 requests at once that both Macs can hold now beside the model, and each Mac reserves that width when the
  model loads. Each request after the first is charged what it adds at the standard request (32,768 prompt plus
  32,768 output tokens): about 9.7 GB.
- The setup screen and the number the pair reports to Darkbloom are the same width. Where only one request fits, the
  pair saves no width and serves one request at a time.
- When a Mac has less memory free at load time than at setup, the pair still loads: each Mac reserves as many of the
  saved requests as it can hold then, at least one, and takes the others as memory allows. On two M5 Ultras an
  8-request pair whose Mac had other programs using 38.68 GiB did not load at all; it now loads with 6 reserved.
- A pair set up before this version is planned again by itself after the update, as after every Darkbloom update,
  and saves its width then.
- Each request still gets exactly the tokens it gets alone.

### Developer tooling

- Add an offline GPT-OSS publisher checkpoint repacker that preserves MXFP4
  experts and BF16 non-expert tensors, with source/output verification and
  comparison receipts. Add frozen-request replay guards for paged attention,
  effective prefix reuse and complete streams. These tools do not change the
  registered model or establish candidate qualification.

### A request no longer waits forever behind the idle speed check

- Before, a request that arrived while the provider ran its idle speed check (MiMo repeats it whenever the Mac is idle) waited for the check to finish, with no time limit, and ignored its coordinator's cancel. If the check stopped making progress, every later request on the Mac was accepted and never started: the coordinator timed each one out, and `darkbloom stop` waited 600 s for them and gave up.
- Now a cancelled request stops waiting at once, and any request stops waiting after 30 s and is refused as busy, so the coordinator sends it elsewhere. While the check is overdue the model reads `crashed` in the heartbeat, so no new requests are routed to it; it serves again as soon as the check finishes.

### Nemotron 3.5 Lightning serves plain decode instead of its MTP head

- Under the default `mtp_mode = "auto"` Lightning now serves plain decode instead of its embedded MTP head. The head speculates for one request only: beside a second request each step became a slower hidden-returning step, and production decode fell from about 110 to about 54 tok/s (11-09). It also charged about 45 KB of head state per context token, so a Lightning slot's token budget was about an eighth of its KV and many Macs could not admit one request with the default 32,768 output tokens. Plain decode commits a Metal command buffer every 100 operations instead of after almost every MoE layer. A single request at temperature 0 keeps the same output. Explicit `mtp_mode = "on"` keeps the head.
- The gain is not universal, on an M3 Ultra: a single request at the artifact's default temperature 1.0 stays about even, text the head predicted very well (counting, repeats, tables) runs up to about 30% slower, and a row decoding beside another request's long prompt runs at about half the head's rate.
- Sampled output follows the target's own distribution: the head's lossy `typical` acceptance no longer applies to Lightning.
- Its complete checkpoints keep native rows by default, as they did beside the head, so a cache hit's output does not move. A global `balanced` in a saved `provider.toml` does not change that; `k4v4`, a per-model setting or the process switch do. Lightning's target-only artifact and explicit `mtp_mode = "off"` follow the same default.
- Cache identity includes the MTP configuration, so a provider's existing Lightning checkpoints stop matching and age out within their 30-minute lifetime.

### Small local requests sent together are no longer refused as "memory" on a warm Mac

- While a Mac's heat or Low Power Mode holds a model to its fallback width (4 instead of the M5's 8, as often right after a start on a warm Mac), a streamed local-API request waiting for its first token counted twice. So the third or fourth of four small requests sent together got 503 "This Mac's memory can't hold this request right now" with most memory free. Each request now counts once, as the memory check already did; a fifth is still refused.

### Answers that repeat themselves verbatim stop early, as `length`

- An answer that starts repeating one block of text word for word now stops after about 2,000 repeated tokens instead of running to its output limit (up to 131,072 tokens, 25–40 minutes on one Mac). It ends like an answer cut at `max_tokens`: `finish_reason` is `length`, the usage counts the tokens produced, and the request is paid as usual. The Mac is free for the next request sooner.
- Only exact repetition counts: the last 2,048 tokens or more must repeat one block of 8–512 tokens at least 8 times in a row, and never within an answer's first 4,096 tokens. A tool call, a JSON answer and a forced tool call are never cut.
- On by default for Gemma 4, Qwen 3.5/3.6/3.8, GPT-OSS, Nemotron 3.5 Lightning and Super (text), GLM-5.3 and MiMo. `DARKBLOOM_LOOP_GUARD=0` turns it off.

### A media decode refusal no longer marks the provider's token budget as full

- A video or audio reader that fails twice with a decoder, hardware or interruption fault, and a Nemotron Super video whose decode allowance runs out, are still refused as a retryable 503 (failure code `capacity`). Their error reason is now `media_memory_unavailable`, not `capacity_busy`.
- The coordinator still sends the request to another provider, up to its three capacity refusals. It no longer reads the refusal as a full token budget, so the provider's budget for the model is not clamped to zero for up to 5 minutes, and the provider gets no capacity strikes.

### A slow MiMo step no longer stops the MiMo slot for good

- Before, a native MiMo step that ran longer than 30 s, such as a prefill step deep into a long prompt on an M3 Ultra, made the engine's step watchdog seal the engine. The engine never took another step, even after the slow step finished, and the slot stopped serving until MiMo was reloaded.
- Now a native MiMo step may run up to 120 s, the time the engine already allows a prefill to go without progress. A step that never finishes is still caught, after two minutes instead of 30 s. Other models keep 30 s.

### Models catalog names the models this Mac could add

- `darkbloom models catalog` now ends with the catalog models that are not downloaded and that this Mac could select: at most three rows with id and download size, larger first, then `darkbloom models download <id>` and `darkbloom switch`. The note is printed only when there is at least one such model.
- A model is named when the `darkbloom start` picker would offer it to this Mac (required runtime capabilities present, not a hidden build or one replaced under a public alias), it is an active text model, its listed `min_ram_gb` is at most this Mac's memory, and it fits the provider's load budget alone. Free disk space, the memory reserve and memory in use at load time, the coordinator's minimum provider version and the provider's trust status are not checked, and the note says so.
- The note only prints: nothing is downloaded, selected or saved, and no request is added. The table's catalog request now also asks for the public aliases (`include_aliases=1`); the `--json` request and output are unchanged.

### Gemma 4 26B QAT drafts with exact MTP acceptance

- The catalog `gemma-4-26b-qat-4bit` now uses exact draft acceptance by default: each token a speculating sampled request commits is the model's own draw, so its outputs follow the model's distribution (exact in distribution; the tokens are not bit-identical to decoding without MTP). Every other model keeps its built-in rule; the 8-bit Gemma builds draft only with `mtp_mode = "on"` and stay typical.
- Its assistant drafts most Gemma rows, and typical acceptance keeps drafts the model would rarely have sampled; once a repetition starts the drafter predicts it and it is kept. On OpenRouter's GPQA run of 10-31 every Gemma answer drafted under typical acceptance and 30 % ran to the 32,768-token cap with no answer.
- Exact keeps fewer drafts, so MTP speeds a Gemma stream up a little less: a speed cost of about 0–4 % (0.96x of typical at one request in the 10-07 measurements, 0.99–1.01x in the 11-10 M5 Ultra A/B). `mtp_acceptance_by_model` with `"gemma-4-26b-qat-4bit" = "typical"` restores the old rule.

### Qwen 3.8 27B drafts with exact MTP acceptance on a single Mac

- The catalog `EigenLabs/Qwen3.8-27B-4bit-mtp` (and its head-less target `EigenLabs/Qwen3.8-27B-4bit`) now uses exact draft acceptance by default: each token a speculating sampled request commits is the model's own draw, so Qwen 3.8's outputs follow its distribution (exact in distribution; the tokens are not bit-identical to decoding without MTP). This applies on every single-Mac path: network serving, Only me / `--local`, and both MTP upgrades. Qwen 3.8 pairs never used typical acceptance, and every other model keeps its built-in rule.
- On a single Mac a lone Qwen 3.8 request drafts, and typical acceptance keeps drafts the model would rarely have sampled. On Qwen3.5-9B typical acceptance made long answers loop to the output cap (13 of 31 draws, against 0 of 31 under exact). Qwen 3.8's own production records point the same way, though they are observational: while the fleet moved from 0.9.17 (exact) to 0.9.18 (typical), Macs on typical ran long Qwen 3.8 answers to their `max_tokens` about 3.6 times as often on the same traffic. Since 11-09, every one of the 229 single-Mac Qwen 3.8 answers of 8,192 tokens or more that ended at their cap had drafted; none of the 33 long answers that never drafted did.
- Exact keeps fewer drafts, so Qwen 3.8 decodes about 4–5 % slower on single Macs, all of it while a Mac serves one request at a time (a lone request runs at about 0.93x of typical in the 10-07 measurements). A Mac serving several requests at once is unchanged. `mtp_acceptance_by_model` with `"EigenLabs/Qwen3.8-27B-4bit-mtp" = "typical"` restores the old rule.

### Drafting models no longer use up Metal shared events while several requests decode

- While two or more requests decoded together on one model, each decode step left one Metal shared event alive. The count fell only when one request drafted alone or the requests ended. This hit Qwen 3.8 by default; the 9B, the 35B and Qwen 3.6 when a client sent `presence_penalty: 0`; Lightning; and Qwen4 Flash-Next. Two Qwen 3.8 requests added about 2,000 events a minute. Shared events are a finite system-wide pool. After roughly 15–50 minutes of such a stretch, the provider could abort with `Failed to create Metal shared event`.
- The SDK now drops each finished step's event from the arrays the drafting history keeps. Tokens and drafts are unchanged, and no GPU work is added.

### MTP assistant upgrade: no forward on the model while it serves

- When a provider attaches the verified MTP assistant to a model that is already serving (the idle upgrade), building the replacement engine no longer runs a forward on that model. It reuses the KV types observed when the model was first loaded.
- A forward from the preparing thread could race the serving engine. With Gemma 4's compiled feed-forward (mlx-swift-lm `093563be` and later), that race crashed the provider with `Attempting to eval an array without a primitive` when a request arrived during the upgrade, typically the first request after a start.

### Nemotron Super serves JSON output, tools and its settings with images and video

- An image or video request to Nemotron 3.5 Super now takes the same request plan as a text request. `response_format` (`json_object` and `json_schema`), `tools`, `tool_choice` (auto, none, required or a named function), `parallel_tool_calls` and `min_p: 0` are served with media. Before, the Mac refused every such request as `invalid_media` (400).
- Tool calls and JSON answers with media are withheld and validated as for text: an invalid JSON answer or a broken forced tool choice returns 422, or ends a stream with an error event.
- Nemotron Super now advertises `native_media_tools`, so the coordinator sends it forced tool choice with media and media in tool results. It also advertises `native_media_controls`, which a coordinator can require before it sends a Super request with media and a JSON response format or tools, so Macs without this release do not receive them.
- A media-route refusal names its cause by its failure code. A request control that the text route also refuses (`logit_bias`, `n > 1`, `min_p` other than 0, `prompt_cache_key`, `top_logprobs` outside 0 to 20) is `invalid_request` (400), as are a prompt whose visual tokens do not fit the context and text that names `<image>` or `<video>`. Media the route does not serve (a label or encoding outside the image format reference, audio, more than 16 images, images with a video, a second video, a codec other than H.264 or HEVC) is `unsupported_media` (the coordinator answers 415). Media above a size, pixel or frame limit is `media_too_large` (the coordinator answers 413). Only corrupt media stays `invalid_media` (400). Before, all of these were `invalid_media` (400), a video's own frame and pixel limits included.

### Nemotron Super's prompt cache now restores exactly

- Nemotron Super's prompt cache now restores exactly: an answer from a cached prompt is the answer the same prompt gets without the cache. Super now saves its prompt checkpoints at native precision. Before, they used the provider-wide `balanced` default, which stores older attention rows at 4 bits.
- Measured on the production weights on an M5 Ultra, with 3 reasoning prompts of about 8,600 tokens restored from an 8,192-token checkpoint: `balanced` checkpoints changed all 3 answers, and native checkpoints matched the uncached answers bit for bit in all 3, tokens and logprobs alike.
- Checkpoints are larger. At 8,192 tokens one is about 249 MB instead of 204 MB, so about 15 % more is written per prompt; at 30,720 tokens it is about 457 MB instead of 285 MB. The SSD cache keeps its shared disk budget, so it holds fewer Super checkpoints.
- Super's own per-model setting or the process switch still selects another precision. A global setting, even an explicit `k4v4`, `k8v4` or `k8v8`, no longer applies to Super. Existing Super checkpoints stop matching and age out within their 30-minute lifetime.

### Nemotron Super takes WebP, GIF and BMP images, under any image label

- Nemotron 3.5 Super now decodes WebP, GIF (the first frame) and BMP images as well as PNG and JPEG. The coordinator already fetched and inlined these formats; every Super Mac refused them.
- ImageIO decodes them to the same RGB input as PNG and JPEG, under the same byte, pixel and resize limits, checked from the header before any pixel is decoded. A WebP's EXIF orientation is applied as for PNG and JPEG. Alpha is dropped; a fully transparent pixel reads as black.
- Other formats (TIFF, HEIC and the rest) are still refused, now as `unsupported_media`.
- An inline image is taken under any image label, in any case: the format comes from the bytes, so a JPEG sent as `data:image/jpg` (an alias some clients send) or `data:image/JPEG` is served. Before, only `data:image/png` and `data:image/jpeg` were taken, and every other label was refused as `invalid_media` (400). A label that is not an image, percent encoding or a remote URL is refused as `unsupported_media`.

### A nullable tool parameter takes `null`

- A tool parameter a client declares nullable (`"type": ["integer", "null"]`, or `anyOf` with a `null` branch) reaches the model's parser as `"nullable": true`, which the SDK ignored. A model's `null` for it, as Qwen 3.5-family XML calls write it, stayed the string `"null"`, failed the parameter's type, and the client got a tool error for a legal argument. It now becomes JSON `null` and passes validation for a nullable integer, number, boolean, object or array. A nullable string keeps the text `null`, and `enum`, `const` and combinators still apply.

### Paged decode keeps one attention pass per layer on a busy Mac

- Before, on the paged KV backend (the 9B, Qwen 3.6, gpt-oss-20b, the 35B, Gemma 4 and the other paged models), decode slowed while a Mac stayed busy and recovered only when the engine drained. Freed pages went back to the front of one shared free list, so new requests' pages spread over many segments, and the decode kernel, which binds at most 17 segments per pass, needed about one pass per 256 tokens of context per layer instead of one per layer. In production the 9B decoded at 0.40× its fresh speed 3–6 minutes into a busy run and 0.30× after 6 minutes.
- Now each layer of a request takes its pages in runs of 16 consecutive pages, in as few segments as it can, and requests that start together take different segments. A CPU model of the allocator and the decode planner stays at one pass per layer through busy runs: Qwen 3.6 at 4 requests goes from about 930 passes per step to 10, the 9B under a production-like load from about 430 to 8.
- Pages that the prefix cache still names are still reused last. Each attention partition is computed as before, so outputs are unchanged.

### Truer words on a paired Mac, the split question names each mode's context, and refusals without a usage block

- On the Mac that follows in a pair, `darkbloom doctor` now reads the pair as `darkbloom status` does, from the leading Mac's answer: it said "loading" for as long as the pair served. That Mac's own view (`status --solo`) says "started" there, since only the leading Mac's part knows whether the pair serves.
- After `darkbloom cluster leave` on one Mac, the Mac left behind no longer says it leads and the other Mac follows: while the other Mac doesn't answer, `status`, `cluster status`, `doctor` and the cluster screen say "this Mac (…) is paired with the other Mac (…), which isn't answering". The cluster screen of a stopped pair whose other Mac is gone says it is stopped, as `cluster status` does, instead of "degraded: serving on this Mac alone … (its solo server is still loading)" with nothing running.
- How both Macs split a model: each mode's line now says the context it serves, for example "context 262,144 tokens" for Qwen 3.8 27B's tensor parallel and "context 65,536 tokens, prompts up to 32,768" for its pipeline, and the recommendation puts context before speed ("the longest context here (262,144 tokens; the other serves 65,536)"). A mode that serves less is recommended only when it alone fits now.
- An image or video sent to a model that doesn't take it, on one Mac's local API or a pair's, is now refused with the error code `unsupported_media` beside the same words.
- On a Mac in a pair, every flag beside `--solo` is for that start only, and a solo start saves nothing in `[local]`, which holds the pair's settings, but this Mac's one port. A mode flag (`darkbloom start --solo --local`) or the answer to `--choose` serves that start, and `[local] mode`, the pair's answer, is no longer replaced; `--choose` asks no route. `--route`, `--me-first-idle`, `--no-me-first`, or `--me-first` over a pair whose pause is off, would change the pair's setting, so beside `--solo` each is refused before anything starts, naming it. A plain `darkbloom start --local` on one Mac still saves its choice.
- `darkbloom local` names the file that holds the key it shows (`key file: ~/.darkbloom/local_token`), and on a pair's API also the pair's key file, whose key works there too.
- A tool set up beside a paired Mac's solo server (the other Mac away) names its models "(this Mac)", not "(your pair)".
- A terminal `darkbloom start` on a stopped pair says "Press Enter to start it …" only while the other Mac answers. The app's start page on a pair that was started but can't be seen serving from this Mac says Start serving "Makes sure the pair serves …".
- A script's `darkbloom start` on a pair with no model says only how to choose one, without "starting the pair" first. On a serving pair whose cluster service runs from a terminal session, it again moves the service to its login agent, so the pair comes back after a restart, instead of saying "the pair already serves" and leaving it.
- A refusal a command makes once it runs now ends with its own words, without the generic "Usage: darkbloom <subcommand> / See 'darkbloom --help' …" block; mistyped flags still get the usage. Ctrl-C on `darkbloom start --local --here` no longer prints the local server's "Server shutdown error: Already closed" and "Waiting on child channel" lines.

### A pair Mac that runs short of memory ends only that request

- When one Mac's memory refuses a request while it runs, both Macs now end that request alone and keep serving, in every pair mode: the pipeline (Qwen, Gemma 4, GLM, MiMo V2.6, GPT-OSS) and tensor parallel (Qwen 3.8 27B, Gemma 4, GLM, MiMo V2.6), one request or several. A local request that isn't streamed gets one Mac's memory 503, "This Mac's memory can't hold this request right now. …". A streamed one gets the tokens already sent, then an error chunk with `code` `request_exceeds_node_budget` and the same words. Darkbloom traffic gets `capacity` with `request_exceeds_node_budget`. Before, the refusing Mac's worker exited, the client got an untyped 500 and the pair stopped serving for about a minute.

### A MiMo slot whose engine stops stepping stops taking requests

- Before, a native MiMo slot whose engine had stopped stepping, with a request queued and nothing running, still reported itself idle for as long as it stayed that way, so the coordinator kept routing requests to it. Each was accepted and timed out without a word.
- Now an engine whose native work failed and was sealed by the SDK reads `crashed` at once, on any model. A native MiMo slot whose queue holds work with nothing running and no step reads `crashed` after 30 s. Either way the coordinator routes around it, and the provider then retires the MiMo slot, recording "Native MiMo slot failed; confirmed retirement or process restart required" in `darkbloom status`.
- Other models keep their existing wedge rules: on them a queue that waits with nothing running is usually healthy.

### A media request a Mac can't hold now is refused as `media_memory_unavailable`

- A media request that this Mac's memory can't hold right now is refused as a retryable 503 with the reason `media_memory_unavailable` (it was `capacity_busy`), so Darkbloom sends it to another Mac without counting this Mac's capacity as full.

### Qwen3.5-9B speculates and caches again, with exact MTP acceptance; the 35B Qwen builds keep their penalty

- Since 0.10.5 the catalog `Qwen3.5-9B`, `qwen3.5-35b-a3b` and `qwen3.6-35b-a3b-vl-mtp-mxfp8` builds have given a request that omits `presence_penalty` the model cards' 1.5. The engine drafts no row with a penalty, and these builds' MTP heads keep the prompt history, so through 0.10.11 such a row also staged no resident or SSD prefix checkpoint.
- The 0.10.12 gate on the signed 0.10.11 decided each build. It ran temperature 1, `top_p` 0.95 and `top_k` 20 over #1652's four loopers and five tool transcripts at 32,768 tokens and nineteen everyday prompts at 8,192, three seeds each.
  - **`qwen3.5-35b-a3b`:** without the penalty it ran away under typical MTP acceptance (8 of 12 loopers to 32,768, 5 of 19 everyday prompts) and under exact (2 of 12 loopers).
  - **`Qwen3.5-9B`:** it ran away on 13 of 31 draws under typical acceptance and on none of 31 under exact.
- **`Qwen3.5-9B`** now has no default presence penalty, and its built-in MTP acceptance is exact. Its requests speculate and stage prefix checkpoints: in the gate the penalty-free body cached 8,192 tokens on its second send, where the penalty body cached none. A `[backend] mtp_acceptance_by_model` or `mtp_acceptance` value still takes precedence.
- **`qwen3.5-35b-a3b` and `qwen3.6-35b-a3b-vl-mtp-mxfp8`** (one architecture) keep the 1.5, so their requests that omit it still run without MTP; they now save prefix checkpoints (see the entry on Qwen 3.5/3.6 requests that cannot speculate).
- A request's own `presence_penalty` always wins: `0` on a 35B build speculates under typical acceptance and donates checkpoints, and any nonzero value on the 9B turns MTP off for that request, which still saves prefix checkpoints.

### Qwen 3.5/3.6 requests that cannot speculate save prefix checkpoints again

- From 0.10.5 through 0.10.11 the `Qwen3.5-9B`, `qwen3.5-35b-a3b` and `qwen3.6-35b-a3b-vl-mtp-mxfp8` builds gave a request without a `presence_penalty` the model card's 1.5, and a request with a penalty cannot speculate. Their MTP head keeps each request's prompt history, and a request that could not speculate recorded none, so it saved no SSD or resident prefix checkpoint. A repeated prompt or the next turn of a conversation was prefilled again from the start, and the coordinator saw almost no cache holders for these builds.
- Such a request now records the head's prompt history and saves the same checkpoints a speculating request saves. That covers the card's penalty (still the 35B builds' default), any other penalty, a `stop` string, logprobs, `logit_bias` and a token constraint. The penalty and its sampling are unchanged, and the request still never speculates.
- The same holds on Qwen3.8-27B (the same embedded head) and on Nemotron 3.5 Super: a request with a `stop` string, logprobs, a penalty, `logit_bias` or a token constraint now saves prefix checkpoints too. Its prompt runs the prefill a speculating request's prompt runs, and its answer is unchanged.
- A request that cannot speculate and restores one of these checkpoints answers exactly as without the cache, tokens and logprobs alike. A speculating request restores the same history its own prompt would record.
- From the SDK pin `libs/mlx-swift-lm` at `505e6bd8` and later, which contain Layr-Labs/mlx-swift-lm#398 (it carries #397).

### Qwen 3.5 MTP prompts project only their last position

- With MTP active, every prompt chunk of a Qwen 3.5-family model (Qwen3.5-9B, Qwen3.5-35B-A3B, Qwen3.6,
  Qwen3.8-27B and Bonsai 2 9B) went through the 248,320-way output head at every position, though only the last
  row is used. The pinned SDK (mlx-swift-lm #302) now projects only the last position of the last chunk. On an
  M3 Ultra, time to first token with MTP fell by about a tenth at 4K–16K prompt tokens on Qwen3.5-9B and
  Qwen3.5-35B-A3B, with identical temperature-0 outputs. The first token's logits now equal the MTP-off path's
  exactly. Requests where MTP does not run see no change.

### A refused request tells the coordinator why

- **The `inference_error` frame of a client refusal names its reason:**
  `refusal_reason`, the closed reason `darkbloom logs` already names (such as
  `missing_user_query`, `unmatched_tool_result` or `request_exceeds_context`),
  and `refusal_message`, one fixed sentence for that reason. Neither carries
  request text. The `error` text the requester gets is unchanged ("Invalid
  inference request."); today's coordinator ignores both keys until it is
  updated to record or forward them.
- **Qwen 3.5/3.6/3.8 tool conversations name the check that refused them:** a
  conversation with no real user turn is `missing_user_query`, and a `tool`
  message with no assistant `tool_calls` before it is `unmatched_tool_result`
  (before, both logged and sent no reason). The same history checks on every
  model, GPT-OSS's and Gemma 4's included, name theirs, and required or named
  `tool_choice` with image or video input is `unsupported_forced_tool_choice`.

### Selected models recover their residency automatically

- A model you selected explicitly (`enabled_models`, `preload_models`, the pinned `model` or Autopilot's selection) that the startup preload skipped or failed to load for memory, or left untried at the slot cap, is now retried automatically: after 30 s, backing off to every 10 minutes, at once after any unload or a saved `enabled_models` or Autopilot change, and when a placement hold, an idle threshold, a minimum dwell or a lease ends. Previously nothing retried it, so behind a busy model outside the selection it stayed cold until a restart. A model that loads but is then refused for memory three times (too little left to serve) waits for an unload or such a change instead of the backoff, since each of those retries loads the whole model. The queue lives in memory: after a restart only the startup preload queues a model again.
- The same applies to a selected model an Autopilot operation unloads to load another model, for example Nemotron Super unloaded to place GLM-5.3-Flash: it waits from the moment it leaves residency, whether the operation then succeeds or fails, and comes back once the placement no longer protects GLM. An operation that only unloads models queues nothing.
- A retry never evicts a selected model. Before loading it may unload only models outside the selection that no request could load straight back and whose memory makes the room, and only once such a model has no request in flight and no Autopilot hold, pin or per-model lease, has been resident for Autopilot's `min_dwell_seconds`, and has been idle (since its last request or its hold's expiry) for the longer of two minutes and `min_idle_seconds`. A model of the running daemon's selection, even one your saved filter dropped, is never evicted, so a recovery never alternates between two models. It waits while a live Autopilot lease manages residency, a drain runs, an add-on holds the Mac or you use the Mac under me first; one of these that begins while a retry unloads a model stops the retry before its load, and a hold that begins during the load cancels it.
- `darkbloom status` prints `Retrying <model> when memory frees; next check in …` (or `next check after an unload or a configuration change`) with what blocked the last check, and `Configuration change needs a restart to apply: enabled_models adds/removes …` when the saved filter differs from the one the running selection applies: the filter the daemon started with, or the one the last `darkbloom switch` saved and applied, so a committed switch no longer asks for a restart.
- `darkbloom stop`, `restart` and `start` no longer need `--force` when a model's native retirement never finishes: shutdown waits at most 15 s for each model's unload, so that model no longer keeps the process from exiting.
- Policy (the owner kept it): ten minutes after the placement's hold ends or the selected model began waiting, whichever is later, and not before the placed model's minimum dwell or per-model lease ends, an adopted model outside the selection that keeps a waiting selected model out only by serving Darkbloom requests is released: it takes no new requests, finishes those in flight and is evicted. Holds, selected models, pins and a model one of your local requests is using are never released.

### `darkbloom start` serves Both without a question; `darkbloom local` serves only you

- `darkbloom start` no longer asks how this Mac serves, in a terminal or not. On a Mac with no choice saved it
  serves the Darkbloom network and this Mac's local API, and Darkbloom keeps serving while you use the Mac; one
  line says so (``Serving Darkbloom and your local API at http://127.0.0.1:8001/v1 (`darkbloom local` for local
  only).``) and the choice is saved (`[local] mode = "both"`, `me_first = false`). With an account key saved, a
  request this Mac can't take goes to your other Macs, free. Scripts and the desktop app's Start without its local
  API take the same default where nothing is saved (they served the Darkbloom network alone before).
- A saved choice is never changed: starts, `restart`, `update`, login and the watchdog serve it as saved, a pause
  saved by the earlier question included. `--local`, `--network`, `--me-first`, `--no-me-first`, `--me-first-idle`
  and `--local-endpoint` work as before. `--choose` asks nothing and says which commands to use.
- `darkbloom local` starts Only me in the background where nothing serves, then prints the address and key. Where
  Darkbloom serves, it prints them (or that there is no local API) and, only in a terminal, asks `Switch this Mac
  to local only (stops serving Darkbloom)? [y/N]`; without a terminal it never switches. Where Darkbloom is stopped
  but saved (network or Both), it says so and asks the same in a terminal only; without one it changes nothing
  (exit 1). On a Mac in a two-Mac cluster it points to `darkbloom cluster local`. `--model <id>` names Only me's
  models; `--json` only reads.
- A plain `start` no longer reaches the Autopilot question, which only a Darkbloom network start asks: use
  `--network` or `darkbloom autopilot enable`. The idle-memory question is skipped when standard output isn't a
  terminal, as it already was for standard input.

### `darkbloom status` shows the answers in progress

- Under the serving block, `darkbloom status` lists each answer the Mac is
  writing: the model, how long it has run, output tokens so far, its current
  tokens per second and a short hash of its request (never the prompt, the
  answer or the request ID), then "Credits post when a paid answer finishes;
  requests to your own machine are free." A Mac writing two long answers no
  longer looks hung while its served and token counters wait for them to
  finish. The engine's own calibration and warmup probes are not listed. On a
  two-Mac cluster the leading Mac lists the pair's answers under the pair.
  `darkbloom status --json` prints the same list as JSON.
- The daemon reads them from counters its engines already keep, once per
  state-file write (about every 2 s), into `running_requests` in its state
  file. Nemotron Super's answers are not listed yet.

### `darkbloom status` lists the answers in progress on a Mac that serves only you

- A Mac that serves only you (`darkbloom start --local`) now lists its answers
  in progress under `darkbloom status` (and in `status --json`), as a Mac that
  serves Darkbloom does: before, its state file never carried them, so a long
  local answer looked like nothing was running (0.10.12 W1). Its standalone
  server samples the counters its engines already keep, at most every 2 s.
- A pair that serves only on its local API (`darkbloom cluster local`) still
  lists none: its serving process writes no state file yet.

### `darkbloom status` says which requests that ended early are paid

- The line under `Requests served` said that every request that ended early "may be unpaid". Many are paid: when the requester leaves mid-answer, the coordinator pays for the prompt and the output your Mac had already sent. `status` now lists those requests by what stopped them and whether they are paid, for example:
  ```
    7 of them ended early:
      5 paid for the work done: the requester left mid-answer
      1 unpaid: another Mac answered first
      1 unpaid: the connection to the network dropped
  ```
  Your Mac knows itself when its connection dropped or when it stopped a request (a drain or an add-on hold). The other causes come with the coordinator's cancel from the coordinator update that sends them; until then those requests share one note: paid for the work done if the requester left mid-answer, unpaid if another Mac answered first or this Mac started too late.
- With the coordinator update that sends the cause, a request whose answer had already finished when the requester left is no longer counted as ended early: it is paid as delivered. About 1 in 100 of the requests counted before were such answers. An unpaid stop still counts, finished answer or not.
- The count now takes a line per cause, so a script that reads `status` line by line sees more lines.

### `darkbloom status` says whether fan control is on

- Fan control is opt-in (`sudo darkbloom fan enable`), and only `darkbloom fan status` said it was off, so a Mac with supported fans could serve hot under macOS automatic fan speed without anything in the normal flow saying so. `darkbloom status` now has a `Fan control (experimental)` line from the same report: the helper's mode when it runs; `off, macOS automatic` with the hottest GPU sensor and the enable command on supported hardware without the helper; and otherwise not answering, installed but not running (after `fan disable`, with no advice to enable), unsupported or unavailable. Fan control stays opt-in; nothing enables it.

### Nemotron 3.5 Super: a request that arrives as the previous one finishes waits instead of bouncing

- A Super Mac serves up to 8 requests at once, but only one image or video at a time. It answered another image at once with 429 `queue_full`, which sends the image to another Mac. That included images arriving after the previous answer had ended but before its cleanup (native retirement, and the release of its image memory) had finished. The same held for any request when the Mac's Super owner was at its request limit.
- Such a request now waits up to 1 s for that cleanup and is then served. The previous request's memory is released before the next one reserves its own, so memory use is unchanged. A request that arrives while the previous answer is still being generated is still refused at once.

### Nemotron 3.5 Super: an image that arrives while another image's answer is streaming waits for it instead of bouncing

- A Super Mac serves up to 8 requests at once, but only one image or video at a time. An image that arrived while another image's answer was streaming was refused at once with 429 `queue_full`, so the coordinator sent it elsewhere or, after three refusals, gave up. Such an image now waits for the slot, up to 3 s, and is served when the image ahead of it finishes. An image's answer usually ends about 2 s after it starts streaming.
- For Darkbloom requests the wait never spends the request's time limit for its first token. It stops early enough to leave room for this Mac's slowest recent time to first token on images (counted as at least 6 s), and is skipped when no room is left.
- Only one request waits at a time, and a waiting request reserves no memory, so two images are never in memory at once. A waiting image never takes the last request slot a text request could use. Text requests never wait behind an answer still being generated, and an image never waits behind a text answer or behind an image whose prompt is still being processed.

### Nemotron 3.5 Super answers that repeat themselves verbatim stop early too

- Super's text requests now get the loop guard the other models have: an answer that starts repeating one block word for word stops about 2,000 repeated tokens in, as `finish_reason: "length"` with its usage, and is paid as usual. Super's requests take the owner's own route, which passed no guard before.
- The same rules apply: never within the first 4,096 tokens; never for a JSON answer, a forced tool call, a tool call once it starts, or a request with images or video. `DARKBLOOM_LOOP_GUARD=0` turns it off for Super too.

### Opt-in: answer before the checkpoint write finishes

- A request that donates a complete SSD checkpoint ends its response only
  after the checkpoint is durable, so the client waits for the write.
  `DARKBLOOM_PREFIX_CACHE_SSD_TERMINAL_BEFORE_PUBLICATION=1` (default off)
  ends an unseeded donor's response as soon as the answer is complete. The
  provider still holds the request's rows, KV reservation and service
  allowance until the write settles, so other requests see no added
  capacity. A follow-up that arrives before the write finishes can't use
  that checkpoint yet: it restores an earlier one, if any, and prefills the
  rest. Seeded requests keep the old order.
- For an installed provider, set it in the shell for `darkbloom start`,
  which writes it into the provider's launchd job; an ordinary `darkbloom
  restart` keeps the saved value. Each such request that retires at least
  1 ms after its answer is logged with that time, which for a donor is how
  long its write held its capacity after the answer (`Early terminal: request
  … retired N ms after its answer`). The 1 ms floor is a timing heuristic: on
  a busy provider a request that wrote no checkpoint can be logged too. The
  line is only in the provider log.

### `tool_choice: auto` returns the model's tool calls as generated

- With `tool_choice: auto` (or no `tool_choice`) and no function declared `strict: true`, the provider now returns the model's calls the way OpenAI and vLLM do. A call to a function the request did not declare, and arguments that do not match the declared schema, reach the client unchanged. When a streamed call's arguments are not valid JSON, the text already sent stays as the raw `arguments` string, the call is closed and the response finishes with `tool_calls`. Before, each of these failed the request with a 422 `tool_noncompliance` after its reasoning had streamed, so the client saw a 200 followed by an error and the coordinator could not send it elsewhere. This mostly affected GPT-OSS agent turns.
- A function declared `strict: true` keeps the whole request validated, as do `required`, named and `none` tool choices, a request that declares no tools, and `parallel_tool_calls: false`. A call read from a frame that `max_tokens` cut off is still validated, since it may be missing arguments.
- On a Mac's own API (`--local`) and for GLM-5.3-Flash, a strict request no longer refuses a valid value for a property that declares no type: the provider fills in `type: "string"` for such properties so the chat templates can render them, and it used to enforce that type too; strict calls are now checked against the schema as the caller sent it. Through Darkbloom's coordinator, strict requests to every other model still refuse a non-string value there, because the coordinator itself writes `type: "string"` into typeless properties before the request reaches the Mac.
- A `tool_noncompliance` error frame now carries `tool_check`: which check failed (`undeclared_name`, `schema`, `malformed`, `diverged`, `unterminated`, `parallel`, `response_format`, `forced_choice`, `native_output` or `other`). The provider's local failure log line shows it too. It names the check only, never the tool or its arguments.

### A restart you ask for after an update no longer rolls the update back

- Until a new release has run for 10 minutes, three failed starts bring back the previous release and quarantine the new one. A `darkbloom restart` (or `stop` and then `start`) in those 10 minutes could count as one: the watchdog, started again by the command, looked at the provider the command had just replaced, saw no heartbeat from it, and counted a failed start, so a Mac restarted three times was rolled back and its release quarantined though nothing had failed. Now a provider that was asked to stop (by `darkbloom stop` or `restart`, or by its own restart into an update) records that before it exits, and the watchdog times the next provider's start from when that provider started: the restart is never a failed start. After a crash, a hang, a reboot, a `kill` or any other stop, whatever starts the provider again, its start is still timed from the update's launch, as before, so a release that crashes or hangs the Mac is still rolled back. A `--force` stop that has to kill the provider before it records its stop is timed from the update's launch too. A provider that sends no heartbeat in its first 5 minutes (longer with a raised `startup_preload_timeout_secs`) still counts too.
- A new release is promoted only once one provider process has served it for 10 minutes. When something restarts the provider more often (a script, a cron job or a login item), the watchdog now says so in `~/.darkbloom/watchdog.log` after 5 restarts, then after 10, 20, 40 and so on.
- On a `darkbloom cluster` Mac, a clean stop of the cluster service that its supervisor didn't ask for (`darkbloom cluster` replacing a service started from a terminal, a `kill`) no longer counts as a failed start either. A crash, an exit with an error, a service that stops beating and a release that fails its start check still do.

### The watchdog brings back a provider job launchd lost

- When launchd dropped the provider's job while it was enabled (booted out, not stopped with `darkbloom stop`), the watchdog treated it as stopped and nothing restarted it until someone ran `darkbloom start` (#1104). It now restarts it after the usual grace, when `auto_restart` is on, the installed job is the provider's own and enabled, and no provider process is still alive, under the same lock as `stop` and updates. A job you stopped stays stopped, and nothing changes for a Mac whose pair runs here or for a pair member's job.
- A pending update is handled as on a crash: a confirmed failed start counts once, the verified rollback and its retry backoff apply, and no update is downloaded on this path. An uncertain `launchctl` result keeps the crash-loop protection without counting a restart.

## v0.10.11

Published 2026-11-09 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.10.11)).

### Upgrade and rollout notes

- 0.10.11 is a large release: **use your Mac yourself, first** (local-first), faster two-Mac pairs, longer answers on one Mac, and many pair fixes. The toolchain (Xcode 27.2, macOS 27.2 SDK) is 0.10.10's; `libs/mlx` and `libs/mlx-swift` are unchanged, `libs/mlx-swift-lm` moves (Swift model code only).
- **Behaviour changes to read first:**
  - **Macs serving with `--local-endpoint`, including the desktop app's "Alongside the network", now pause Darkbloom while you use their local API**, and take Darkbloom requests again 2 minutes after your last one (`me_first_idle_minutes`, 1 to 120). To keep sharing the Mac as before, add `me_first = false` under `[local]` in `~/.config/darkbloom/provider.toml`, then run `darkbloom restart`.
  - **A pair paused for its owner keeps its base reward** on the coordinator that ships with 0.10.11 (darkbloom-platform#709 onwards), as a single Mac paused for you does; both stay connected and take no Darkbloom requests while paused. On coordinators before #709, both Macs of a paused pair lose it for the pause plus the idle minutes.
  - **An unknown `reasoning_effort` is now refused** with a typed 400 (`invalid_reasoning_effort`, the field in `param`, the accepted names) on every model that reasons, including Qwen 3.5/3.6, Bonsai 2, Gemma 4, GPT-OSS and Nemotron Lightning, which used to accept it. Every standard value is accepted everywhere: `none`, `minimal`, `low`, `medium`, `high`, `xhigh` and `max`, each mapped to the model's nearest level. GPT-OSS reasons at every level, through OpenRouter too, once the Mac runs 0.10.11; a Mac still on 0.10.10 renders `high` as `medium` until it updates.
  - **Cut, don't refuse:** on one Mac, a `max_tokens` larger than the prompt leaves is cut to the model's window, and the answer ends with `finish_reason: length` if it gets there. A request with no `max_tokens` may now write up to 32,768 tokens (it stopped at 8,192, or 4,096 on MiMo V2.6, Nemotron Super and GLM-5.3-Flash). Network requests change only where the coordinator undercounts the prompt: **OpenRouter requests that the coordinator undercounts on GLM-5.3-Flash, MiMo V2.6 and Nemotron Super are now served, cut to the window, instead of refused.**
  - **A request this Mac's memory can't hold gets a 503 before any SSE header**, streamed or not, with a plain message ("This Mac's memory can't hold this request right now. Lower max_tokens or shorten the prompt …"), instead of HTTP 200 followed by an error.
  - **One local API port and one key per Mac.** Every way of serving locally on a Mac uses the same saved port, so your tools' address never moves. A Mac updated from 0.10.10 whose local API serves on 8000 keeps 8000; a Mac with no local API takes the first free port from 8001. The key stays in `~/.darkbloom/local_token`.
- **Use your Mac yourself, first.**
  - The first `darkbloom start` in a terminal asks how this Mac serves: **Only me, on this Mac**, **Darkbloom network**, or **Both, me first** (pre-selected). The answer is saved; `darkbloom start --choose` asks again. **Starts without a terminal (the login service, the app, scripts) never ask:** without a saved choice they keep today's behaviour exactly.
  - **Only me now runs as a background service**, like the other choices: it starts at login, restarts after a crash, updates itself, and keeps serving after you close Terminal. The app's "Local only" saves Only me, and "Alongside the network" saves Both, me first.
  - **Me first gives way:** while you use the Mac, Darkbloom requests still queued on it go back to the network instead of making yours wait; requests already running finish.
  - **`darkbloom --opencode` and `darkbloom --hermes`** (also `darkbloom start --opencode` / `--hermes`) set OpenCode 2 or Hermes Agent up to use your Mac, the way `ollama launch` does: the tool's config (never the key), a backup first, and a one-line undo. **Hermes needs v0.20.2 or later.** The installer now ends with `darkbloom --opencode` as the next command.
  - **Routing: this Mac first, then your Macs.** `darkbloom route this-mac`, `my-macs` or `my-macs-first` saves where your requests go when this Mac can't take them. Your other Macs are free; **the paid Darkbloom network is used only if you opt in** with `my-macs-first` and an account key saved by `darkbloom route key`. Answers say who served them.
  - **Pairs:** `darkbloom cluster` asks the same three questions for a pair. With **Both, me first**, every Mac of the pair has its own local address, and the whole pair pauses Darkbloom while you use it.
  - **`darkbloom cluster leave`** leaves a pair in one command, from either Mac.
  - **`darkbloom doctor`** opens with how this Mac serves you: the local API's address and port, whether it answers, and whether OpenCode and Hermes point at it. On a Mac set to Only me, it skips the checks Darkbloom serving needs.
  - `darkbloom status` says in one line how the Mac or pair serves and whether Darkbloom is paused for you. No screen shows the local key or a speed.
- **Pairs: faster, and fewer surprises.**
  - Qwen 3.8 27B pairs decode with their speculative assistant through Darkbloom, and with the assistant they now prefill as fast as pairs without it. A Qwen pair takes `max_tokens` up to 65,536 and tells Darkbloom the requests it can serve, so larger ones go to single Macs instead of to a refusal. Qwen and Gemma 4 tensor-parallel decode and prefill are faster with unchanged output (Gemma 4 prefill nearly twice as fast).
  - **Gemma 4 pairs:** in tensor parallel a pair serves the model's whole context (262,144 tokens: prompts up to 262,143, answers up to 32,768), with one Mac's `max_tokens` cut, its `context_length_exceeded` words and the memory 503 before any header (#1923, proven on real Macs at 64K and 128K and a full-window answer). In pipeline it serves 65,536 with prompts up to 32,768, as every model's pipeline does, and refuses a longer request at once with a typed 400 (`prompt_too_long` or `context_length_exceeded`); an oversized `max_tokens` is cut (#1930, proven on real Macs). Pipeline's whole context waits for 0.10.12.
  - Pair fixes: a pair comes back by itself after an update; a memory re-plan keeps a stopped pair stopped; the Mac that follows no longer says a serving pair hasn't served; on a paired Mac `darkbloom start` starts the pair and `start --solo` serves the Mac alone; `darkbloom restart` on a stopped pair starts nothing; the app on a paired Mac offers **Start serving**; Apple's check during a start reads as progress, and both Macs show the pause.
  - DevNet and production no longer share a pair on a Mac with both apps; production wins the GPU.
- **Other fixes:** a video (and a MiMo V2.6 audio track) whose reader fails once is read again instead of refused, and a second hardware fault is a retryable 503; a Nemotron Super video that decodes too slowly on one Mac is retried elsewhere; chunked file reads and update hashes no longer hold everything in memory; the update check asks again instead of waiting a minute; a pair's local API ends a failed stream with the single-Mac error chunk; Gemma 4 thinks when asked to, and GPT-OSS reasons at the nearest of its three levels.
- **Known issues in 0.10.11, fixed in 0.10.12 (none blocks this release):**
  - When a pair's leading Mac is away, the first local request to the other Mac gets a 503 without an error code, and the later typed 503 doesn't mention `darkbloom start --solo`.
  - After `darkbloom cluster leave` on the leading Mac, the other Mac's status and screen can say things that are no longer true until it leaves too.
  - On the Mac that follows in a pair, `darkbloom doctor` can say the pair is "loading" while it serves.
  - A Gemma 4 pair refuses an image with "Media input is not supported." but without an error code.
  - An unknown `reasoning_effort` sent through the Darkbloom network comes back as an untyped error (the coordinator's, not the Mac's).
  - A pair, in tensor parallel or pipeline mode, can restart once (about 1 minute; requests in flight fail) if one of its Macs runs out of memory partway through a long request. It is rare and has existed since October. Gemma's pipeline is now capped (#1930), which makes it rarer there; Gemma tensor parallel's whole context makes it possible on long Gemma requests, as it already was on Qwen tensor parallel.
  - `darkbloom start --solo --local` saves Only me as this Mac's choice, so later starts without a flag serve Only me too.
  - After an update, the pair setup's question about how a Gemma 4 pair splits the model can pre-select Pipeline ("faster here") without saying that Pipeline serves 65,536 tokens and tensor parallel 262,144.
- Pair owners: both Macs of a pair must run the same version; a pair on 0.10.10 updates itself at its slot, or at once with `darkbloom update` on each Mac. `darkbloom update --rollback` puts back 0.10.10.
- Pairs still on 0.10.9 stop serving through Darkbloom once 0.10.11 registers, until they update (0.10.11 and 0.10.10 hold 24 pair approvals each, the coordinator keeps 64).
- The registration keeps 0.10.10's fields; its cluster runtime facts now carry each mode's request limits and the Qwen assistant's evidence, and the leader's heartbeat adds `request_limits`. A Mac or pair paused for its owner reports `draining` with `busy_reason: "owner"`, which the coordinator treats as a plain drain.
- The 66 entries below are the pending fragments rendered verbatim; CI-only entries change no provider behaviour.

### The app on a paired Mac offers Start serving, and its lines say what happened

- On a Mac in a two-Mac pair, the app's Autopilot was a dead end. Onboarding's **Start serving with Autopilot** first downloaded a model, then showed three lines meant for the command line, and **Retry** showed them again. Autopilot chooses the models of one Mac, so on a paired Mac it is now refused before anything downloads, in words the app shows: the pair's state and what works there, for example "This Mac is in a pair, which is stopped; Autopilot isn't available for pairs yet. Use Start serving." The Autopilot page's model refresh is refused the same way.
- The app now offers **Start serving** on a paired Mac, which starts the pair. Its onboarding says the pair's state and what Start serving does there, for example "This Mac is in a pair, which is stopped. Start serving starts it with <model>." ("This Mac serves in a pair …" only while it serves), and it starts the pair without naming a model or a local API of its own. When the pair has no model yet, the page offers no Start serving: it says to choose one with “darkbloom cluster” in Terminal on the Mac that leads the pair. The Mac tells the app it is in a pair, so even an app from before this offers the plain start there.
- After the app's Start on a paired Mac, its last lines say what happened. When the app named another model, the pair "serves" its own model, or "was asked to start" with it and "isn't serving" when it doesn't serve yet. Before, it said "serves in a pair: started the pair" in both cases, and also for a pair that was already running. When the app asked for a local API that the pair doesn't give this Mac, it now says "No local API was added on this Mac", with where to change how the pair serves.
- When the app's runtime refuses an action, the app's notice now shows only the refusal's own words, without "Error invoking remote method …" in front of them.
- When a pair's other Mac isn't answering and this Mac's part was given up after 15 minutes, a start's `Next:` line and `cluster status --json`'s `next` now also name `darkbloom start --solo` to serve this Mac alone.

### A MiMo V2.6 video whose audio reader fails once is decoded again, not refused

- When the reader of the audio track (LPCM or AAC) of a MiMo V2.6 video fails after the metadata checks passed, the provider reads the track once more with a new reader over the same bytes. A valid clip that met one audio reader failure is now served with the same samples. Before, the provider refused it as `invalid_media` (400), and the coordinator did not send it to another provider.
- When the audio reader fails again with a decoder, hardware or interruption fault, the provider refuses the request as a retryable 503, and the coordinator can send it to another provider. Any other second failure is still the deterministic `invalid_media` (400).
- Each failed audio reader pass logs a WARN `engine_health` event `audio_reader_failed` with the reader status and the domain and code of its errors. It carries no media or prompt content.

### Chunked file reads release each chunk

- Before, a file read in chunks kept every chunk in memory until the thread that read it went idle. On macOS each chunk read returns an autoreleased buffer, and a Swift task or a Dispatch block does not release these buffers between chunks. Thus memory grew with the size of the file.
- Now each chunk read releases its buffer before the next read. This applies to the model manifest hash in `darkbloom-publish`, the speculative-decoding store's artifact hash, the binary and file hashes, the metallib snapshot copy, the streamed SSD KV cache read, the cluster worker hash, the MTP benchmark weight hash and the App Attest worker's executable hash. It also applies to the output readers of desktop commands and sandbox commands.
- The output readers of desktop commands and sandbox commands keep only the last 32 KiB of output. Before, the buffer that held these 32 KiB also kept all the earlier output. The stderr tail that the provider keeps for a failed helper process had the same problem, and it is fixed the same way. Its stderr reads also release each buffer.
- The digests and the copied bytes do not change.

### Provider CI: build once, test on small Macs

- Each lane builds its debug test products once, on a 12 vCPU Blacksmith Mac: Build cluster test products and Build provider test products. The test jobs download the products and run them with `swift test --skip-build`; they compile no package. A test job refuses products of another commit or of another Swift, Xcode or SDK version, and warns when only their builds differ.
- The jobs that build or run the products work at one fixed path, `/private/tmp/dinf`, because SwiftPM's products hold absolute paths and Blacksmith and Darkbloom check out to different paths.
- The cluster tests start as soon as the cluster products are up. The worker capability and prefill schedule checks, which compile a release build, run in Cluster Release Build Checks on a 12 vCPU Blacksmith Mac. The `Provider Tests` gate requires it.
- Refresh build caches is gone: a push whose tree a pull request run already tested runs the build jobs of the components it changed, without an upload.
- Cluster Runtime Tests runs in 3 shards: the Gemma 4 base suites (592 of the base tests' 970 s) run in their own process on shard 3. Cluster Focused Checks runs in 2 shards: the runner scripts, and the stage metadata, provisioning and onboarding runners.
- The provider shard weights are measured again, so the last selection no longer runs every suite the old weights missed. The last shard's audit warns when a serial suite has no weight.
- Only the 7 blocking test shards ask Darkbloom for a Mac; the build jobs, Cluster Release Build Checks and Cluster GPU Tests use Blacksmith directly.
- Every macOS job samples its memory and CPU use and prints the peaks; the samples upload as `resource-samples-*`. The sampler never fails a job. The products hand-off prints the archive size and the upload and download times.

### Provider CI: the prompt parity fixtures come from a verified cache

- Provider shard 1 restores the prompt artifacts that both Prompt Parity steps read (tokenizers, templates and configs of the 7 v1 contracts and the Nemotron contract, 104 MB) from an Actions cache keyed by the hash of their manifests. Pushes to `dev` and `master` save it after both parity steps pass; pull requests restore it and save nothing.
- `scripts/prepare-prompt-fixtures.py --download-cache` (`PROMPT_PARITY_DOWNLOAD_CACHE` in both parity scripts) uses a cache entry only if it is a regular file with the pinned size and SHA-256. Any other entry is downloaded and replaced. A cache that cannot store an entry never fails the run. Contracts that share a tokenizer download it once.
- A contract's download deadline is now 120 s plus its missing bytes at 128 KiB/s, at most 900 s, instead of a flat 120 s. The 17 MB Nemotron contract that timed out at under 142 KB/s in run 42330647893 now has 256 s.
- For each contract the script prints how many artifacts came from the cache and how many bytes it downloaded, and how long that took.

### Provider CI: the diagnostics and placement flow runners compile, and CI runs them

- `provider-swift/Tests/ClusterDiagnosticsChecks/run.sh` and `provider-swift/Tests/ClusterPlacementChecks/run-flow.sh`
  compile again. Since 2026-11-04 both stopped at `cannot find 'GLM5NextGPULimitEligibility' in scope`, and CI ran
  neither, so nothing noticed.
- Shard 1 of Cluster Focused Checks now runs both, after the pairing runner, which adds about a minute (49 s and 18 s
  on CI). A change that breaks either fails that shard.
- A change to `GLM5NextGPULimitEligibility.swift` alone now runs the cluster jobs too, as the other provider files
  that the cluster runners compile do: the console, diagnostics and placement flow runners compile it.

### CI runs every test of `dev` every hour

- `.github/workflows/ci-dev-hourly.yml` runs from `master`'s schedule at minute 7 of every hour. It dispatches CI (dev) on `dev`, unless a dispatched run is still queued or in progress.
- A dispatched CI (dev) run selects every component and never skips a tested tree: every provider and cluster shard, the focused and release build checks and the non-blocking GPU shards. It uses the lanes, sizes and caches of a push to `dev`, and saves caches as that push does, so the 1.87 GB MiMo audio codec stays cached on `dev`. Dispatched runs share one concurrency group: a new dispatch never cancels a running one.
- When a job of a dispatched run fails, `Report hourly failures` comments on the open issue `Hourly full dev CI failures` (and opens it when none is open) with the run, the commit and the failed jobs.

### Provider CI: per-job macOS sizes for Darkbloom Sandboxes

- Each macOS CI lane can ask the Darkbloom plane for a size, `<vCPUs>x<GiB>`. The route job checks each size against this grammar and fails on a bad value before it sends a request.
- Sizes are sent only when the repository variable `DARKBLOOM_JOB_SHAPES` is exactly `on`. While it is off, the route request is byte for byte the request without sizes, and every job keeps the runner it has today.
- Each size comes from the job's sampled memory: the smallest signed size that holds 1.25 times its used memory (app + wired + compressed) without making the job more than 5% slower. While sizes are on, the 7 blocking test jobs ask for 4x16 (provider shard 1, cluster runtime shard 1, both Cluster Focused Checks shards), 4x24 (provider shard 2, cluster runtime shard 3) or 12x32 (cluster runtime shard 2, 29.3 GiB). Build cluster test products and Cluster Release Build Checks ask for 8x16 and Build provider test products for 12x32, on the `required` lanes `build-cluster`, `build-provider` and `cluster-release-checks`. A run that tests every component then asks for 10 macOS jobs. While sizes are off, the `required` jobs use `blacksmith-12vcpu-macos-27` without asking.
- The 2 Cluster GPU Tests shards are not routed. Shard 2 uses 42 GiB, which no signed size holds, so both shards run on `blacksmith-12vcpu-macos-27`.
- A sized lane uses a grant only when its labels end in the qualified label, such as `darkbloom-macos-arm64-4x24`. Otherwise it keeps `blacksmith-12vcpu-macos-27`.
- For each lane, the route job's log and summary show the size asked, the runner, and the decision with its reason, such as `shape_not_signed`, `unavailable`, `unsupported_runner_class`, `image_not_available` or `lane_not_enabled`.
- The `DARKBLOOM_MACOS_LANES` cap still keeps the critical-path test lanes first. The `required` lanes come after them.

### Provider CI: smaller test products hand-off

- The test products archive leaves out what no test step reads: every `.dSYM` bundle (the test bundle's own included), the host tools (the `-tool` macro and `Modules-tool`) and SwiftPM's bare clones in `.build/repositories`. The coverage report reads the coverage maps in the binaries, not DWARF, so it does not change. A stalled-test sample now names each frame's function and offset, but not its file and line.
- zstd packs the archive at level 9 with a 2 GiB long-distance window, which stores repeated content such as the test bundle's metallib copies once. On the provider products of run 42318853015 the archive goes from 1,065 to 265 MiB. Unpacking needs the same window and about 2 GiB of memory.
- The pack step also prints the size of the archived files.

### Provider CI: the real-geometry rows check runs in two halves

- Cluster GPU Tests shard 1 ran one test, `rowsEqualTheirSoloStepsAndWindowPositionsAtRealWidths`, for 18 to 19 min. It ended at 22 to 23 min of every run, after the `Provider Tests` gate, so it set the run's wall time.
- `QwenTensorParallelRowsCheck.run` takes the halves of the check to run (`parts`, default both). The rows half checks the rows of 100 to 4,090 tokens: alone on a one- and an eight-lane host, beside rows that join and leave, while an assistant observes the cohort, and at every verify-window position. The segments half checks the rows of 4,000 to 4,600 tokens across KV segments. Each half compares only against the solo runs it makes itself and keeps its refusals: non-finite logits, reference logits that are not all distinct, a blind comparison (rows half), and rows within one KV segment (segments half). No row, width, step or window position is dropped.
- `QwenTensorParallelRealGeometryRowsTests` runs each half as a test: `rowsEqualTheirSoloStepsAndWindowPositionsAtRealWidths` (rows) and the new `rowsAcrossKVSegmentsEqualTheirSoloStepsAtRealWidths` (segments). Each test checks its half's digest count on both ranks (200 and 136, the whole check's 336). `darkbloom-cluster-tp-check qwen-rows run` still runs the whole check.
- Cluster GPU Tests has 3 shards. Shard 1 runs the rows half alone, the new shard 3 runs the segments half alone, and shard 2 does not change. All three run on `blacksmith-12vcpu-macos-27` and are not routed. A run that tests the cluster uses one more macOS job.

### Provider CI: shorter cluster runtime shards

- Cluster Runtime Tests runs in 5 shards instead of 3. The batch-session suite (672 s in one process) runs in two processes: its warm and SSD prefix tier tests in `base-batch-session-prefix-tiers`, its other tests in `base-batch-session`. Each runs beside one half of the Qwen GPU chain, on shards 2 and 3. The Gemma 4 base suites (610 s) run in two processes, each alone on its own shard: `Gemma4TensorParallelTests` on shard 4 and the other Gemma suites on shard 5. Every test still runs in exactly one selection.
- The two new shards ask for no new lane: shards 2 and 3 share the lane `test-cluster-2`, and shards 4 and 5 share `test-cluster-3`, each requested for 2 jobs. A run that tests every component asks Darkbloom for 9 macOS jobs while job sizes are off (7 before).
- The cluster plan audit checks that each Gemma suite runs whole in exactly one base selection of Gemma suites, and that each test of a split suite runs in exactly one of its selections.
- The CI plan checks run in their own job, Check the CI plans, beside the test jobs. The `Provider Tests` gate requires that job and no longer runs the checks after the last test job.

### Provider updates hash bundles in bounded memory; CI samples memory by class

- An install, a verify or a rollback of the provider no longer keeps every byte it hashes in memory. Each 1 MiB read of the bundle hash and the file hash now releases its buffer before the next read. Before, a rollback test of the debug CLI held 15 GiB until its test process ended. The hashes are unchanged.
- The CI resource sampler now records memory by class: app (with Metal buffers), wired, file cache, compressed and swap. It also records the physical footprint of each process, which includes Metal memory, the test selection each large process runs, and busy vCPUs from the host's CPU ticks. Each job's report and `summary.json` show the peaks, the three largest processes and the time the job would take on 4 and 8 vCPUs. The sampler stays report-only.

### DevNet and production no longer share a pair

- On a Mac with both the production app (`darkbloom`) and the DevNet app (`darkbloom-dev`), each app now keeps its own pairing, cluster setup, logs, cluster service and login job, each in its own folder (`~/.darkbloom` and `~/.darkbloom-dev`), and each app's pair uses its own ports on the cable. The DevNet app no longer reads the production app's pair, restarts its cluster service or removes its login job: `darkbloom-dev cluster pair --forget`, `darkbloom-dev cluster stop --service` and `darkbloom-dev uninstall` act on the DevNet app's pair only, and the production app's commands on its own only. This ends the 0.10.9 known limitation about the two apps on one Mac.
- Only one app's pair runs on a Mac at a time. Both apps take one device lock (`~/Library/Application Support/io.darkbloom.cluster/native-device.lock`, an empty file in a folder neither app owns) while a pair's part, a member's preparation or a GLM model check uses the GPU. The other app's pair then waits: its status says which app holds the Mac's GPU, and it starts by itself within seconds of that app's pair stopping. A wait never counts as a failing pair, so production never falls back to serving on its local API because DevNet held the Mac. A DevNet pair can no longer push a production pair out of memory.
- Production wins on a Mac both apps serve from. Production 0.10.10 and earlier take no lock, so the DevNet app also waits while a production serving process runs on that Mac (`darkbloom start`, a pair's part or its worker, read from the process list) or production's cluster service says its pair serves there (its published status, read only), and a running DevNet pair releases the GPU at once and stops once production starts serving there (say both start at login). So a waiting DevNet pair never takes the GPU while production's pair restarts, for example for its update. If production's status was written in the last two minutes but can't be read, the DevNet app waits too and says why. The DevNet app's single-Mac serving loads no model while production serves on that Mac either, so its requests go to other providers meanwhile. A cluster member run with the developer route `--always-on` waits for the other app's hold on the GPU without spending its restart budget. DevNet never tells you to stop production: production serves there, and its owner decides.
- Providers with the production app alone see no other change: its files, its login job and its ports are the same as before, and its pair takes the device lock, which nothing else holds there.
- After this update the DevNet app starts unpaired, even on a Mac where it had paired, and copies nothing from the production app: update the DevNet app on both Macs, then run `darkbloom-dev cluster` on both to pair it again. If the DevNet app was the last to pair on a Mac before this update, the production app's `darkbloom cluster` may say the Secure Enclave key changed: choose **Pair again** there.
- The two apps still share the models and the cable port setup (one cable, one network setup). Uninstalling one app keeps the cable port setup while the other app is installed, so it asks for no password, and removes only its own pairing, cluster setup and cluster service; the other app's uninstall undoes the cable port setup later. `cluster link --remove` in one app now names the other app when that app still uses the port and asks first, even with `--yes`; without a terminal it changes nothing.
- A model copy between the two Macs stages in the shared model store under its own app's name (production's `.darkbloom-incoming-…` as before, DevNet's `.darkbloom-incoming-dev-…`). A copy short of disk space frees only its own app's abandoned copies, never the other app's copy under way.

### A pair's leader can take its owner's local requests beside Darkbloom

- The member that hosts a pair's slot can now run the local OpenAI-compatible API while the pair serves through Darkbloom. Local and Darkbloom requests share the pair's one engine and its lanes: no second process or engine, and no extra copy of the stream. `darkbloom cluster` starts it when you choose **Both, me first** for the pair.
- Only that member runs it, and always with a key. Any other member still refuses a local API.
- While the pair isn't serving (it is forming, re-forming or stopped), a local request gets 503, as `darkbloom cluster local` answers, instead of a 500. A model the pair doesn't serve gets 404.
- When every lane is busy, a local request waits its turn in a bounded queue, as on `darkbloom cluster local` (`DARKBLOOM_CLUSTER_QUEUE_WAITING`, default 64): 429 when the queue is full, 503 when it waited too long. A waiting request is woken when a lane frees and is never polled; Darkbloom requests never wait for it.
- A local request that arrives while the pair runs its first test request waits until the pair opens, and gets 503 if the pair stops instead.

### `darkbloom cluster leave`: leave a pair in one command

- `darkbloom cluster leave`, on either Mac of a pair, stops this Mac's part (the pair stops on both Macs while the other Mac answers, then this Mac's cluster service leaves login) and forgets this Mac's pairing, the same steps `darkbloom uninstall`, **Start over** and `darkbloom cluster pair --forget` take. Leaving no longer takes four steps: `cluster pair --status`, reading a pin, `cluster pair --forget <pin>`, then `start`.
- In a terminal it says what leaving does and asks `Leave the pair? [y/N]` (No by default); without a terminal it needs `--yes`. A part that doesn't stop leaves the Mac paired, and the command says so.
- It ends with this Mac's next steps (`darkbloom start` serves it alone, or `darkbloom cluster` pairs it again), what the stop did to the other Mac and that it keeps its pairing until you run `darkbloom cluster leave` there, and how the two Macs pair again (`darkbloom cluster` on each, Start over on the other Mac).
- It says only what happened to the other Mac: "stopped serving the pair too" only when it did, "wasn't asked to stop" when nobody asked it, and, when it didn't answer, that it may have left the pair already.
- On the leading Mac, the forget step no longer says the other Mac's pair cache stays until `darkbloom cluster pair --forget <its 64-digit pin>` there, which was false once that Mac had left. When it isn't reached, it says "If that Mac is still paired, run `darkbloom cluster leave` there." `cluster pair --forget` and `uninstall` say the same.
- While leaving, and in `darkbloom uninstall`, the stop no longer says "Run `darkbloom cluster` to serve again", "to start it again", or to stop the other Mac's service with `cluster stop --service`: the last lines say what to do next. `uninstall`'s summary says when the other Mac didn't answer.
- The Mac left behind can't tell the other Mac having left from it being off: its `status`, `cluster status` and a `start`'s result now end "If the other Mac left the pair, `darkbloom cluster leave` here unpairs this Mac too." instead of saying `start` on either Mac starts the pair, and `darkbloom cluster` there offers Start over or `darkbloom cluster leave` for a Mac that left.

### Both, me first for a pair, in `darkbloom cluster`

- In a terminal, `darkbloom cluster` now asks how a pair serves, with the single-Mac start's three choices: **Only me
  (this pair, local)**, which is `darkbloom cluster local`'s way, **Darkbloom network**, or **Both, me first**, which
  is preselected. On a set-up pair, the list's **Change how the pair serves** asks again. The answer is saved in
  `[local] mode` once the start goes ahead. `darkbloom cluster local` is unchanged and asks nothing.
- With **Both, me first**, the Mac that runs the pair's first part also runs the pair's local API beside Darkbloom,
  with the pair's key, on every network of that Mac. Its port is the first one from 8001 to 8020 free on both Macs,
  never 8000 or the pair ports 47420–47423. Darkbloom pauses for the whole pair while you use it and comes back 2
  minutes after your last request. The other Macs run no local API.
- Without a terminal nothing is asked or saved. The login service and scripts keep serving each pair as its setup
  says, and a pair set up before this build serves through Darkbloom with no local API, as before.
- The question says that the pair's pause, route and account key are the leading Mac's. **Serve locally only** at the
  login check after **Both, me first** saves no answer: the pair serves locally only, and **Only me** isn't saved.
- `darkbloom status` and `darkbloom cluster status` say whether Darkbloom is paused for you, the pair's local address
  (never its key), and that the other Macs are part of the pair. On the other Mac they say that `darkbloom local` on
  the leading Mac shows the address and key. No line shows a speed.
- Requests from other machines never use the paid network; they can use this Mac and your other Macs. A local API that
  other machines reach (a pair's, or one started with `--bind`) passes their requests to your Macs only, even with
  `route = "my-macs-first"`, and lists no network model to them. Programs on the Mac itself keep the route.
- `darkbloom start --cluster-member` takes `--local-endpoint --port --bind` from the cluster service, never with
  `--no-auth`.
- A pair's local API without a cluster approval (its leader registered with the coordinator, or serving locally because
  the coordinator couldn't take it) no longer asks the coordinator whether your other Macs serve a model before passing
  your request on to them, as `cluster local` already didn't. The coordinator's count never includes that leader, so
  with exactly one other Mac serving the model the request was refused as `this_mac_only` instead of going to that Mac.
- With **Only me** saved, by `darkbloom cluster` for the pair or by `darkbloom start`, a `darkbloom start --solo`
  without a terminal (a script) on a Mac whose pair doesn't run here is refused in one line, as on one Mac. This Mac's
  part of the pair keeps running, and its saved start stays.

### Every Mac of a pair answers locally in Both, me first

- With **Both, me first**, every Mac of the pair now has its own local API address, as with **Only me**
  (`darkbloom cluster local`), not only the Mac that runs the pair's API: each other Mac passes its own port to it over
  the cable. `darkbloom local` there prints `http://127.0.0.1:<port>/v1` and the key to use, `darkbloom status` names
  that address instead of pointing at the leading Mac, the setup's ✓ block prints this Mac's own address once its port
  is up, and `darkbloom start --opencode` or `--hermes` there sets the tools up for it.
- Each Mac's tools use that Mac's own key (`local_token`), with **Only me** and with **Both, me first**. The pair's API
  takes its own Mac's key and the pair's key (`cluster_local_token`), which tools set up before keep working with; the
  other Mac's port passes requests on with the pair's key.
- A pair's local API now takes each Mac's own saved `[local] port`, as every other local API on that Mac does, with
  **Only me** and with **Both, me first**: the Mac that runs the pair's API listens on its port, and each other Mac's
  port passes requests to it, so the ports can differ, and each Mac keeps its own whichever Mac runs the pair's API.
  Before, the pair's API took a port free on both Macs (Only me 8000 when free) and the other Mac took the same one. A
  Mac with no saved port keeps the one its local API already uses, else takes the first free one from 8001, never 8000
  or the pair ports 47420–47423, and saves it; a Mac updated from 0.10.10 keeps 8000. With the pair's API kept on its
  own Mac (`--bind` loopback or one address), the other Mac passes nothing on, as before.
- A saved port is never moved, a pair's included: when another program holds it, `darkbloom status` on that Mac names
  the port and says to free it, or set another `[local] port` in `provider.toml`, then run `darkbloom restart`. For the
  pair's API this replaces "`darkbloom restart` starts the pair's API on a free port".
- While Darkbloom doesn't have a **Both, me first** pair (no approval yet), the pair answers on the leading Mac only,
  and the other Mac passes nothing on: its `darkbloom status` says so, and never shows an address that resets every
  connection.
- While the Mac that runs the pair's API is away (unplugged, asleep), the other Mac's own port answers every request at
  once with a `503` (`code` `pair_mac_unreachable`) that says so: "Your pair's other Mac (…) isn't reachable; this Mac
  relays to it. Requests resume when it's back, or run `darkbloom stop`, then `darkbloom start --solo`, to serve this
  Mac alone." That Mac counts as away once it hasn't answered over the cable for 12 seconds. Only a request with this
  Mac's key or the pair's gets those words; any other gets the local API's usual `401`, or a `503` without names where
  the API needs no key. With **Only me**, that port used to close each connection unanswered then, for up to 15 minutes.
  `darkbloom status` and `darkbloom local` now say the same, and relaying resumes by itself within seconds of that Mac
  answering again. A request while that Mac's API doesn't listen gets a `503` with `code` `pair_api_unavailable`.
- On the other Mac, `darkbloom local` and `darkbloom start --opencode` say why it has no address for the pair (Darkbloom
  doesn't have the pair yet, its port is held, or the leading Mac is away), as `darkbloom status` does: `local` no
  longer prints the pair's key there, and `--opencode` says it at once instead of after a 30-second wait. While that
  address is still starting, `local` says so beside the pair's key, instead of "No local server running."
- The app's **Start serving** on the other Mac no longer says "No local API was added on this Mac" when the pair's API
  is on every address: that Mac's relay gives it one. While the relay can't answer (the leading Mac away, Darkbloom not
  having the pair, its port held), the app says `status`'s `Local API:` line instead. With the pair's API kept on the
  leading Mac, **Only me** included, the line stands.
- The solo server a pair falls back to when one Mac is away for 10 minutes takes that Mac's own saved `[local] port`
  too, instead of 8000, so its tools keep their address.
- A request on the other Mac's port pauses Darkbloom for the pair, as one on the leading Mac does, and never uses the
  paid network: the pair's API sees it come from that Mac.
- `darkbloom start --opencode` on a paired Mac waits up to 30 seconds for that Mac's local API after the pair starts,
  and says at once when the pair serves only the Darkbloom network.

### Me first for a pair: Darkbloom pauses while you use the pair

- While you use a pair through its leader's local API, the pair takes no new Darkbloom requests. It takes them again
  two minutes after your last request ends (`[local] me_first_idle_minutes`). `[local] me_first = false` keeps today's
  shared serving.
- Darkbloom requests already running finish, and nothing is cut. A request that races the pause goes to another Mac.
  The pair keeps its session and its loaded model.
- The leader decides for the pair: its heartbeat says `draining` with `busy_reason: "owner"`, which takes the whole
  pair out of routing, your own `self` and `prefer` requests included. The other members don't change, and nothing
  assumes two Macs.
- The pair's base reward while it is paused depends on the coordinator. From
  [darkbloom-platform#709](https://github.com/Layr-Labs/darkbloom-platform/pull/709) on, the pair keeps it, as a single
  Mac does. On coordinators before #709, both Macs lose it for the pause plus the idle minutes, as for any pair drain.
- It costs next to nothing: one heartbeat when the pause begins and one when it ends, an O(1) update per local
  request, and an idle check on the member's existing 5-second beat.
- `darkbloom cluster` starts the leader's local API when you choose **Both, me first** for the pair.

### A pair takes the long requests it can serve and reports its speed

- A Qwen 3.8 27B pair in tensor parallel now accepts `max_tokens` up to 65,536, the catalog's output limit and the value the coordinator gives a request that omits `max_tokens`. It accepted at most 32,768 before. In production, five 18,774-token prompts that asked for 65,536 were refused with 503 `request_exceeds_context`, although single Macs served requests of the same size. Prompts up to 262,143 tokens and the 262,144-token context are unchanged. Each Mac's memory gate still decides, request by request, whether a long request fits.
- The leader's heartbeat now tells the coordinator which requests the cluster serves, for every Mac in it (`request_limits` on its slot): the prompt, output and context limits of the mode it runs, and the context that every Mac's memory admits now. A pipeline reports the 32,768 + 32,768-token request its Macs accept, and its leader refuses a longer request itself before asking either Mac.
- The release's public envelope for each mode now carries those limits instead of 1,048,576 for prompt and output. For a model whose clusters serve the public, larger requests go to single Macs instead of to a refusal.
- A pair's slot now reports measured prefill and decode speeds from the requests it serves, as a single Mac's slot does. A prompt is measured as it ran, up to its first token, so a prompt that ran alone counts as isolated even when another request joins its answer. Before, it reported none, so the coordinator could not predict a pair's first-token time and a free single Mac always took the request first. The warmup request a pair runs before it opens is not counted.
- Providers no longer log an error every 30 seconds while connected. The coordinator's round-trip probe is a WebSocket ping that carries a counter, and the provider tried to read it as a message. On a pair leader, this showed up in the system log as an error of category `coordinator` with a hidden (`<private>`) message. It never affected serving.

### The cluster setup quotes no speeds, and its recommendation follows the pair's measurements after an update

- `darkbloom cluster`'s model list no longer shows tokens per second. It named each mode with the speed the pair
  served it at ("Gemma 4 26B · tensor parallel 96 tok/s or pipeline (not measured on these Macs yet)"); it now
  names the modes only ("Gemma 4 26B · 15.6 GB · tensor parallel or pipeline"), the one the mode question recommends
  first. A model named on the command line (`darkbloom cluster local <model>`) starts in that mode too. The mode
  question already quoted no speed.
- After a Darkbloom update, until one of a model's modes has served with the new build, the mode question ranks the
  modes by what the two Macs served with an earlier build that recorded how it served (through Darkbloom or locally,
  with or without Qwen's tensor assistant). Builds record this from 0.10.11 on, so it first applies at the update
  after 0.10.11: updating from 0.10.10, whose records don't say how they were served, the question still recommends
  from the planner's prediction until a mode has served with 0.10.11. Once a mode has served with the new build, that
  build's measurement decides, as before. On one DevNet pair the question said "Pipeline, faster here" for Gemma 4 26B
  right after an update, although the pair had served tensor parallel faster before; from its earlier
  tensor-parallel measurement it now recommends tensor parallel.
- The developer setup wizard (`darkbloom cluster --wizard`) no longer shows predicted speeds on its model step or its
  help, or a speed on its check's result. A test prompt sent from its last step still reports that request's speed.

### A two-Mac pair's local API no longer cuts a failed stream short

- When the provider rejects a streamed chat completion's output mid-generation on a pair (for example a named or required `tool_choice` the model answers with text, or a streamed tool call that fails validation), the leader's local API now ends the stream with the same error chunk (`finish_reason: "error"`) as one Mac. Before, the client could get HTTP 200 and the chunks already sent, then the connection closed with no error chunk. Some clients took that cut-short stream for a complete answer.

### A pair comes back by itself after an update

- After both Macs of a pair restart into an update, the leading Mac stops the pair once to set it up again for the new release, and again to save the release's cluster approval. When that stop failed (the other Mac didn't answer in time, or refused it because it had taken the lead for a moment while the leading Mac restarted), the pair stayed stopped on both Macs ("Stopped; last model …") until someone ran `darkbloom cluster`. Now a failed stop keeps the pair started, and the leading Mac tries again: the setup 10 minutes later, the approval at its next check, a minute later.
- The leading Mac now sets the pair up after an update, and changes its cluster approval, only once the other Mac has confirmed that it leads (or hasn't answered for 30 seconds), as `darkbloom cluster` already did for a person's commands. While the other Mac doesn't answer, it doesn't stop the pair to change its approval, which needs both Macs; it changes it once the other Mac answers again.
- A stop you make during these steps holds: neither step starts the pair again. `darkbloom stop` and `darkbloom start --solo` on a Mac where the pair doesn't run now wait, up to 10 minutes, for a cluster command that is running, as `darkbloom cluster stop` does. They say so at once, and if the command is still running after those 10 minutes, they say so and stop or start nothing.

### `darkbloom --opencode` and `darkbloom --hermes`

- `darkbloom --opencode` is `darkbloom start --opencode`, and `darkbloom --hermes` is `darkbloom start --hermes`;
  both together work too. Any other `start` option goes with them, in any order (`darkbloom --opencode --me-first`,
  `darkbloom --me-first --opencode`), and `start`'s errors and refusals apply. `darkbloom start --opencode` keeps
  working; `--help`, `--version`, plain `darkbloom` and every subcommand are unchanged, and a mistyped flag
  (`darkbloom --opencod`) gets the usual unknown-option error.
- `darkbloom --help` shows the two shortcuts, one line each.
- The lines that name the command say the short form: `darkbloom local`'s `tools:` line, the line `--port` prints
  when it replaces a saved port, the refusals, the tool step's lines, the installer's closing lines, and the comment
  above the `darkbloom` block in OpenCode's and Hermes' configs (a config set up before keeps its line).

### Darkbloom watchdog reads any listing size and rescues partial strands

- `.github/workflows/darkbloom-watchdog.yml` is now darkbloom-sandbox's template at `d6d257c2`, copied unchanged. The old copy passed the day's run and job listings to `jq` as command-line arguments. When the repository was busy they were larger than Linux allows for one argument, and the watchdog failed with `Argument list too long` (exit 126) before it checked any run. It now passes listings to `jq` through files and stdin.
- A job's wait is timed from its own creation. Only a Darkbloom job of the run that got a runner within the wait holds the rescue back, so a run with one shard stranded while other shards ran is rescued too.
- The watchdog sees only GitHub: a job that waits at the payer's concurrency or resource limit looks stranded to it. Set `DARKBLOOM_WATCHDOG_MINUTES` above such waits. The repository variables are unchanged.

### `darkbloom doctor` knows how this Mac serves you

- The report opens with a `LOCAL API` section: how this Mac serves (Only me, Darkbloom network or Both, me first; what runs now, else your saved choice), its local API's address, whether it answers and on which port, whether its key file is there (the key is never shown), and whether OpenCode and Hermes point at it, or somewhere else. Every problem names the next command: `darkbloom start`, or `darkbloom restart` for a stopped background service (it starts again as saved), the free port to use, or `darkbloom --opencode` / `--hermes` to point a tool here again.
- A local API that stops answering is started again the way it serves now, never another way: Only me in a terminal with Ctrl-C there, then `darkbloom start --local --here` (`restart` never stops it, and would serve your saved choice); the background service with `darkbloom restart`; a service serving another way than your saved choice with `darkbloom start` and that way's flag.
- On a Mac set to Only me, `doctor` no longer checks what Darkbloom serving needs: the account link, MDM, coordinator health and trust, App Attest, attestation readiness, coordinator traffic and billing are skipped, with one line that says they aren't needed. This holds while Only me loads its models too, which the section says ("starting"). `--coordinator <url>` still runs them. `darkbloom verify` is unchanged.
- On a Mac in a two-Mac cluster, the section names the pair's way of serving and the Mac that runs the pair's API, or says the pair hasn't chosen yet. A paired Mac serving alone (`start --solo`) is described by what it serves, with `--solo` in its commands. A Mac whose own port passes the pair's API on, and can't now, says why in `status`'s words: with the other Mac away, its port answers 503 for now, and it says to wait, or to serve this Mac alone, never to restart.
- OpenCode and Hermes are read and judged as `darkbloom start` judges them: `localhost` is this Mac, and another file holding the same key is the same key.

### Gemma 4 thinks when asked to, and GPT-OSS reasons at the effort you send

- Gemma 4 thinks for every reasoning effort but `none`, as `reasoning_effort` or `reasoning.effort` (it ignored the effort before, and its template doesn't think by default). An explicit thinking switch still wins.
- GPT-OSS renders each effort at the nearest Harmony level: `none`, `minimal` and `low` as `low`; `medium` as `medium`; `high`, `xhigh` and `max` as `high`. `high` rendered `medium` before, and `minimal`, `xhigh` and `max` reached the template as sent. Every level works for GPT-OSS, through OpenRouter too, once the Mac runs this release; a Mac still on 0.10.10 renders `high` as `medium` until it updates.
- **Rollout:** Darkbloom's coordinator with darkbloom-platform#721 (the same effort mapping and the typed 400 for an unknown effort) is deployed before this release is tagged; no auto-update hold is needed.
- Darkbloom's coordinator maps every effort the way this provider does, and both check the same 446 cases and the same lists of model types (`fixtures/prompt-contract/v1/reasoning_effort_vectors.json`), so a model type added to one side only fails a test.

### A Gemma 4 pair serves the model's whole context and answers a long request as one Mac does

- A Gemma 4 26B pair now accepts prompts up to 262,143 tokens and up to 32,768 output tokens within 262,144, the model's declared context, in tensor parallel, as one Mac serving it does. Its pipeline keeps the 32,768 + 32,768-token request, as every model's pipeline does, so a longer request goes to tensor parallel or to one Mac. Before, it served 65,536. The pair is still loaded and planned for the 32,768 + 32,768-token request; each Mac's memory gate decides, request by request, whether a longer one fits now.
- On any pair, a `max_tokens` above the output limit the pair serves, or above what the prompt leaves of its context, is cut to fit, as on one Mac, and the answer ends with `finish_reason: length` if it gets there. Before, it was refused with 400 `output_too_long`.
- A prompt that fills the context a pair serves is refused with one Mac's 400, `context_length_exceeded`, and the words that name the window. A request both Macs' memory can't hold now gets one Mac's 503, "This Mac's memory can't hold this request right now. …". Both arrive before any SSE header. Before, a streamed request to the leader's local API in "Both, me first" got HTTP 200 and then "Response generation failed" (Gemma 4 26B on pair-2: prompts of about 40,600 and 58,000 tokens).
- `/v1/models` on the leader and `darkbloom cluster local` list the context and output the pair serves, and default an omitted `max_tokens` within them.

### Gemma tensor parallel prepares the next token while reading the last

- For requests without sampling (temperature 0, no logprobs, no logit bias or penalties), a Gemma 4 pair now starts the next token's work on the GPU before it reads the token it just made, as GLM's pair already does. On GLM this took a token from 13.4 to 12.0 ms on two M5 Ultras; Gemma's gain has not been measured yet. The output is unchanged.

### Gemma tensor parallel prepares the next token ahead for sampled requests too

- Requests that sample (temperature above 0, with or without logprobs), and greedy requests with logit bias or penalties, now also start the next token's work on the GPU before the last token is read. Each token is still the exact draw for its position and seed, so the output is unchanged (except that a request that already fails because one Mac stopped on its own may stream one extra token first, as on GLM). Greedy requests that ask for logprobs keep the old order.

### Gemma 4 tensor-parallel prefill can overlap its link traffic with compute (off by default)

- A Gemma 4 pair in tensor parallel can now split each prompt chunk's work after attention into parts, so one part's results cross the cable while the next part computes. On a two-Mac pair's GPUs the results are bit-identical to the whole chunk (not on the CPU backend, and not with more than two Macs); since nothing enforces that at full size, it stays off. On two M5 Ultras, 4 parts prefilled a 9,651-token prompt at 1,196–1,208 tok/s instead of 1,064 (+13 %), with identical output. It stays off by default; the bench tool takes `--prompt-parts`.

### Gemma 4 tensor-parallel prefill is nearly twice as fast

- A Gemma 4 pair in tensor parallel computed each prompt chunk's experts one token at a time on each Mac. Each chunk's experts now run together, with every value unchanged. On two M5 Ultras a 9,651-token prompt prefilled at 1,066 tok/s instead of 569, with identical output.

### The installer ends with `darkbloom --opencode`

- The installer's last lines say that `darkbloom --opencode` asks how this Mac serves (Only me, Darkbloom network, or
  Both, me first), then sets OpenCode up (`/models` → Darkbloom; `darkbloom --hermes` for Hermes), and that two Macs
  pair with `darkbloom cluster` on each. The last line is the command to run next, with its full path so it works
  before the shell picks up the new `PATH` line: `Next: ~/.darkbloom/bin/darkbloom --opencode`. Before, it listed
  `doctor`, `models catalog`, `models download`, `login` and `start`.
- `curl … | bash` prints these lines once the platform's copy of the installer is updated.

### Link control reports the end of a superseded session

- The listener did not report the end of a session that a newer session superseded. When the connector's record budget ran out, it said goodbye with `rekey` and dialed again at once. If its next session arrived before the listener's reader read the goodbye, the old session ended with no `disconnected` event. `testRecordBudgetRollsOverToFreshKeys` failed on master push run 42258366869 for this reason. Now a superseded session gives exactly one `disconnected` event, after the newer session's `connected`. The listener shuts down only the sending side of the superseded session, so its reader can still read the goodbye. The reason is `rekey` when the session ended as a rollover, and `superseded` for all other ends. Neither reason is a peer loss. When the edge stops, it also ends each superseded session that is still reading.
- `testRecordBudgetRollsOverToFreshKeys` waits again for the listener's `.rekey` disconnect, and also for the connector's. A new test parks the listener's first reader until the connector's next session supersedes it, and requires exactly one `.rekey` for that session, after the second `connected`. Another new test requires one `.superseded` for a superseded session with no goodbye when the edge stops.
- `testReconnectResumesExactlyOnceInOrder` waits for the client's resumed `.connected` event instead of reading the client log at once after a wait on the server log.

### This Mac serves its model's whole window and holds every request to it

- A request to this Mac's own API that names no `max_tokens` (curl, the OpenAI SDKs, any client that leaves it out) may now write up to 32,768 tokens, as on a pair. Before, it stopped at 8,192 tokens, or 4,096 on MiMo V2.6, Nemotron Super and GLM-5.3-Flash, which could cut a thinking model off before its answer. Diffusion Gemma keeps its generation config's own default. That default is cut to the context window the prompt leaves, so a long prompt without `max_tokens` is served until the window is full instead of being refused.
- Every model is held to its window on this Mac: the context it advertises (GLM-5.3-Flash, MiMo V2.6, Nemotron Super), else its model's own (Gemma 4, Qwen 3.5, 3.6 and 3.8, GPT-OSS, Nemotron Lightning). A `max_tokens` larger than what the prompt leaves is cut to fit, on every model, and the answer ends with `finish_reason: length` if it gets there; before, a model that advertises a context refused it, so OpenCode and Hermes, which name a `max_tokens` on every request, were refused 32K to 65K tokens before GLM's, MiMo's or Super's window was full. Only a prompt that leaves no room is refused, with 400 `context_length_exceeded` and a message naming the window; before, on a model that advertises no context, it ran past the window.
- This Mac's `/v1/models` lists each of its models' window as both `context_length` and `max_output_length`, so `darkbloom start --opencode` and `--hermes` write the model's own output limit instead of the catalog's. A pair's leader lists the context and output the pair serves, which it holds every request to.
- This Mac's API now says which bound a request met. A request this Mac's memory can't hold now (on a paged slot, the default, one that can never fit; the rest queue) gets 503 before any SSE header, streamed or not, "This Mac's memory can't hold this request right now. Lower max_tokens or shorten the prompt (or send less media), or retry when this Mac's other requests finish."; before, a non-streamed one got "Provider capacity is temporarily unavailable.", and a streamed one HTTP 200 and then "Response generation failed".
- Network requests (OpenRouter's included) change only where the coordinator's estimate undercounts the prompt, as it can for dense text: the coordinator refuses an estimated prompt plus `max_tokens` past the catalog's context (413) before any provider sees it, so only an undercounted request reaches a Mac with an oversized total. Such a request is now served, cut to the window and ending with `finish_reason: length`, instead of being refused with 400 on GLM-5.3-Flash, MiMo V2.6 and Nemotron Super, or running past the window on the other models; one whose prompt alone fills the window is refused with 400, as before on the first three.

### Your own requests pause Darkbloom on your Mac

- With the local API beside Darkbloom (`darkbloom start --local-endpoint`), the Mac stops taking Darkbloom requests
  while one of your requests uses a model on it, and takes them again once none of your requests has run for 2 minutes
  (`[local] me_first_idle_minutes`, 1 to 120). Before, your requests and Darkbloom's shared the Mac.
- **This starts with this update on every Mac already serving with `--local-endpoint`**, including the desktop app's
  "Alongside the network": it pauses Darkbloom while you use its local API. Darkbloom requests already running finish.
- To keep sharing the Mac, set `me_first = false` under `[local]` in `provider.toml`
  (`~/.config/darkbloom/provider.toml`), then restart serving (`darkbloom restart`).
- Listing models, health checks, `/metrics` and the tokenizer utilities don't count, and neither do requests refused
  before they hold a model (a model the Mac doesn't serve, a load that doesn't fit, a drain).
- `darkbloom start --local` never connects to Darkbloom, so it has nothing to pause.

### Me first: Darkbloom pauses while you use your Mac

- The provider can pause Darkbloom requests while you use this Mac through its local API, and take them again once
  none of your requests has run for the idle time (`[local] me_first_idle_minutes`, 2 minutes by default).
- While paused the Mac stays connected, keeps its models loaded and keeps its uptime. Darkbloom requests already
  running finish, and new ones go to other Macs. Heartbeats say `draining` with `busy_reason: "owner"`, which
  coordinators treat as a plain drain.
- It is event-driven: a heartbeat only when the pause begins or ends, one timer only while your idle time counts down,
  and nothing at all when it is off.

### Local-first settings in provider.toml

- `provider.toml` takes a new `[local]` section for using your Mac yourself, beside or instead of Darkbloom: `mode`,
  `me_first`, `me_first_idle_minutes` (default 2, from 1 to 120), `route`, `port` and `bind`. The provider reads and
  checks it. Serving uses `mode`, `me_first` and `me_first_idle_minutes` for the local API beside Darkbloom; it does
  not use `route`, `port` or `bind` yet.
- Without `[local]`, nothing changes, except on a Mac serving with `--local-endpoint`: it now pauses Darkbloom while
  you use its local API ("Your own requests pause Darkbloom on your Mac"). A value the section can't take stops the
  provider at startup with one plain line that names the key, for example
  `[local] me_first_idle_minutes must be a whole number of minutes from 1 to 120, not 0.`

### One start screen: only me, the Darkbloom network, or both with me first

- In a terminal, the first `darkbloom start` asks how this Mac serves: **Only me, on this Mac**, **Darkbloom
  network**, or **Both, me first** (pre-selected: Darkbloom pauses while you use this Mac and comes back after 2 idle
  minutes). With an account key saved, it also asks where your requests go when this Mac can't take them. The answer
  is saved in `[local]` once the start goes ahead; later starts don't ask again, and `darkbloom start --choose` asks
  again. See [Use your Mac yourself, first](docs/provider/local-first.md).
- Starts without a terminal (the login service, the app, scripts) never ask. Without a saved choice, a plain start
  keeps today's behaviour exactly: the Darkbloom network, no local port, nothing written. **Changed:**
  `--local-endpoint`, which the desktop app's "Alongside the network" passes, now pauses Darkbloom while you use the
  local API (below).
- A saved **Only me** serves in a terminal. A start without one, such as the app's Start, is refused in one line
  before anything stops or starts, naming `--local`, `--network` and `--me-first`.
- New flags, for one start: `--network`, `--me-first`; saved settings: `--no-me-first`, `--me-first-idle <min>`,
  `--route this-mac|my-macs|my-macs-first`. Contradicting flags such as `--local --me-first` are refused before
  anything runs. On a paired Mac they need `--solo`, like the other single-Mac options.
- **Changed:** `--local-endpoint` now means Both, me first: Darkbloom pauses while you use the local API.
  `--local-endpoint --no-me-first` keeps the old shared serving. Its LaunchAgent arguments are unchanged.
- A new local API takes the first free port from 8000 up, never 8000 itself (other local AI apps use it) or the
  pair ports 47420–47423, saves it and says which; `--port` still picks one.
- `darkbloom status` says how this Mac serves in one line (for example `Serving: you first — Darkbloom paused since
  14:02 …`) and where your requests go, with whether an account key is saved. `darkbloom local` adds the same, and
  names `start --me-first` beside `start --local`. With `--no-auth`, `start` and `status` say your requests stay on
  this Mac. No start screen prints the local key (except `--local`'s own banner, as before), and no screen shows a
  speed.
- `darkbloom start`'s lines, such as its banner and `Listening on …`, now show at once when its output goes to a log
  or a pipe (`start … > log`). Before, a start that serves held them until it stopped.

### A streamed local request that can't get this Mac's memory is a 503 before any header

- A streamed request to this Mac's API sends its response head once the engine admits it. One the engine queued for
  memory and then couldn't admit, because its 120 s admission lease ran out or a full paged pool outlasted its
  requeues, now gets HTTP 503 with "This Mac's memory can't hold this request right now. Lower max_tokens or shorten
  the prompt (or send less media), or retry when this Mac's other requests finish.", before any SSE header. Before,
  it got HTTP 200 and then "Response generation failed".
- A request that isn't streamed and outlasts the admission lease gets the same words (they were "Provider capacity is
  temporarily unavailable.").
- The prompt progress comments start when the engine admits the request, so a queued request says nothing until then:
  while the engine keeps it queued, its client gets no bytes, headers included, for up to the 120 s lease before its
  503. Before, it got its head at once and a `: prefill in progress` comment every 5 seconds. A request the engine
  admits at once gets its head within a few milliseconds.
- A pair's API, Darkbloom's requests and a Nemotron Super request that asks for logprobs (its entries are spliced as
  the stream is read) are unchanged. A request admitted and later preempted, and never admitted again, still ends a
  streamed answer with an error event.

### This Mac's model list says what each model takes, and a long prompt shows progress

- This Mac's `/v1/models` lists each model's `input_modalities`: `["text", "image"]` for a model it serves with vision, and on a pair's leader the media the pair takes (`["text", "image", "video"]` for GLM-5.3-Flash and Qwen 3.8 27B in tensor parallel, `["text", "image"]` on the GLM and MiMo image candidates, `["text"]` on the other pairs). For a model this Mac or its pair serves, `darkbloom start --opencode` and `--hermes` give image input exactly when the list does, whatever Darkbloom's catalog says: MiMo V2.6, which the catalog lists as text only, gets it, also when the catalog can't be reached, and a Gemma 4 pair, which serves text alone, no longer gets image input its requests would be refused for (400). Your other Macs' and the network's models keep the catalog's. Reasoning still comes from the catalog.
- A streamed request to this Mac's API, or to a pair's, gets an SSE comment every 5 seconds from the moment the engine admits it (on a pair's API, accepts it) until its first token: `: prefill in progress, <total> prompt tokens`, which OpenAI clients ignore. Before, a long prompt streamed nothing after its first chunk until its answer began (9 minutes for a 255K-token prompt on an M3 Ultra). `<total>` is the prompt's tokens as the engine counts them. Once an engine reports how much of the prompt it has computed, the comment gives that count instead (`: prefill <done>/<total> tokens`); today's engines report it only when the prompt is done. A prompt done within 5 seconds gets no comment. A request that isn't streamed gets nothing new: give its client a timeout of minutes for a long prompt.

### This Mac's model list says which models reason

- This Mac's `/v1/models`, and a pair's, lists `"supported_features": ["reasoning"]` for each model it serves that reasons, loaded or not, and `[]` for one that doesn't, by the model's type: the same table that takes every reasoning effort for a model and refuses one that is none of the names. Your other Macs' and the network's models keep the coordinator's `supported_features`, the catalog's.
- `darkbloom start --opencode` offers reasoning for a model this Mac or its pair serves exactly when the list says so, whatever Darkbloom's catalog says, also when the catalog can't be reached. Qwen 3.8 27B, which the catalog lists without reasoning, now gets it; a model whose effort would be ignored no longer does. Hermes has no per-model reasoning setting in a provider's block and sends your effort to every model; the ones that reason take it and the others ignore it.

### One local API port per Mac, and a local API that can't listen says why

- Every local API this Mac serves takes the same port: Only me and Both, me first from the start question, a saved choice, `--me-first`, `--local`, `--local-endpoint` and the Darkbloom app's starts, its local mode included. The first one saves it as `[local] port`, and every later start uses it, so the address your tools were given (`http://127.0.0.1:<port>/v1`, with the key in `~/.darkbloom/local_token`) never moves. Before, `--local`, `--local-endpoint` and the app took 8000 while the start question took 8001.
- A Mac whose local API already serves keeps that port and saves it: the running API's port, else the one its installed background service serves on. A Mac updated from 0.10.10, whose local API serves on 8000 (the app's setup, "Alongside the network", "Local only", `--local-endpoint`, `--local`), keeps 8000: ``Local API port: 8000 (saved; this Mac's local API already uses it).`` Only a Mac with no local API at all takes the first free port from 8001, never 8000 or 47420–47423.
- A saved port always wins, and is never moved. `--port <n>` replaces it and is saved too: ``Local API port: 8007 (saved, instead of 8005: tools set up for 8005 need `darkbloom --opencode` or `--hermes` again).``
- A Mac without `[local]` started without a terminal still serves exactly as before: the Darkbloom network, with no local API and no port.
- When the local API of Both, me first can't listen, `darkbloom status` no longer reads "Darkbloom network only": it says ``Serving: Darkbloom and you, me first — the local API isn't up: port 8001 is in use (`darkbloom start --port 8002`)``, and `darkbloom local` says the same. Only me names the next free port the same way. On a Mac in a two-Mac cluster these lines name `darkbloom start --solo --port <n>`, or `darkbloom restart` for the pair's own API.
- The app's local mode runs as launchd's `--foreground` service on that port, saves a new port only once the service started, and its log no longer shows the local key.

### Local API: this Mac first, then your Macs

- The local API (`start --local`, `--local-endpoint` and a pair's local API) now routes like the iPhone app. A request
  this Mac can't take (it doesn't serve the model, its queue is full, or it is draining) goes on to your other Macs
  (free) with `[local] route = "my-macs"`. With `"my-macs-first"` it goes to your Macs first and then the Darkbloom
  network (billed), without waiting on a busy Mac of yours while another Mac can take it. When the network refuses it
  for money (no balance, or the key's spend cap), it goes to your Macs only, free. Nothing leaves this Mac without a
  saved account key, with `route = "this-mac"`, or with `--no-auth`.
- `darkbloom route key` saves the account API key in this Mac's Keychain after one check with Darkbloom
  (`--stdin` to pipe it in, `--remove` to remove it). The key is never printed, logged, or written to a file. ^C at
  its hidden prompt gives the terminal its echo back.
- The local API reads the key once and keeps it in memory; `route key` tells it when the key changes. It never waits on
  a Keychain dialog to read the key: when the Keychain won't hand it over without asking (a locked keychain, or a new
  local build), it says so once in its log and keeps requests on this Mac.
- Tools keep one local URL and the local key. Their own route header is ignored. Answers say who served them
  (`X-Darkbloom-Served-By: this-mac` or `darkbloom`), and the coordinator's errors come back as sent. A refusal on the
  network route says why: no balance, or Darkbloom's own reason (a key's spend cap, for one). A client that disconnects
  mid-stream stops the request at the coordinator too.
- `/v1/models` lists this Mac's models, then your Macs' (and the network's with "My Macs first"), each once, with
  `owned_by` and, when known, `context_length` and `max_output_length`. This Mac's models now say
  `owned_by: "this-mac"` instead of `"local"`. A model this Mac serves is listed once, under its own id, even when your
  Macs list it under its public alias, and a request for that alias is answered by this Mac.
- A chat request that names only `max_completion_tokens` is served with that limit, as `max_tokens` is.
- A request this Mac serves takes the same path as before, plus a few microseconds.

### Me first: queued Darkbloom requests make room for yours

- On a Mac that serves both with me first on, a request of yours that has to wait for this Mac's memory, or its room
  for requests, no longer waits behind Darkbloom requests still queued here. Those go back to the network: they end
  with the typed `capacity / 503 / draining` refusal, which doesn't count against this Mac. Each is served by another
  Mac, or gets a retryable "busy" error (429) if the whole network is full. Darkbloom requests this Mac has started,
  in their prompt or answering, still finish.
- Your request then waits only for requests this Mac has started, Darkbloom's or your own, up to the engine's 120 s
  admission lease, as before.
- Nothing changes with `--no-me-first`, or on a pair.

### The memory re-plan keeps a stopped pair stopped and a started one started

- When a Mac's part of a pair is refused at load twice because its memory moved, the leading Mac plans the model again on the memory now. That re-plan could come due right after you stopped the pair with `darkbloom stop`, and then started it again. It now does nothing once the pair is stopped, as the leading Mac's steps after an update already do.
- When that re-plan's own stop of the pair failed (the other Mac didn't answer, or a part didn't release in time), the pair stayed stopped on both Macs until someone ran `darkbloom cluster`. Now the pair stays started, and the re-plan can come due again.

### metal-cpp from the Darkbloom sandbox image

- `scripts/fetch-metallib.sh` uses the metal-cpp archive that Darkbloom's macOS sandbox images carry, when it is the archive the nested MLX core names and its SHA-256 matches the pin. The metallib build then makes no download from developer.apple.com, where downloads through the sandbox's egress ended early (`transfer closed with … bytes remaining`). Elsewhere, MLX's configure downloads the archive as before.
- Changing the script changes the metallib cache key once: the first CI runs after this change rebuild the metallib.

### MiMo image fixture downloads stay on their host

`scripts/prepare-mimo-image-http-fixtures.py` now follows a redirect only to
the scheme, host and port of the requested URL, for at most 10 redirects. curl
no longer follows redirects itself, so the script never requests another
origin. A redirect to another HTTPS host, another port or plain HTTP fails at
once and is not retried. The provider test gate now runs the script's offline
self-test on every run.

### MiMo prompt fixture downloads follow only allowed redirects

`scripts/prepare-mimo-prompt-fixtures.py` now follows a redirect only when the
target keeps the scheme, host and port of the URL that redirected, or when
`https://huggingface.co` redirects over HTTPS to a Hugging Face CDN host
(`hf.co` or a name that ends in `.hf.co`), where the Hub serves
`tokenizer.json`. Any other redirect (another host, another port or plain HTTP)
fails at once, is not retried, and its target is never requested. Before, the
script followed any redirect and refused only a final plain-HTTP URL. The
prompt fixture downloaders now share this rule in `scripts/fixture_redirects.py`.

### A Nemotron Super video that decodes too slowly on a provider is retried elsewhere

- When the wait on the video decoder outlasts its decode allowance (5 s, then 2 ms a frame and 4 ns a coded pixel, at most 120 s of wall time), as on a slow or loaded Mac, Nemotron Super now refuses the request as a retryable 503 (failure code `capacity`), and the coordinator can send it to another provider. Before, the provider refused the valid video as `invalid_media` (400).
- The video's own limits (frame size, frame grid, source frames, control markers, decoded pixels) are still `invalid_media` (400).

### Only me serves in the background, and the background service always serves your saved choice

- **Only me** now serves in the background, as Darkbloom network and Both, me first do: the provider LaunchAgent the Darkbloom app's local mode uses, on this Mac's one port. It starts again at login, the watchdog restarts it after a crash, and it updates itself (a check 5 minutes after it starts, then every 30 minutes; it lets your requests finish first). Closing the Terminal window no longer stops it; `darkbloom stop` does. `darkbloom start --local --here` serves in the Terminal window instead, for that session.
- Only me gets the same **model list, downloads included**, and the same **memory question** as the other choices, and models idle past that setting are unloaded. When Darkbloom's catalog can't be reached, it serves the models already on the Mac. A Mac with no model it can serve ends with ``No model to serve yet. See them: `darkbloom models catalog`. Get one: `darkbloom models download <id>`, then `darkbloom start`.``
- A start without a terminal (the app's Start, a script) now serves a saved Only me in the background, instead of refusing, and asks nothing: the models you last chose that are still on the Mac, else every one it can serve.
- **The Darkbloom app's choices are saved too:** "Local only" saves Only me, and "Alongside the network" and the app's setup save Both, me first, so the app's Start, Restart and Update keep serving the last choice, as login and the watchdog do. A Mac whose app ran "Local only" before now updates itself there and unloads models idle past `idle_timeout_mins` (60 by default).
- Only me reports itself alive from the start, while it loads its models, as Darkbloom network does: the watchdog never takes a first load longer than 5 minutes after an update for a failed start (three of which would roll the update back), `darkbloom stop` and `restart` during it drain it, and `darkbloom status` says `Serving: only you, on this Mac — starting: its local API opens once its models are loaded`.
- **A mode flag saves the choice** (`--local`, `--network`, `--me-first`, `--local-endpoint`), as the start question does. The background service, `darkbloom restart` and `darkbloom update` always serve the saved choice: a service an earlier version or start left serving another way restarts as saved, and says so. Before, `start --me-first` on a Mac set to the Darkbloom network kept serving Both, me first after `restart` while the config said network.
- `restart` and `update` wait for Only me's local API, never for coordinator authorization, and never stop Only me running in a terminal (`--here`): they say to press Ctrl-C there first.
- Starting Only me where Darkbloom served says so: ``Darkbloom network serving stops: this Mac serves only you from now on (`darkbloom start --me-first` serves Darkbloom and you).`` `start --local --here` says what it stops, and on the way out that nothing serves now and how to serve again.

### OpenCode and Hermes: the config writers for `--opencode` and `--hermes`

- The writers that make OpenCode 2 and Hermes Agent ready to use Darkbloom as a provider, called by
  `darkbloom --opencode` / `--hermes`.
- OpenCode gets a `providers.darkbloom` block in its global `opencode.jsonc` (or an existing `opencode.json`): the
  local endpoint at its live port from `local.json`, the models with their names, context and output limits and
  capabilities, and `max_tokens` as the output-cap field (OpenCode otherwise sends `max_completion_tokens`, which the
  engine ignores, so a long answer would stop at its 4,096-token default). Its default model is set only when no
  global config file sets one: with both files, the owner's default in `opencode.json` stays in effect.
- Hermes gets `providers.darkbloom` (`key_cmd`, `extra_body.max_tokens`, each model's context and vision) and
  Darkbloom as its main model in `$HERMES_HOME/config.yaml` (`~/.hermes/config.yaml` by default), as `ollama launch`
  and `omlx launch` make theirs. Models under Hermes' 64,000-token floor are left out, and none at or above it
  refuses. A file in PyYAML's style, with lists at their key's indent as oMLX writes it, is edited and its lists kept.
- Hermes needs v0.20.2 or later, which added `key_cmd` (an older Hermes sends no key); the start flag warns in one
  line when the installed Hermes is older. An open Hermes bug (#124289) can drop `max_tokens` after a `/model … --provider <bare name>` switch, so
  those turns get the engine's 4,096-token default.
- Neither file ever holds the key: OpenCode reads it with `{file:~/.darkbloom/local_token}`, Hermes with
  `key_cmd: /bin/cat …`. Every comment and key outside the `darkbloom` block stays (the block itself is rewritten
  whole); a second run with the same models writes nothing; a change first backs the file up to
  `~/.darkbloom/integrations/backups/` (five kept per file name), replaces it atomically and comes with an exact undo
  command. A file Darkbloom can't edit safely (invalid, YAML anchors, several documents) is refused, unchanged.
- `scripts/integrations/opencode-smoke.sh` runs the real OpenCode on the written config in a throwaway home against a
  fake server.

### The Mac that follows no longer says a serving pair hasn't served

- On the Mac that follows in a two-Mac pair serving through Darkbloom, `darkbloom status` and `darkbloom cluster status` said ``The pair hasn't served for N min since it started (the other Mac answers). Run …`` from 15 minutes after every start, while the pair served, before the leading Mac's `✓ Serving …`. That Mac looked for the pair's serving line in its own log, but only the leading Mac's part writes it.
- Because of that line, that Mac also treated the pair as not running there. `darkbloom start --solo` was allowed and stopped its part of a serving pair. The leading Mac's next lease then started the part again, and it waited behind single-Mac serving.
- Now the Mac that follows counts its part as serving while it runs and the leading Mac answers, as the other parts do, and leaves whether the pair serves to the leading Mac's lines. It still says the pair hasn't served when its own part never ran in the first 15 minutes, and it still gives its part up when the leading Mac hasn't answered for 15 minutes.

### A paired start says what it does, Apple's check reads as progress, and both Macs show the pause

- A script's `darkbloom start` on a pair that already serves now says `…: the pair already serves.`, shows the result block and exits 0, without asking either Mac to start again. Before, it said "starting the pair".
- `darkbloom start` in a terminal no longer says "starting the pair" before a screen where nothing starts until you choose. On the leading Mac of a stopped pair it says "Press Enter to start it with Qwen 3.8 27B (last used), or choose another model." (or "Choose its model to start it."), and otherwise "opening the pair's screen".
- During a normal pair start, each Mac's new part waits about a minute for Apple's check (App Attest). Status and a script's start now say `… is not serving yet: checking both Macs with Apple.`, read as loading. Before, every healthy start said "This Mac isn't verified by Apple yet; … Don't restart either Mac until then." for both Macs. That warning now comes only once a Mac's part has run 2 minutes without the check, or its key-generation safeguard holds it back.
- While a pair that serves Both, me first is paused for you, `darkbloom status` and `darkbloom cluster status` on the Mac that follows now say so under the pair's line too, with how long and when it comes back. Before, that Mac said only "✓ Serving … through Darkbloom". The leading Mac's status carries the pause, which the other Mac already asks for, so nothing new crosses the cable.
- A pair with no model yet: a script's `darkbloom start`, and the app, now say to choose one with `darkbloom cluster` in a terminal on the Mac that leads the pair, which has the model list: ``No model was chosen for the pair yet: choose one with `darkbloom cluster` in a terminal on this Mac.`` Before, they said to run `darkbloom start` in a terminal, which on the Mac that follows opens a screen that can't choose one.
- Pause times are said from now: "paused for 10 minutes", "back in about 2 minutes if you stay idle". Before, they were clock times in the Mac's own time zone, which no line named, such as "since 21:41" read over SSH at 05:41 UTC. This applies to one Mac's `Serving:` line and to the pair's `Pair:` line.

### On a paired Mac, `darkbloom start` starts the pair and `start --solo` serves the Mac alone; no start asks without a terminal

- On a Mac in a two-Mac cluster, plain `darkbloom start` now starts the pair whatever its state: in a terminal it opens the `darkbloom cluster` screen, and without one it starts the pair's saved model and waits until it serves. That includes a pair stopped with `darkbloom stop` and one whose other Mac isn't answering, as `darkbloom stop` and `darkbloom cluster status` already said. Since 0.10.9, a `start` without a terminal there (a script, or an agent following `cluster status`) served the Mac alone instead, and one in a terminal asked first.
- `darkbloom start --solo` is the way to serve a paired Mac alone. It works whenever the pair doesn't run on that Mac, and is refused while it does (stop the pair first). Single-Mac options need `--solo` in every state of the pair: without it, `darkbloom start --model <id>` in a terminal and `darkbloom autopilot enable` start nothing and exit 64 at once with the reason, as they already did while the pair ran. They no longer serve the Mac alone while the pair is stopped.
- The desktop app's **Start serving** has no `--solo`, so on a paired Mac it now starts the pair, as a plain `darkbloom start` does, in every state of the pair. It never serves that Mac alone and never waits for an answer. The pair serves its own model: when the app named another, the start ends with ``This Mac serves in a pair: started the pair with <the pair's model>; `darkbloom cluster` changes its model.``, which the app shows. Since 0.10.9 it served the Mac alone while the pair didn't run there, and was refused while the pair ran.
- The lines that name the way back now say `darkbloom start` for the pair and `darkbloom start --solo` for serving alone: `darkbloom status` for a part that stopped because the other Mac stopped answering, the `Next:` line of `cluster status`, `restart` on a Mac where nothing serves, and the line `start --solo` prints. They no longer send you to `darkbloom cluster` to start the pair.
- `darkbloom start --solo`, `restart` and `update` on a Mac with a leftover part of the pair now say that its saved start is cleared only once it is. They first say that they are stopping the leftover part. If a cluster command is running, they wait for it; when it is still running after 10 minutes, nothing is stopped or cleared, and they no longer say it was.
- No start asks a question without a terminal. On pair-2, a start with `--opencode` that got no answer waited forever on "Serve on this Mac alone / Start the pair"; that question is gone. On a paired Mac, a start without a terminal, with or without `--opencode` or `--hermes`, starts the pair and reads nothing. Where a start can't go on without asking, it says in one line what to add.
- A start for **Darkbloom network** or **Both, me first** that names no models (`--model <id>`, `--all`) can't pick them without a terminal. On any Mac it now says so in one line and stops (exit 64), before anything is stopped or started, instead of printing the numbered model list and waiting for an answer that may never come. **Only me** serves the models already on the Mac and is unchanged.
- `darkbloom status` on a paired Mac now says plainly when the Mac serves alone instead of the pair: a line under the pair's block names single-Mac serving and its process, and its own `Daemon:`, `Serving:` and `Trust:` lines follow. Before, it said only "Single-Mac serving: running beside the pair" at the end, and the `Serving:` line needed `status --solo`.

### Qwen 3.8 27B pairs with the assistant now prefill as fast as pairs without it

- A Qwen pair in tensor parallel that decodes with its speculative assistant processed each 512-token prompt chunk one at a time, waiting for its link traffic after each. It now processes up to eight chunks together, as a pair without the assistant already did, so one chunk's link traffic overlaps the next chunk's compute, and assisted pairs prefill at the same rate as pairs without the assistant. Measured gains: about 1.25× on an M3 Ultra + M5 Max pair serving real requests through DevNet, and about 1.85× on two M5 Ultras with the bench tool (synthetic prompt tokens, real weights); the gain depends on the Macs and the prompt. The prompt's results and the assistant's state are unchanged.

### Qwen3.8-27B pairs decode with their speculative assistant through Darkbloom

- Two-Mac pairs that serve Qwen3.8-27B in tensor parallel through Darkbloom
  now decode with the model's speculative assistant (depth 3), as local
  clusters and single Macs already do. The guided setup plans it under the
  default `mtp_mode = "auto"`. `mtp_mode = "off"` still plans the pair
  without it. If the assistant cannot be planned, the pair is planned plain,
  as before, and the setup screen and `darkbloom cluster status` say why in
  one line.
- On one pair, the same requests decoded with the assistant and without it
  gave identical greedy, sampled and tool answers. Requests that ask for
  logprobs, use penalties or a logit bias, or carry images decode one token a
  step, as before. The evidence is in
  `docs/reports/2026-11-05-qwen27-public-assistant.md`.
- The release's cluster runtime facts name the assistant: the model's
  serial-prefill tensor-parallel qualification rests on that report, and its
  resource policy digest carries the build's declared assistant settings. A pair whose Macs run another
  assistant is refused before any part stops.
- Speed records from served requests now say whether the request came through
  Darkbloom or the local API and whether the assistant decoded it. A plan uses
  only the records served the way it will serve, so a local pair's assisted
  speed no longer stands for the same pair through Darkbloom.

### Every model that reasons takes every reasoning effort a client sends

- `reasoning_effort` and `reasoning.effort` take `none`, `minimal`, `low`, `medium`, `high`, `xhigh` and `max` on every model that reasons, on one Mac, on a pair and through the coordinator. Each becomes the model's nearest level, the higher one between two: `minimal` its lowest, `max` its highest, `none` thinking off where the model can.
- Qwen 3.8 27B (and the owned Flash-Next build) answered `high` and `max` with a 400 "Invalid inference request.", so Hermes, which sends the user's `max`, fell back to the user's other, paid provider. They now render `xhigh`, the template's highest level, and `minimal` renders `low`.
- MiMo V2.6 thinks for every effort but `none` (it refused them all), Nemotron 3.5 Super renders `minimal` and `low` at its medium depth and `xhigh` and `max` at its default (it refused them), and DiffusionGemma and Flint take `max`.
- An effort that is none of the names is refused on every model that reasons, also on Qwen 3.5 and 3.6, Bonsai 2, Gemma 4, GPT-OSS and Nemotron 3.5 Lightning, which rendered it. The local API answers 400 with code `invalid_reasoning_effort`, the field in `param`, and the accepted names. A model that doesn't reason ignores any effort.
- Nemotron 3.5 Super reads both `reasoning_effort` and `reasoning.effort`, and refuses two that differ, even two names such as `high` and `max`. Its local API now answers that with the same 400 as an unknown name (code `invalid_reasoning_effort`, `param` naming both fields, and the accepted names), where it gave an untyped "Invalid inference request." Send one of them, or the same effort in both.

### `darkbloom restart` on a stopped pair starts nothing

- On a Mac in a two-Mac cluster whose pair is stopped, or doesn't run on that Mac, `darkbloom restart` and the app's Restart no longer start single-Mac serving that was stopped. Since 0.10.9 they started it whenever its launchd file was still on disk, and `darkbloom stop` keeps that file. So a Mac that served alone before it was paired began serving alone again with its old models, registered with the coordinator and held the Mac's serving lock, and the pair couldn't start until single-Mac serving was stopped again. Now a plain `restart` there restarts single-Mac serving only while it runs. With none running it changes nothing, exits 1, and says that `darkbloom start` starts the pair and `darkbloom start --solo` serves the Mac alone. `restart --solo` still starts single-Mac serving that is set up but stopped.
- After a restart of single-Mac serving on such a Mac, `restart` no longer says "`darkbloom restart` restarts both Macs", which a restart there doesn't do. It says that `darkbloom start` starts the pair. Where the pair is started but its other Mac is gone, `restart` says the pair isn't running there instead of "This Mac serves in a two-Mac cluster".

### `darkbloom route this-mac`, `my-macs` or `my-macs-first`

- `darkbloom route this-mac`, `darkbloom route my-macs` and `darkbloom route my-macs-first` save where your requests go when this Mac's local API can't take them (`[local] route`), so the route no longer needs a hand edit of `provider.toml` or a whole `darkbloom start --route`. Each says what it means: `my-macs` sends them to your other Macs, free, and never to the network; `my-macs-first` sends them to your other Macs, then to the Darkbloom network, billed, and requests from other machines (your LAN or tailnet) never use the paid network.
- `my-macs` and `my-macs-first` need your account API key: without one they save nothing, exit 1 and name `darkbloom route key`. They only ask whether a key is saved; no line shows a key.
- A running local API uses a saved route from its next request, with no restart and no model reload: its router reads `[local] route` again when `provider.toml` changes (one `stat` by a request this Mac can't take or a model list; none for a request this Mac serves). The command says "Saved. Your local API uses it now.", or "It applies when your local API starts." with none running. A malformed edit keeps the last good route and is said once in the local API's log, with nothing from the file. So does a read that catches an editor saving the file in place (it empties the file before it writes it): only a whole file counts, so a saved `this-mac` never passes a request on while the file is saved.
- `darkbloom route key` says the same when it saves or removes the key, which a running local API already read again from its next request. A key removed while the route passes requests on says that the next request this Mac can't take gets this Mac's own answer.
- That answer now says why. A request this Mac can't take, with `my-macs` or `my-macs-first` saved and no account key, or after `darkbloom route key --remove` removed the key a running local API used, keeps this Mac's 404, 429 or 503. Its message says that this Mac doesn't serve the model (or can't take the request now), and that reaching your other Macs needs an account key (`darkbloom route key`), with code `account_key_needed`. The local API's log says it once, never with the key. Before, it was this Mac's plain "Requested model is unavailable." with nothing in the log.
- In a two-Mac cluster, both commands say plainly that the leading Mac's route and key apply: the pair's local API runs there, and requests from the other Mac reach it from another machine, so with `my-macs-first` they never use the paid network, which both Macs now say. Their words are now true for each Mac. On the leading Mac, a removed key says that the pair passes nothing on until a key is saved there again, `route this-mac` says that the pair's local API passes nothing on, and the summary and `--no-auth` lines name this pair, not this Mac. The other Mac says only that the leading Mac's route decides what the pair passes on, and names `darkbloom route key`, or `darkbloom route key --remove`, to run on the leading Mac; refused for want of a key, it names the leading Mac first. A pair's local API without a local key (`--no-auth`) never claims to pass requests on.
- `darkbloom route key`, with `[local] route = "this-mac"`, now names `darkbloom route my-macs` to use the key.

### A simpler start: Autopilot only for the network, a picker that opens on what fits, no key on screen

- The experimental Autopilot is for the Darkbloom network, so `darkbloom start` asks about it only when this Mac serves the Darkbloom network. Both, me first never asks and keeps your saved answer; `darkbloom autopilot enable`, `--autopilot` and `--no-autopilot` change it. Only me has no Autopilot: there, `darkbloom autopilot enable` says `Autopilot requires a network provider. Nothing was saved.`
- The model picker opens with your last selection still on this Mac selected, else one downloaded model that fits with room to spare, else the smallest one that fits. It never pre-selects a model it would have to download, and no longer the biggest one that fits (it pre-selected a 176 GiB model on a test Mac).
- No start screen prints the local key: `darkbloom start --local --here` now says ``API key:  `darkbloom local` shows it``, and where your requests go, instead of the key and `export OPENAI_API_KEY=…` lines.

### One flag sets OpenCode or Hermes up: `--opencode` and `--hermes`

- One flag sets OpenCode 2 or Hermes Agent up to use Darkbloom, as `ollama launch` and `omlx launch` do:
  `darkbloom --opencode`, `darkbloom --hermes`, or both. If this Mac's local API already runs, nothing restarts;
  otherwise `start` runs as usual and the tools are set up once its local API answers.
- It prints the file it changed, the backup and a one-line undo, then where your requests go and the two variables
  other OpenAI clients need (naming the key file, never the key). No line, and no tool file, holds the key.
- A Hermes older than v0.20.2 is set up with one warning line: it can't read the key until `hermes update`.
- A tool that isn't installed, OpenCode 1, Hermes without a 64K-context model, or a start that serves only the
  Darkbloom network: a plain `✗` line, nothing written, and Darkbloom keeps serving. Refused with `--network` and
  `--no-auth` (and with `--distributed`). Beside a running `--no-auth` local API, it says so and starts nothing.
- Without Darkbloom's catalog (offline, or the coordinator down), a run again keeps each model's name, image support
  and limits as they were set up, changes nothing, and says the catalog wasn't reachable. A model set up for the first
  time then gets its ID and text input only, and one line says to run the start again online for its name and image
  support.
- A model that isn't loaded yet gets one line: run the start again once it is, to pick up its limits. See
  [Use it from OpenCode or Hermes](docs/provider/local-first.md#use-it-from-opencode-or-hermes), which also
  covers `OPENCODE_CONFIG_DIR` and Hermes profiles.

### Qwen tensor-parallel decode wastes less time per token

- A Qwen pair now hands each token's work to the GPU every eight layers instead of after every layer, so the GPU spends less time waking up and waiting. On two M5 Ultras a token took about 15 % less time for one request and about 13 % less for four at once. The output is unchanged.

### `darkbloom --opencode` and `--hermes` say what happened to your default model, and where the models run

- OpenCode: Darkbloom's model becomes OpenCode's default only when OpenCode has none: neither of its global config files sets one (`opencode.json`, `opencode.jsonc`; OpenCode 2 doesn't read OpenCode 1's `config.json`), and its TUI remembers no model you picked with `/models` (`~/.local/state/opencode/model.json`). Its own line says so, and how to go back for good: ``New OpenCode sessions now use Darkbloom's Qwen 3.8 27B. To go back, remove "model" from ~/.config/opencode/opencode.jsonc or run the Undo below.`` When a file sets one, nothing is written for it, and the line names it: ``Your default stays exo/llama-3.3-70b; pick Darkbloom with /models.`` When OpenCode remembers a pick: ``Pick Darkbloom once with /models; OpenCode remembers it.`` The `Undo:` line stays.
- Hermes: Darkbloom still becomes the main model, and the line names the one it replaced: ``New Hermes chats now use Darkbloom's Qwen 3.8 27B (before: gpt-6-astra via opencodex). Switch back: hermes model``. Its headline matches OpenCode's (``✓ Hermes can use Darkbloom: 1 model.``).
- A start with a tool flag beside a local API that already serves names the URL the tools use, not the address it listens on: ``Darkbloom already serves at http://127.0.0.1:8001/v1; setting up OpenCode for it.`` (it said `0.0.0.0:8001` for a pair's).
- On a Mac whose local API is its pair's (the leading Mac's, or a member's relay), the tools name the pair's models ``Qwen 3.8 27B (your pair)``, not `(this Mac)`, for a pair of any size; a run again changes nothing. Hermes makes the pair's model its main one, as it does this Mac's, and a pair's models take their engine's word on image input and reasoning, as this Mac's do.

### `darkbloom --opencode` and `--hermes` wait for your model, and starts say when a tool points elsewhere

- Before it writes a tool's config, the start waits while this Mac still loads the models it started with, so OpenCode and Hermes get the limits this Mac gives each model instead of the catalog's. A terminal shows one live line, ``⠙ Loading Gemma 4 26B before setting up OpenCode… 42s``; without one, a line as it starts and one as it ends. It waits at most 10 minutes. A model still loading then, or one that didn't load, sets nothing up, and one line names the next step (`darkbloom status`, then `darkbloom --opencode` again). Ctrl-C stops the wait: nothing is written, and the start says so, also when the model finishes loading just then. Darkbloom keeps serving either way. On one Mac only for now: a pair's local API isn't waited for.
- A model that isn't loading as the tools are set up (one unloaded when idle, or one that loads on a request) is named in one line: run `darkbloom --opencode` again once `darkbloom status` shows it loaded. That holds too when a route that dials out lists the catalog's limits for it.
- A start without `--opencode` or `--hermes` never changes a tool's config. When OpenCode or Hermes is set up for another address than this Mac's local API (another port or `--bind`), or reads another key file, one line says so: ``OpenCode points at http://127.0.0.1:8001/v1, not this Mac's local API (http://127.0.0.1:8002/v1): `darkbloom --opencode` points it there.`` `localhost`, `127.0.0.1` and `::1` are this Mac, in any case, and so is its `.local` name for an API on every address. On one Mac only for now: a paired Mac's start doesn't say it.

### The update check asks again instead of waiting a minute, and says what failed

- The check for a new release sent one request to the coordinator and waited up to 60 seconds for its answer. When that connection stalled, `darkbloom update` failed after a minute with "download failed: update check failed: The request timed out", although nothing had been downloaded, and `--check-only` with "update check failed: …". Now each try waits at most 15 seconds, and a try that gets no answer, loses or can't open its connection, or can't resolve the coordinator's name is made again after 0.5 to 1, then 1 to 2 seconds: 3 tries, under a minute in all. An answer from the coordinator, an error included, is not asked again. Every automatic update (a single Mac's, a pair's, the watchdog's and the startup check) uses the same check.
- A pair's automatic update, at its update slot or catching up with the other Mac, asks once more 1 to 2 minutes after a check without an answer, within the same slot, so one stalled minute no longer costs both Macs 30 minutes.
- A check that still fails says what failed and what to do, on two lines, and points at the network only when no answer came: `Couldn't check for updates: api.darkbloom.dev didn't answer within 15 s (3 tries). Nothing was downloaded or changed.` and ``Run `darkbloom update` again in a minute. If it keeps failing, check this Mac's network connection.`` When the coordinator answered with an error or with no release this Mac can use, the second line says the network works; when the check failed on this Mac (its update record, its coordinator URL), it says so.
- Each failed try is logged with how it connected (HTTP version, a new or reused connection, direct or through a proxy, the address) and the error's domain and code, so a stall leaves evidence in the provider's, the cluster service's or the watchdog's log.

### A video whose decoder fails once is decoded again, not refused

- When the video reader of GLM 5.3, MiMo V2.6, Qwen4 or Nemotron Super fails on a video that passed its metadata checks, the provider decodes the video once more with a new reader over the same bytes. A valid video that met one reader failure is now served with the same frames. Before, GLM refused it as `invalid_media` (400), and the coordinator did not send it to another provider.
- When the reader fails again with a decoder, hardware or interruption fault, the provider refuses the request as a retryable 503, and the coordinator can send it to another provider. Any other second failure, such as a truncated video, is still the deterministic `invalid_media` (400). A Qwen4 video whose reader fails twice without such a fault is now `invalid_media` (400) too; before, every Qwen4 reader failure was a retryable 503.
- Each failed reader pass logs a WARN `engine_health` event `video_reader_failed` with the reader status and the domain and code of its errors. It carries no media or prompt content.

## v0.10.10

Published 2026-11-06 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.10.10)).

### Upgrade and rollout notes

- 0.10.10 is 0.10.9 plus Darkbloom's waitlists. Nothing else changes: the serving engine, the pair setup and the models are 0.10.9's, built with the same toolchain (Xcode 27.2, macOS 27.2 SDK) and the same MLX pins.
- **New: `darkbloom waitlist`.** It lists the waitlists Darkbloom offers (clusters and Darkbloom Sandbox) and where your account stands on each: not joined, your place in line, approved (with the command that starts the feature) or not approved. `darkbloom waitlist cluster` or `darkbloom waitlist sandbox` puts your account on that list; running it again keeps your place. A waitlist is per account, not per Mac.
- **A new sandbox or a new pair needs an approval.** A new Darkbloom Sandbox setup (`darkbloom sandbox setup`) and a new two-Mac pair serving through Darkbloom (`darkbloom cluster` on a Mac that is not paired) now need your account to be approved from that waitlist. If you are not on it yet, setup offers to add you (for the sandbox, `--yes` adds you without asking). Waitlisted or not approved: it shows where you stand, changes nothing and exits 1. Not logged in, refused, or the coordinator can't be reached: it says why and to try again, and exits 1.
- A pair serving only you on your own Macs (`darkbloom cluster local`) needs no approval and works offline.
- **Existing setups keep working exactly as before:** an installed sandbox, and Macs already paired, set up or serving as a cluster, are never asked, including after this update and a restart.
- If the coordinator does not offer waitlists yet, both new setups go on as in 0.10.9, so this release can ship before or after the coordinator change.
- Pair owners: as with every release, both Macs of a pair must run the same version. A pair on 0.10.9 updates itself at its update slot, or at once with `darkbloom update` on each Mac; check that `darkbloom --version` prints 0.10.10 on both. To roll back, `darkbloom update --rollback` puts back 0.10.9 (on a pair: `darkbloom cluster stop --service` on one Mac first; the other Mac follows).
- Pairs still on 0.10.8 stop serving through Darkbloom once 0.10.10 registers, until they update themselves. Production keeps at most 64 pair approvals, newest release first and each release whole: 0.10.10 and 0.10.9 hold 24 each, so 0.10.8's 24 are left out. Single Macs do not use pair approvals.
- Known limitations are 0.10.9's, unchanged; see the v0.10.9 entry below.
- The registration is the one 0.10.9 sent: the same fields and a `darkbloom_cluster_runtime_v2` block with the same models, grants and qualifications. MLX pins are unchanged (`libs/mlx` `72dffa2d`, `libs/mlx-swift` `c633d221`, `libs/mlx-swift-lm` `32f5c744`), and the toolchain is unchanged, so the tag build's `metallib_hash` should equal v0.10.9's `5b97893c…70ac`.
- The 1 entry below is the pending fragment rendered verbatim.

### Join Darkbloom's waitlists with `darkbloom waitlist`; new sandbox and cluster setups need an approval

- `darkbloom waitlist` lists every waitlist the coordinator offers and where your account stands on each: not joined, your place in line, approved (with the command that starts the feature) or not approved. Darkbloom offers waitlists for clusters and Darkbloom Sandbox.
- Join one with `darkbloom waitlist cluster` or `darkbloom waitlist sandbox`. A waitlist is for your account, not for a Mac: joining sends nothing about the Mac, and running it again keeps your place and shows where you stand. An unknown name lists the waitlists there are and exits 1 without joining. `--json` prints the coordinator's answer.
- A **new** Darkbloom Sandbox setup (`darkbloom sandbox setup`) and a **new** two-Mac pair serving through Darkbloom (`darkbloom cluster` on a Mac that is not paired) now need your account to be approved from that waitlist. Not on it yet, setup offers to join (sandbox `--yes` joins); waitlisted or revoked, it shows where you stand, changes nothing and exits 1. Not logged in, refused, or the coordinator can't be reached: it says why (and to try again) and exits 1. A coordinator without waitlists lets setup go on as before.
- Serving a cluster on your own Macs only, `darkbloom cluster local`, needs no approval and works offline.
- **Existing setups keep working exactly as before**: an installed sandbox add-on, and Macs already paired, set up or serving as a cluster, are never asked, also after updating and restarting.

## v0.10.9

Published 2026-11-05 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.10.9)).

### Upgrade and rollout notes

- **Pair owners, first:** make sure both Macs run 0.10.9 (the pair updates itself at its update slot, or run `darkbloom update` on each Mac), then check that `darkbloom --version` prints the same release on both. If either Mac ever ran a plain `darkbloom start` before 0.10.8, run `darkbloom stop --solo` on that Mac first. A pair with one Mac on 0.10.8 and one on 0.10.9 behaves the old way until both run 0.10.9.
- **Still on 0.10.8 and stuck?** To go back to serving on one Mac alone after a pair test: `darkbloom cluster pair --status`, then `darkbloom cluster pair --forget <pin>`, then `darkbloom start`. To free a pair that single-Mac serving blocks: `darkbloom status --solo` on each Mac, then `darkbloom stop --solo` on the Mac where it runs, then `darkbloom start`. Never use plain `darkbloom stop` for either: on a paired Mac it stops the pair and leaves single-Mac serving running. 0.10.8's own screens advised plain `darkbloom stop` for this; that advice was wrong.
- Why pairs failed to load on 0.10.7 and 0.10.8, as found on 2026-11-04 and fixed in 0.10.9:
  - 0.10.7's updater, and a login, could restart single-Mac serving left over on a paired Mac. It then held the Mac's one serving lock, and the pair's part ended every 38 seconds while the screens said the model was loading.
  - The single-Mac updaters never checked for a pair, so one Mac of a pair could update alone and leave the two Macs on different releases.
  - A Mac that tested a pair and went back to serving alone could keep a leftover pair part. That part registered as a pair member with no models, so the Mac sat online with no requests, and 0.10.8 refused every way back to serving alone.
  - After a few quick failures, a pair fell back to serving locally only for up to an hour, so it stayed off Darkbloom even after the cause was fixed.
- A pair on 0.10.8 updates itself; nothing needs to be run. With `auto_update` on (the default) and `DARKBLOOM_NO_UPDATE_CHECK` unset on both Macs, at the pair's update slot both Macs download and verify 0.10.9, the pair finishes the requests it accepted, and both Macs install it together. To update at once, run `darkbloom update` on each Mac. The second Mac now waits for the leading Mac's new setup instead of restarting from its old one, and the leading Mac checks every 5 seconds instead of every minute. The `darkbloom update` you run for this update is still 0.10.8's, so it can end with "Still waiting after 600 s" although the Mac already runs 0.10.9: check `darkbloom --version`. From 0.10.9 on, `darkbloom update` ends as soon as this Mac runs the new release. A pair serving on the leading Mac's local API only, or a paired Mac whose cluster service serves it alone, does not update at the pair's slot while it serves.
- **The two Macs of a pair no longer stay on different versions,** from 0.10.9 on (a Mac still on 0.10.8 has none of this). When one Mac already runs a newer release, or is updating to one, the other Mac's cluster service notices within a minute and updates right away instead of waiting for the next update slot. The background updater no longer updates one Mac of a running pair alone: it has the pair restart into the release together, and the watchdog doesn't install a release while the pair runs on that Mac. When the versions differ, both screens say so at once ("The two Macs run different Darkbloom versions …"), name each Mac's version and the Mac to run `darkbloom update` on, and the start no longer loops.
- **A Mac that stopped clustering serves normally again.** Whether the pair runs on a Mac now comes from what is happening (the other Mac answering over the cable, the pair having served), not from a saved setting. On a Mac whose pair isn't running, `darkbloom start --solo`, Go Online, Autopilot and a script's `darkbloom start` stop the leftover pair part and serve alone; in a terminal, plain `darkbloom start` offers "Serve on this Mac alone" or "Start the pair"; `darkbloom stop` and `restart` act on this Mac only. A leftover pair part gives up by itself after about 15 minutes without the other Mac. A Mac stuck this way on 0.10.8 recovers once 0.10.9 runs it: about 15 to 20 minutes after its next login, or at once with one `darkbloom start` or Go Online. A real pair whose other Mac is slow to load, reboots or loses the coordinator is left alone.
- **Single-Mac serving that blocks a pair is said on both screens, and nothing loops on it.** `darkbloom cluster` checks both Macs before it starts. Both Macs show the same ✗, naming the Mac and the process, with `darkbloom stop --solo`, and the leading Mac offers to stop single-Mac serving on both Macs and start the pair; it stops nothing unless you choose that. This also holds when you start a stopped pair from the leading Mac, and both Macs' `darkbloom cluster status` report the block. The leading Mac no longer restarts its part every 38 seconds while a block is reported. On a Mac whose pair is started and wants its part, single-Mac serving that nobody chose since the pair started now steps aside by itself, as `darkbloom stop --solo` would, and the pair goes back to Darkbloom at once instead of after up to an hour. `darkbloom stop --solo` on the wrong Mac names the other Mac and offers to stop it there. The stop sticks across a logout.
- **The joining Mac ends with the leading Mac's outcome.** States that clear by themselves (Apple verification, registering, the coordinator pairing both Macs) keep it waiting with a timed row; its final ✓ or ✗ is the leading Mac's, in the same words, and "Choose Retry on the other Mac" appears only under a real ✗. It no longer shows "✗ Not serving: not offered to Darkbloom" while the leading Mac is still registering the pair. It also follows a model or mode change started on the leading Mac.
- **Waits say the real cause.** When the coordinator doesn't pair both Macs within 15 minutes, the ✗ says so, with the coordinator's reason when it gives one, and q or Esc leaves the wait while both Macs keep trying. When the coordinator's model catalog doesn't list the pair's model, both setup screens end with "✗ Not serving: The coordinator does not pair Macs for <model>: its model catalog does not list it". While a Mac's part keeps ending and starting again during a load, `darkbloom cluster status` gives that end as the reason, for example "this Mac's part ended (exit 1: deadline) and starts again by itself", instead of only `loading`.
- **A pair no longer loses a model from its list after serving a long request; a model that can't be offered now says why.** After a pair served prompts longer than a model's limit (on two M5 Ultras, Qwen 3.8 27B vanished from `darkbloom cluster` after prompts of 71,545 to 94,423 tokens), the next plan skips those served requests, still uses every other one, and says so in one line. A model approved for clusters that can't be offered on these two Macs says why in one line above the model list, instead of disappearing.
- **MiMo-V2.6-Flash in tensor parallel now loads in time.** Each Mac read its half of MiMo's expert weights in about 100 million tiny pieces, which took over an hour, so the load always ran out of time. Pieces that sit next to each other on disk are now read together, which takes seconds. The bytes loaded and the memory used are unchanged.
- **Pairs that serve several requests at once keep streaming.** On a GLM-5.3-Flash pair in tensor parallel, running requests no longer pause while the pair admits a new one, a request being admitted counts as a place taken (so Darkbloom no longer sends one more request than the pair has room for), and a cancel takes effect at once. A Gemma 4 pair serving locally with requests waiting no longer stops and reloads every half minute trying a setup it can't serve.
- Setting up a pair needs someone at both screens, or Screen Sharing. macOS asks for approvals on each Mac's own screen: the administrator password for the cable port, Allow for Local Network, Yes to the pairing code, and the password for `darkbloom cluster gpu-limit`. The first line of the Connect step says "Allow macOS permissions." For a Mac with no display (a Mac Studio, or a MacBook with its lid closed), open Screen Sharing to it before you start. Over SSH macOS cannot show these prompts: `darkbloom cluster` says so before its first step and offers to quit with nothing changed, `darkbloom cluster link --fix` and `--remove` say so before they start, and `darkbloom uninstall` over SSH stops before it changes anything when a cable port setup is left to undo.
- GLM-5.3-Flash now loads on two 128 GB Macs. Each Mac loads its half on what loading needs, and each request is checked against the memory free when it arrives: a busy pair serves shorter requests and answers a longer one with a retryable "busy" error before it starts, never by running out of memory. Closing large apps brings back the full length. `darkbloom cluster` offers only the ways a pair can actually run GLM-5.3-Flash: on two 128 GB Macs, including an M4 Max with an M5 Max, that is the pipeline. When nothing fits as the Macs are, the model's row says what is needed, for example that `darkbloom cluster gpu-limit` must run first, with the Mac and the figures.
- New, optional: `darkbloom cluster gpu-limit` lets the GPU of an Apple silicon Mac with 128 GB or more keep more of its memory: its memory less 16 GiB, so 112 GiB on a 128 GB Mac. That leaves room for longer requests on such a pair. Run it on each Mac yourself: it explains the change and asks you once, then macOS asks for an administrator password on that Mac's screen. The setting stays after a restart. `darkbloom cluster gpu-limit --undo` puts macOS's default back. After macOS approves, the command reads the setting back and shows ✓ only if it took effect; otherwise it shows ✗, what is off and what to run next. Darkbloom never changes the limit on its own, and `darkbloom uninstall` does not undo it: run `--undo` first if you want macOS's default back.
- **Switch to serving through Darkbloom** on a pair that served locally only now plans the model again for Darkbloom, and the screen says ✓ only once Darkbloom has the pair. A pair set to serve through Darkbloom that Darkbloom doesn't take says so on both Macs, `✗ Not serving: not offered to Darkbloom (…)`, and `darkbloom cluster status` reads `not_serving`, exit 3. No line says "earning through Darkbloom" unless it is.
- Through Darkbloom, a pair reading a long prompt now answers Darkbloom's checks as they arrive and takes in each new request as soon as it arrives (its prompt is still read after the one in progress). A cancel takes effect without waiting behind queued requests (on 0.10.8 one pair saw cancels take effect 20 to 29 seconds late), and a cancelled request that was still waiting is never started. A pair reading several long prompts no longer reports itself as crashed, which could end its serving.
- The mode question shows the split that loads and loads exactly that, including a choice made on the Mac that joined and the first pipeline offer after another model stops. Each mode says how many requests it serves at once, and the question recommends one mode for these two Macs and says why, on both screens; Enter takes it. The question no longer quotes tokens per second: its recommendation says why in words (for example "Pipeline, faster here"), and a mode that serves more requests at once and is as fast says so. A mode that has served on these two Macs is trusted over one that is only predicted ("Tensor parallel, the only one measured on these Macs so far"), and a pipeline is no longer predicted faster than what a Mac measured for its share, so Gemma 4 26B on two M5 Ultras now recommends tensor parallel. The short speed measurement a Qwen or Gemma 4 tensor-parallel load takes no longer counts the model's first-use warm-up against its time budget, so a cold first load no longer skips it for that reason. Each mode's line fits the window and redraws when the window is resized. Local Network hints name the row System Settings shows, "Darkbloom".
- Both Macs show how far a start is: each Mac names its part at the top, the Mac that joins says what the leading Mac waits on with a timer out of 15 minutes, both screens show the step, a real progress bar for a copy or download, and one row per Mac while the parts load, and each finished step folds to one line. Every live line stays one line that fits the window, and a plain transcript prints one line per change.
- `darkbloom cluster stop --service` on the leading Mac now works when the other Mac's cluster service is already off, and says what happened on each Mac. `darkbloom uninstall` and `darkbloom cluster link --remove` undo every Thunderbolt port Darkbloom set up under one approval, including a port whose only network service is Darkbloom's, and say which ports are left if one step fails.
- Sandbox setup can put its VM images and jobs on an external drive.
- `darkbloom update --rollback` puts back the release a Mac ran before its last update (0.10.8, after this update). On a pair: `darkbloom cluster stop --service` on one Mac, `darkbloom update --rollback` there, then `darkbloom cluster`; the other Mac follows to the same release. Where the published v0.10.7 notes say to press `m` and choose the model again for a Qwen pair "not offered for pairing", choose the model again in `darkbloom cluster` instead: no list item starts with `m`.
- Pairs still on 0.10.7 stop serving through Darkbloom once 0.10.9 registers, until they update themselves (0.10.7 pairs update together at their slot). Production keeps at most 64 pair approvals, newest release first and each release whole; 0.10.7 and 0.10.8 hold 24 each, and 0.10.9 adds 2 per model of its cluster runtime facts, so with more than 8 models 0.10.7's are left out. Single Macs do not use pair approvals.
- Known limitation: a pair with one Mac on 0.10.8 and one on 0.10.9 behaves the old way until both run 0.10.9, including the old restart loop when single-Mac serving blocks it. Update both Macs.
- Known limitation: a GLM-5.3-Flash pair in pipeline, and a Gemma 4 pair in tensor parallel, serve one request at a time, and a request cancelled while its prompt is being read keeps that one place until the prompt is read (about a minute for a 16,000-token prompt). Through Darkbloom such a pair turns other requests away as "at capacity" meanwhile. For GLM pairs, use tensor parallel where it fits; the mode question recommends it there. Two 128 GB Macs fit only the pipeline, so such a pair serves one request at a time.
- Known limitation, unchanged from 0.10.8: a Qwen3.8 27B pair runs in tensor parallel only, because only that mode keeps images, video and logprobs; the mode question does not offer the pipeline for it.
- Known limitation, unchanged from 0.10.8: during a model or mode change on a pair, or while a pair updates itself, `darkbloom status` and `darkbloom cluster status` can read `stopped` (exit 4) or `unknown` on either Mac for a minute or two. Check again after a minute before acting on it, including before running `darkbloom start`.
- Known limitation: while the model loads, neither Mac shows a percentage, because Darkbloom has no measure of how many layers are loaded yet. You see a turning mark and the time.
- Known limitation, unchanged from 0.10.7: a pair in tensor parallel reads prompts one at a time, so a short request that arrives behind a long prompt can time out before its first token. Such a request is safe to retry.
- Known limitation: GLM-5.3-Flash on two 128 GB Macs is proven by the planner's checks on the recorded hardware profile and the real model files, not yet by a pair of such Macs loading and serving it. `darkbloom cluster gpu-limit`'s raise, repeat and `--undo` were tested on an M3 Ultra.
- Known limitation: on a Mac where both the DevNet app (`darkbloom-dev`) and the production app are installed, the DevNet app can read production's pair state, restart production's cluster service, and `darkbloom-dev cluster pair --forget` can remove production's login job, so production's cluster service doesn't start at the next login. Providers with only the production app are not affected.
- 0.10.9 is built with Xcode 27.2 (macOS 27.2 SDK, Swift 6.4.2). With that SDK, comparing two dates with `>=` or `<=` calls two Foundation functions that some macOS 27.2 pre-release builds lack; a DevNet build made that way crashed at launch on such a Mac. 0.10.9's code no longer compares dates that way, a source check refuses it, and the release build refuses any binary that still calls either function. A DevNet build with this fix ran on that Mac without crashing.
- The registration is the one 0.10.8 sent: the same fields and a `darkbloom_cluster_runtime_v2` block, carried while `PROD_CLUSTER_RUNTIME_ENABLED` is `true`. The scripts that build the registration and its cluster runtime facts, and `ClusterPublicModels`, are unchanged since v0.10.8, so the production coordinator needs nothing new. The facts are computed again on 0.10.9's tree, because the cluster planner and runtime changed. After the tag the platform snapshots its provider contracts from the tagged commit and sets `LatestProviderVersion` to `0.10.9`.
- MLX pins are unchanged from v0.10.8: `libs/mlx` and the nested `mlx` (`72dffa2d`), `libs/mlx-swift` (`c633d221`) and `libs/mlx-swift-lm` (`32f5c744`). The Metal kernels are compiled by Xcode 27.2's Metal compiler, so the tag build's `metallib_hash` changes from v0.10.8's `98bab9d7…614be`; DevNet's Xcode 27.2 builds have `5b97893c…70ac`.
- The 38 entries below are the pending fragments rendered verbatim, in filename order, including the sandbox entry, which reached `master` directly. The fragments that v0.10.7 and v0.10.8 already published, and that `dev` reworded afterwards, are not repeated; the rollback note above carries the one change of meaning (`m` is gone). The five CI entries change how the repository is tested and built; only the Xcode 27.2 one changes what providers run. Pull requests that change only tests, or only wording in another entry, have no entry of their own.

### CI

- The Darkbloom watchdog (`.github/workflows/darkbloom-watchdog.yml`) is now on `master`. GitHub runs scheduled workflows only from the default branch, so before this change the watchdog never ran, and a run stranded on Darkbloom waited until someone cancelled it. The file is the same as on `dev` and as darkbloom-sandbox's copy. It checks the queued runs of every branch, `dev` included.

### CI rescues runs stranded on Darkbloom

- A scheduled workflow, `darkbloom-watchdog.yml` (darkbloom-sandbox's GitHub-side watchdog, copied unchanged), cancels a run whose Darkbloom job waited `DARKBLOOM_WATCHDOG_MINUTES` with no runner and re-runs its route on the Blacksmith fallback, once per run. Its token can only cancel and re-run this repository's workflow runs and write a check run.

### CI has a dev workflow and a master workflow; dev runs only the tests

- Two reusable workflows hold the CI jobs: `provider-plan.yml` (the component classifier, the tested-change lookup and the run's one Darkbloom route request) and `provider-tests.yml` (the provider shards, the cluster jobs and the `Provider Tests` gate). `ci-dev.yml` runs both for pull requests into any branch but `master` (`dev` and stacked branches) and for pushes to `dev`. `ci-master.yml` runs both for pull requests into `master` and pushes to `master`, with Release Integrity and Docs Lint beside them. `ci.yml` is gone.
- Pull requests into `dev` no longer run Release Integrity, Docs Lint, Commit Signatures or Docs Impact. Pull requests into `master` run all of them, as before; Release Integrity keeps its check name, which `master`'s ruleset requires. The `Provider Tests` gate runs the cluster plan audit and the CI plan self-tests on every run, `dev` included.
- The test jobs' checks are now named after the caller's job, for example `Tests / Provider Tests`.
- Release Integrity and Docs Lint read their Linux lanes from the plan's route request, with `blacksmith-4vcpu-ubuntu-2404` as the fallback.

### CI's macOS jobs ask for Darkbloom Sandboxes again

- The macOS CI jobs read the Darkbloom route again, as they did before they moved to Blacksmith only. Each provider and cluster test job runs on a Darkbloom Mac when the plane grants its lane, and on `blacksmith-12vcpu-macos-27` otherwise. The job list and shard counts are those of the entry "Provider CI: fewer Mac jobs per run" below.
- A lane is requested only when its job runs: the provider lanes when provider inputs change, and the cluster lanes when cluster inputs change.
- Limitation: a lane the plane's approval does not name keeps Blacksmith, as do all lanes while `DARKBLOOM_ROUTING` is not `on` and for pull requests from forks.

### Provider CI: fewer Mac jobs per run, loose build-cache restores, macOS lane cap

- Provider Unit Tests runs in 2 shards instead of 3. Each shard builds once and runs 3 test selections at the same time, each serially in its own process with its own `TMPDIR` and provider state files. The isolated processes and the native gates still run after them, alone. The processes start 15 s apart. A selection whose SwiftPM found the build database locked by another process's startup runs once more, but only when its log proves every test passed; both attempts' logs and reports are kept. The plan is unchanged; the audit counts 6 selections.
- Cluster Runtime Tests runs in 2 shards instead of 3. Shard 1 runs the `base` selection alone, then the share probe alone. Shard 2 runs two groups at the same time, each in plan order: the batch-session suite with the GLM paged-KV, invariance and census, TF32 and Gemma selections; and the Qwen GPU chain with `glm53-prefix-ssd`. A grouped selection that finds the build database locked runs once more, under the same rule.
- The Provider SDK Tests lane is removed: 226 of its 236 test seconds repeated the SDK's own Fork Tests. Its one other step, `MiMoV26NativeMediaDeadlineTests`, is left for the SDK's Fork Tests to run. Release qualification still builds and tests the provider, with the SDK compiled in, under SDK 27.
- CI tests each change once: a run whose change a successful run of the same workflow already tested, with every component this run selects, runs no test job, and its gate cites that run. A record binds to its tree, its base and head commits and the commit its run tested; the push of a pull request's merge commit finds the pull request's record through the merge's two parents. Such a push runs one build-only job that refreshes the branch's build caches.
- Pull requests and pushes run the same jobs. On `dev` both select components by their diff (a push against the branch's previous commit); pushes to `master` and pull requests into `master` select every component. Only pushes save caches. Cluster GPU Tests (report only) run whenever the cluster jobs run.
- Provider Unit Tests Summary is gone: each shard audits its own selections against `swift test list` and reports its own coverage, and the last shard checks that the plans cover the suite once. Cluster Metadata Checks run inside Cluster Focused Checks, which makes them part of the `Provider Tests` gate.
- A provider-only pull request now runs 2 Mac jobs instead of 4 (5 with an SDK input); a cluster pull request 7 instead of 11; the push of an already tested merge commit at most 1 build-only job instead of 12.
- The Swift build cache restores from a loose tier that ignores the CI recipe, so a workflow or CI script edit no longer makes every build cold, and then from a tier keyed only on the toolchain and the MLX pins, so a manifest change still restores the compiled MLX. A build that fails over a loose-tier entry builds once more from nothing. CI (master) restores only entries of its exact recipe. On Darkbloom hosts a push saves at most one build per lane and day.
- The MiMo metadata downloads are cached by their pinned SHA-256 and used only when their bytes match.
- The repository variable `DARKBLOOM_MACOS_LANES` caps the macOS jobs one run asks Darkbloom for; the rest use Blacksmith at once.

### Provider builds use Xcode 27.2 (SDK 27.2, Swift 6.4.2)

- Release builds, release qualification and signing accept only SDK 27.2 and Apple Swift 6.4.2 (Xcode 27.2). `release-provider.yml` and `provider-signing-validation.yml` set `DARKBLOOM_PROVIDER_TOOLCHAIN=release`, as do master and dispatched SDK 27 release preparation.
- Provider CI accepts SDK 27.2, or SDK 27.0 (Xcode 27.1), with Swift 6.4 or 6.4.x. SDK 27.0 stays only while the Darkbloom Sandbox production macOS CI base is on Xcode 27.1.
- The toolchain step tries the image's Xcode, then each installed Xcode, and takes the first with SDK 27.2. When it selects another Xcode than the image's, it exports `DEVELOPER_DIR`, so Metal, `xcodebuild` and signing use the same Xcode. When no Xcode qualifies, it names the installed ones.
- `PROVIDER_SDK_VERSION` is the SDK that was selected, not a fixed 27.0. A resumed release signs an unsigned build only when that build linked SDK 27.2.
- `mise.toml` pins Swift 6.4.2.
- No provider code compares Dates with `>=` or `<=`. SDK 27.2 back-deploys these two operators. Pre-release macOS 27.2 builds (26B5091g) do not export them, and DevNet build `0.10.6-dev.branch.87` crashed in a loop on such a Mac. `scripts/check-date-comparisons.py` refuses the pattern in source. It runs in the `Provider Tests` gate of every CI run and in Release Integrity. The release build refuses a binary that imports either symbol (`scripts/check-provider-weak-imports.py`).

### The mode question trusts a measured mode over a predicted one

- While one mode has served on the pair and another hasn't, `darkbloom cluster` now recommends the measured mode ("Recommended for Gemma 4 26B on these two Macs: Tensor parallel, the only one measured on these Macs so far.") instead of comparing two predictions. On two M5 Ultras the planner predicted Gemma's pipeline at 152 tokens/s and recommended it over tensor parallel, which had served at 111; the pipeline then served at 64. Through Darkbloom a mode that serves more requests at once still comes first.

### A two-Mac pair answers Darkbloom's checks and cancels while a long prompt is read

- When requests arrived while a pair was reading a long prompt, each one could take up to 30 s to be admitted, because both Macs answer at the end of their current prompt step, and they were admitted one after another. Meanwhile the leading Mac held back the Darkbloom messages that came after them: attestation checks, cancels and the next requests. On one pair a cancel took effect 20–29 s late, and a request waited 18 s before the leading Mac even read it. A late answer to an attestation check counts against the pair.
- The leading Mac now answers attestation checks as they arrive, takes in each new request as soon as it arrives (its prompt is still read after the one in progress), and keeps its reports of what the pair is serving up to date.
- A cancel now takes effect as soon as the admission in progress returns, not after every admission queued behind it. A cancelled request that was still waiting to be admitted is no longer admitted at all, and one that was being admitted never starts its prompt. A request already reading its prompt frees its place on the pair within one prompt step, as before.
- A two-Mac pair reading several long prompts no longer reports itself as crashed, which could end its serving. A pair is reported crashed only when a request is still waiting well past its own first-token allowance.
- Unchanged: a request that arrives during a long prompt still waits for the pair to admit it, and for that prompt before its own is read, so a short request can still time out before its first token. Such a request is safe to retry.

### The joining Mac ends with the leading Mac's outcome

- While the pair is offered to Darkbloom and waits for Apple's verification or for the coordinator, the joining Mac now
  keeps waiting. It shows a live row such as "Waiting for Apple to verify this Mac (Darkbloom retries by itself) · 2 of
  15 min". Before, it judged the pair by its own wait: on a real pair it ended with "✗ Not serving: This Mac isn't
  verified by Apple yet …" while the leading Mac showed "✓ Serving … through Darkbloom on both Macs" 41 s later.
- Its last word is the leading Mac's: the same ✓, or the same ✗ with its next step. When the leading Mac's start
  ends with ✗ on its screen, it publishes that ✗ in its status, and the joining Mac shows it named from its own side
  ("This Mac isn't logged in to Darkbloom …").
- "Choose Retry on the other Mac" appears only under that ✗, since the leading Mac's screen then shows Retry. It is no
  longer said while a part restarts by itself.
- With a leading Mac on an earlier release, which publishes no outcome, the joining Mac waits until the stage's
  15 minutes run out. It then ends with "✗ Not serving: The other Mac (…) didn't say how its start ended within
  15 minutes.", the last state it saw, and where to look.

### The joining Mac no longer shows ✗ while the leading Mac registers the pair

- Right after both Macs loaded the model, the joining Mac's window could end with "✗ Not serving: not offered to Darkbloom
  (no cluster approval is attached to its setup)" and "Choose Retry on the other Mac". Meanwhile the leading Mac went on
  to register the pair and showed ✓ through Darkbloom. The joining Mac now keeps following while the leading Mac's start
  still runs, and ends with the leading Mac's ✓ or ✗.
- When the leading Mac's ✗ says the pair answers on its local API, the joining Mac's copy keeps "(no Darkbloom
  traffic)".

### The Mac that joins a cluster says what it waits for

- While the Mac that joined waits for the leading Mac to start, its line now says what the leading Mac is waiting on:
  Allow on its Local Network prompt, a model choice on its screen, a login, Try again, a copy, or the start itself.
  It also says how long it has waited out of 15 minutes, for example "Waiting for the other Mac (Apple M5 Max,
  128 GB): it's waiting for Allow on its Local Network prompt · 2 of 15 min (q leaves)". It only knows this when the
  leading Mac runs this release or a later one. With an older leading Mac it keeps the general words.
- The live line always fits the window, even after the window is made narrower. Before, a long line could wrap and
  leave a new copy of itself on screen at every redraw. A plain transcript (`NO_COLOR`, `TERM=dumb`, a pipe) gets one
  line per change, never one per tick.
- If the two Macs run different Darkbloom builds, the waiting Mac now stops at once with
  "✗ Not serving: The two Macs run different Darkbloom builds." It names both versions and says which Mac needs
  `darkbloom update`. The leading Mac ends with the same ✗. Any other refusal by the leading Mac ends the wait
  at once too, with its reason.
- If nothing starts within 15 minutes, the wait ends with a ✗. It says what the leading Mac was last doing, what to
  do on it, and how to check that both Macs run the same build. Before, it ended with a plain sentence.
- The leading Mac's wait for Allow on its Local Network prompt now shows a timer and gives up after 10 minutes. It
  ends with a ✗ that says where to turn Darkbloom on, and what to do when Darkbloom isn't in the list: macOS asks on
  that Mac's screen the next time it connects.
- Every live line is one row: in the cluster screens, and in `darkbloom start`, `stop`, `restart` and `update`.
  - A long reason is shortened and keeps its time at the end. Its newlines and tabs become spaces.
  - Line wrap is off while the row is drawn, so a terminal that draws a character wider can't wrap it.
  - Before, the loading line could repeat across the window at every turn of its petal ("Loading Gemma 4 26B on both
    Macs (starting; this Mac's part ended (exit 1: …  ▖ Loading Gemma 4 26B …").

### Both Macs of a pair show how far the start is

- While the parts load, the leading Mac's screen shows one row per Mac with its share of the layers and the time:
  "This Mac: ready (layers 0–46)", "The other Mac: loading its share (layers 47–93)", or "part ended (exit 1);
  starts again in 5 s". A row that doesn't fit the window gets shorter instead of being cut. A plain transcript
  (`NO_COLOR`, `TERM=dumb`, a pipe) says each row once, when it changes.
- The leading Mac now publishes the start's step in its status: downloading, copying, stopping the model that served,
  loading, testing, or registering with Darkbloom. It also publishes a copy's or download's bytes as the sending Mac
  counts them, and which Mac's part is ready. The Mac that joined uses this to open its own "4/4 Start" heading
  and show, right under it, the same step, a real progress bar
  during a copy or download, and the same per-Mac rows. While the model loads there is no percentage, because
  Darkbloom has no measure of it: you see a turning mark and the time.
- On the Mac that joined, each new step gets the full 15 minutes again. A long copy no longer ends the wait with a ✗
  while its bytes still move.
- A Mac with an older Darkbloom ignores the new fields, and with an older leading Mac the joining Mac keeps its general
  words.

### Two-Mac cluster: the mode question shows what loads, and Local Network hints name the row macOS shows

- When you choose how both Macs split a model, each way now shows the split that loads, and the start loads exactly
  that plan. Before, with nothing serving, GLM-5.3-Flash's pipeline was offered as "this Mac 1 layer / the other Mac
  44 layers" and loaded as 44 / 1. A way chosen on the Mac that joined now loads too; before, the leading Mac loaded
  its own first choice.
- Two Macs of the same hardware (chip, GPU cores and macOS build) are planned at the same speed until the pair has
  served the model. Before, each Mac's own one-second speed sample decided, and a sample 0.1% slower (taken just after
  another app's pair stopped) offered GLM-5.3-Flash's pipeline as "1 layer / 44 layers" on two M5 Ultras, where 24 /
  21 is the split once the pair has served.
- Each way also says how many requests it serves at once: "serves one request at a time" for GLM-5.3-Flash's
  pipeline, "serves up to 8 requests at once" for its tensor parallel. On a GLM-5.3-Flash pair, choose tensor
  parallel where it fits (two 128 GB Macs fit only the pipeline): through Darkbloom its pipeline turns every other
  request away as "at capacity".
- Each way's line fits the window as it is now, and the list draws again when the window is resized. Before, a line
  was cut at the width the window had when the question opened, such as "… the other Mac 44 layers) · ser…" at 120
  columns, and it stayed cut after widening. A line that's too wide drops the split first, then what each Mac does.
  The way's name and how many requests it serves at once always stay.
- The Local Network hints on the setup screens, in `status` and `cluster status`, and in the log of the process that
  dials the other Mac name the row System Settings shows, "Darkbloom". The DevNet app's row has that name too, since
  both apps share one bundle ID. Where macOS never recorded an answer for the app and lists no row, the hints say to
  click Allow when macOS asks on that Mac's screen.
- The question recommends one way for these two Macs and says why: the only one that fits now, the one that serves
  more requests at once through Darkbloom, or the clearly faster one. It is the same on both Macs' screens, and Enter
  takes it. When nothing fits or nothing is known yet, it recommends none and says why.
- That recommendation is the question's first line and names the model, for example "Recommended for Gemma 4 26B on
  these two Macs: Tensor parallel", with the mode in bold in a colour terminal; in a narrow window the reason is
  shortened, never the names.
- `darkbloom uninstall` and `darkbloom cluster link --remove` undo every Thunderbolt port Darkbloom set up under one
  macOS approval, instead of stopping at "More than one port qualifies …; choose one". Each port's own network service
  is removed before the port goes back into its bridge (it used to end up in both), the removal stops at the first
  command that fails and says which ports are left, and an uninstall that already forgot the pairing says what is
  left and that running `darkbloom uninstall` again finishes it.
- On a Mac whose Thunderbolt ports start in the Thunderbolt Bridge, such as a MacBook, Darkbloom's network service is
  the port's only one, which macOS refuses to remove with its usual command. The removal now takes it out through
  macOS's network preferences, after checking its name and port, and setting up the cable port again reuses
  Darkbloom's existing service instead of removing and remaking it.

### The mode question recommends without quoting speeds

- `darkbloom cluster`'s mode question no longer shows tokens per second. The recommendation says why in words ("Recommended for Gemma 4 26B on these two Macs: Pipeline, faster here.") instead of "faster here (about 56 against 52 tokens/s, predicted)", and each mode's line drops its "N tok/s measured" or "not measured on these Macs yet". A re-plan's "Planned in the mode chosen" line drops the planner's predicted speed too. The measured or predicted speeds still decide which mode is recommended.
- A mode that serves more requests at once and is as fast now says "serves up to 8 requests at once and is as fast here" instead of calling itself faster.

### A two-Mac pair serving locally no longer reloads every half minute when requests queue

- A Gemma 4 pair in tensor parallel, serving locally with requests waiting, tried every 30–40 s to switch to an 8-request pipeline it could not serve the same way (only tensor parallel returns token logprobs). Each attempt stopped serving, failed, and reloaded the model on both Macs for about 15 s, so queued requests waited minutes. A replacement that would change what the API offers is no longer proposed.
- A wider setup that fails to start is now remembered: the same width is not tried again for that setup for 2 minutes, then 4, up to 30, while a changed setup is tried at once.
- Known limitation, now documented: a Gemma 4 pair in tensor parallel serves one request at a time, as its mode question says, and a request cancelled while its prompt is read keeps that one place until the prompt is read (about a minute for a 16K-token prompt).

### A two-Mac pair keeps its requests streaming while it admits another

- On a pair that serves several requests at once (GLM-5.3-Flash in tensor parallel serves up to 8), every running request's tokens waited while the pair admitted a new one. Under steady traffic, streaming fell to a few tokens a second. Running requests now keep streaming during an admission.
- A request the pair is admitting, or about to admit, now counts as a place taken in what the pair reports to Darkbloom. Before, Darkbloom could send one more request than the pair had room for, and the pair refused it ("provider capacity unavailable").
- A cancel now takes effect at once, even while the pair admits another request.

### Two-Mac pairs: the Macs no longer stay on different versions

- **Pair owners:** after an update, check that `darkbloom --version` shows the same version on both Macs; to update at once, run `darkbloom update` on **both** Macs. If either Mac ever ran a plain `darkbloom start` before 0.10.8, run `darkbloom stop --solo` on that Mac first.
- From 0.10.9 on, when one Mac of a `darkbloom cluster` pair already runs a newer release, or is updating to one, the other Mac's cluster service notices within a minute and updates right away, instead of waiting for the pair's next update slot. This covers a Mac that updated alone (single-Mac serving or `darkbloom update`), or a Mac that was asleep at the slot. Each newer release gets one immediate try; after that the Mac tries again at the update slots as before. A release quarantined on that Mac is never installed this way. With automatic updates off, the log says which version the other Mac runs and to run `darkbloom update` on this Mac.
- The provider's background updater no longer leaves a pair split: when it updates a Mac whose pair runs there, it asks the cluster service to restart into the release together with the other Mac. The watchdog doesn't install a release while the pair runs on that Mac. A Mac that only serves alone, its pair gone, simply updates.
- When the two Macs run different versions (both 0.10.9 or later), both screens say so at once: "The two Macs run different Darkbloom versions: the other Mac (…) runs 0.10.7, this Mac runs 0.10.8", with the Mac to run `darkbloom update` on. The start no longer loops: it offers to check the versions again, and a Retry checks them first. `darkbloom status`, `darkbloom cluster status --json` (`reason` and `next`) and the cluster service's wait lines also name the other Mac's version and the command. The version split is shown before single-Mac serving when both apply. DevNet builds say `darkbloom-dev`.

### Two-Mac cluster: a pipeline is no longer predicted faster than a share its Mac measured

- On two M5 Ultras the mode question recommended Gemma 4 26B's pipeline, "about 183 against 107 tokens/s,
  predicted"; 59.9 and 105.1 tok/s were served. Until a model has been measured whole on a Mac, its pipeline speed
  came from the Mac's device index alone, which leaves out every per-token cost. Where the Mac has measured a share of
  the model (a tensor-parallel load's share probe, or requests served in tensor parallel), the whole model is now
  planned at least as slow as that share plus the rest of its weights, so tensor parallel is recommended there.

### Each Mac of a pair names its part at the top

- On a paired Mac, `darkbloom cluster` (and the screen that `start`, `stop`, `restart` and `update` open in a terminal)
  now opens with "Darkbloom cluster · Leading Mac" or "Darkbloom cluster · Joining Mac", beside the Darkbloom mark or
  as the first line of plain output. You can always tell which Mac leads. A first setup, before the two Macs pair,
  still says "Darkbloom cluster" alone; the pairing then says which Mac leads.

### Switching a pair to Darkbloom plans it for Darkbloom, and no screen claims it serves there before it does

- Affected: a pair serving locally only, switched with **Switch to serving through Darkbloom** in `darkbloom cluster`. The switch kept the plan made to serve locally. For Qwen3.8 27B in tensor parallel that plan carries Qwen's speculative assistant, which only local serving uses, on any two Macs, and on two different Macs (an M3 Ultra and an M5 Max) unequal shares, such as 2:3. The coordinator can't register either, so the pair was never offered. Yet the screen showed ✓ "Serving … through Darkbloom on both Macs", and `darkbloom status` and `darkbloom cluster status` said `serving`, exit 0, "earning through Darkbloom". Since 0.10.8's login check, "Serve locally only" at the first setup also makes such a local plan, so a pair set up before both Macs were logged in hit this when it switched.
- The switch now plans the model again for Darkbloom, without the assistant and with equal shares. It adopts that plan before anything stops, starts both Macs, and asks the coordinator for the pair, as a start does. The screen says ✓ only once the coordinator has the pair.
- A pair set to serve through Darkbloom that the coordinator doesn't take (no approval, a refused one, or a coordinator that can't be reached) serves on the leading Mac's local API only. Both Macs now say so: `✗ Not serving: not offered to Darkbloom (<why>).`, then where it answers meanwhile. `darkbloom cluster status` reads it as `not_serving`, exit 3, with what to do next. No line says "earning through Darkbloom" any more.
- Choosing the serving model again on such a pair asks once, then starts it again from a plan for Darkbloom. Before, it said "✓ Already serving" and planned nothing.
- When a plan can't be offered (unequal shares, or Qwen's speculative assistant), the reason now says to choose the model again in `darkbloom cluster` (`darkbloom-dev cluster` in the DevNet app). It said to press m, but no item of the list starts with m, so the key did nothing.
- `darkbloom cluster status` and the other Mac's window no longer repeat the setup screen's "Then choose Retry, or serve locally only now." after a reason such as "isn't verified by Apple yet": neither has a Retry. `Next:` says what to do.

### `darkbloom cluster` says up front that its prompts are on each Mac's own screen

- Setting up a pair raises macOS prompts on each Mac's own screen: the password for the cable port, Allow for Local Network, and Yes to the pairing code. `darkbloom cluster` now opens with that on both Macs, and says to open Screen Sharing first to a Mac with no display, such as a Mac Studio or a MacBook with its lid closed.
- Once paired, the line for the other Mac's Local Network prompt names that Mac and says to use Screen Sharing if it has no display.
- Over SSH, macOS can't show its approval prompt. `darkbloom cluster` now says so before its first step, before anything is tried, and offers Quit (nothing changed) or to go on over SSH. `darkbloom cluster link --fix` and `--remove` say it before they start and no longer wait for a prompt that cannot appear. `darkbloom uninstall` over SSH stops before it changes anything when a cable port setup is left to undo, instead of stopping part way.
- The first line of the setup's Connect step now reads "Allow macOS permissions." (over SSH: "Allow macOS permissions here and on this Mac's screen (Screen Sharing if headless).") instead of naming the password and Local Network prompts.

### A pair keeps a model on its list after a request longer than the model's limit

- A pair no longer loses a model from its list after serving a request longer than the model's limit. On two M5 Ultras, Qwen 3.8 27B vanished from `darkbloom cluster`, and `darkbloom start` could not start it, after the pair served prompts of 71,545 to 94,423 tokens in tensor parallel. The next plan now skips each such served request and still uses every other request the pair served. It says so in one line, for example "Skipped 7 speed records longer than the 65,536 tokens planning covers (the longest was 94,522)".
- If the speed-up a speculative pipeline served can't be recorded, the plan now says so in one line instead of failing. That pipeline is then predicted at its plain speed, so the plan may choose another mode even where the speculative pipeline served faster.
- A model approved for clusters that can't be offered on these two Macs now says why, in one line above the model list, instead of disappearing. For example: "Qwen 3.8 27B: not offered on these two Macs: the plan for it failed (…)".

### Both Macs say when single-Mac serving blocks the pair

- The Mac that joined now shows the same ✗ as the leading Mac when single-Mac serving blocks the pair. The ✗ names its own single-Mac provider and process, and gives `darkbloom stop --solo`. It also says that the leading Mac's screen offers to stop it and start the pair. Before, that window said "registering with the coordinator" for minutes. Once single-Mac serving stops, it follows the start by itself.
- Each Mac reports single-Mac serving as soon as it runs, not only once the pair wants to start. So the leading Mac sees it before anything starts.
- The leading Mac's part no longer starts and ends every 38 seconds while the other Mac reports single-Mac serving. It waits until that changes. The same rule covers any reason the other Mac reports that its part can't start.
- In `darkbloom cluster status`, `Next:` now says what to run on both Macs instead of "Both Macs keep trying by themselves". A `darkbloom start` run from a script ends its wait at once for this reason.

### The single-Mac block shows on both Macs when the pair is stopped

- When you start a stopped pair from the leading Mac and single-Mac serving blocks it, the joining Mac's `darkbloom cluster` screen now shows the same ✗ instead of "Stopped … Close". It names the provider and process, gives `darkbloom stop --solo`, and says that the leading Mac's screen offers to stop it. Both Macs' `darkbloom cluster status` say the block too (`not_serving` with its reason, exit 3) while single-Mac serving runs, instead of `stopped` with no reason.

### A pair says when single-Mac serving blocks it, and offers to stop it

- When single-Mac serving (`darkbloom start --solo`, or a plain `darkbloom start` from before 0.10.8) runs on either Mac of a two-Mac pair, the pair can't start: both use the Mac's one serving lock. `darkbloom cluster` now checks both Macs before it starts the pair. It shows one ✗ that names the Mac and the process, with the command to run on that Mac: `darkbloom stop --solo`. It also offers "Stop single-Mac serving on both Macs and start the pair", and stops nothing unless you choose it.
- The pair no longer loops "this Mac's part ended … and starts again by itself" for this cause. Each Mac's cluster service waits for single-Mac serving to stop, and its status names the provider. The other Mac's line then gives that reason instead of "its part is running, no error reported".
- The lock's message names its owner correctly. It used to say "another update operation owns the lock (pid N, provider-instance)" for a provider that was serving. It now says "a single-Mac Darkbloom provider (process N) is serving on this Mac". An update, a rollback and a stop or restart are each named as such.
- The pair's advice when single-Mac serving runs, and the refusal of the pair's part, now say `darkbloom stop --solo`. On a paired Mac, plain `darkbloom stop` stops the pair and leaves single-Mac serving running.
- On a Mac whose pair is started, `darkbloom update` restarts the pair, and the watchdog no longer revives a single-Mac provider job that was left set up there. Before, the update restarted that job first and never restarted the pair. That job then took the serving lock, and the pair could not start again. The update says the job was left as it was and how to remove it.

### Single-Mac serving steps aside for a started pair, and the pair goes back to Darkbloom at once

- When the pair is started and wants this Mac's part, but single-Mac serving holds the Mac's serving lock and nobody chose it since the pair was started, the cluster service now stops it the way `darkbloom stop --solo` does. It logs why, and `darkbloom status` says so too. This covers single-Mac serving restarted by 0.10.8's updater during the update to 0.10.9, by a login, or by the watchdog. It doesn't step aside when you chose single-Mac serving yourself: `start --solo`, the terminal's "Serve on this Mac alone" and serving alone from the app record that choice, and starting the pair or `stop --solo` on that Mac clears it. A Mac updated from 0.10.8 has no recorded choice, so the started pair wins. It never steps aside while the pair isn't running there (serving alone stays as it is).
- Parts that ended because single-Mac serving held a Mac's serving lock no longer count toward the pair falling back to local-only serving. Once single-Mac serving stops, through the offer, `stop --solo` or a step aside, the count resets. An approval set aside for "parts kept ending" is offered to Darkbloom again at once, instead of after up to an hour.
- When the two Macs run different versions, the start's ✗ says that first, not the single-Mac block.

### `stop --solo` on the wrong Mac finds the right one

- If `darkbloom stop --solo` finds no single-Mac serving on this Mac but finds it on the other Mac of the pair, it names that Mac and its process and offers to stop it there. `--yes` stops it without asking, for scripts. It no longer points to plain `darkbloom stop`, which stops the pair and leaves single-Mac serving running.
- While single-Mac serving blocks a started pair whose other Mac answers, `darkbloom start` starts the pair (in a terminal, the screen that offers to stop it). It no longer offers "Serve on this Mac alone", which would recreate the block.
- "Single-Mac serving is set up" now means its job is loaded, not that its file exists. After `stop --solo`, a pair whose other Mac goes quiet no longer gives up its part for single-Mac serving that can't come back.
- An orphaned pair part, one that outlived its cluster service, is never reported as single-Mac serving. `stop --solo` can't stop it, so you're never told to try.

### `cluster status` says why a load keeps starting again

- While a Mac's part of the pair keeps ending and starting again during a load, `darkbloom cluster status` and `cluster status --json` now give that end as the reason, as the start's screen says it, for example "this Mac's part ended (exit 1: deadline) and starts again by itself". Before, both Macs said only `loading`, with no reason.

### The cluster screen folds each finished step to one line

- In a color terminal, `darkbloom cluster` (and the screen that `start`, `stop`, `restart` and `update` open on a paired
  Mac) now folds each step to one line once the next one begins, for example "✓ 2/4 Pair (1 min 12 s)". The screen
  no longer runs down with a line for every update.
- The lines that stay are the pairing code, each question with the answer you gave, any ✗ with its next steps, and the
  final outcome. A step taller than the window stays as it was.
- Nothing is lost: each run's whole flow, line by line, goes to a log file in `~/.darkbloom/cluster-setup/screens/`.
  Its path is the last line ("Full log: …"), and a ✗ names it too.
- Plain output (pipes, logs, `NO_COLOR`, `TERM=dumb`) doesn't change.

### `darkbloom cluster stop --service` works when the other Mac is already off

- On the Mac that leads, `darkbloom cluster stop --service` failed (exit 1) when the other Mac's cluster service was
  already off or did not answer, and left this Mac's cluster service and login agent running; only
  `--local-only` finished it.
- Once this Mac has stopped serving, its cluster service now stops and leaves login anyway, and the command says what
  happened on each Mac: `This Mac stopped serving.`, then that the other Mac did not answer and was not asked to stop
  (its cluster service may already be off), and to run `darkbloom cluster stop --service` there too if it is still on.
- When this Mac's own part has not finished releasing its memory, the command still fails and keeps the service, as
  before.

### The second Mac of a pair waits for the new setup after an update

- After the pair restarts into a new release, the Mac that follows no longer starts its part from the setup it saved
  for the previous release. That setup still names the previous release's files, so the part ended within a second,
  again and again ("Installed input identity or SHA-256 differs"), until the leading Mac sent the setup for the new
  release: on the M5 Ultra pair's update to 0.10.8, six times in about 2 minutes.
- It now waits for the leading Mac's setup and says so once: `this Mac runs Darkbloom v<version>, but its saved setup
  is for an earlier build: waiting for the other Mac's setup for v<version> (the old setup is not started)`. Every
  check of the installed files stays as strict; a setup that does not match them is never loaded.
- The leading Mac, waiting for both Macs to run the new release, checks again every 5 seconds instead of every
  minute, so it sets the pair up again sooner.

### The two-Mac setup's wait for the coordinator says the real cause, can be left, and the joining Mac follows a model change

- When a pair offered to Darkbloom isn't paired within 15 minutes, both Macs are registered and authorized, and the coordinator gave no reason, the ✗ now says "The coordinator didn't pair both Macs within 15 minutes". If the coordinator's reason is known, that reason is shown instead. Apple verification is named only while a Mac actually reports its App Attest authorization missing. Before, a reason seen once early in the wait could become the ✗, and two authorized Macs could read "isn't verified by Apple yet".
- q or Esc now leaves the wait for the coordinator: both Macs stay registered and keep trying by themselves, and the screen says to check with `darkbloom status`. A `darkbloom cluster stop` from another window or the other Mac ends the wait at once on both Macs with "Stopped (by `darkbloom cluster stop` …)", instead of waiting on with rows that go back to "registering".
- `darkbloom cluster` on the Mac that joined now follows any start the leading Mac runs, including a model or mode change: the steps, the bytes bar, each Mac's row and the final outcome. Before, it showed "This Mac runs its part by itself … Close".

### A pair the coordinator won't pair for its model says why

- A two-Mac pair offered through Darkbloom for a model that the coordinator's model catalog doesn't list waited on "waiting for the coordinator to pair both Macs" until the 15-minute limit, and `darkbloom cluster status` showed `loading` for as long as it ran. The coordinator refuses such a pair every time it checks and tells neither Mac. On DevNet this hit Gemma 4 26B and every other model that has a DevNet pair approval but no DevNet catalog entry.
- Each Mac's part now reads the coordinator's public model catalog once after it registers. If the catalog doesn't list the model, the part says so: "The coordinator does not pair Macs for <model>: its model catalog does not list it". The setup screens on both Macs show that reason at once, and `darkbloom cluster status` and `darkbloom status` report the pair as not serving with that reason instead of `loading`. A catalog that can't be read changes nothing. The part keeps running, so a pair whose model is added to the catalog later still forms.
- A pair that the coordinator paired, but under an approval it serves only to this account's own requests, no longer shows "✓ Serving … through Darkbloom". On DevNet a Gemma 4 26B pair under a DevNet model approval showed ✓ while every public request was refused because the pair was not public. The coordinator serves the public only from a pair under a release's build-pinned approval, for a model the release approves for public pairs and in a mode it approves. Each Mac's part now checks its saved approval against that rule. Both screens and `darkbloom cluster status` say "Not serving publicly: the coordinator paired both Macs but doesn't send public requests to this pair (…)" and what to do: update both Macs to a release that approves the model, choose an approved model, or choose an approved mode. A pair that meets the rule still shows ✓ once it serves; the provider doesn't see the coordinator's other public-serving checks.

### GLM-5.3-Flash runs on two 128 GB Macs

- Two M5 Max Macs with 128 GB each now load and serve GLM-5.3-Flash together, about half the model on each Mac. Before, `darkbloom cluster` refused the pair even with plenty of free memory, because each Mac set aside room for the longest possible request before loading.
- Each Mac now loads its half on what loading needs, and each request is checked against the memory free when it arrives. If a Mac is busy, the pair serves shorter requests and answers a longer one with a retryable "busy" error before it starts, never by running out of memory. Closing large apps brings back the full context.
- New: `darkbloom cluster gpu-limit` lets the GPU of any Apple silicon Mac with 128 GB or more keep more memory (its memory less 16 GiB: 112 GiB on a 128 GB Mac), an M4 Max or M3 Ultra as well as an M5, which leaves room for long requests. Run it on each Mac: it asks you once, then macOS asks for an administrator password, and the setting stays after a restart. `darkbloom cluster gpu-limit --undo` puts macOS's default back. Darkbloom never changes the limit on its own. After macOS approves, the command reads the setting back and shows ✓ only if it took effect; otherwise it shows ✗, what is off and what to run next.
- When a Mac's GPU limit is what stops a plan, the plan now says so and names that command on the Macs it runs on. A Mac that cannot load its part says which memory it is short of.
- `darkbloom cluster` offers only the ways a pair can actually run GLM-5.3-Flash: on two 128 GB Macs, including an M4 Max with an M5 Max, that is the pipeline. When nothing fits as the Macs are, the model's row says either "Needs `darkbloom cluster gpu-limit` first" (with the Mac and the figures) or "Needs more memory" with the reason, instead of the old "Too large … even with every application closed". The plan counts a GPU-limit raise only on Macs the command runs on (Apple silicon with 128 GB or more), so it never asks for a step that would be refused; Intel Macs and Macs under 128 GB are refused with the reason, and a Mac that does not report its GPU limit is never changed.

### MiMo-V2.6-Flash tensor parallel now loads in time

- Each Mac read its half of MiMo's expert weights in about 100 million tiny pieces, which took over an hour, so the load always ran out of time and both Macs showed "Loading" until "this Mac's part ended (exit 1: deadline)". The pieces that sit next to each other on disk are now read together, which takes seconds. The bytes loaded, and the memory used to read them, are unchanged.

### Sandbox setup can put the VM images and jobs on an external drive

- `darkbloom sandbox setup --disk <volume>` (repeatable) passes each drive to the add-on's installer, for its plan and its install. The VM images and the jobs go on those drives; the add-on, its settings and logs stay in `~/DarkbloomSandbox`. Add `--disk ~` to keep using the internal disk too.
- Without `--disk`, a first setup at a prompt lists the external APFS drives with room for jobs and asks where the VM images and jobs go. Enter keeps the internal disk.
- Setup checks each drive before it installs anything: mounted, APFS, ownership on. With ownership off it prints the exact command, such as `sudo diskutil enableOwnership /Volumes/FastSSD`, and offers to run it; sudo asks for your password. With `--yes` or without a terminal it prints the command and stops. Setup never formats a drive.
- The plan shows each drive, its free space and the jobs it gets. When the installer refuses a drive, setup shows the installer's fix and stops.
- `darkbloom sandbox status` shows each work disk, its free space and slots, and what to do when one is not connected.
- `--disk` needs an add-on release with work disks (1.2.0 or later). With an earlier release, setup says so and changes nothing. On a Mac that is set up, setup suggests `--disk` only when the installed add-on supports it.

### A Mac that stopped clustering serves normally again

- In 0.10.8, a Mac that had been in a two-Mac pair could show as online but get no requests. Its cluster service still had the pair's saved start, so it kept running its part of a pair that no longer formed. That part registers only as a pair member, and ordinary requests never go to it. `darkbloom start`, the app's Go Online and Autopilot enroll then acted on the pair, or were refused, so there was no simple way back.
- Whether the pair runs on a Mac now comes from what actually runs: the other Mac answering over the cable, and the pair serving. It no longer comes from the saved start alone.
- When the pair doesn't run on a Mac, `darkbloom start` serves that Mac alone. It first stops the leftover part, then says so in one line. The same goes for `darkbloom start --solo`, `start --model`, the app's Go Online and `darkbloom autopilot enable`. In a terminal, `darkbloom start` asks whether to serve this Mac alone or start the pair. Serving alone is the default when the other Mac isn't answering. While the other Mac answers but the pair hasn't served yet (a large model may still be loading), only `start --solo` and that choice stop the pair's part on this Mac. The pairing stays, and `darkbloom cluster` starts the pair again.
- `darkbloom stop` and `darkbloom restart` act on what runs on that Mac. `darkbloom update` and the watchdog bring back single-Mac serving there. On a Mac whose pair does run, they still protect the pair as before.
- A part whose other Mac hasn't answered for 15 minutes stops by itself and frees the Mac. `darkbloom status` says why, with the command to serve alone. The part starts again when the other Mac answers. A reboot of a few minutes doesn't break the pair, and time a Mac spends asleep doesn't count toward the 15 minutes.
- **Still on 0.10.8:** to serve a Mac alone again, run `darkbloom cluster pair --status` (it shows the other Mac's pin), then `darkbloom cluster pair --forget <pin>`, then `darkbloom start`. Plain `darkbloom stop` on 0.10.8 stops the pair, not single-Mac serving.
- **Known limitation:** on the Mac that follows, serving alone clears only that Mac's saved start. While the leading Mac keeps the pair started, it may start the following Mac's part again once single-Mac serving stops there. `darkbloom start` says so, and `darkbloom stop` on the leading Mac stops the pair.

### `darkbloom update` on a pair Mac ends once this Mac runs the new release

- `darkbloom update` on a Mac set up with `darkbloom cluster` could wait its full 10 minutes and end with "Still
  waiting after 600 s", although the Mac had already restarted into the new release: the restarted cluster service
  reports that no update runs, and the command waited to see its own request reach "restarting".
- It now also ends as soon as this Mac's cluster service runs the release it installed, and says so: `This Mac's
  cluster service now runs v<version>; the cluster sets itself up again once both Macs run it.`

## v0.10.8

Published 2026-11-04 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.10.8)).

### Upgrade and rollout notes

- Both Macs of a pair must run 0.10.8. A pair whose Macs run different builds refuses to pair: it fails closed ("the two Macs run different Darkbloom builds; install the same Darkbloom on both") until both Macs run the same release. The pair's own update installs a release on both Macs or on neither.
- A pair on 0.10.7 updates itself; nothing needs to be run. With `auto_update` on (the default) and `DARKBLOOM_NO_UPDATE_CHECK` unset on both Macs, at the pair's update slot (every 30 minutes) both Macs download and verify 0.10.8, the pair finishes the requests it accepted (at most 120 seconds, never cancelling one), and both Macs install it, restart their cluster services and set the pair up again. To update at once, run `darkbloom update` on each Mac; no log-out is needed. Two cases wait, as `docs/provider/two-mac-cluster.md` ("Updating Darkbloom on the pair") describes: a pair serving on the leader's local API (`darkbloom cluster local`) or a Mac serving alone does not update while it serves, and a pair whose cluster services were started by 0.10.6 (updated by hand but never logged out) must log out and back in on both Macs, or restart them, once.
- A pair still on 0.10.6 stops serving through Darkbloom once 0.10.8 registers, if 0.10.8's cluster runtime facts list more than 8 models (0.10.7's listed 12). The production coordinator keeps at most 64 pair approvals, newest release first and each release whole: 0.10.6 and 0.10.7 hold 24 each, and 0.10.8 adds 2 per model, so 0.10.6's are left out. Such a pair updates by hand once, as 0.10.7's notes say: `darkbloom update` on both Macs, then log out and back in on both. Single Macs do not use pair approvals.
- `darkbloom update --rollback` puts back the release a Mac ran before its last update (0.10.7, after this update) and quarantines the one it leaves. On a Mac that serves in a pair it refuses and changes nothing; stop that Mac's cluster service with `darkbloom cluster stop --service`, run `darkbloom update --rollback`, then start it again with `darkbloom cluster`, and the other Mac follows to the same release. From 0.10.8 on, plain `darkbloom cluster stop` stops serving on both Macs and leaves their cluster services on, so where the published v0.10.7 entries say `darkbloom cluster stop` for a rollback or a restart of the cluster service, use `darkbloom cluster stop --service`.
- New commands. `darkbloom uninstall` takes Darkbloom off a Mac: **Remove everything**, or **Keep models** for a later reinstall (`--everything` or `--keep-models` with `--yes`, and `--dry-run`, for scripts). On a paired Mac, `darkbloom start`, `stop`, `restart` and `status` now act on the pair, from either Mac, and `--solo` acts on single-Mac serving on this Mac only. `darkbloom stop` stops serving on both Macs; they stay stopped after a restart until `darkbloom start` on either Mac. `darkbloom cluster status` answers in plain words, with `--json` and an exit status for scripts and agents (`--details` is the earlier report).
- Macs stuck in App Attest's `is_supported_false` after a self-update serve again (#1765). When Apple first answers unsupported, 0.10.8 refreshes macOS's record of its own app (LaunchServices) and asks Apple again, once each time the provider starts or a scheduled availability window opens. So the update to 0.10.8 clears it too, although 0.10.7's updater installs it, and 0.10.8's updater refreshes the record after every later update. 0.10.7's automatic restart for this state had cleared 1 of 117 Macs.
- Known limitation, unchanged from 0.10.7: a pair serving in tensor parallel prefills prompts one at a time, oldest first. A short request that arrives while a long prompt is being prefilled waits for it. If that wait passes the short request's first-token allowance (10 seconds plus a share per prompt token, or the coordinator's first-content budget), the request ends with a first-token timeout, which the local API reports as `server_error` "Response generation failed". It is a timeout behind another request, and the request is safe to retry. It shows under mixed load with long prompts: in a 20-minute test on one pair, with prompts of about 56,000 tokens among short ones and up to 32 requests at once, 102 of 178 requests timed out this way. The pair kept serving, and a client that disconnects during a long prompt now frees its place within seconds once the pair receives the cancel. Through Darkbloom, a cancel can take 20 to 30 seconds to reach a pair that is busy with other long prompts, and under sustained load with long prompts the coordinator can end a pair's serving and set it up again, failing the requests in flight; they are safe to retry. Both are unchanged from 0.10.7.
- Known limitation, unchanged from 0.10.7: on a pair serving locally only, **Switch to serving through Darkbloom** doesn't offer the pair to Darkbloom until the pair starts again, although both screens show ✓ and `darkbloom status` says it is earning through Darkbloom. Stop the pair and start it again with **Serve through Darkbloom** (`darkbloom stop`, then `darkbloom cluster`).
- Known limitation: a GLM-5.3-Flash pair in pipeline serves one request at a time, and a request cancelled while its prompt is being read keeps that one place until the prompt is read. Tensor parallel serves several requests at once and was about 2.6 times faster per request on two M5 Ultras, so use it for GLM pairs.
- Known limitation: during a model or mode change on a pair, or while a pair updates itself, `darkbloom status` and `darkbloom cluster status` can read `stopped` (exit 4) or `unknown` on either Mac for a minute or two. Check again after a minute before acting on it, including before running `darkbloom start`.
- The registration is the one 0.10.7 sent: the same fields and a `darkbloom_cluster_runtime_v2` block, carried while `PROD_CLUSTER_RUNTIME_ENABLED` is `true`. The scripts that build the registration and its cluster runtime facts, and `ClusterPublicModels`, are unchanged since v0.10.7, so the production coordinator needs nothing new. The release jobs, their permissions and their order are unchanged too; only the notes on the GitHub release page are written differently. After the tag the platform snapshots its provider contracts from the tagged commit and sets `LatestProviderVersion` to `0.10.8`.
- MLX pins are unchanged from v0.10.7: `libs/mlx` and the nested `mlx` (`72dffa2d`), `libs/mlx-swift` (`c633d221`) and `libs/mlx-swift-lm` (`32f5c744`), so the tag build's `metallib_hash` should equal v0.10.7's `98bab9d7…614be`.
- The 20 entries below are the pending fragments rendered verbatim, in filename order. The two CI entries (#1752, #1771) and the release page entry (#1786) change no provider artifact. #1780 and #1784 have no entry of their own: they update entries of earlier pull requests (#1780 the uninstall entry of #1772), as #1783 and #1786 also do. The 0.10.7 entries that #1774 corrected after publication (`darkbloom cluster stop` to `darkbloom cluster stop --service`) are not repeated; the rollback note above carries that change.

### App Attest keeps an attestation cut off by a disconnect or a stop

- When the coordinator connection ends, or the provider is stopped or restarted (`darkbloom stop`, the cluster service restarting this Mac's part, an update), while Apple is attesting a new App Attest key, the provider now waits up to 30 seconds for Apple's answer and keeps the proof. The next connection sends it instead of retiring the key, so the Mac no longer loses private serving for an hour, and a pair it leads can serve once both Macs are verified.
- A crash or forced kill during that Apple call still retires the key under the same one-hour rule, and the hourly key budget is unchanged.

### App Attest keeps working after a self-update

- After a self-update, 12–15% of updating macOS 27 Macs reported App Attest as unsupported (`is_supported_false`) for minutes to hours. Restarting did not help: 0.10.7's automatic restart for this state fixed 1 of 117 Macs. Macs without the Darkbloom MDM profile received no inference until it cleared. The cause: Apple's answer depends on macOS's record of the installed app (LaunchServices), and the update replaced `Darkbloom.app` without refreshing that record.
- The updater now refreshes that record right after it installs a release.
- When Apple first reports App Attest as unsupported, the provider now refreshes the record for its own app and asks Apple again before it answers the coordinator, once each time the provider starts or a scheduled availability window opens. This also covers the update to this release, which the previous release's updater installs.
- When the provider already runs in the logged-in GUI session, `darkbloom doctor` no longer advises logging in through Screen Sharing and restarting for `is_supported_false`. It explains that this usually follows a self-update and prints the `lsregister -f` command that refreshes the record by hand.

### CI caches .git and SwiftPM repositories; only master and dev pushes save caches

- Every `ci.yml` job that checks out restores the newest saved `.git` first, so the checkout fetches only new objects and reuses submodule clones. A restored `.git` that `git fsck` rejects is deleted first; no step continues on error. The `.git` key names the UTC day, so each branch saves `.git` at most once a day. The full-history `docs` job keeps its own entries.
- The build lanes restore SwiftPM's repository clones, which a cold build otherwise downloads.
- Checkouts download less. Every job but Docs Lint skips the evidence tarballs under `docs/reports/evidence` and `landing/public/media` (408 MB of tarballs and landing videos), which no other job reads. Docs Lint and Docs Impact fetch history without file contents, about 37 MiB instead of about 1 GB, and fetch old file versions only when the provenance check reads them.
- Only pushes to `master` and `dev` save CI caches. A pull request restores its base branch's entries, then `master`'s, and saves none, so it no longer evicts them from the repository's 10 GB Actions cache.
- Provider builds on Darkbloom Macs use the CMake 3.31.12 already in the image's tool cache instead of downloading 80 MB each time; other runners still download and verify it.
- The MiMo audio gate, and the 1.87 GB codec its fixture needs, run only when the gate's inputs change (MiMo, audio and media provider code, the MiMo tests, the MLX pins, the fixture scripts or the gate's recipe) and on every `master` push. Pull requests never save the codec.
- Checkouts no longer keep the job token in `.git/config`, which the `.git` cache would otherwise store.
- Each job logs whether `actions/cache` compresses with zstd or gzip; entries saved with one are not restored by a runner using the other.
- Limitation: on a pull request, the provider summary job restores its base branch's newest compatible build and rebuilds the commit's changes instead of reusing its shards' build.

### CI's macOS jobs ask for Darkbloom Sandboxes again

- The macOS jobs of `ci.yml` read the Darkbloom route again, as they did before they moved to Blacksmith only. Each provider shard (`test-provider-1` to `test-provider-3`), the shard summary (`test-provider-summary`), the SDK lane (`test-provider-sdk`), the cluster metadata checks (`test-cluster-checks`), each cluster runtime and GPU shard (`test-cluster-1` to `test-cluster-3`, `test-cluster-gpu-1`, `test-cluster-gpu-2`) and the cluster focused checks (`test-cluster-focused`) run on a Darkbloom Mac when the plane grants their lane, and on `blacksmith-12vcpu-macos-27` otherwise.
- A lane is requested only when its job runs: the provider lanes when provider inputs change, the SDK lane on pushes and SDK-lane changes, and the cluster lanes when cluster inputs change.
- The provider shard count, the cache-save rules and the `.git` and SwiftPM caches are unchanged.
- Limitation: a lane the plane's approval does not name keeps Blacksmith, as do all lanes while `DARKBLOOM_ROUTING` is not `on` and for pull requests from forks.

### The everyday commands show the Darkbloom mark in a terminal

- In a terminal, `darkbloom start`, `stop`, `restart`, `status` and `update` open with the Darkbloom mark beside the
  command's name, blooming once as the cluster setup's does, and show its turning one-row live line while they wait
  for a drain, a restart or an update's download.
- Look only: every line the commands print is unchanged and in the same order, and so are their exit statuses.
- Scripts, logs, the background service's files, `NO_COLOR`, `TERM=dumb` and narrow windows keep exactly the plain
  output. `DARKBLOOM_NO_ANIMATION` or `CI` keeps the mark and the live line still.
- On a paired Mac, `darkbloom start` in a terminal opens the cluster's screen, which already draws the mark, so it
  isn't drawn twice.
- A command that refuses before doing any work (an unreadable pairing record, nothing to restart, flags that can't go
  together), or finds nothing to do (`stop --solo` with no single-Mac serving), prints only its lines, with no mark.
- The mark appears once, at the top of the command you ran: `unenroll` and `autopilot enable`, which run `stop --solo`
  and `start` inside themselves, show none.

### A pair no longer drops all its requests when one request runs out of time before it starts

- Only that request now fails, with a deadline error, and the pair keeps serving.

### A client that disconnects during a long prompt no longer stalls a two-Mac pair

- On a pair that serves several requests at once, a request whose client disconnects before any output now stops within seconds instead of first running its whole prompt, and the pair serves the next request at once. Before, a 60,000-token prompt kept both Macs busy for about 4 minutes, and the requests that arrived meanwhile failed. A pair that serves one request at a time still runs the prompt to its end.

### Two-Mac cluster: Serve locally only starts the faster local plan, and a closing link names the other Mac

- Choosing **Serve locally only** at the first setup's login check now starts the local plan: the model is planned again
  for serving locally before anything starts, so Qwen 3.8 27B in tensor parallel keeps the speculative assistant that
  only local serving uses (measured on one pair: 15.7 tok/s without it, 36–39 tok/s with it).
- When a part keeps ending because the link to the other Mac keeps closing, the ✗ says so and names the other Mac's side
  ("the other Mac's worker ended or the cable dropped") instead of blaming this Mac and calling the other "running, no
  error reported"; the ✗ title no longer begins with "starting; ".
- The DevNet app's cluster screens and `status` name its own command (`darkbloom-dev …`), not the production
  `darkbloom`.
- The mode you choose for a model is now the one that loads, also for GLM-5.3-Flash. When a part keeps ending, the
  message names the Mac whose worker actually stopped, this Mac's included (or says it can't tell), gives the other
  Mac's own reason when it can't connect (for example, macOS blocking its local network access), and no longer shows a
  planned model switch as a crash. The DevNet app names its own command in more messages.
- When macOS's Local Network setting keeps a Mac's Darkbloom app from reaching the other Mac, every screen now says so
  and what to do on that Mac (turn on Darkbloom under Privacy & Security → Local Network, through Screen Sharing on a Mac
  with no display), instead of "the other Mac did not answer". Retry starts a stopped pair again, q leaves a start's wait
  at once, and the joining Mac's window shows how the leading Mac's start is going.
- The Local Network ✗ no longer ends with a line that repeated its instruction and was cut off mid-sentence, and a ✗
  line too long for the screen is cut at a word and marked with "…". In the DevNet app, the pairing screen's firewall
  hint and its line about a reinstall name Darkbloom Dev.
- While a model serves, the question of how both Macs split a model says the split is decided when it loads, instead of
  offering one that may not be the split that loads; one layer reads "1 layer". The joining Mac's last lines say whether
  it serves again after a restart as its cluster service stands when they're shown.
- The card after a start says "Starts by itself at login on both Macs." only when the cluster service on both Macs
  does; otherwise it names the Mac where it doesn't, or says the other Mac doesn't say (an older Darkbloom there).

### `darkbloom cluster` after setup works like `darkbloom start`

- Run again on a set-up pair, `darkbloom cluster` (and `darkbloom start` on a paired Mac) opens with both Macs and the
  cable ("This Mac (Studio A) leads · the other Mac (Apple M3 Ultra, 256 GB) follows · cable ready") and the pair's
  status, then the pair's model list instead of a menu. The model serving now ("serving now", or "last used" when
  stopped) is preselected: Enter keeps it, or starts it again in the mode it served in.
- Each model shows its modes with the speed this pair served it at, or "not measured on these Macs yet". A model that
  runs more than one way asks how both Macs split it (the fastest measured first, tensor parallel or pipeline one
  keypress away, on mixed Macs too).
- A line under the models switches between local only and serving through Darkbloom (both logins are checked first,
  before the local API stops); another starts over after one question.
- Choosing another model while one serves asks once, then says "✓ Stopped … on both Macs" and shows each Mac's load.
  Choosing the serving model in its mode sends one test request and shows its result ("Already serving …; test
  response in 0.61 s", or the ✗ block with its choices); a pair served only through Darkbloom says this Mac has no local
  API to test from.
- Every start ends like `darkbloom start`: the outcome block, then the model in its mode and split, the Macs, where it
  serves, the log, whether it starts by itself at login on each Mac, and `darkbloom stop` / `restart` / `status`. A
  pair that does not serve keeps its ✗ block with Retry, Change model, Serve locally only and Diagnostics.
- The Mac that follows says that its part runs by itself, where to change the model, and that `darkbloom stop` there
  stops both Macs; Enter closes it.
- When the other Mac does not answer, the screen no longer says `darkbloom cluster stop` turned its service off, and
  says to run `darkbloom start` or `darkbloom cluster` there.
- A fresh setup opens with what it will ask and how long it takes.
- During the first setup the Mac that joins keeps its window open: it waits for the leading Mac to choose the model,
  follows the start, and ends with the leading Mac's own outcome instead of a test of its own: ✓ with the leading Mac's
  response time, or the same ✗ and reason ("Choose Retry on the other Mac" after ✗). Both windows tell the same story,
  serving locally only or through Darkbloom, also when the leading Mac's test request fails or when it checks with
  Darkbloom before it offers the pair (until then, neither Mac's status shows ✓). q leaves and the pair keeps going.
- Once the pair is registered, the screen says "Offered to Darkbloom as a pair for <model>; waiting for Darkbloom to
  accept this pair…" instead of "Registered with the coordinator as a cluster member" and the approval's ID, which read
  as if Darkbloom had already accepted the pair.
- When the other Mac isn't found within about 25 s at "2/4 Pair", the screen says what to check (the other Mac on this
  screen, macOS's firewall, or pairing directly with `darkbloom cluster pair --listen` and `--connect <address>`) and
  keeps waiting.
- A part that stops serving is reported with its own reason ("the coordinator reported this member's runtime as
  outdated", from its log), not "CancellationError()", on screen and in the diagnostics file.
- Switching how a pair serves no longer announces the result before it is known.
- The serving model chosen in another mode asks as a mode change ("Switch Gemma 4 26B from tensor parallel to pipeline?
  It stops serving on both Macs while it loads again …"), and the list names the mode it serves in when it shows another
  ("serving now in pipeline"); a set-up pair with no model to list (or whose planning fails)
  still offers Start over and Quit; a pair that doesn't serve is never marked "serving now"; a failed test says "Not
  serving" once, and its Retry waits for the pair as the start's Retry does.
- A mode is offered only where it keeps every feature of the model. Qwen 3.8 27B is therefore offered in tensor
  parallel only: in pipeline it would lose image and video input and logprobs. Choose the mode on the leading Mac; a
  model chosen on the Mac that follows starts in the mode Darkbloom's plan picks.
- The status shows the leading Mac's latest test. When a later test fails (testing the serving model again, its Retry,
  or the test after switching between local only and serving through Darkbloom), the status shows ✗ with "The last
  test from the leading Mac failed." instead of the earlier ✓ and response time. Switching between local only and
  serving through Darkbloom clears the test results, as a new start or a stop does.

### `darkbloom cluster` counts only the disk space that is free now

- Before a model is downloaded or copied between the two Macs, each Mac that receives it must have the model's size free on disk now, plus 2.1 GB to spare. Space macOS could free later is no longer counted, such as Time Machine local snapshots or files iCloud keeps elsewhere. On one Mac Studio, macOS reported 256.6 GB available with only 54.1 GB actually free, and the setup offered a 172.9 GB download that could not fit.
- When that space would have made room, the refusal says so: "Can't start Xiaomi: MiMo-V2.6-Flash: this Mac has 54.1 GB free; the model needs 172.9 GB and 2.1 GB to spare. macOS could free up to 202.5 GB more (purgeable files such as local snapshots), but Darkbloom doesn't count on it. Free space, then run `darkbloom cluster` again."
- The model list shows such a model last, ending "not enough free disk". The setup's Disk line and its low-disk warning use the same figure.

### Large models no longer loop on "not enough memory" on 128 GB Macs

- Large models such as MiMo V2.6 Flash no longer refuse to start on two 128 GB Macs. Each start used to read the whole model into macOS's file cache first. Loading a Mac's share then made macOS compress other memory, the memory check stopped counting the cache, and the start was refused, again and again. On 2026-11-01 a pair of 128 GB M4 Max Macs was refused 680 times in a row and never served.
- Each Mac now clears its model's files from the file cache before its part starts, and each load clears the cached pages of the weight files it reads. The loads read from the SSD into free memory, so nothing has to be compressed. Only the model's own files are cleared. Their contents are never changed and no password is asked for.
- The same cause sometimes refused Qwen3.8 27B for one start on a busy 128 GB MacBook Pro. That refusal is fixed too.
- A load can take a few seconds longer, because its weights now come from the SSD instead of memory.
- The worker log now records each load's memory check in one `darkbloom-load-memory-v1` line: what it needed, what was free, how much file cache there was, and how much was compressed during the load. A refusal now explains itself.

### On a Mac in a two-Mac cluster, the everyday commands control the pair

- `darkbloom stop`, `start`, `restart` and `status` now work on a paired Mac the way they work on one Mac, and each
  says first that it acts on the pair. `--solo` on any of them acts on single-Mac serving on this Mac only and never
  touches the pair.
- `darkbloom stop` (or `darkbloom cluster stop`) stops serving on both Macs, from either Mac. They stay stopped when
  a Mac restarts, and both Macs stay reachable, so `darkbloom start` on either Mac starts the pair again. It ends by
  checking that the memory was freed on both Macs. If the leading Mac doesn't answer, it says so and how to stop this
  Mac alone. The earlier `cluster stop`, which also turns this Mac's cluster service off, is
  `darkbloom cluster stop --service`.
- `darkbloom start` opens the same screen as `darkbloom cluster` in a terminal. In a script it starts the pair's saved
  model, waits until it serves, and ends with a short summary, as single-Mac start does; the exit status says whether
  it serves. Single-Mac options such as `--model` need `--solo` there; without it, `start` names them and
  starts nothing.
- `darkbloom restart` restarts the pair with its current model. `darkbloom status` starts with the pair: who leads,
  the model, whether it serves now and what to do.
- `darkbloom stop` no longer says "Provider service is not running" on a paired Mac, and never stops the cluster's own
  part when stopping single-Mac serving.
- `darkbloom cluster status` answers in plain words, with `--json` for scripts and agents and an exit status (0
  serving, 3 not serving yet, 4 stopped, 5 the other Mac isn't answering, 6 not in a cluster, 7 this Mac's pairing
  record can't be read). The earlier detailed report is `--details`.
- A Mac whose pairing record can't be read is never reported as "not in a cluster": the commands say so and how to
  check it (`darkbloom cluster`). `start`, `stop` and `restart` then change nothing without `--solo`.
- `darkbloom cluster --help` lists the other cluster commands and what each is for.
- `darkbloom cluster link --remove` on a paired Mac warns first that it undoes the working cable setup and stops the
  cluster on both Macs, and asks once (`--yes` for scripts).
- `darkbloom stop` says the pair stopped only once both Macs' parts have ended (it waits up to a minute); otherwise it
  says it asked both Macs and what is still running. A failed stop on the Mac that follows says what is known.
  `darkbloom restart` starts the pair again only once both parts have ended. A script `start` waits through the
  coordinator's pairing and an Apple verification retry instead of reporting "not serving".
- A cluster service left from an earlier pairing no longer makes a Mac count as paired; `darkbloom cluster status`
  names it and how to remove it. `--solo` refuses while this Mac's part of the pair serves (they share one serving
  lock). The app's local mode says plainly that it isn't available on a paired Mac.
- `darkbloom update --rollback`'s advice turns the cluster service off with `darkbloom cluster stop --service`.
- The DevNet app names `darkbloom-dev` in every command it suggests for a pair: the card after `start` and
  `restart`, `cluster stop --service`, `cluster local`, `cluster pair --forget` and the hints. Its Local Network hint
  names the app to allow, Darkbloom Dev.
- `stop`, `restart`, `cluster stop --service` and a script `start` say what they are waiting for and for how long at
  most, instead of going quiet for minutes.
- With Darkbloom and Darkbloom Dev on one Mac, each lists only its own cluster incidents. Incidents recorded before
  this count as Darkbloom's.
- The leading Mac's service log notes the other Mac's status checks once a minute, not every second.
- Darkbloom Dev keeps its cluster incidents in a file of its own, so Darkbloom never lists them, even before
  Darkbloom itself updates.
- Right after Darkbloom Dev is installed on a paired Mac, `darkbloom-dev doctor` no longer fails with "Configuration
  input is unsafe, empty or oversized" before a cluster setup is chosen with it. A saved setup in a file that other
  users can open fails with the fix (`chmod 600 …`).
- In the DevNet app, `darkbloom-dev cluster` without a terminal, the "Cluster service" line of `status`, Ctrl-C in
  the setup screen and the pair update hints name `darkbloom-dev`.
- `darkbloom cluster status --json` on the leading Mac says whether the other Mac answers while they run the cluster.
- On the Mac that follows, `cluster status` and `status` wait at most 10 seconds for the leading Mac's answer, and say
  so when it is slow; past that they show this Mac's own view.
- `darkbloom unenroll` (leaving fully) and the app's local mode no longer stop with an internal error when they stop or
  drain the provider first.
- `status` and `cluster status` no longer say "loading" while macOS keeps a Mac off the local network: both Macs say
  the pair is not serving and what to turn on, on which Mac. A stopped pair reads stopped even when the other Mac has
  gone.
- On the leading Mac, that "not serving" now holds while the other Mac stays refused, also while the leading Mac's
  part restarts; `cluster status --json` then lists the same "Not serving" line as the plain output. The DevNet app's
  stopped pair names its own `local` command.
- `cluster status --json` gives the serving mode and each Mac's share, and the "Model:" line of `status` and `cluster
  status` names the mode, for every mode. Before, a pair serving GLM-5.3-Flash in pipeline left them out.

### A paired Mac's cable port is no longer reported as not isolated

- `darkbloom cluster link` and `darkbloom cluster doctor` no longer report a paired Mac's cable port as not isolated ("the cluster subnet 10.219/16 is already used on this Mac") because macOS routes the port's own address through the loopback.

### Cluster model list: one rule for what fits

- The cluster's plan now judges a Mac's memory with every app closed the way the load-time memory gate does, which counts cached files: a 128 GB Mac can give a model 120 GiB, not 75.6 GiB. MiMo V2.6 Flash on two 128 GB Macs, and large models on an M3 Ultra with an M5 Max, are offered (with "Quit apps first" when apps hold the memory) instead of being called too large even with every application closed.
- A split whose GPU part is larger than a Mac's GPU memory limit is no longer offered just because memory happens to be free; it would fail with "Insufficient Memory".
- A Mac under memory pressure is no longer described as fitting on cached files the gate will not count; the plan says to quit apps there first.

### `darkbloom cluster` on Macs paired before: next steps, Pair again and Start over

- A Mac whose saved pairing was made with another Secure Enclave key (after
  moving between the Darkbloom and DevNet apps, or after the installer made a
  new key) now says so when `darkbloom cluster` opens and offers **Pair again**,
  instead of its usual menu while every start of its part failed with "pair
  again".
- When the other Mac does not answer over the cable, the screen names that Mac,
  its likely reasons (its cluster service is off, or it is asleep, off, or
  waiting for someone to log in) and the command to run there. It keeps **Start
  over**, which asks first, since a Mac that is away is not a
  broken pairing; the Mac that follows also offers **Try again**. This ends the
  case where one Mac waited at "2/4 Pair" while the other, still holding an
  earlier pairing, showed its status and ended.
- Choosing a model no longer spins on "Reading both Macs over the cable" with no
  reason: the screen says why it is still waiting and, on a Mac paired before,
  ends with **Try again**, **Start over** and **Quit**.
- The Mac that follows names the Mac it follows and the command to run there,
  instead of "Nothing to do here".
- Setting up a cable port from `darkbloom cluster` continues to the Mac's usual
  screen instead of ending there.
- Every paired Mac offers **Start over**, which asks once (No by
  default). It and **Pair again** unpair this Mac exactly as `darkbloom cluster
  pair --forget` does, then run the ordinary pairing with the code on both
  screens.

### `darkbloom cluster` says Serving and Done only once the model is loaded

- The setup ends with its outcome between two rules: `✓ Serving <model> through Darkbloom on both Macs (<split>)` (or
  `on this Mac's local API only`) with the API and the test response, then Done; or `✗ Not serving: <reason>.` with
  the next step. Before, a pair registered with the coordinator said Serving and Done on both Macs while nothing was
  loaded.
- Such a pair is now awaited, at most 15 minutes, until both Macs loaded the model and it answered its first request.
- The reasons it names: a Mac without a Darkbloom login, a Mac Apple hasn't verified yet (with when Darkbloom retries
  by itself; don't restart either Mac until then), a Mac without free memory for its share, or a part that keeps
  ending. **Retry**, **Change model**, **Serve locally only** and **Diagnostics** follow; q exits with status 1 and
  never says Done.
- Switching a serving pair between serving through Darkbloom and locally only, from the leading Mac, now ends the same
  way as a start: tested (or, for a pair registered with the coordinator, awaited until it serves), then the outcome
  block. Before, a registered pair was called serving at once.
- A missing login is named before the Start step starts anything, with **Log in on this Mac** (or **Check again**),
  **Serve locally only** and **Cancel**.
- The Start step says loading takes a few minutes for a large model; a color terminal shows one live row per Mac with
  its time so far.
- `darkbloom cluster` status calls a registered pair serving only while it serves, else
  `<model> is not serving yet: <reason>.`, and says a Mac serving alone is still loading until its solo server answers.
  The other Mac shows the same outcome block, and its setup ends with the same ✓ or ✗ as the leading Mac.

### A setup prompt for AI agents

- New provider how-to, `docs/provider/agent-setup.md`, for a person to hand to their own AI agent. The agent installs and checks the signed release, logs in with the person's help, and either serves on one Mac or pairs two Macs over a Thunderbolt 5 cable. It then proves the result with `darkbloom status`, `darkbloom cluster status --json` (its exit status and `state`) and a test request, instead of trusting the setup screen alone.
- It lists, up front, what only the person can do, such as the Terms of Service, the Darkbloom login, the RDMA switch, the macOS password and Local Network prompts, the pairing code, the model choice and Screen Sharing for headless Macs. It also sets the agent's safety rules, among them: no security settings changed, no Darkbloom files or Keychain items deleted by hand, no `darkbloom cluster link --remove` unless asked, and no large download without asking.
- Once a pair is set up, the agent checks it with `darkbloom cluster status --json` and starts or stops both Macs with `darkbloom start` and `darkbloom stop`, all without a terminal. The page also covers changing the model, pairing again, `--solo`, troubleshooting by message, and `darkbloom uninstall`.
- Checked by an agent that followed it on a real two-Mac pair: it now has a DevNet variant (`darkbloom-dev`, the DevNet installer, `Darkbloom Dev.app`; a pair's local API on port 8000 in both apps), tells the agent to have the person turn on Local Network access in System Settings on each Mac instead of waiting for a macOS prompt, quotes the screens and the `darkbloom cluster status` reason that say when macOS keeps a Mac off the local network (the agent then stops and asks instead of waiting), and covers the app switch that offers no **Pair again**.
- Documentation only: no provider artifact changes.

### Uninstall Darkbloom: remove everything, or keep the models

- `darkbloom uninstall` takes Darkbloom off a Mac in one step. In a terminal it shows two choices with this Mac's sizes: **Remove everything** (the app, settings, pairing, logs and all models) or **Keep models** (everything else goes; a reinstall reuses the models). Esc cancels, and **Remove everything** asks once more, with the size of the models it deletes. Run it as yourself: with `sudo` it refuses and says so.
- Both choices stop serving the way `darkbloom stop` does. On a Mac in a two-Mac pair, that means both Macs stop, from either Mac, and this Mac's cluster service is turned off; when the other Mac doesn't answer, only this Mac's part stops. Then they remove every Darkbloom background service, revoke this Mac's account token where the coordinator can confirm it, unpair, undo the cable port setup (macOS asks for your password) and delete Darkbloom's settings, logs, caches, the app and the `darkbloom` command link.
- **Keep models** leaves the models Darkbloom downloaded and the cluster model store in place: after installing again, `darkbloom start` or `darkbloom cluster` finds them without downloading. The sizes count APFS clones once.
- It never deletes a models folder you chose or the cluster model store beside it, even inside `~/.darkbloom`, nor anything outside Darkbloom's folders (links that point elsewhere, another disk mounted in them), and never touches Keychain keys; the summary lists what was kept and where. When a folder of Darkbloom's could not be removed, the summary says Darkbloom is not fully removed, says why, and the command exits 1. On a paired Mac it ends with what to run on the other Mac.
- On a Mac with both the production Darkbloom and Darkbloom Dev, uninstalling one keeps this Mac's pairing, cluster setup and cable port setup, which the other still uses, removes only its own cluster service, and says so; uninstall the other one too to remove them. When your models folder is `~/.darkbloom` itself, the summary says Darkbloom is not fully removed and what to do. A dry run also names a cluster service running without a login agent.
- A cluster service that runs without its login agent (development builds, or a Mac where launchd did not take it) is now stopped before anything is deleted: with one install, any `darkbloom cluster service` is; beside the other install, only this install's, and the other's keeps running. A cluster service it doesn't stop, or can't tell apart, makes the uninstall delete nothing and say why. The two choices' lines say only what each removes on this Mac.
- Uninstalling one install of a serving pair beside the other install on this Mac now stops the pair first, on both Macs, as `darkbloom stop` does, so the other Mac no longer keeps restarting its part. It says so before it waits for accepted requests to finish (up to about 6 min); if the other Mac doesn't answer, the summary names it and the command to run there.
- Uninstalling Darkbloom Dev beside the production Darkbloom also removes Darkbloom Dev's own cluster incident log (with its lock and corrupt copy), which it kept in the shared cluster folder, and names it in the summary.
- For scripts and agents: `--everything` or `--keep-models` with `--yes`, and `--dry-run` (with `--json`) to list every action and path without changing anything. `darkbloom stop --uninstall` works as before.

### Release pages list every pull request in the release

- A provider release page on GitHub now lists every pull request in the release, with its title, its author where known, and a link. This includes the pull requests that reached `master` through `dev` in a squash merge, which GitHub's generated list left out: the v0.10.7 page showed 5 of its 50 pull requests. Pull requests merged directly into `master` are listed separately. The promotion of `dev`, the release preparation and syncs of `master` into `dev` are named once, not listed as changes.
- When the release job cannot read pull requests through GitHub's API, the titles come from the merge commits, and an author is shown only where a commit's GitHub address names the account.
- The page also shows the release's whole `CHANGELOG.md` section, with its upgrade and rollout notes. The update banner's short summary is unchanged.

### A pair Mac reinstalled with `install.sh` no longer acts on releases it does not run

- `install.sh` (or a copied app) replaces Darkbloom without updating the record the updater keeps of what is installed. A pair Mac reinstalled this way could keep an older release as "pending": at every update slot it then tried to reinstall the release it already ran, and three unexpected stops of its cluster service would have restored an old release that the other Mac cannot pair with.
- Before each start of its cluster service, a pair Mac now checks that record against the installed app. When they differ, the record is corrected to the installed release, the stale pending release is dropped, and the copy kept for rollback is removed, because the other Mac does not have it. The Mac logs one line saying what changed. Rollback is possible again after the next update, which keeps a copy of the release that ran.
- A kept copy recorded under the wrong version by an earlier update, on a Mac reinstalled with `install.sh`, is now recorded as the release its app really is and kept, so the Mac can still roll back to the release the other Mac returns to. A kept copy that cannot be verified is removed. An update over a reinstalled app now records that app as the release it is.
- A damaged install (a file missing or unreadable) is not taken for a reinstall: its failed starts still count, and the third restores the kept copy, as before.
- The release a Mac runs is never offered as an update: the update slot reports it up to date instead of downloading it, reinstalling it and restarting the cluster service.

## v0.10.7

Published 2026-11-03 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.10.7)).

### Upgrade and rollout notes

- Both Macs of a pair must update to 0.10.7. The Gemma 4 and MiMo-V2.6-Flash plans change (#1706, #1707, #1715), as does the Qwen tensor-parallel control wire (#1727), and a pair whose Macs run different builds refuses to pair: it fails closed until both Macs run the same release.
- A pair on 0.10.6 cannot update itself into 0.10.7: its cluster service predates the pair's coordinated update. On each pair, once: run `darkbloom update` on both Macs, then log out and back in on both (or restart them), as `docs/provider/two-mac-cluster.md` ("Updating Darkbloom on the pair") describes. From 0.10.7 on, the two Macs of a pair update together by themselves (#1702). If `darkbloom cluster` then says that a Qwen pair of two different Macs, which 0.10.6 saved with unequal tensor-parallel shares, is not offered for pairing, press `m` and choose the model again: it is planned with equal shares and registers (#1723).
- Gemma 4 and MiMo-V2.6-Flash tensor parallel are public (#1736): `ClusterPublicModels` declares `gemma-4-26b-qat-4bit` and `mimo-v2.6-flash-mopd` in pipeline and tensor parallel, as it does GLM-5.3-Flash and Qwen3.8-27B, and MiMo-V2.6-Flash's speculative pipeline too, so this release's cluster runtime facts carry their pair-serving grants and parity qualifications. Their tensor parallel is in this build (#1706, #1707, #1716), and a pair chooses it only on tensor parallel's own measured speed and only where it keeps every feature of the mode it would replace (#1715), so normal setups keep the pipeline for now. Speed on a real pair is not measured for either model's tensor parallel, and MiMo has no tensor-parallel qualification record yet. The entry "MiMo-V2.6-Flash and Gemma 4 26B QAT serve public cluster traffic" below says their tensor parallel serves once its code is in the build: in 0.10.7 it is.
- `darkbloom update --rollback` (#1729) puts back the release a Mac ran before its last update (0.10.6, after this update) and quarantines the one it leaves, without contacting a coordinator. It refuses on a Mac that serves in a pair: stop that Mac's cluster service first. The other Mac follows a rollback only to a release that has #1739, so a pair rolled back to 0.10.6 needs the rollback on each Mac.
- The operator's enabled-model filter wins over coordinator model changes (#1730): with `enabled_models` set, a coordinator `load_model` or `prefetch_model` outside it is refused (`model_not_selected`), and a provider no longer moves to a new build of a model by itself; `darkbloom switch` takes one.
- On one Mac, Gemma 4 replies keep the space before punctuation (#1693) and characters outside its vocabulary (#1703), with the same token IDs and cache keys, and a client `stop` sequence matches only the answer's `content`, not reasoning (#1650).
- The registration is the one 0.10.6 sent: the same fields and a `darkbloom_cluster_runtime_v2` block, carried while `PROD_CLUSTER_RUNTIME_ENABLED` is `true`. After the tag the platform snapshots its provider contracts from the tagged commit and sets `LatestProviderVersion` to `0.10.7`.
- MLX pins: `libs/mlx` and the nested `mlx` (`72dffa2d`) and `libs/mlx-swift` (`c633d221`) are unchanged from v0.10.6. `libs/mlx-swift-lm` moves from `7933a0fa` to `32f5c744`, its fork's `main` (SDK #370, #371, #375 to #377 and #379 to #384). It changes Swift files only, and the one Metal kernel it adds, an FP32-output variant of MiMo's decode down projection, compiles at run time (`MLXFast.metalKernel`), not into `mlx.metallib`, so the tag build's `metallib_hash` should equal v0.10.6's `98bab9d7…614be`. Complete SSD checkpoints stay per build: 0.10.7 does not restore those 0.10.6 wrote.
- The 39 entries below are the pending fragments rendered verbatim, in filename order. #1711 (a latent GPT-OSS cache-metadata fix), #1743 (two race fixes; one keeps `darkbloom cluster stop` from failing with "could not save the stop request") and the CI and test PRs #1665, #1691, #1733, #1737, #1741, #1747, #1749, #1750 and #1753 have no entry.

### App Attest restart covers the first episode after an update

- The `is_supported_false` restart now also works in the first process after an update from a version that did not record its App Attest authorizations. At serve start, when `app-attest-verified.json` is missing, the provider fills it once from the previous `daemon-state.json`, with evidence from the last 7 days: the last successful Apple call of a stored key that Apple attested, or an App Attest grant left by an unclean exit. All other conditions stay the same.
- A Mac whose previous provider was itself reporting `is_supported_false` has no such evidence, so it still waits for the coordinator to grant App Attest again.

### App Attest recovers by itself after a self-update

- A provider that launchd runs as its provider job now relaunches through launchd after a startup self-update, as it already did after a background update. Only a provider that launchd does not run, such as `darkbloom start --foreground` in a terminal, replaces itself in place. A background update or App Attest restart in such a provider no longer starts the LaunchAgent instead.
- When App Attest reports `is_supported_false` on a Mac that the coordinator verified for App Attest in the last 7 days, the provider restarts once through launchd. It waits until the state lasts 5 minutes and the provider is idle, and it checks Apple's answer again after the drain. If the new process still reports unsupported, it does not restart again until the coordinator verifies the Mac again. This restart and the stall restart share one limit: one automatic App Attest restart per 6 hours. Cluster members never restart for it.
- The provider keeps the time of its last App Attest authorization in `app-attest-verified.json` beside the daemon state file.
- The local provider log gets an `App Attest entitlement evidence` line at startup and at each `is_supported_false` answer: the start reason, the App Attest entitlements of the running process and of the code on disk, and the executable's modification time relative to the process start. It is not sent to the coordinator.

### Cache restores finish sooner

- Restoring a prefix-cache checkpoint decodes its older attention rows from the
  default `balanced` checkpoint precision on the CPU. The decoder now checks each
  row for values its native type cannot hold once per row instead of once per
  eight values, with the same bytes and the same refusals. On Gemma 4 26B
  follow-up requests served from the SSD cache, time to first token fell by about
  0.2 s per restore (about 25% over an 11-request conversation on an M3 Ultra),
  and responses that save a checkpoint also end about 0.2 s sooner. Output is
  unchanged.

### Responses that save a cache checkpoint finish sooner

- Saving a prefix-cache checkpoint encodes its older attention rows at the default
  `balanced` checkpoint precision. That encoding now prepares its buffers and its
  check once per segment instead of once per row and writes the same bytes. On a
  Gemma 4 26B request that saves a checkpoint, the end of the response arrived
  about 0.7 s sooner (1.7–2.0 s → 1.0–1.2 s on an M3 Ultra), with identical
  output. Requests that save no checkpoint are unchanged.

### Pair Macs set up with `darkbloom cluster` update themselves

- A Mac set up with `darkbloom cluster` now updates itself, as a single Mac does: with `auto_update` on (the default) and without `DARKBLOOM_NO_UPDATE_CHECK`, its cluster service checks the coordinator's latest release every 30 minutes, at the pair's update slot, which both Macs derive from their pairing's cluster ID.
- Each Mac downloads, verifies and stages the release while the pair serves. Only once both Macs have it does the pair stop taking new requests; the Mac that serves the pair finishes its accepted requests (at most 120 seconds, never cancelling one), then both Macs install the release and restart their cluster services, and the cluster sets itself up again for the new release with no command run.
- A pair under constant traffic updates too: once it takes no new requests, the accepted ones finish. A pair still running a request at the bound takes requests again and tries at the next slot. A release one Mac cannot download or verify is installed on neither Mac; both try again at the next slot.
- An installed release is promoted once its cluster service has stayed healthy for 10 minutes; three starts of its service that end on their own restore the previous release and quarantine the new one, as the watchdog does for a single Mac.
- Before a Mac restarts into an installed release, its cluster service runs the new `darkbloom --version` once (at most 30 seconds). A release that does not answer with its version is never restarted into: the Mac restores the previous release at once, quarantines the new one and starts its cluster service again, so a release that cannot start no longer leaves the Mac with nothing to roll it back.
- `darkbloom update` on a cluster Mac installs the release and then restarts the cluster service into it together with the other Mac, after the pair drained; logging out and back in is no longer needed. Run it on both Macs (or let the other Mac update at the next slot); the first Mac waits up to 15 minutes for the second, also when automatic updates are off. A Mac whose partner has automatic updates off downloads nothing at the slot.
- A pair that serves on the leader's local API, or a Mac that serves alone, is not drained for an update yet: it does not update while it serves, and a cluster set to serve locally (`darkbloom cluster local`) or a Mac serving alone downloads nothing at the slot.
- A cluster service started by an earlier release does none of this: to reach this release, run `darkbloom update` on both Macs, then log out and back in on both (or restart them) once.

### Tensor parallel only where it keeps every feature

- On a two-Mac pair, Gemma 4 and MiMo V2.6 Flash use tensor parallel only where it keeps every feature and caching behavior of the mode it would replace: prompt-prefix and SSD cache reuse, speculative (MTP) rounds, batch lanes, media, penalties and logit bias, stop handling and logprobs. What tensor parallel adds, such as logprobs where the pipeline has none, never counts against it. Each mode's features come from the installed cluster worker's capability record.
- Gemma 4's tensor parallel keeps every feature of its pipeline, prompt-prefix and SSD reuse included, so its measured speed decides. MiMo's tensor parallel decodes in speculative rounds, so it keeps every feature of the speculative pipeline and its measured speed decides; only where the plain pipeline is the mode it would replace do that pipeline's batch lanes keep it. The plan's "Tensor parallel or pipeline" line says what tensor parallel would drop ("Pipeline: tensor parallel would drop batch lanes up to 8 (it serves 1) that the pipeline keeps; held back until it keeps them."), and the model list says "tensor parallel: drops a feature".
- Where only tensor parallel fits the two Macs, the plan refuses with that reason and saves no setup, instead of saving one with fewer features. The developer's forced mode (debug builds) still places tensor parallel, and the plan says exactly what it drops.
- Qwen and GLM plans are unchanged.

### Simpler two-Mac cluster setup

- `darkbloom cluster` setup says far less: four steps (Connect, Pair, Model, Start), a line per thing that happened,
  and the next thing to do last. Every choice is a list (↑↓ and enter, as `darkbloom start` picks models; numbered in
  plain transcripts); q or Esc cancels.
- The model list shows only the models approved for clusters (GLM-5.3-Flash, Qwen3.8 27B, MiMo-V2.6-Flash and
  Gemma 4 26B QAT) that the two Macs can serve, each with its size and its split: tensor parallel or pipeline. The
  serving lines name the split too.
- The Mac you set up on leads and keeps leading: every plan puts rank 0 on it, the cluster service's own re-plans
  included, so a pair set up with 0.10.6 whose other Mac took over leading moves back at its next plan.
- macOS's password and Local Network prompts come at stated moments (sudo in the terminal over SSH); both Macs ask
  about Darkbloom's Local Network access right after pairing, and the setup waits until Allow or q.
- Both Macs confirm the pairing code; the Mac that follows only shows the status. The serving line says whether the
  pair earns through Darkbloom or serves locally only.
- `darkbloom doctor` includes the cluster's checks on a Mac paired for a cluster.

### Qwen pairs of two different Macs register with the coordinator

- Affected: a pair of two different Macs set up with `darkbloom cluster` to serve through Darkbloom, with a Qwen model planned in tensor parallel. The planner gave the faster Mac the larger share of every layer (for example 2:1 on an M3 Ultra and an M5 Max), and the coordinator registration cannot name unequal shares yet. Both Macs still said `Registered with the coordinator as a cluster member`, then each Mac's part refused to register ("The saved roster registration is not valid for this Mac: invalidPlan"), the pair fell back to the leader's local API, and the coordinator never formed it or routed it a request. This hit Qwen3.8 27B, which pairs only in tensor parallel, and Qwen3.5 9B where tensor parallel was chosen. GLM-5.3-Flash, pipeline splits and two identical Macs were not affected.
- A pair served through Darkbloom is now planned with equal tensor-parallel shares, so it registers and is routed like a pair of identical Macs; on two different Macs the slower one sets the pace. A pair that serves you alone (`darkbloom cluster local`) keeps the faster unequal split.
- A setup saved with unequal shares (by 0.10.6, or a local cluster switched to Darkbloom with `p`) is not offered for pairing, and the leader says why before it stops either Mac's part: `Not offered for pairing: this Mac's check refused it: Unequal tensor-parallel shares serve local clusters only …`. If `darkbloom cluster` shows this once both Macs run this release, choose the model again there: it is planned with equal shares and registers.

### Both Macs of a pair roll back together

- When one Mac of a `darkbloom cluster` pair rolls a release back (three failed starts of its cluster service, a failed start check, or `darkbloom update --rollback` while its cluster service was stopped), the other Mac now rolls back to the same earlier release, and the pair serves it together. Before, the pair stayed split until a newer release updated both Macs.
- The other Mac checks at its start and every minute while no update runs, also with automatic updates off. It finishes the accepted requests of its part first, as for an update, restores the release it kept from before its last update, quarantines the rolled-back release and restarts. Both Macs then skip that release, and the next newer release updates both.
- A Mac that keeps another earlier release, or none, or whose part serves on the leader's local API or alone, does not follow (yet) and says so once in `~/.darkbloom/cluster-setup/service.log`. While a pair runs on it, a Mac whose partner stops answering during the follow waits at most a minute, then changes nothing and tries again at the pair's next update slot. A Mac whose partner quarantined a release does not install that release either.
- Both Macs need this release or a later one, and the release a Mac rolls back to must have it too: the Mac that rolled back reports the rollback from the restored release. A rollback of this release itself is therefore not followed; rollbacks of later releases are.
- To roll back a pair by hand, stop one Mac's cluster service with `darkbloom cluster stop --service`, run `darkbloom update --rollback` there, and start it again with `darkbloom cluster`; the other Mac follows.

### Two-Mac pairs recover after losing a rank during a stop

- A two-Mac pair no longer stays unable to serve when it loses a rank while
  its slot is stopping. Until the provider restarted, its leader refused every
  later start, and `darkbloom cluster stop` left that Mac's part still
  releasing.
- Fixed a deadlock in the pair's request engine. Stopping the pair slot
  cancelled a request's stream while the engine was telling that request the
  pair had lost a rank. The stream's cancellation waited for the engine, and the
  engine waited for the cancellation to finish, so the slot never stopped.
  Cancellation and stream termination now never wait for the engine.
- The leader also releases a committed start as soon as its session ends,
  instead of after the old slot has fully stopped, so a slow stop can no longer
  make it refuse later starts with "a committed start is already served". The
  release receipt still waits, bounded, for the slot to retire, and a pair still
  never serves two slots at once.

### MiMo-V2.6-Flash and Gemma 4 26B QAT serve public cluster traffic

- Two more models are approved for public traffic on two-Mac clusters, in pipeline and tensor parallel, as GLM-5.3-Flash and Qwen3.8 27B are: MiMo-V2.6-Flash (`mimo-v2.6-flash-mopd`) and Gemma 4 26B QAT (`gemma-4-26b-qat-4bit`). A release's cluster runtime facts carry their pair-serving grants and parity qualifications, so a pair of either model earns through Darkbloom on any Apple silicon pair, and `darkbloom cluster` lists them.
- Their tensor parallel serves once its code is in the build (Gemma 4 and MiMo tensor parallel PRs); until then they pair as a pipeline. MiMo-V2.6-Flash's speculative pipeline, its default split, is declared too.

### A running cluster service answers after the Macs pair again

- When the two Macs pair again while their cluster services run (`darkbloom cluster` or `darkbloom cluster pair`), each service starts its setup and control-lease listeners again with the new pairing within about 5 seconds. They used to keep the earlier pairing's key until the service restarted, so the other Mac's leases and its "Reading both Macs over the cable" step were refused (`refused (handshakeRejected)`). The service log says `this Mac's pairing changed (<cluster label>): answering the paired Mac with the new one`.
- A Mac left with no pairing stops answering over the cable. A pairing store that cannot be read leaves the listeners as they are.
- A Mac that paired again under a new Secure Enclave key of its own drops its earlier control state, as it already did when the other Mac's key changed.
- A cluster service started by an earlier release keeps the earlier behavior until it restarts (log out and back in, or `darkbloom cluster stop --service` and then `darkbloom cluster`).

### Tensor parallel for Gemma 4 and MiMo only on measured speed

- Gemma 4 and MiMo V2.6 Flash pairs choose tensor parallel only once tensor parallel's own speed is measured on both Macs: each Mac's half timed by a tensor-parallel load (Gemma), or requests this Darkbloom build served in tensor parallel. An estimate from the Macs' device index alone does not choose it, because the index overstates what half a model saves on big Macs: on two M5 Ultra it predicts a short Gemma request 6% faster in tensor parallel, where the plans expect decode 6-8% slower.
- When the estimate says tensor parallel would be faster, the pair keeps the pipeline. The plan's "Tensor parallel or pipeline" line says the predicted gain and that it comes from the device index, and the model list says "tensor parallel: not measured yet".
- Normal setups do not load tensor parallel to measure it, so these pairs keep the pipeline for now. MiMo does not yet time its halves at load, so MiMo pairs reach tensor parallel only from requests the same build served in tensor parallel.
- Tensor parallel must also keep every feature of the mode it would replace (see "Tensor parallel only where it keeps every feature").
- Qwen and GLM still choose tensor parallel wherever it fits.

### Fresh MDM removal guidance

- Keep `darkbloom status` and both `darkbloom doctor` authorization summaries from offering MDM removal when the coordinator decision is too old for removal readiness. An unexpired App Attest serving lease stays visible; removal advice asks for fresh readiness and keeps existing profiles installed. The `darkbloom unenroll` checks are unchanged.

### Gemma 4 replies keep characters outside its vocabulary

- A Gemma 4 reply that ended in characters its vocabulary writes as byte tokens, such as many newer emoji, rare CJK and most Hangul syllables, lost all of them: `all zipped up 🗜` came back as `all zipped up `, and a reply made only of such characters came back empty. A long reply could also corrupt such a character when streaming restarted its decode inside its bytes.
- The Swift tokenizer library releases byte tokens only when a later token arrives. The provider's tokenizer bridge now releases a trailing run itself. `/detokenize` keeps it too.
- Token IDs, numeric logprobs, sampling and cache keys do not change, with one exception: a stop string that a trailing run completes now matches when the run completes, one token sooner, so `completion_tokens` can fall by one.
- A streamed reply's `logprobs` gains the entries of those tokens, which it used to drop. A byte token's `logprobs` text and `bytes` are U+FFFD or its ASCII character instead of empty, not the real byte. A reply cut inside a character by `max_tokens` now ends in U+FFFD instead of dropping it.

### Gemma 4 plain decode commits by operation count

- Plain decode steps of Gemma 4, the rows served without its assistant, commit a Metal command buffer every 100 operations instead of many times per step. Outputs are bitwise identical. Prefill and assistant rounds keep MLX's defaults.

### Gemma 4 text keeps its spaces before punctuation

- Gemma 4 replies, reasoning and tool arguments no longer lose the space before `.`, `,`, `?` and `!`, or repeat a quote. `git add .` came back as `git add.`, `bash ./run.sh` as `bash./run.sh`, `x != y` as `x!= y`, and, when streamed, `role = 'start'` as `role = ''start'`.
- Gemma 4's published `tokenizer_config.json` omits `clean_up_tokenization_spaces`, and the Swift tokenizer library reads a missing key as cleanup on, where Python Transformers reads it as off. The provider now resolves a missing key to off in memory for every model. An explicit Boolean is kept.
- Token IDs, sampling, model state and cache keys do not change. Only the text decoded from the same tokens does. Stop strings match the text as spelled: one with a space before punctuation can now match, and one that matched only the cleaned text (`add.` for `add .`) no longer does.

### Faster Gemma 4 pipeline pairs

- Gemma 4 pipeline stages compute a prompt chunk's expert blocks in one shared dispatch per operation instead of one subgraph per prompt token, with the same bytes for every token (unchanged arithmetic receipt). Batch-decode rows share the same dispatch. On one synthetic expert layer this cut a 2,048-token chunk from about 370 ms to about 31 ms; pair throughput is not yet measured.
- A Gemma 4 pipeline pair whose setup prefills serially, coordinator-registered pairs included, now serves four requests at once. Each lane is admitted against live memory on both Macs. A pair planned with the one-chunk lookahead keeps serving one request at a time.
- The planner's hardware prior counts 8 of Gemma 4's 128 experts per token instead of every expert byte.

### Gemma 4 tensor parallel on two-Mac clusters

- Gemma 4 26B (QAT 4-bit and 8-bit) can run tensor parallel on a pair: each Mac holds half of every layer's heads and expert channels, both share every token over the encrypted link, and the pair returns the same tokens a single Mac would on the synthetic checks. Text only.
- The planner chooses tensor parallel for Gemma 4 only where it predicts it faster than the pipeline, from tensor parallel's own speed measured on both Macs (see "Tensor parallel for Gemma 4 and MiMo only on measured speed"). Prompt-heavy requests keep the pipeline. Qwen and GLM still choose tensor parallel wherever it fits.
- In tensor parallel, Gemma 4 returns logprobs (`logprobs` / `top_logprobs`), and each Mac reserves memory for its own half of the model: about 8.0 GB of weights at QAT 4-bit (14.9 GB at 8-bit) plus its own KV, with a conservative 5.5 GiB activation reserve until a pair measures one.
- Gemma 4 tensor parallel keeps prompt prefixes as the pipeline does, in memory and in the encrypted SSD tier: a repeated or shared prompt prefix is restored only when both Macs hold it, with exactly the tokens of a request that prefilled the whole prompt, and it survives a restart of both Macs. Each request reserves room for its own prompt's prefix (about 0.44 GB a Mac for a 32K-token prompt); kept prefixes use free memory only and are dropped first when memory runs short.
- Gemma 4 tensor-parallel pairs serve one request at a time unless `DARKBLOOM_CLUSTER_BATCH_LANES` names more. Speed on a real pair is not measured yet.

### A latent stop race in GLM tensor parallel's one-token decode

- No released pair is affected, and serving is unchanged: every v0.10.6 GLM-5.3-Flash tensor-parallel pair loads the model's NextN (MTP) layer and decodes every request in MTP rounds, which already end both Macs together when a request stops just before the model's end token.
- The one-token decode, which only a build without that layer runs, now does the same: both Macs end at the end token and return the text up to the stop (for example, a stop string that matched just before the answer ended). Before, the stopped Mac built one more step alone and waited in a collective the other Mac, already finished at that token, never joined, so the request would stall and fail on both Macs.

### GPT-OSS plain decode commits by operation count

- Plain decode steps of GPT-OSS commit a Metal command buffer every 100 operations instead of after almost every MoE layer. Outputs are bitwise identical. Prefill keeps MLX's defaults.

### MiMo pipeline decode command buffers and expert routing

- MiMo V2.6 Flash pairs encode decode steps, lane steps and speculative rounds
  in Metal command buffers of up to 100 operations with no input-size bound, as
  GLM and Qwen tensor parallel already do. Prefill keeps the rank's limits.
  Tokens, logits and caches are byte-identical on synthetic stages. The speed
  effect on the registered model has not been measured yet.
- A MiMo request's memory charge now prices every full-attention layer's decode
  score rows at once, which the larger command buffers can keep alive together.
  The LOAD quote is unchanged. Only requests whose prompt frames are shorter
  than a stage's full-attention layers times the decode rows (32 tokens at most)
  are charged slightly more.
- The planner's hardware prior now counts MiMo's routed experts at the 8 of 256
  a token uses: 10.77 GB read per decode step instead of 166.6 GB. The prior
  prices only tensor parallel, so MiMo's pipeline plans are unchanged.

### MiMo image-candidate pairs keep cluster prompt prefixes

- A MiMo V2.6 Flash pair serving the private, local-only image candidate no
  longer fails its requests while the cluster prefix cache is on (the
  default). That candidate is the only MiMo load with contiguous caches. MiMo
  still required the five metadata values that older MLX SDKs wrote for a
  sliding-window cache, while the pinned SDK writes seven (adding the capacity
  origin and a wrapped flag), so requests, text or image, failed at their
  first prompt-prefix capture. Prefixes are now captured and restored. The
  four text serving modes use paged histories with prefix reuse off and were
  not affected.

### MiMo V2.6 Flash tensor parallel on two-Mac clusters

- MiMo V2.6 Flash text can run tensor parallel on a pair: each Mac holds half of every layer's heads and expert channels and half of the output head, both share every token over the encrypted link, and on the synthetic checks the two Macs agree bit for bit with a one-process simulation of both halves. The image candidate stays a pipeline.
- Each Mac's half of a layer's attention output and feed-forward is kept at full 32-bit precision until both halves are added, then rounded once, so a pair never rounds more than one Mac does. On the synthetic checks, the two halves of an expert's output add up bit for bit to the full output that one Mac rounds once.
- The planner chooses tensor parallel for MiMo only where it predicts it faster than the pipeline with speculative decoding, which MiMo's qualification records credit 1.37x, from tensor parallel's own speed measured on both Macs (see "Tensor parallel for Gemma 4 and MiMo only on measured speed"). Two 128 GB Macs, which cannot hold MiMo alone, can serve it this way. Qwen and GLM still choose tensor parallel wherever it fits.
- In tensor parallel, MiMo returns logprobs (`logprobs` / `top_logprobs`), serves one request at a time with speculative decoding (see "MiMo V2.6 Flash tensor parallel with speculative decoding"), and each Mac reserves memory for its own half: 84.0 GB of weights plus its own KV, work and buffers, with a conservative 5.5 GiB activation reserve until a pair measures one (about 100 GiB per Mac at the longest request, the draft heads included).
- No MiMo tensor-parallel qualification record exists yet, and speed on a real pair is not measured.

### MiMo V2.6 Flash tensor parallel with speculative decoding

- A MiMo V2.6 Flash tensor-parallel pair decodes with MiMo's own trained draft heads: each round checks up to two drafted tokens in one pass through the pair, so every token a round keeps shares that pass's link and weight costs.
- It is on by default: the installed provider starts both Macs' tensor-parallel workers with two drafts a round.
- Output is identical to tensor parallel without drafting, token for token and bit for bit on the synthetic checks: greedy (with or without logprobs) and sampled. Each Mac's halves stay at full 32-bit precision inside a round too, exactly as in a one-token step. Every kind of stop works inside a round. Requests with penalties or a logit bias, and sampled requests that ask for logprobs, decode one token at a time, as in the speculative pipeline.
- Each Mac holds the draft heads whole (about 2 GB more) and reserves their per-request state, and the plan counts both before it chooses tensor parallel. Two 128 GB Macs still fit, at about 100 GiB a Mac.
- Because MiMo's tensor parallel now keeps the speculative pipeline's rounds, feature parity no longer holds it back where that pipeline is the mode it would replace; its measured speed decides, and the plan credits the rounds no speed-up until they are measured. Where the plain pipeline is the mode it would replace, that pipeline's batch lanes still keep it.
- Not yet measured on a real pair: the speed-up, the heads' acceptance rate and qualification records.

### The Models page shows what the network registered

- Each model on the Models page now says whether this Mac's live registration carries it: "Registered with the network" (the network sends it requests), "Registered for Autopilot" (Autopilot can load it), or, for a selected or pool model, a warning "Not registered with the network yet". Before, the page showed only what was selected, downloaded or loaded, so a selected model the network did not know looked like it was serving.
- The provider writes the registered set to its state file (`registered_models`).
- A Mac with Autopilot that is busy at every check, or always under a lease, now reports a newly verified build after at most 10 minutes. The re-registration closes admission, lets accepted requests finish, then reconnects. Before, such a Mac could wait without end, and Autopilot could not use the build.

### Pipeline decode command buffers for the remaining cluster models

- Cluster pairs of the Qwen and Bonsai rows, Nemotron 3.5 Lightning, Gemma 4,
  GPT-OSS 20B and GLM-5.3-Flash encode decode steps (pipeline and phase split),
  lane steps and speculative rounds in Metal command buffers of up to 100
  operations with no input-size bound, as GLM and Qwen tensor parallel already
  do. Prefill keeps the rank's limits. Tokens, logits and caches are
  byte-identical on synthetic stages. The speed effect on registered models has
  not been measured yet, and each family keeps the change only if a pair A/B
  shows a gain.
- A request's memory charge on those pairs, other than GLM's, now prices every
  attending layer's decode rows at once, which the larger command buffers can
  keep alive together. The LOAD quotes are unchanged. Only requests whose prompt
  frames are shorter than their decode rows (at most 80) are charged more, and
  only on a rank that decodes.

### The enabled-model filter wins over coordinator model changes

- A model you deselect with `darkbloom switch` or delete with `darkbloom models remove` no longer comes back on its own. Before, when the coordinator moved a public model to a newer build, every Mac serving that model downloaded the newer build, served it in place of the build its operator chose and loaded it, even when `enabled_models` left it out. For example, with `gemma-4-26b` selected and `gemma-4-26b-qat-4bit` deselected, `gemma-4-26b-qat-4bit` returned within minutes and `darkbloom status` showed `Serving outside the enabled model filter: gemma-4-26b-qat-4bit`.
- With `enabled_models` set, the provider now refuses a coordinator `load_model` or `prefetch_model` for a model outside it (`model_not_selected`), and keeps serving the build you selected when its public model moves to a build you did not list. The log then says `desired_models: <model> → <build> is outside the enabled model filter; not converging`.
- **Your provider no longer moves to a new build of a model by itself.** To take one, run `darkbloom switch` and pick the model's public name; the picker shows its newest build under that name. Until you do, the newer build gets that model's requests first.
- `darkbloom switch` applies its selection as the filter at once, without a restart.
- Nothing changes with an empty `enabled_models` (serve every downloaded model), or for Autopilot's consented downloads and placements.

### Child process exit waits

- Report a finished child process without the former polling and run-loop delay. Bounded children (the paged-kernel preflight, update staging, runtime smoke and signature checks, `darkbloom doctor` and `verify` probes) are reported up to about 120 ms sooner each, and waiting for `launchctl`, `codesign`, `profiles`, `open` and `log` no longer runs the calling thread's run loop. Timeouts and the SIGTERM-then-SIGKILL escalation are unchanged.

### Provider status App Attest lease

- Keep `darkbloom status` and `darkbloom doctor` reporting App Attest authorization until the coordinator lease expires. They required a renewal within the last 10 seconds, so one delayed renewal showed `Trust: self_signed / online` although serving continued. `darkbloom unenroll` still requires a renewal within 10 seconds before offering MDM removal.

### Roll a Mac back to its previous release

- `darkbloom update --rollback` restores the release a Mac ran before its last update. When the updater installs a release, it keeps the signed release it replaces; the rollback puts that release back, also after the new one has served for 10 minutes and was promoted.
- It shows the installed and restored versions and asks `Roll back to vX? [y/N]` before changing anything (`--yes` skips the question). The running provider finishes its accepted requests (`--timeout`, `--force` as for `darkbloom update`), the kept release replaces the installed one in the watchdog's journaled swap under the update lease, and the provider restarts on it. It contacts no coordinator.
- The rolled-back release is quarantined on that Mac: the provider's 30-minute update check, the startup check and the watchdog do not reinstall it, and the next newer release installs normally, so automatic updates can stay on. `darkbloom update --override-quarantine` installs it again on request.
- It refuses and changes nothing on a Mac that serves in a `darkbloom cluster` pair, while a provider runs in the foreground (`darkbloom start --foreground`), while another update or recovery runs, when no earlier release is kept or the kept one is already installed, when the installed bundle is not the release the updater recorded, and when the kept release fails its hash or signature check.
- Only one earlier release is kept. A Mac rolls back to the release it ran before its last update, not further.

### Qwen tensor-parallel decode control in the selection sum

- A Qwen tensor-parallel pair's plain decode step now carries the next step's
  plan and report in its own sealed selection sum, so the step pays one sealed
  sum and one host read fewer than before. Tokens, logits and native state are
  unchanged; assisted (MTP) rows, prompt steps and idle steps keep their own
  exchange.
- Owner answers, cancellations and joins now apply one step later while plain
  rows decode. A row decodes its next token once the owner answered the token
  before it, so an answer that arrives while a step computes no longer leaves
  the row idle for a step. Rank 0 still publishes a token only after the
  owner's answer to the one before it. A token selected before a stop answer is
  never published, so streamed text, usage and logprobs are unchanged.
- A clean stop the owner asks for (a stop string, for example) can cost one
  more forward, which is discarded. On a one-lane pair every such stop after a
  request's first token does (assisted rows excepted), and that request's
  finish arrives one decode step later than before.
- Both ranks of a pair must run this build: the load agreement binds the new
  control wire (`qwen-tp-independent-history-batch-v2-folded-control`).
- `darkbloom-cluster-tp-check qwen-decode` times the batch driver's decode on
  two ranks over the loopback ring, with the control exchanged or folded, and
  checks that both retire the same tokens.

### Qwen tensor-parallel decode routes, row exactness and finiteness check

- A Qwen3.8-27B tensor-parallel row now decodes the same bytes alone as beside
  other rows and in verify windows on the registered weights. A one-row decode
  step's fused SwiGLU computed its sigmoid with Metal's fast `exp`, while
  cohort and window steps use MLX's precise `exp`. The two round a gate of
  exactly bf16 -6.84375 differently, which could change later tokens. Dense
  Qwen tensor-parallel output changes only where a one-row decode step meets
  that gate value, and there it now equals the cohort path. Regenerate
  tensor-parallel serving references recorded with earlier builds once.
  Single-Mac output is unchanged.
- A non-finite logit on either rank of a Qwen tensor-parallel pair now fails
  both ranks in the same selection step, before any token is published;
  previously the other rank waited in the selection collective. The check moved
  into the selection's sealed sum, so a decode step no longer pays a separate
  finiteness read. Selected tokens are unchanged.
- Each rank logs its decode routes once per load, when it first serves
  (`darkbloom-qwen-tp-decode-census-v1`): which projections take the
  batch-invariant kernel and at which layout per row count, the attention and
  residual-norm routes, and the arithmetic switches in force.
- `darkbloom-cluster-tp-check qwen-rows` checks, on one Mac over the loopback
  ring, that a Qwen3.8-27B row decodes the same bytes alone, beside other rows
  and in verify windows at the registered per-rank widths, with random weights
  that follow the registered artifact's value statistics or with the registered
  checkpoint itself; `qwen-rows layers` names the first layer that differs.

### Qwen tensor-parallel pairs serve up to 8 requests at once, sized to memory

- `darkbloom cluster` now sets how many requests a Qwen tensor-parallel pair
  serves at once: 8, 6, 4 or 2, the most that both Macs' memory holds now with
  the full load reservation for that many. The pair serves them from its first
  load. Before, it served one at a time: a local pair widened only after a
  burst, through a reload the burst waited for, and a pair serving Darkbloom
  traffic never widened.
- On two idle Macs, Qwen3.8-27B serves 8 at once from 64 GB a Mac without the
  speculative assistant (4 at 48 GB, 2 at 32 or 36 GB), and 8 from 96 GB a Mac
  with it (local clusters only); smaller Macs serve fewer. Two M5 Ultras serve 8 either
  way. When not even 2 fit, the pair serves one request at a time, as before.
- Memory safety is unchanged: both Macs reserve that many requests' full memory
  when the model loads and admit each request alone. A local pair set up
  narrower still widens when requests queue; a pair set up for 8 is never
  reloaded for it.
- Existing setups keep serving one request at a time until they are planned
  again, as after an update. A pair serving Darkbloom traffic keeps its width
  beside its approval; no approval, registration or committed-start digest
  changes.

### Qwen tensor-parallel prompt wavefront

- A Qwen tensor-parallel pair now prefills a text prompt faster, in steps of up
  to eight consecutive 512-token frames built as one graph, layer by layer:
  while one frame's sealed sum crosses the link, the next frame computes. Every frame
  keeps its own shapes and kernels, so logits, KV, recurrent state, prefix
  captures and tokens are unchanged. Steps run two frames while another lane
  decodes and end at the prompt-cache capture point. Media prompts, assisted
  (MTP) prompts, packed KV and routed-expert models keep one frame a step.
- The merged step's frames in flight are charged in LOAD, the placement quote
  and each request's charge: a Qwen3.8-27B tensor-parallel rank needs about
  367 MB more at any width.
- `darkbloom-cluster-tp-check qwen-prefill --wavefronts 1,8` and
  `darkbloom-cluster-tp-check qwen-wavefront` measure the merged steps on one
  rank and on two ranks over the loopback ring.
  `DARKBLOOM_QWEN_TP_PROMPT_WAVEFRONT=0` restores one frame a step for
  diagnosis; both ranks must agree.

### Qwen3.8 27B tensor parallel reuses whole prompt prefixes

- A Qwen tensor-parallel pair now reuses a repeated prompt's prefix to its last whole 512-token chunk instead of at most 4,096 tokens, including prompts longer than 32,768 tokens: a repeated 33K-token prompt restores 32,768 tokens on both Macs, as one Mac does. It also keeps the boundaries the next turn of a conversation and prompts that share a long system prompt need, so in each of these cases it reuses at least what one Mac reuses, to the nearest 512 tokens.
- A prefix restored from memory returns exactly the tokens of a request that prefilled the whole prompt (checked bit for bit on synthetic pairs at 8K, 16K and 32K boundaries); one restored from the SSD tier's default `balanced` records is close but not identical, as before. Both Macs must hold a boundary; otherwise both start from zero.
- Each request reserves room for its own prompt's prefix (about 1.8 GB a Mac for a 32K-token prompt on the 27B), and a pair loads with one such prefix per lane: about 1.1 GB a Mac more than before at one lane. Every pair size that ran the 27B in tensor parallel still does. Kept prefixes use free memory only (half of what is left after loading) and are dropped first when memory runs short. Prefixes kept on SSD by an earlier build are not reused.
- Requests served by the assistant (MTP) lanes still reuse at most 4,096 prompt tokens, less than one Mac reuses for a long prompt; deepening them is a separate change. Speed on a real pair is not measured yet.

### Stop sequences no longer match Gemma 4 or `<think>` reasoning

- A client `stop` sequence on Gemma 4 models such as `gemma-4-26b-qat-4bit`,
  and on models that reason in `<think>` blocks (Qwen 3.5, 3.6 and 3.8,
  among others), now matches only the text returned as `content`. With
  reasoning on, it used to match the reasoning too, so a sequence that
  appeared while the model reasoned (for example `"."` or `"\n\n"`) ended the
  request before any answer: `finish_reason` `stop`, reasoning only, empty
  content.
- With tools declared, tool-call frames are not cut either, except a frame
  whose arguments quote its own closing tag, or a bare `<function=…>` frame
  written without its wrapper. When a request has no tool handler (no declared
  tools, or a media request on a family without native media tools), a literal
  tool tag in an answer is text the client receives, and stops still apply to it.
  Whitespace before the answer's first character (the blank line after
  `</think>`) cannot complete a stop sequence on its own.
- A stop sequence that names a marker no longer fires on it: `</think>`, or
  `<tool_call>` with tools declared.

### Sandbox setup shows the add-on's own sizing plan

- `darkbloom sandbox setup` now asks the Darkbloom Sandbox installer for the add-on's own plan before it asks you to confirm. After its own chip, macOS, session, network, power and sleep checks, setup runs the downloaded installer with `--plan` (add-on 1.1.1 and later). The installer verifies the release and sizes this Mac without installing anything. Setup then prints the plan's cores, memory and disk lines and how many Linux and macOS jobs this Mac can run at a time. Example: `Disk: 157 GiB free; 100 GiB stays free for you; Linux images 4 GiB + 30 GiB per Linux job; macOS images 46 GiB + 40 GiB per macOS job`.
- Disk follows the add-on's rules. A tenth of the disk (50 to 100 GiB) stays free. The first job of a platform also needs that platform's VM images (Linux 4 GiB, macOS 46 GiB, nothing once installed). Each Linux job takes 30 GiB and each macOS job 40 GiB.
- When no job fits, setup prints the plan's message and how much disk to free for one Linux job and for one macOS job. It then stops without installing.
- The installer is now downloaded before the question, so the plan is shown before you confirm. Nothing is installed before you answer `y`.
- With an older installer that cannot report a plan, setup prints `[INFO] Sizing` and estimates with the same rules.
- Setup's output is line-buffered: run over ssh or into a pipe, it shows the approval link as soon as the installer has it, not once setup ends.
- With add-on 1.1.2 and later, a Mac waiting for approval keeps waiting in the background, also across restarts, and enrolls by itself, and setup now says so. On the waitlist it says you can close the window, and after Ctrl-C it says that the Mac keeps waiting; both point at `darkbloom sandbox status`. With an earlier add-on, setup words both as before.

### Sandbox setup offers the add-on's new plan on a Mac that is set up

- Running `darkbloom sandbox setup` on a Mac that is set up now asks the Darkbloom Sandbox installer for the add-on's plan again (`--plan`, which changes nothing). When the plan's Linux and macOS job counts differ from the installed ones, setup shows the plan's CPU, memory and disk lines and asks, for example `This Mac now fits 1 Linux + 1 macOS (installed: 3 Linux + 0 macOS). If a job is running, the installer refuses and changes nothing. Apply? [Y/n]`. Yes reinstalls with the plan's counts; no prints the `--linux-slots`/`--macos-slots` command that applies it later. When the counts match, the output is exactly as before.
- With `--yes` or without a terminal, setup applies the plan only when it adds jobs and removes none; otherwise it prints `Not applied` and the command, and exits 0.
- While jobs run, setup skips the check and says to run it again once they finish. When the installer refuses because a job is running (exit 4), setup now says that a job is running, to run setup again when it finishes, and that it never passes the installer's `--force`, which would stop running jobs, which aren't paid.
- Explicit `--linux-slots`/`--macos-slots`, an installer without `--plan` and a failed download behave as before. A platform missing from the add-on's `status --json` counts as 0 slots.
- When the add-on's plan gives macOS no job for want of free disk space, setup adds one line: ``Free space here is what `df -h ~` shows as Avail; Finder also counts purgeable space, which macOS frees only when it needs to (restarting, or removing Time Machine local snapshots: `tmutil listlocalsnapshots /`, frees it now). A macOS job needs about N GB more.`` N counts the disk the plan's Linux jobs take, so a Mac planned for 3 Linux jobs and no macOS job gets a real number.

## v0.10.6

Published 2026-10-31 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.10.6)).

### Upgrade and rollout notes

- This is the first production release with two-Mac clusters (#1628 with #1407, #1426 and #1577, and the cluster PRs merged after it): run `darkbloom cluster` on each of two Apple silicon Macs joined by one Thunderbolt 5 cable, pick a model, and the pair serves it together. Both Macs need macOS 26.2 or later, RDMA over Thunderbolt turned on by an administrator (System Settings on macOS 27, `rdma_ctl enable` in Recovery on macOS 26) and the same Darkbloom release. The planner chooses tensor parallel or a pipeline; GLM-5.3-Flash and Qwen3.8-27B can serve in tensor parallel, with images and video. `darkbloom cluster local` serves a pair without any coordinator. A Mac that never runs `darkbloom cluster` keeps serving alone.
- Releases carry their cluster runtime facts (#1692): every release lane computes them from the final signed app and shows them in its job summary, and the registration carries them as `cluster_runtime` only while that environment's repository variable is `true`. A coordinator with darkbloom-platform#643 and `EIGENINFERENCE_CLUSTER_PAIR_APPROVALS_FROM_RELEASES=true` derives from them the build's cluster approvals, their pair-serving grants and the public qualifications of GLM-5.3-Flash and Qwen3.8-27B in pipeline and tensor parallel (the owner's decisions of 2026-10-31); every other model's clusters serve their owner only. A pair without a cluster approval serves only on its leading Mac's local API, with the `darkbloom start --local` key.
- A production registration carries the block only once `PROD_CLUSTER_RUNTIME_ENABLED=true`, which is set only after the following, and before the tag, because a release registered without the block can never gain one. A coordinator without #643 refuses a registration that carries the block, and the release then fails after signing.
  - The production coordinator runs #643, with migration 58 applied and three cluster settings: `EIGENINFERENCE_CLUSTER_PAIR_APPROVALS_FROM_RELEASES=true`, `EIGENINFERENCE_CLUSTER_PUBLIC_ROUTING=true` and `EIGENINFERENCE_CLUSTER_PAIR_TRUSTED_TLS_PROXIES=127.0.0.1,::1` (without it no member connection attaches to pair control behind production's TLS-terminating proxy). Approvals derived from releases are its only approval source: `EIGENINFERENCE_CLUSTER_PAIRS`, the operator's approval table, stays unset. App Attest serving is on for every account (`EIGENINFERENCE_APP_ATTEST_SERVING=true`, `EIGENINFERENCE_APP_ATTEST_ENVIRONMENT=production`, `EIGENINFERENCE_APP_ATTEST_ROLLOUT_PERCENT=100`), because a member on macOS 27 without MDM pairs only through App Attest.
- This release was not proven on DevNet first: its derived approvals and a pair session under one are first checked in production. The entry "A Mac pair registers with the coordinator as a cluster member by itself (DevNet)" below predates this: with the coordinator above, production has pair control and serves the approvals derived from this release.
- Single-Mac serving needs no coordinator change and no provider-version floor, but three answers to coordinator requests change, all with codes the coordinator already knows. A content part of an unknown type is refused with 400 instead of being answered from the remaining text. Media the model's processor refuses answers 400 `invalid_media` instead of the retryable 503. A `response_format` answer cut off by `max_tokens` is a client error (`client_error`) instead of the retryable `tool_noncompliance`, so the coordinator no longer retries it on another provider. After the tag the platform snapshots its provider contracts from the tagged commit and sets `LatestProviderVersion` to `0.10.6`; of the 34 snapshotted inputs only `ProviderCore.swift` changes since v0.10.5.
- The local API of one Mac (`darkbloom start --local`) changes too. A request that fails to decode is normalized as on the coordinator path (a scalar `stop`, the `developer` role, messages without content, hosted tools) and decoded again before it is refused. It returns `logprobs` where the model captures them and reports `usage.completion_tokens_details.reasoning_tokens`, and it answers a `response_format` request cut off by `max_tokens` with 422 and a message that says so, instead of "Internal inference failure.". Two operator changes have no entry of their own: `provider.toml` is written owner-only (a group- or world-readable file is tightened at its next save), and the 0.10.6 updater (`darkbloom update` and the automatic update) extracts the next release under `umask 022`, as the installer has since v0.10.0.
- Recent cluster fixes: a registered pair's cluster service is no longer restarted many times a day by its own part's heartbeats (#1690); pair members register GLM-5.3-Flash and Qwen3.8-27B under their pair-serving grant instead of ending a second after they start (#1686); a single Qwen3.8-27B request in tensor parallel decodes about 6% faster on two M5 Ultra with an M5 Ultra verify-window layout (#1680). On every Mac, `darkbloom models download` and the `darkbloom start` picker show one progress line (#1683); without a terminal they print a plain line at most every 30 seconds, and `darkbloom models download` ends with `Cached at <path>` instead of `Done. Cached at <path>`.
- MLX pins: `libs/mlx` and the nested `mlx` (`72dffa2d`) and `libs/mlx-swift` (`c633d221`) are unchanged from v0.10.5. `libs/mlx-swift-lm` moves from `2beb401f` to `7933a0fa`, its fork's `main` (#1680, #1684): SDK #373 adds an M5 Ultra layout table to `AffineQuantizedVectors`, which only the cluster's Qwen tensor-parallel exact projections use, and a layout never changes a result. The MLX core is unchanged, so the tag build's `metallib_hash` should equal v0.10.5's `98bab9d7…614be`, which the dev-branch build of this preparation's base (`a0413a8a`) also registered on DevNet. Complete SSD checkpoints stay per build, because their namespace binds the binary hash: 0.10.6 does not restore those 0.10.5 wrote. Cluster entries below that describe MLX or SDK work (steel tiles, `MLX_QMV_BATCH_INVARIANT`, fast-fence ordering, GPU streams that no longer spin on each other's fences, the GLM-5.3-Flash SDK speedups) describe code that v0.10.5's pins already contain.
- The 107 entries below are the pending fragments rendered verbatim, in filename order. Most were written on the cluster branch, and some record steps that newer entries supersede, wherever those sit in the list: "Fixed" predates GLM-5.3-Flash tensor parallel; widened Qwen tensor-parallel owners keep fast fences, not the event path; the pair's SSD prefix records are `balanced` by default, not exact; and Qwen3.8 27B tensor-parallel text speculation ships (automatic setup drafts three tokens a round). Four single-Mac statements repeat changes that v0.10.0 published: `previous_response_id` on one Mac, "Preserve truncated reasoning in collected responses", the local API's reasoning by model type (two bullets of the `darkbloom cluster local` entry) and the start-time weight hash without the file cache (in the MiMo entry). #1666 (approval check follow-ups) and #1674 (CI shards) have no entry.

### One progress line for model downloads

- `darkbloom models download` and the `darkbloom start` picker show one line for the whole model, redrawn in place at most four times a second: a bar, the percent, the bytes, the rate and the time left, leaving out what does not fit the window's width. They no longer print a line for every file or a block of per-file bars.
- The line keeps its shape while the window keeps its width: each figure has a fixed column, sized for its widest form, so the bar and the figures do not move as the numbers change. The rate and the time left appear after 2 seconds, and a time left over 24 hours is not shown.
- The line reads "Verifying" while the files are checked, then ends with one line: `✓ Downloaded <name> (16.3 GB in 2m 10s)`, `✓ <name> is already downloaded (16.3 GB)`, where the download stopped, or `Verification of <id> failed: <reason>`. The picker no longer adds its own "Downloaded" line, and `darkbloom models download` ends with `Cached at <path>` instead of `Done. Cached at <path>`.
- Without a terminal (a pipe, a log, the desktop app) the download prints plain lines with no carriage returns: the first at once, then at most one per 30 s and 10 points, one at 100%, and the same last lines. The desktop app reads its download progress from them.
- `darkbloom cluster` shows a model download or a copy over the cable on its live line instead of adding a line every second. A plain transcript keeps the first report, about one per 30 s and 10 points, and the lines for the record.
- Sizes in the line are decimal, as the catalog gives them.

### Identical Macs split a model evenly

- When cuts predict the same request time (identical Macs, or equal measured speeds), the placement planner now chooses the one that uses each Mac's hardware capacity most evenly, instead of the earliest cut the second Mac's free memory held at that moment. Two M5 Ultra 256 GB had planned GLM-5.3-Flash 11/34 and then 5/40 of its 45 layers; they now plan it 22/23 whichever Mac leads. A faster split is never traded for balance, and the "Quit apps first" refusal is unchanged. This applies to every model the cluster plans.

### Bonsai FP32 residual stream and the cluster memory gate under pressure

- Bonsai (Prism) packs keep their FP32 residual stream on the fused Qwen 3.5 decode, verify and stage paths. The fused residual step rounded each FP32 branch to the stream's FP16 embedding dtype, so the stream stayed FP16 and a Bonsai producer stage's residual left its FP32 contract; such a stream now takes the unfused sum, as the unfused forward computes it. Qwen 27B and the other uniform-dtype rows are unchanged.
- The cluster load gate's room-making pass runs only at normal memory pressure. Above it the gate withdraws all file cache on purpose, and a refusal now stands on the gate's own sample instead of a fresh one taken after the pass.

### Two-Mac cluster capability honesty

- A cluster member registers image and video input only when its pair's placed mode serves media (GLM-5.3-Flash and Qwen3.8 27B in tensor parallel), so the coordinator no longer routes media to a pipeline pair that answers text only; a pair registered for media serves only while both Macs report the media contract.
- `darkbloom cluster status` and the pair's `/metrics` report MTP on for GLM-5.3-Flash in tensor parallel, which always decodes with its NextN head (depth 2); they said "MTP off".
- A content part of an unknown type (`input_file`, `input_video`, `refusal`, ...) is refused with HTTP 400 naming the type on the local API of one Mac and of a pair, and with the closed invalid-request error on coordinator requests, instead of being answered from the remaining text.
- With images or video, a GLM-5.3-Flash pair answers the output controls as one Mac does: it withholds hidden reasoning (`reasoning.exclude`, `include_reasoning: false`, `thinking.display: "omitted"`) and refuses a `response_format` JSON answer or a required or named tool call with 400 before any media decode.
- A `response_format` answer the service validates that was cut off by `max_tokens` (a reasoning model can think through the whole budget) now returns 422 saying so, instead of "Internal inference failure." GLM-5.3-Flash, which validates its withheld JSON itself, keeps its typed 422.

### Cluster models pin the manifest a Mac downloads

- The cluster worker now pins the model CDN's `manifest.json` bytes for every registered model. GLM-5.3-Flash pinned bytes that no Mac could fetch, so a downloaded GLM was never described and the cluster refused it. Qwen3.5 35B A3B, Qwen3.6 35B A3B, Nemotron 3.5 Lightning, GPT-OSS 20B, MiMo V2.6 Flash and the three Gemma 4 26B entries pinned the production coordinator's re-encoding, whose `created_at` is different on each environment, so DevNet could not use them. The files and aggregate digests are unchanged; only the pinned serialization of each manifest is different.
- A cluster folder with the earlier bytes is repaired when setup next lists the models, with no hand step. This includes a folder copied over the cable from the other Mac, which has no download receipt on this Mac. The cluster store fetches the published manifest (the CDN first, then the coordinator) and writes it in place only when it names the same model, version, aggregate and files and this Mac's worker takes it. Weight files are not written. When nothing answers, the folder stays as it is and the repair is tried again a minute later. When the published manifest names other files, the folder stays as it is and the worker refuses it as before.

### Derived cluster control leader, failover, `darkbloom cluster` on every member

- If one Mac goes away the cluster keeps itself running and re-forms by itself when it is back; `darkbloom cluster` works on either Mac.
- The cluster's control leader is derived, not the Mac where onboarding started: once a plan is adopted its rank 0 leads (requests enter there and registration v3 treats the plan's first member as the head); otherwise the member present that holds the model alone, then the most memory, the most GPU cores and the lowest member identity (from its Secure Enclave key pin). Leadership is a claim with a term, persisted in each Mac's setup record so a restart re-forms the same way; claims are totally ordered (term, then identity), travel only over the pairing-keyed link control channel, and a member refuses a superseded claim so a stale leader steps down. A leader acts on the cluster only after every plan member confirmed its claim.
- The leader renews a control lease with each member at the rank lease's cadence (5 s / 30 s) on a listener and edge epoch of its own. When the leader's lease expires the survivor takes over at the next term; a leader left alone serves the model on that Mac alone when the planner said it holds it alone (the ordinary single-Mac local server under the Mac's own identity: "degraded: serving on this Mac alone"), and otherwise says it cannot serve and runs nothing. When the missing Mac answers again the pair re-forms by itself and control returns to rank 0.
- `darkbloom cluster` works on any member: status, test request, model change, stop and start, and a verify-teardown summary of every Mac are forwarded to the control leader and its answer is shown. A model change while serving drains both Macs' parts before the setup changes.
- Failover serves alone only on a verdict for the plan saved now: the planner's alone verdicts are recorded with the plan's SHA-256, travel with the lease under it and are dropped for any other plan, and a refused (stale) lease never rewrites them; a member that has a new setup but not yet its verdicts says it cannot serve rather than load a model the planner never checked for it. A Mac re-paired with another Mac starts a new leadership history at term 0 instead of carrying the old pair's claim (which named the gone Mac and not the new one).
- Serving alone waits for the absence grace (10 minutes of peer or link absence, for every model and Mac): control still fails over at lease expiry (30 s), but until the grace ends the leader keeps its part ready for the missing Mac, its status says how long until it serves alone, and a Mac back before the grace re-forms the pair with nobody serving alone. A developer (debug) build may shorten the grace with `DARKBLOOM_DEBUG_CLUSTER_SOLO_GRACE_SECONDS`.
- A Mac restarted with a saved leader claim acts as the leader (model change, setup write, start, stop; forwarded or typed) only once the other Mac confirmed the claim, or once the confirmation window passed with no member reachable; a superseded claim steps down first and the command goes to the current leader.
- The control lease runs on the continuous clock, which keeps counting while a Mac sleeps: a woken leader no longer counts a Mac that left during the sleep as present, and a woken member gives its leader one lease time awake before it takes over.
- The solo readiness check names this Mac's own solo server (its process, checked by start time, holds the listening socket) instead of trusting any server on the port; another program on the port is reported as such.
- `darkbloom cluster verify-teardown` counts only this cluster's processes: its workers carry this Mac's member identity, its owners run this install's executable or own one of its workers. Other cluster homes' processes (another identity or install, a check's fake workers) are listed apart and do not fail the check.
- A rank 0 told to stop while it is still starting exits promptly: the signal handler is installed first (a stop is latched, never lost), the wait for the follower ends within 0.2 s of the stop, and the cluster service repeats SIGTERM every 5 s while it waits (never SIGKILL).

### A Mac pair registers with the coordinator as a cluster member by itself (DevNet)

- After the Test stage passes, `darkbloom cluster` reads the cluster approvals the coordinator serves (`GET /v1/cluster/approvals`, from the operator approval file) and takes the entry whose model, prefill schedule and eight digests match this pair's installed app and model. Each Mac checks it against its own files before it saves it, and both Macs save it, or neither does. Both Macs then run as coordinator-paired members, owner-only, and the status says "Registered with the coordinator as a cluster member" with the approval and its end.
- The leader asks again at each start of its cluster service, after each Darkbloom update and every minute while the pair is registered, and takes a later matching entry when the saved one ends within a day. An approval that ended is removed before a part starts, and the pair serves on the leader's local API again.
- When the coordinator gives no answer for 10 minutes (the absence grace), the pair serves on the leader's local API, and it is registered again when the coordinator answers with a matching entry.
- A coordinator without pair control (production, staging) or without a matching entry changes nothing: the saved setups stay byte for byte as they were. `darkbloom cluster local` never asks the coordinator. A pair approval saved by hand with `darkbloom cluster configure` is never removed.

### Cluster: degraded mode only where single-Mac Darkbloom serves the model

- When the other Mac goes away, a Mac serves the model alone only if single-Mac Darkbloom would serve that model on it (the same runtime requirements `darkbloom start --local` applies, such as an Apple M5 chip for Qwen3.8 27B) and the planner said it fits in that Mac's memory. Otherwise its status says it cannot serve the model alone and waits for the other Mac; the cluster re-forms by itself when it is back. A single-Mac server that still ends right after starting three times in a row is not started again until the cluster re-forms.
- The deployment line ("Serving … across both Macs: pipeline, M5 Ultra 40 layers / M3 Ultra 8 layers") is the same on whichever Mac leads, also when the model's first part runs on the other Mac. Models are listed by their catalog names.
- A stopped cluster's `darkbloom cluster` offers `v` (check that both Macs released their memory) on the leading Mac too, not only on a member.

### Cluster setup finds models a dev install downloaded

- `darkbloom-dev cluster` (and a staging install's) lists and uses the models that install downloaded. The cluster's model lookup read only production's `refs/main`, while a dev or staging install records its downloads under its own ref (`refs/darkbloom-dev`), so on a Mac with only a dev install the leader's download step failed with "downloaded, but the product's model store does not list it". It now reads the install's own ref, then production's, as single-Mac model discovery does.

### GLM pair: a joining prompt no longer stalls decoding lanes

- While other lanes decode on a GLM-5.3-Flash tensor-parallel pair, a joining lane's prefill runs in layer slices of about 500 ms, one slice a step, with every decoding lane's step after it, so decoding streams wait about 0.6 s instead of a whole 8K chunk (about 2.3 s). The lane with the shortest remaining prompt prefills first, and a prompt that fits one slice runs between another prompt's slices. Tokens are the same as a request served alone.

### GLM pair: logprobs on lanes, reasoning exclusion and MTP metrics

- A GLM-5.3-Flash tensor-parallel pair serves `logprobs` / `top_logprobs` on batch lanes (it refused them with 503 when lanes were on), clamps `top_logprobs` to 20 as single-Mac does, accepts `reasoning: {"exclude": true}` (it answered 400), and reports MTP rounds, proposals and acceptances, its KV ledger, waiting requests and prefix-cache status on `/metrics`.

### GLM tensor-parallel setup reads metadata once, beside the link

- A GLM-5.3-Flash tensor-parallel rank parses its model metadata once (the prepared loader's inventory) and does that work on its own thread while the link comes up, instead of serially before it; tensor-name matching runs on bytes. Setup before the load intent drops from about 5.7 s to about 3 s a rank, and `open` to about 0. Loaded weights are byte-identical and every file is still hashed.

### GLM images and video on a tensor-parallel pair

- A GLM-5.3-Flash pair serving in tensor parallel accepts image and video input as the single-Mac product does: the leader runs the product's media decode, processor and prompt expansion, rank 0 reproduces the same patches (checked by digest) off its executor and runs the vision tower when the request opens, and both ranks prefill the same spliced embeddings. Batch lanes carry media requests too, with the same arithmetic as a request served alone. Media requests decode with MTP rounds like text (the NextN history is primed with the media features) and without prefix reuse. Rank 0 now loads the vision tower (1.13 GB) with the tensor-parallel shard.

### GLM tensor-parallel prefill: 8K micro-batches on long prompts

- Long prompts on a GLM-5.3-Flash tensor-parallel pair prefill in 32K-token graphs with 8,192-row micro-batches where every micro-batch's cross-Mac sums stay hidden behind the rest of the graph; shorter prompts keep their current plan. Prompt prefixes are still kept every 4,096 tokens, and DSA top-k selection keeps each row's original candidates, so outputs are bit-identical. A 31.5K-token prompt prefills about 4 % faster on two M5 Ultra.

### GLM tensor-parallel prefill: faster bit-identical kernels

- GLM-5.3-Flash prompts prefill a little faster on a tensor-parallel pair: each hyper-connection site (89 per forward on both Macs) computes the expanded residual streams inside the products that read them, about 9 % faster per site, roughly 5 ms per 4,096 prompt tokens. Outputs are bit-identical.

### GLM-5.3-Flash tensor-parallel prefix SSD tier

- A GLM-5.3-Flash pair serving in tensor parallel keeps its prompt prefixes in the encrypted SSD tier as well as in memory, so a repeated long prompt starts with its prefix restored after both Macs restart. Each Mac writes its own state at a prompt's kept 4,096-token boundary (its heads' linear-attention state, its copy of the sparse-attention histories and the MTP history) behind serving, once the request finished, read from the memory tier's pages without copying them first. The sealed prefix vote now counts SSD records; a boundary taken from an SSD record on either Mac is restored only after a second exchange confirms both Macs have it, otherwise both prefill from zero. A restored request writes the record into its own pages. Records store the sparse-attention latents at the pair's checkpoint precision (`balanced` by default, older rows approximate after a restore; see the quantized SSD prompt-prefix records entry); with `native` records a restored request produces the same tokens and logits as a request that prefilled the whole prompt. Records are scoped by the artifact, both builds and the MTP policy, never by the session. The same `DARKBLOOM_CLUSTER_PREFIX_SSD_*` settings, budgets and daily write limit apply. The prefix agreement field becomes `glm5-next-tensor-parallel-prefix-v2`.

### GLM pair: experimental speculative depth by load (off by default)

- A GLM-5.3-Flash tensor-parallel pair can verify one NextN proposal a round while three or more requests decode together and two otherwise (`DARKBLOOM_GLM_TP_MTP_DEPTH_POLICY=load`, threshold `DARKBLOOM_GLM_TP_MTP_LOAD_LANES`, 2 through 8, default 3), with `DARKBLOOM_GLM_TP_WIDTH_INVARIANT=1` (implied by `load`) giving verification rows one arithmetic in more window shapes. It is off by default: on two M5 Ultra Macs it raised the aggregate of 4 and 8 concurrent requests by about 11 %, but some concurrent requests' outputs differed from the same request alone, so it stays a diagnostic until that is fixed. Both Macs' cluster services must set the same values; the default keeps today's outputs bit for bit.

### Clearer cluster setup and recovery

- Follow five visible setup stages, see the default model before pressing Enter, and use a shorter status menu on either Mac.
- Preserve plain text when output is redirected or color is disabled.
- Report a failed test request with a status-and-retry step instead of announcing that setup succeeded.

### Hardware-only cluster split, prompt-prefix cache for every family, GLM cluster residency

- The split across the Macs is chosen from each Mac's hardware and measured speed alone: free pages, cached files and what other programs hold never move it. A range fits a Mac when its whole need is within the GPU's working set, the allocator's and buffer limits, and what the Mac's memory gate can admit at rest (physical memory less the system's own wired share and the file cache macOS always keeps, 10/27 of the rest). The live answer per Mac is still shown ("Quit apps on … first") and the load gate still decides each load.
- Gemma 4 pairs keep and reuse the prompt prefix too: each sliding-window layer's window is kept at every frontier and restored exactly, so a repeated 3,521-token prompt's first token comes in 0.08 s instead of 0.98 s on an M3 Ultra + M5 Max pair, and after both Macs restart the SSD tier gives it back in 0.23 s.
- GLM-5.3-Flash pairs keep and reuse the prompt prefix (resident and encrypted SSD tiers) with the same two-rank agreement as the other families: DSA histories are kept once per prompt, KDA state per frontier.
- A GLM stage holds standing GPU residency, as MiMo's does: without it every command buffer made its tens of gigabytes of weights resident again and decode fell to 0.5 tok/s (30 tok/s on one Mac with it, same tokens).
- A GLM pair always uses the keyed, encrypted data plane, including over the paired link; a model `config.json` up to 32 MiB is accepted (GLM's NVFP4 configuration is 10 MB); a model folder whose bytes are a catalog entry's is listed by that entry's name.

- Compact GLM convolution and recurrent cache states at transaction ownership boundaries before using the smaller retained-state reservation. Keep pending prefill histories and cast allocations charged per layer, enabling automatic 2048-token placement without choosing a hardware-specific split.

### Cluster planning accepts a DevNet app's install path

- Planning a two-Mac cluster with a DevNet build no longer fails every model with "Peer installation paths must be absolute and shell-safe". The DevNet app is installed as `Darkbloom Dev.app`; a saved cluster setup now accepts a space in the installed owner and worker executables, the model directory, and the native member's metallib and resource library.
- Shell syntax, relative paths and `..` are still refused, and the developer SSH route still checks every path it puts in a remote command.
- The orphan sweep, the teardown check and `cancel-all` now find a DevNet build's `darkbloom-dev cluster worker-owner`, and the cluster service stop finds a `darkbloom-dev cluster service`. Before, they knew only the production `darkbloom` name.

### Independent cluster lane withdrawal

Fixed cluster batch cancellation so withdrawing an admitted request that has
not started retires that request without interrupting another request waiting
for token credit. Accepting a start command closes the withdrawal window, and
duplicate cancellation messages share the pending retirement acknowledgment.

### `darkbloom cluster local`: a Mac pair serving without a coordinator

- `darkbloom cluster local [model]` sets up and serves the pair exactly as `darkbloom cluster` does, but no Mac of the cluster contacts a coordinator: no registration, heartbeat, public traffic or billing, and serving needs no network beyond the cable. A coordinator can therefore never refuse the start.
- The API is on the leading Mac's local endpoint with the same API key as `darkbloom start --local`; it listens on every network of that Mac (LAN or tailnet) unless `--bind` names an address (`--bind 127.0.0.1` keeps it on the Mac). `darkbloom local` prints the base URL, a `network:` URL and the key.
- The choice is kept across restarts and reboots until changed: in `darkbloom cluster`, `l` serves locally only and `p` serves through Darkbloom again; a serving cluster restarts its leading part that way and the screen waits until it serves.
- A cable moved to another Thunderbolt port no longer leaves both Macs unreachable: each cluster service follows the cable to the new port within a few seconds.
- A cluster set up from the plain `darkbloom` command (the installer's link on the PATH) now starts its leading part; it used to stop with "Installed local owner is unsafe or not executable".
- `darkbloom cluster local` on the Mac that joins a pairing carries on to the model choice (it runs on the leader over the cable) instead of sending you to the other Mac.
- The model list shows one line per model (its size and how it is split, or how it gets onto the Macs); what moves and the planner's reason are said once a model is chosen, and the public-traffic line only when serving through Darkbloom. Two models with the same name show their ids. A part that keeps ending the same way is said after three tries instead of repeating, errors read as words (not `invalid("…")`), and pairing waits for the cable's address instead of failing with developer options.
- A smaller Mac takes the share of a model it can hold: the stage memory gate's 6 GiB floor and 4 GiB loading headroom (measured on 256 GiB Macs) now scale with the Mac's memory below 96 GiB (36 GB Mac: 2.25 / 1.5 GiB). A one-layer part on a 36 GB Mac was refused before. "Restart <Mac> to free memory" is said only when nothing else frees enough; a choice made on the member survives a leader restart; the model list keeps the last catalog it read when the catalog does not answer.
- Hardware run on an M4 Max 36 GB + M5 Max 128 GB pair (Gemma 4 26B QAT, local only): another server on port 8000 (oMLX) no longer makes every start end after both Macs loaded: the port is checked before anything loads and the leading part takes the next free port; Gemma's thought-channel markers no longer reach `content` on the local API (the cluster's API parses reasoning by the model's type, as the coordinator path does); the leader no longer re-sends its cache settings every 15 s to a member that drove the onboarding; the ready screen's deployment line is the running setup's, not one recorded for an earlier start.
- The leading Mac downloads a catalog model the cluster serves whatever its chip: Qwen 3.8 27B's single-Mac requirement (an M5's neural accelerators) no longer stops an M4 Max leader from fetching it for the pair; single-Mac serving keeps its own check.
- Models the cluster takes from this Mac's own model store (Qwen 3.5 9B, a freshly downloaded Qwen 3.8 27B) are offered and copied again: their manifest is the catalog's exact file (the CDN lists the files in another order, which was refused), and a copy written earlier is corrected once.
- On a 36 GB Mac the prompt-prefix cache works: a memory-bound context keeps room for it (a repeated 5.5K-token prompt starts in 0.28 s instead of 7.1 s); a thinking model's reasoning streams from its first token on the cluster's API; each Mac keeps its worker's own log (`~/.darkbloom/cluster-setup/worker.log`).
- `darkbloom cluster local` answers at the same address and with the same key whichever Mac the plan makes rank 0: the other Mac passes the same port to the API over the cable, both Macs keep one API key, and `darkbloom local` shows it on either Mac. The port is 8000 when both Macs have it free, else the lowest port from 8000 to 8020 free on both, and it is kept while it stays free on both (another server on 8000 on one Mac no longer puts the API on 8000 or 8001 by which Mac is rank 0).
- A model chosen on a member is fetched there (it said "Nothing to copy: plan again."); a model's manifest is the encoding this Mac's worker accepts (GPT-OSS 20B was refused); the plan uses the other Mac's served speeds; the start screen no longer prints index estimates as seconds; the test request counts a thinking model's reasoning.
- PrismML Bonsai 2 27B serves on a pair with a 36 GB Mac: the worker's idle context check no longer recomputes the stage plan's constants for every step of its search (it outlasted the 10 s a request waits, so every request failed); a failing local request leaves a line in the log.
- A Mac whose memory moved after the plan (apps opened, cache refilled) no longer makes the pair retry the same split forever: after two load refusals for memory the leading Mac plans the model again on the memory now.
- The local API (single Mac and cluster alike) parses Gemma 4's thought channel and GPT-OSS's Harmony markers out of `content` by the model's type; think-tag models keep the raw stream there, as before, so the cluster still answers exactly as a single Mac does.
- Before a part starts, the model's own pages are dropped from the Mac's file cache (no privileges; the files are untouched): the load gate does not count active cache, and right after a download a 36 GB Mac's share was refused.
- The relay on the Mac that is not rank 0 is hardened: it listens only when the API listens on every address, bounds its connections and idle time, never closes a descriptor another thread may reuse, survives running out of descriptors, and leaves another local server's discovery file alone.
- A 36 GB Mac in everyday use keeps its share: a request on a loaded part asks only for what it needs plus headroom, and when the gate is short only because it does not count file cache the kernel could drop, the worker lets the kernel drop it first (stopped at any sign of compression, swap or pressure); "Quit apps" is no longer said for that case.
- When the cable moves to a Thunderbolt port that was never set up, `darkbloom cluster` says so and sets it up with one key (f); the service's log says what to do.
- The local API (single Mac and cluster) puts every model's reasoning in its own field, Qwen and Nemotron included, on chat completions and the Responses API; a stream whose prompt opens no think block still streams its answer at once.
- Shorter onboarding screens: models held back for the same reason share one line, two Macs running different Darkbloom builds are named as such ("install the same Darkbloom on both") instead of "Planning failed (Peer native build differs from the capability)", models the cluster cannot run say "not supported on a cluster yet", and the development-build service line says only what to do after a restart (the reason is in the service log).

- Guided cluster setup shows five stages, names the default model choice, refreshes peer labels from the authenticated Mac, and reports completion only after the test response succeeds. Terminal color respects `NO_COLOR`; redirected output stays plain.

- Cluster members prevent idle sleep while a deployment is serving or waiting for its peer; assertions remain held until the child and relay stop, then are released.
- A cluster service recovering a model process from its previous run keeps waiting after the cleanup deadline, keeps that process visible and protected from idle sleep, and starts no replacement model until it exits.

- Raise cluster worker output support from 4,096 to 32,768 tokens, with 65,536 combined prompt/output tokens subject to model and live per-rank memory limits. Refuse requests over the advertised bounds rather than truncating them.

- Keep fixed-scope model reservations at their full serving context when recent short requests tune automatic placement. GLM placement includes the native transport buffers and allocator bounds, so those requests cannot make an oversized split appear loadable.

### A Mac pair serves locally when its coordinator has no cluster support

- A cluster whose coordinator cannot take its cluster member role (unreachable, or a coordinator that answers the member's registration as an ordinary provider's because it predates the role) now serves on the leader's local API only, with the same local token as `darkbloom start --local`, instead of restarting every 38 s without ever serving. No public traffic reaches it and nothing is advertised to the coordinator; the Macs stay held for the cluster as before.
- The onboarding screen and `darkbloom cluster` status say so in one line: "Serving locally on this Mac's API; public serving needs a coordinator with cluster support." The next start registers normally once the coordinator supports the role.
- A coordinator that refuses this member or its pairing is still a refusal: that start fails as before.

### Cluster pairs register GLM-5.3-Flash and Qwen3.8 27B as cluster members

A pair started with a coordinator approval (DevNet) now registers both Macs as cluster members for GLM-5.3-Flash and Qwen3.8 27B. Before, each Mac's member part ended about a second after it started, with "Cluster member control connection ended", and after three tries the pair served on the leader's local API only.

The member applied the single-Mac requirements (`mlx_nax`, and `glm5_next_v1` for GLM) to its model in two places: before connecting, and when building its registration, which left the model out of `cluster_models`. A member reports hardware-only capabilities, and its pair-serving grant admits its model, so both places now follow the grant. A solo provider keeps the single-Mac requirements.

### Cluster member refusals and stops release what they hold

- A cluster member that refuses an inference request because it has no live pair slot now sends `service_reservation_released` with its 503, on the receive path, in the dispatcher and in the request handler. A request that raced a pair-slot retirement left its reservation held on the coordinator before. The handler refusal also settles the request's prefix-cache lookup receipt. The 503 answer is unchanged.
- A session that ends while the leader still forms its pair (slot publication and warmup canary) retires the published slot before the leader sends `native_pair_owner_released`. The receipt went out while the slot was still published before.

### Cluster member restarts re-register when the coordinator comes back

- A cluster member (leader or follower) that starts while its coordinator is briefly away keeps its reconnects inside its registration wait: a retry the backoff would place after the wait is made at its end and is given its own terms, as is an attempt already under way when the wait ends, so a coordinator that returns before the wait ends is reached and its in-time acceptance is honoured.
- A wait in which the coordinator was never reached now says so ("The coordinator could not be reached …") instead of "Coordinator did not accept the control-only member role."; the role check itself is unchanged.

### MiMo V2.6 Flash on the two-Mac pair

- MiMo V2.6 Flash can be served by an M5 Ultra and an M3 Ultra together.
- MiMo pair runs produce qualification records (the reference names its request and is compared on it), and MiMo V2.6 Flash is granted on an M5 Ultra + M3 Ultra pair by its six records (pipeline at the planner's cut, in the order the records passed; the mirrored order is refused).
- The provider's start-time weight hash reads with the file cache off (`F_NOCACHE`, same digest, earlier readers kept as fallbacks), so hashing a 172 GB model no longer fills the Mac's file cache before the memory gate decides. The memory gate is unchanged.

### Pair-serving grants bound to the mode their records ran

- A qualification record now grants only its own mode family (pipeline variants, pipeline with speculative rounds, tensor parallel, or the off-by-default hand-off modes) and only the chip classes in the roles it ran; a phase-split pass no longer opens pipeline or tensor-parallel placements. A diverged record withholds its own family; an inconclusive one neither grants nor withholds. The planner keeps to the same rule, and a start checked without its mode is refused.
- Seven pipeline qualification records on an M3 Ultra + M5 Ultra pair at the planner's sharded cut (Qwen3.5 9B and Qwen3.8 27B at cut 4 and 8 and Nemotron 3.5 Lightning at cut 8 with the M3 Ultra leading; both Qwen 35B A3B models at cut 36 and Ternary Bonsai 2 27B at cut 56 with the M5 Ultra leading; GPT-OSS 20B at cut 20, which stays withheld by its earlier diverged pipeline records) are bundled: every model the pair served only through phase-split records on these Macs now has a pipeline grant of its own.
- The onboarding offers exactly what a start serves: a model whose chosen placement any rank's grant check would refuse (GPT-OSS 20B, withheld by its diverged pipeline records although cut 20 passed) is listed as not served, with the reason, instead of being offered and then refused at start.

### A Mac pair keeps its DevNet cluster approval across provider updates

- The coordinator can serve a model approval: a cluster approval that names the model, its prefill schedule and its serving terms, but no build. The pair takes it when its model, schedule and artifact are the saved setup's, and it computes no build facts for it. Entries pinned to one build are matched as before.
- After an update, the re-adopted setups find the same model approval at the next check, so the pair is registered with the coordinator again with no new entry from the operator.
- Under a model approval each Mac registers its plan with its own runtime (worker, capability, resource policy and profile), and a session starts only with that runtime. Each Mac hashes its worker against its saved setup and its metallib and resource library against the digests it took when it registered.
- When the pair set a model approval aside because its parts kept failing, the next update can take it again. The same build does not take it again.

### Changing a serving cluster's model plans again once its memory is free

- Changing the model of a serving two-Mac cluster (`m` in `darkbloom cluster`, or `darkbloom cluster local <model>`) now plans again after both Macs have stopped their parts and given back their memory, and starts that plan. Before, it started the plan made while the old parts still held the memory, where tensor parallel did not fit, so a pipeline started instead. GLM-5.3-Flash on two M5 Ultras came back at less than half the speed (47.9 instead of 126.9 tokens/s in the setup's test request), serving the pipeline's 65,536-token context instead of its native 1,048,576.
- The leading Mac's own re-plan after two load refusals for memory starts the plan made once both parts stopped and gave back their memory, too.

### Cluster model provisioning without manual downloads

- `darkbloom cluster` needs no `--model-dir`: the cluster keeps its models in a store beside the product's model cache, and models single-Mac Darkbloom installed are cloned in (APFS clones, the catalog's exact manifest bytes).
- A model one Mac lacks is copied over the Thunderbolt cable on the pairing-keyed link control channel (encrypted records, 4 MiB chunks acknowledged after the receiver wrote and hashed them, resumable). The receiving Mac accepts only a manifest whose digest this build's qualification records pin, refuses hard links, unexpected files, an occupied destination and too little free disk, writes uncached, and has its own worker check the staged files before an exclusive rename into place.
- A catalog model neither Mac has is downloaded once on the leader (the product downloader, written and verified uncached through the new opt-in `ModelDownloader.uncachedWrites`), then copied. A copy predicted under 30 s at the rate measured on these Macs starts by itself (`n` within 3 s stops it).

### Animated Darkbloom cluster setup

`darkbloom cluster` setup now opens with the Darkbloom mark, which blooms in on color UTF-8 terminals at least 40 columns wide. Stage headings show a step meter, and long work (cable check, reading both Macs, planning, loading, first tokens) shows a live line that the next transcript line replaces. `DARKBLOOM_NO_ANIMATION` or `CI` keeps the mark and meter but stops the motion. Narrow or non-UTF-8 terminals keep colored headings only. `NO_COLOR`, `TERM=dumb` and redirected output stay byte-for-byte plain. The model-free onboarding checks cover all four presentations (438 checks).

### Cluster setup names "this Mac" and "the other Mac"

- `darkbloom cluster` names the two Macs from the screen that shows them: "this Mac" and "the other Mac (Apple M5 Ultra, 256 GB)" in pairing, the machine list, each model's split ("this Mac 50% / the other Mac 50%"), the serving and API lines, status, teardown checks and copies. Two identical Macs were both "Apple M5 Ultra, 256 GB", and the API line did not say it was on the other Mac. Answers the leader gives to the other Mac are worded for that Mac's screen.
- The Mac that joins a waiting leader stops after pairing, also when started with `darkbloom cluster local`; it says to run that on the Mac that leads instead of showing a second model list.
- A model one Mac holds twice (the catalog's download beside the cluster's own copy of the same files) is listed once, and a supported model is never listed as "not supported on a cluster yet" for a copy the cluster worker does not take.

### Darkbloom mark on every `darkbloom cluster` run

Running `darkbloom cluster` again on a Mac that is already in a cluster (the leader or a member) now opens with the same Darkbloom mark as the first setup, beside "Darkbloom cluster" and what can be done there (status, test, change model, stop). It follows the same terminal rules as the setup: color UTF-8 terminals with room for the mark draw it, `DARKBLOOM_NO_ANIMATION` or `CI` keep it still, and `NO_COLOR`, `TERM=dumb` and redirected output print the two heading lines as plain text. The onboarding checks cover the leader and the member, in color and plain.

### Cluster setup in narrow terminal windows

In a colour terminal between 40 and 56 columns wide, `darkbloom cluster` setup no longer smears the Darkbloom mark: the mark and its bloom appear only when its widest row fits, and narrower windows keep the step meter and live lines. A live progress line wider than the window is now cut to one row, so the line that replaces it no longer leaves its first half in scrollback.

### One command for a cluster: `darkbloom cluster`

- Run `darkbloom cluster` on each Mac, pick a model, done. `darkbloom cluster setup` is the same command; with no terminal it says where to run it.
- Choosing the model starts it (3 s to press n); no second question. The screen then says how the model is served in one line, for example "Serving Qwen3.8-27B across both Macs: pipeline, M3 Ultra 40 layers / M5 Ultra 24 layers", and where the API is ("API at http://localhost:8000 on <Mac>").
- Models that fit in the Macs' free memory now are listed first, a model that does not fit says what frees the memory, and the fit is checked again right before the start. A model the pair may not serve with this release is listed under "Not offered" ("Not yet qualified on this pair of Macs") instead of failing after a long wait.
- Two cables: the onboarding asks which one to use. The cable check prints plain lines ("Cable found.", "Cable ready."). macOS's one Local Network prompt is announced before it appears, and a denied prompt is named with where to allow it.
- After a Darkbloom update the cluster sets itself up again by itself ("Updating the cluster setup after a Darkbloom update."). After a restart, the screen says whether the Mac comes back by itself (automatic login) or once someone logs in (FileVault).
- A start that does not finish shows each Mac's last error and offers `d` to save a redacted diagnostics file. Error messages name only `darkbloom cluster`; `plan`, `configure`, `console`, `pair` and the other developer subcommands and options are hidden from the help.

### Cluster KV in pages

- GLM-5.3-Flash tensor-parallel ranks, GLM pipeline stages, Qwen 3.5 pipeline stages (MTP heads included), Qwen tensor-parallel shards, Gemma 4 stages (any lane count) and Nemotron 3.5 stages keep request KV in page pools instead of contiguous per-request arrays. Prefix entries share pages (refcounted, copy on write at a shared partial page) instead of copying histories, and a GLM tensor-parallel request is charged its pages (about 18.4 KB a token a rank) rather than the contiguous growth charge. Outputs are bitwise the contiguous ones. `DARKBLOOM_CLUSTER_GLM_PAGED_KV=0` keeps contiguous GLM tensor-parallel KV for diagnosis.
- GLM tensor-parallel (solo) and GLM pipeline requests start with their prompt's pages plus a 1,024-token granule and grow between steps, with no context cap; a request whose growth the memory gate refuses ends at `length` without touching others. GLM page pools compile their kernels at load and keep up to `DARKBLOOM_CLUSTER_GLM_PAGED_RETAIN_MB` (2,048 MB a rank) of slabs between requests.

### A coordinator deploy no longer takes a cluster pair off public traffic

- A pair registered with the coordinator serves on the leader's local API instead when its coordinator-paired parts end three times in a row right after starting. A part that ended because the coordinator did not accept its registration within the 10-second window counted too, although the coordinator decided that end: it happens during a coordinator deploy, right after a restart, or while the coordinator is slow. Such an end no longer counts. Ends with a local cause, such as a changed input or a crash, still count.
- This complements a coordinator that ends each pair session before it shuts down, which makes a deploy's ends cleaner: the provider rule still covers coordinators without that change, coordinator crashes and slow registrations.
- A pair set aside this way is offered to the coordinator again with the same approval an hour later, or at once with a later approval. Before, only a later approval, the approval's end or a Darkbloom update brought it back, so it could serve only the leader's local API for the rest of the release.

### Pair Macs set up with `darkbloom cluster` do not update themselves yet

- Darkbloom on a Mac set up with `darkbloom cluster` does not update itself yet. To update a pair, run `darkbloom update` on both Macs, then log out and back in, so that the cluster service runs the new release. If `darkbloom cluster` status then says that Qwen's speculative assistant is not offered for public traffic, press `m` once in `darkbloom cluster` to plan the model again.

### Speculative rounds on the pipeline, recorded and on by default

- A qualification (recording) request now runs a pipeline's speculative rounds (`pipeline_mtp_v1`) as served, and its decoding rank records the accepted timeline: one step per selected token (its row's digest and highest candidates), so the near-tie rule reads every accepted token. Drafts never change the accepted output.
- A qualification record may carry the decode speed timed runs of its own placement and request measured, in its mode and as the plain pipeline (`darkbloom-cluster-pair-check record --timing-mode/--timing-plain`). A passing `pipeline_mtp_v1` record grants the pipeline-with-speculative-rounds family, and the planner credits the rounds with its measured speed-up until the pair has served the same placement both with and without the rounds and its own speed-up replaces it: the rounds are planned by default where lossless and measured faster. The onboarding line reads "pipeline with speculative decoding".
- Records on an M3 Ultra + M5 Ultra pair at the planner's sharded shapes: Qwen3.8 27B at cut 8 (tokens equal to both single-Mac references and to the plain pipeline; 57.7 against 35.6 tok/s), Qwen3.5 9B at cut 4 (near tie at a true tie; 130.9 against 75.1 tok/s) and MiMo V2.6 Flash at cut 47 (tokens equal at 1,024 and 4,096 prompt tokens; 59.2 against 43.1 tok/s). Output matches a single Mac's up to near ties, as the pipeline's does: the verify window's arithmetic differs in its last bits from one-token decode.
- A member's roster plan may name `pipeline_mtp_v1`; a role-aware coordinator must list it too before it accepts such a plan.

### Cluster planner pricing fixes

- GLM-5.3 Flash tensor parallel: the plan now counts the NextN (MTP) layer every Mac holds beside its share (4.2 GB), the request memory its speculative rounds add, and the decode speed-up the rounds measured, so it no longer admits a pair the load gate then refuses or predicts decode too slow. Two M5 Ultra 256 GB still plan it as tensor parallel on equal shares with eight concurrent requests, on a new pair and after the first load measured the link.
- A pipeline's prompt hop across the cable is priced by the bytes it carries (a GLM chunk is 64 MiB), from the link probe's two record sizes, instead of as one 4 MiB record.
- Requests that answer fewer than 64 tokens (the warm-up canary, the setup's test answer, readiness probes, a quick "Say hi") are no longer speed records, so they no longer choose the mode or the request a plan is made for.
- A Mac with a model loaded no longer runs the GPU speed benchmark when the other Mac checks for updates every minute or plans: it uses the speed index it last measured while idle.

### Two-Mac cluster prompt prefixes per tenant

Both Macs of a cluster now keep and reuse prompt prefixes, in memory and in their encrypted SSD tiers, only for the request's own tenant, as one Mac does: the leader gives both ranks each request's cache switch and a SHA-256 digest of its cache scope (never the scope itself), every prefix key and SSD record scope carries that digest, and a request whose prefix cache is off (a remote request without a cache scope, or a GLM or Qwen request with images or video) reuses and keeps nothing on either Mac. Before, every request on the pair shared one prefix cache. Requests from the local endpoint carry no partition and keep the earlier behavior and bytes. Both ranks bind the partition into the request fingerprint they compare, so ranks given different partitions fail the request. `darkbloom-cluster-pair-check request --request-prefix-cache off|tenant:SALT` writes a qualification request with a partition.

### A request's tokens do not depend on what it is batched with on the new MLX core

- Cluster workers, the single-Mac reference and the tensor-parallel check now set `MLX_QMV_BATCH_INVARIANT=1` before MLX starts, unless their launcher set it. The cluster's MLX core then keeps quantized products of a few rows (speculative verify windows, rows of several requests in one launch) on its per-vector kernels, as before it took MLX main's new kernels for 6 to 16 NVFP4 rows and 8 or more affine rows, whose results change with the row count. A request served beside others keeps the bytes it gets alone. Each process logs `darkbloom-qmv-batch-invariant-v1` with the value and who set it. Single-Mac serving is unchanged.

### Faster Qwen tensor-parallel decode on two M5 Ultra

- Qwen3.8 27B tensor parallel on two M5 Ultra decodes about 6% faster for one request (75.8 to 80.5 tok/s at 256 tokens, 62.7 to 66.8 at 1,024). The exact decode projections take a layout measured on the M5 Ultra for a verify window's vectors (rows in registers). Outputs are unchanged byte for byte, and other chips keep their layouts.

### Pack Qwen MoE tensor-parallel expert and shared reductions

Qwen routed-expert tensor parallelism now carries the shared expert's float32
partial in the routed experts' collective: two collectives per layer instead of
three, with every summed and rounded value unchanged. The load agreement
(`qwen-moe-down-projections-f32-sum-before-weighting-packed-v3`) and the
tensor-parallel check's launch version refuse mixed builds. Placement now
charges the top-K expert rows once per layer instead of the largest payload on
every collective, and the request ledger charges the packed payload's source
partials. Full-model hardware qualification on the pair is still required.

### Qwen3.8 27B pairs register with the coordinator by default

- A Qwen3.8 27B pair set up with `darkbloom cluster` now registers with the coordinator and can serve public traffic. With the default `[backend] mtp_mode = "auto"`, the setup used to carry the model's embedded speculative assistant, which a setup saved for coordinator pairing may not carry. The other Mac therefore refused every cluster approval ("A tensor assistant requires Qwen TP on a row with an inline head, serial prefill and a local cluster setup"), and the pair served on the leader's local API only, although the setup said it was qualified for public traffic.
- The assistant's speculative decoding has no parity qualification, so it stays on local clusters. Under `auto`, a cluster served through Darkbloom is planned without it, as are the re-plans after an update or a memory refusal. `darkbloom cluster local` keeps it. The cost is speed: on two M5 Ultras, one request decodes at about 40 tokens/s without the assistant and about 93 tokens/s with it.
- `mtp_mode = "on"` keeps the assistant in either case. A cluster served through Darkbloom is then not offered to the coordinator, and the setup says so in its public-traffic line instead of claiming qualification.
- The leader now checks a coordinator's approval with every rule the save applies, the assistant rule included, before it stops either Mac's part or sends anything over the cable. The pair is not offered, with the reason in one line: `Not offered for pairing: this Mac's check refused it: Qwen's speculative assistant serves local clusters only …`.
- Public speculative decoding for Qwen pairs needs qualification evidence of its own and is a follow-up.

### Request-owned tensor-parallel lanes for every Qwen row

- Every Qwen tensor-parallel row (Qwen3.5 9B, Qwen3.8 27B, Qwen3.5 and Qwen3.6 35B A3B) now serves through the request-owned batch path the 27B used: main's paged KV host, independent lanes at capacities 1 to 8, the resident and SSD prompt-prefix tiers, committed-token logprobs, and automatic widening that keeps the running shares. Each row's LOAD reservation, placement quote and widening quote are priced by its own geometry (its per-rank KV heads and recurrent state, and a routed-expert row's packed MoE partials). Capacity one is the same path one lane wide. A row that can also run the pipeline keeps the pipeline as a planning candidate while tensor parallel is priced by its quote.
- A routed-expert cohort runs each row's router, shared expert and selected experts with that row's own arithmetic and sends every row's packed expert and shared partials in one collective, so a wider cohort still issues two collectives a layer and every row's tokens equal its solo bytes (`moe-rows-one-collective-v1` in the load agreement).
- The Qwen3.5 9B's inline head now runs as the tensor-parallel speculative assistant beside the 27B's (the assistant inventory and quote follow each row's configuration). The A3B rows' heads are routed-expert layers the tensor assistant does not load, so they serve without speculation.
- Each rank's cut of a row-parallel projection, expert bank or expert input column is copied once into a row-major buffer at LOAD. The interior-axis gather left a transposed view, which every quantized matmul and expert gather copied whole at each call: a routed-expert decode step copied the rank's gate/up and down expert banks for every layer, and every row copied each dense row-parallel weight. Values are unchanged.
- A tensor-parallel decode step is submitted to the GPU layer by layer while it is built (`Qwen35LayerSubmission`), and decode steps, assistant rounds and their selection encode into command buffers of up to 100 operations instead of the worker's 16, as GLM's TP decode does. Tokens are unchanged.
- Batched decode rows take each row-parallel projection's cached FP32 scales and biases, the ones its single-row forward reuses (`QuantizedLinear.independentRowsForward`), instead of widening the BF16 constants inside every quantized matmul, where MLX made that widening on the thread's default GPU stream rather than the caller's. A widened step no longer spans two GPU streams there, and two kernels a projection a step go away. Values are unchanged.
- The single-lane tensor-parallel owner is retired with its own page pool, its prefix cache and `DARKBLOOM_CLUSTER_QWEN_TP_PAGED_KV`; Qwen tensor parallel now requires the authenticated sealed data plane, and each lane reserves its full context at LOAD instead of growing by granules.
- Full-artifact qualification on the pair is still required.

### Qwen27 tensor-parallel prefix SSD tier

Keep the Qwen27 TP batch owner's prompt prefixes in the encrypted SSD tier as well as in memory, so a repeated long prompt restores its prefix after both Macs restart. Each rank writes its own shard (and the assistant's trusted history) behind serving after bilateral clean retirement. The sealed vote now counts SSD records, and a second exchange confirms that both ranks restored, or both prefill from zero. Records are scoped by plan, shares, artifact, storage, both builds and assistant policy, never by membership epoch. The prefix agreement field becomes `qwen-tensor-parallel-prefix-v2`.

### Qwen27 tensor-parallel ranks reserve only their own heads

Each tensor-parallel rank now reserves the request state it actually holds: its own KV heads, linear-attention heads, and its own rows and columns of the fused projections and projection constants under the chosen split. The replicated assistant, hidden-width buffers and gathered logits stay whole on both ranks. Setup quotes both ranks of every supported split. Placement charges each Mac its own figure. It keeps a split for later widening only when, on each Mac, the serving owner's weights and request plus the widened load fit, because widening is previewed before the old owner is released. On a busy second Mac, onboarding can therefore pick a split that widens to two speculating requests instead of one that never can. The whole-model figure remains the bound either rank stays under.

### Qwen27 tensor-parallel resident assistant

Discover and fully quote the catalog Qwen27 embedded assistant during normal cluster setup, retaining the native inventory policy through bilateral launch and READY. Eligible concurrent requests keep independent histories and accepted-token credits while sharing captured target verification; ordinary media, logprob and history-filter paths retain their capabilities. Price surviving cohort backing, the next verification window and assistant prefix ownership through checked retirement. Explicit MTP off retains the fully quoted ordinary target. Full-artifact correctness and release qualification remain separate from component fixtures. Bound the assistant's trusted-history flush to evaluated 512-row blocks (first draft and ordinary decode), and price a verify window by what it writes: partial-page replacements and segment slack, not a second history. At the 64K profile the whole-model bound for one speculating request fell from about 66 GiB to 22 GiB, and for two from 96 GiB to 36 GiB; installed qualification is separate. The saved setup's status binding carries the speculation the session derives, so a pair serving the resident assistant reads as ready instead of stale and automatic setup finishes; capacity-one refusals keep their capacity or deadline reason. The resident owner's memory gate measures compression and swap-out from the start of each served scope instead of the owner's whole life (limits unchanged), so ordinary background compression on a busy Mac no longer refuses later requests. Concurrent speculative requests verify each request's draft window with that request's own single-window arithmetic inside one collective per row-parallel projection, so they emit exactly the tokens they emit alone. One batched product changed kernel at four three-column windows and altered near-tie tokens.

### Qwen tensor-parallel decode with batch-invariant projections

Every Qwen tensor-parallel plain decode step, verify window and batched row
(the 9B, the 27B and the dense projections of both 35B A3B rows) now projects
through the SDK's batch-invariant affine kernel. Each position of a speculative
verify window therefore has the bits of the plain decode step that computes the
same token, and each concurrent row the bits it has alone, at any cohort width.
This changes the rounding of every decode projection relative to MLX's own
kernels, so recorded tensor-parallel references must be regenerated once.

A row-parallel projection reads its bf16 activation directly and writes its
FP32 partial (no separate widening launch and no FP32 copy of its scales), and
its rounded all-sum feeds the fused residual step, so a step runs far fewer GPU
launches. Each rank logs the arithmetic it resolved once per load
(`darkbloom-aqv-kernel-v1`: exact vectors, the kernel's arithmetic and words
per lane on that GPU family, its layouts), and the pair binds whether exact
vectors are on into its load agreement, so two ranks that resolved it
differently refuse to load. `DARKBLOOM_QWEN_TP_EXACT_VECTORS=0` (diagnostic
only, never forwarded to an installed rank) keeps MLX's kernels.

### Qwen tensor-parallel ranks wait for each all-sum in the kernel that reads it

The Qwen 3.5 residual step (`ResidualRMSNorm`) now reads its FP32 tensor-parallel
all-sum as a fenced input, as GLM's hyper-connection sites already did, and a
worker turns `MLX_METAL_FENCED_INPUTS` on for every tensor-parallel family whose
kernels read their sums that way (`ClusterResidentModelCatalog.Family
.tensorParallelSumsAreFencedInputs`; a launcher's own value is kept). The kernel
that reads a sum then waits for the CPU itself instead of MLX's separate
fence-wait launch, about 128 of them per verify window of the 27B. MLX consults
the setting only for inputs a kernel declares fenced, so every other launch is
unchanged, and only where the GPU waits changes, never a value. The fused fence
update stays a launcher's choice. Each rank logs the choice (`fenced_sums=` in
`darkbloom-aqv-kernel-v1`) and binds it into the load agreement.

### Qwen tensor-parallel speculative rounds keep the GPU busy

A single-request speculative round no longer waits for each assistant draft
step before building the next one, and no longer waits for the drafts before
building the verify window: the draft chain and the window are submitted back
to back, and the window itself is submitted layer by layer as a decode step
already was. The drafted tokens' vocabulary check is evaluated with the window
and read when the window is confirmed. Every rank still runs the same
collectives in the same order, the emitted tokens are unchanged, and a failure
on either rank fails the round on both. Batched rounds keep their draft
schedule. `DARKBLOOM_QWEN_TP_MTP_PIPELINED_DRAFT=0` (diagnostic only) waits for
each draft step.

### Faster Qwen tensor-parallel verification: windows evaluated whole

Qwen tensor-parallel speculative verify windows are evaluated whole instead of
being submitted to the GPU one decoder layer at a time. On two M5 Ultra Macs
serving Qwen3.8 27B this makes a single request about 18 % faster (60 against
51 tokens per second) and four concurrent requests about 5 % faster, with
identical outputs. `DARKBLOOM_QWEN_TP_WINDOW_LAYER_SUBMISSION=1` (diagnostic,
never forwarded to an installed rank) submits windows by layer again; both
ranks bind the choice into their load agreement.

### Qwen3.8 27B at its native context on a tensor-parallel pair

- A Qwen3.8 27B pair serving in tensor parallel accepts the context a single Mac serves: prompts up to 262,143 tokens and up to 32,768 output tokens within 262,144 (previously 32,768 + 32,768 within 65,536). LOAD and the planner still size the pair for the 32,768 + 32,768 request at every width (one to eight lanes), so no lane reserves KV for the whole context in advance. Each longer request is charged at its own context when a rank reserves it, and each rank's live memory gate admits it or refuses it alone (HTTP 503 with the context the pair serves now) while other requests keep running. Readiness and keep-warm answers carry that serving context. The 27B's pipeline modes and every other Qwen row keep their limits.
- Qwen tensor-parallel paged lanes reserve their prompt and a 1,024-token granule when they open and grow between steps, instead of reserving every page of the prompt and output at once. Outputs are unchanged byte for byte.
- The 27B's worker profile, load agreement and installed setup fingerprints change. Existing 27B setups re-plan after the update, and 27B pair qualification records are recorded again.

### RDMA setup guidance for macOS 27

When RDMA over Thunderbolt is turned off, `darkbloom cluster` and its setup screens now point a Mac on macOS 27 or later to Apple's switch in System Settings (Privacy & Security, RDMA over Thunderbolt, then restart) instead of macOS Recovery. Macs on macOS 26 keep the Recovery steps with `rdma_ctl enable`. Darkbloom still never changes the setting itself.

### Releases carry their cluster runtime facts

- Every release lane (dev branch, staging, prod) now computes the cluster runtime facts of its final signed app with that app's own CLI and worker: the digests of the cluster worker, placement tool, Metal library and paged-attention source, and for each model the build qualifies on a cluster and the environment's catalog has, the digests of its capability and its pair-serving grant. The job summary and a run artifact show them in every release.
- Each model's pair-serving grant lets a coordinator form its two-Mac pairs: a pair member reports only hardware capabilities, so without a grant no pair of GLM-5.3-Flash or Qwen3.8-27B forms. A declared public model's grant names its declared mode families; any other model's is the grant of the build's own qualification records, or none.
- GLM-5.3-Flash and Qwen3.8-27B are declared for public cluster traffic in pipeline and tensor parallel (owner decisions, 2026-10-31): their entries carry parity qualifications from which a coordinator derives their public qualifications, and it applies them to each declared mode family on any Apple silicon pair, with sampling and tools, and in tensor parallel images and video as the environment's catalog lists them. The qualifications name the evidence placement (two Apple M5 Ultras; a pipeline cut at half the model's layers), not a limit; no pipeline ran on two M5 Ultras and GLM-5.3-Flash has no tensor-parallel cross-cable record, so both rest on the owner's decision and the DevNet serving results. GLM-5.3-Flash runs the serial prefill schedule only, so its schedule 2 entries are inert. Every other model's clusters serve their owner only. The setup says a declared model is qualified for public traffic in pipeline and tensor parallel.
- The release registration carries the facts as `cluster_runtime` only when that environment's repository variable (`DEV_CLUSTER_RUNTIME_ENABLED`, `STAGING_CLUSTER_RUNTIME_ENABLED`, `PROD_CLUSTER_RUNTIME_ENABLED`) is `true`; a coordinator that accepts the block then approves the build's two-Mac clusters automatically. Unset, the registration is unchanged and a failure to compute the facts only warns.
- `darkbloom cluster runtime-facts` (hidden) prints schema `darkbloom_cluster_runtime_v2`: the same digests as before plus each model's `pair_serving_grant` and `parity_qualifications`.

### Cluster runtime facts leave out another model's catalog ID of a shared artifact

- A release's cluster runtime facts no longer fail when one artifact is listed under the catalog IDs of two registered models. Production lists `gemma-4-26b` and `gemma-4-26b-8bit` for the same Gemma 4 26B artifact, and the build registers them as two runtime models that only the manifest tells apart. Only the 8-bit one is qualified on a pair, so `darkbloom cluster runtime-facts --release-candidates` stopped with "Qualified cluster models the release cannot describe: gemma-4-26b", and a production release with `PROD_CLUSTER_RUNTIME_ENABLED=true` would have stopped after signing.
- A catalog model ID whose candidates the build's worker describes only as another registered model is now that model's: it is left out of the facts and named on standard error (`note: left out, the catalog model ID of another registered model: …`). A catalog model ID of which the worker describes no candidate at all still fails the step.

### Cluster served speeds count only for the build that served them

- A two-Mac pair's planner and request router now use a served request's speed only for the worker build that served it. Each speed record in `~/.darkbloom/cluster/served-speed.json` names every rank's worker build; records from another build, including every record written before this release, give no speed and age out of the file, so a new build plans from the share probes and link measurements until it has served. Speeds served by older, slower builds no longer hold a tensor-parallel split where the current build's own probes balance it. The plan is still made for the prompt and answer lengths the pair's clients send.
- The plan says how many records it left out (`N record(s) from other worker builds ignored`). `darkbloom-cluster-plan plan --served` and `route --served` use records only for the build named with `--served-build SHA256`.

### The cluster comes back after a reboot

- After a restart each Mac serves again once it is logged in (by itself with automatic login on); `darkbloom cluster` says which applies to each Mac.
- `darkbloom cluster` (leader and members) installs this Mac's cluster service as a per-user LaunchAgent (`io.darkbloom.cluster-service.<digest of the install>`): launchd starts it at login and runs it under the cluster supervisor (`darkbloom cluster service --supervise`), which restarts it after 15 s doubling to 300 s and parks it after three quick failures; launchd restarts only a supervisor that crashed. Running `darkbloom cluster` again keeps an unchanged agent, replaces a changed one, restarts a parked one, and takes over from a service an earlier version started in a terminal. Nothing is asked beyond the cluster link's one approval.
- `darkbloom cluster stop` stops this Mac's cluster service and removes its login agent (on the leader the cluster stops serving first); unpairing the last pairing (`darkbloom cluster pair --forget`) removes it too. `darkbloom status` shows whether the cluster service starts at login, whether it runs, and its supervisor's phase.

### Cluster background network identity

- Associate the cluster login service with its enclosing app so macOS can retain Local Network approval when the setup terminal exits.
- Replace older unassociated jobs through the normal cluster command; preserve idempotent startup and stop behavior.
- Keep socket failure details in lease diagnostics and explain the session lifetime of an ad-hoc development service.

### The cluster service is no longer restarted while its pair is registered

A pair registered with the coordinator could restart the cluster service of a Mac many times a day (about every 15 minutes on one DevNet leader: "heartbeat missing for 75 s while its process is alive"), and each restart dropped the pair for a short time. The Mac's part inherited the service's heartbeat file and wrote its own heartbeats into it, and the supervisor does not count a heartbeat from another process. The part now writes its heartbeats to a file of its own (`~/.darkbloom/cluster-setup/part-health.json`).

### Cluster sessions without a fixed lifetime; rank lease and keep-warm

- A model served by two Macs stays loaded and serving until you stop it, and a Mac that disappears is reported at once instead of stalling.
- A two-Mac cluster session has no fixed lifetime and no request count any more. The 300-second session (1,800 for MiMo), the sixteen-request cap, the installed session's teardown at its deadline, the rotation to a new session after sixteen requests and the member session's 900-second cap are removed; a loaded model stays resident and serving until it is stopped (`darkbloom stop`, an operator unload, an autopilot model switch) or a real failure is detected. The capability record drops `maxLifetimeSeconds` and `maxRequests`.
- Each worker holds a renewable rank lease instead (S03): armed before its weights load at most one grant away, renewed every 5 s for 30 s by its owner with an `extendDeadline` line on the worker's control pipe, which the worker reads from launch, through the load. An owner that stops renewing (it stopped, died or lost its link) leaves the worker to end by itself within the time to live, through the forced exit that releases MLX's wired memory first. The leader renews each remote owner's lease the same way (`renew` frames), and each owner renews its own worker's.
- A cluster member honors the coordinator's grant lease (S15): `native_pair_lease` frames move its deadline (a grant may leave at most 120 s plus 5 s of clock allowance); an established session survives a dropped control connection for the 90-second grace, and the member claims it again with `resume` in its registration.
- Keep-warm, on by default (S27): a GPU pulse on each worker's own executor every half second while idle once the first request has run (back-off for a minute after a slow submission), and a 1x16 data-plane exchange both ranks run about once a second while idle, sequenced by the leader; a failed exchange ends the session cleanly. `darkbloom-cluster-pair-check --keep-warm off` and the worker's `--keep-warm off` turn it off for comparison.
- `darkbloom-cluster-pair-check` takes any number of repetitions, idle gaps between them (`--idle-seconds`) and a qualification switch that stops renewing both leases (`--stop-renewals-after-seconds`).
- A Mac that vanishes from a cluster is a stated failure, not a stall: when the other member's link control connection closes or goes silent and does not come back within the link's own re-dial time (5 s for a closed connection, 10 s for a silent one with the default link timing, never past the 30 s rank lease), the leader fails the request in flight at once with the reason (`link edge: follower lost: ...`), stops waiting for cleanup proofs that can no longer arrive (the session is quarantined, rank 1 stays unproven, the other Mac's own lease and device journal still end its rank), and exits instead of lingering for minutes; the follower likewise fences a vanished leader's session at once instead of at the end of its lease. A follower that releases a session without a cleanup proof (its owner ended at launch) ends the leader's wait the same way. The follower now says why its rank ended (its worker's last word, e.g. the stage-load memory gate's refusal) and the leader's incident carries it, so such a start is classified `memory_gate_refused` with the follower's own numbers instead of an unexplained `peer_lost`. A cluster member whose coordinator control connection ends or loses trust says why (`Distributed serving stops: <reason>.`) and exits with a failure status. The stale bootstrap-directory check no longer connects to a listener's socket (a connect could fail a live launch); it reads the descriptor tables instead.
- Nothing of a dead cluster session is left behind (orphan eradication, ported from the owner's oMLX and ThunderMLX lifecycle work). An orphan sweep runs at every member's start and end and before every supervised restart, and on demand as `darkbloom cluster reap [--json] [--no-wait]`: a worker or owner whose parent process is gone is given its own contract (the rank lease, the owner's longest signal allowance and the forced exit's dead-man) to end, then SIGTERM, and SIGKILL only after the kill margin, and only while its process number still holds the same process (same start time; a reused number is never signalled); a device journal whose owner died is cleared through `cluster recover`'s proof; bootstrap directories whose socket no process holds any more are removed. `darkbloom cluster verify-teardown [--json] [--baseline-wired-bytes N] [--samples N]` reports, after a stop, whether any cluster process, wired memory above the baseline (tolerance: the larger of 1 GiB and 1/128 of physical memory), stranded journal or bootstrap directory is left (`darkbloom_cluster_teardown_verification_v1`, exit 1 when not clean). `darkbloom cluster cancel-all` force-cancels every request served on this Mac on its own: SIGUSR1 makes an owner fence its worker (the protocol's own drain) and a worker end its requests through the forced exit. A forced exit whose release keeps completing durable writes (`ProcessForcedExit.noteProgress`) gets its 20 s dead-man extended exactly once, to 40 s, and never otherwise. Every rank is started with MLX's command-buffer bounds (`MLX_MAX_OPS_PER_BUFFER=16`, `MLX_MAX_MB_PER_BUFFER=512`) unless the operator pinned them.

### Cluster setup respects model reasoning defaults

- Cluster setup tests a response using each model's default reasoning controls, so GLM-5.3 Flash no longer rejects the generic probe because it sends a binary thinking override. Reasoning-only output remains visible when the test token budget expires.

### Cluster pairs serve sharded deployments by default

- The planner chooses tensor parallel or a pipeline for the Macs it detects; phase split, phase split with MTP, the pipeline-prefill/tensor-decode hybrid and the per-request "alone" route are kept but off by default, reachable only behind `DARKBLOOM_CLUSTER_HANDOFF_MODES=1`, and a setup saved with one of them is refused at start without it. The onboarding's deployment line names the sharded mode.
- Qwen models with an MTP head and MiMo V2.6 Flash can decode as speculative rounds across the pipeline (`pipeline_mtp_v1`): the last Mac holds the head and a copy of the token embedding, drafts, and both Macs verify the drafts in one window. The planner credits the rounds only from what the same placement served with and without them, and a pair serves them only where its own qualification records pass.
- MiMo V2.6 Flash keeps prompt prefixes on both Macs, in memory and in the encrypted SSD tier, restored on both or neither.
- The pair's SSD prompt-cache tier carries its daily write cap across restarts, keeps other plans' records within one byte budget instead of wiping them, stores speculative history once per record, reads records page-aligned without a copy, and hashes model files in parallel.

### Quantized SSD prompt-prefix records on the two-Mac cluster

- The pair's encrypted SSD prompt-prefix records now store attention rows at the single-Mac checkpoint precision, `balanced` by default, like every other model's checkpoints: older rows in 4-bit keys and values (affine groups of 64, FP32 scale and offset, keys Hadamard-rotated) and each record's newest 128 rows exact. Recurrent, convolution and speculative-head state stays exact. A Qwen 3.8 27B tensor-parallel rank's attention rows at 32,768 tokens take about 3.2 times fewer bytes; GLM-5.3-Flash DSA layers about 1.8 times fewer, in pipeline and tensor parallel (BF16 latents; its index keys, pool gates and MTP history stay exact). Live KV stays native.
- A prefix restored from a quantized record is close to, not identical with, computing it again. `engine_v2_kv_checkpoint_quantization = "native"` (or `DARKBLOOM_CBV2_CHECKPOINT_QUANTIZATION=native`, per model with `engine_v2_kv_checkpoint_quantization_by_model`) keeps the pair's records byte-exact. Both Macs must resolve the same precision: the leader does not sync it, and the ranks bind it into their load agreement and refuse to load otherwise. Records of one precision are never restored under another.
- Quantizing a decoded row again does not give it back (the codec is not idempotent on its own output), so a record written from a request that was itself restored from a record keeps the restored rows' first encoding instead of quantizing them again: through repeated restore-and-extend cycles, such as a long conversation, each restored row stays as it was first stored.
- `darkbloom-cluster-tp-check run --prefix-records native|balanced|k8v4|k8v8` measures a record on real weights: per-layer errors, bytes against a native record, the prompt tail scored from the captured and the restored state, and the output after the restore. `darkbloom-cluster-pair-check --prefix-ssd-quantization` selects the workers' record precision.

### Two-Mac clusters follow the provider's KV quantization

- A pair's stage KV now uses the same live precision a single Mac uses for the
  model: `engine_v2_kv_quantization` (global or per model) and
  `DARKBLOOM_CBV2_KV_QUANTIZATION`, resolved on each Mac and passed to its
  worker. The default stays native; pairs whose Macs keep it are unchanged.
- With `balanced`, `k8v4` or `k8v8`, the Qwen 3.5 family (Bonsai included),
  Gemma 4 and Nemotron 3.5 stages and every Qwen tensor-parallel row's
  request-owned lanes (9B, 27B, Qwen3.5/3.6 35B A3B, any capacity) store packed KV on the provider's own pool, after the same kernel check,
  and their memory planning counts packed rows. Both Macs must resolve the same
  precision; otherwise their load agreements differ and the pair refuses to
  load. Set the pair's model to `native` per model to keep a packed global
  setting off the pair.
- Packed stages keep no prompt prefixes, as on one Mac for packed KV. Phase
  split, GPT-OSS and GLM refuse a packed precision; MiMo stays native. The pair's SSD prefix records stay exact native states.
- `DARKBLOOM_CLUSTER_KV_BACKEND=contiguous` is removed: cluster stage KV is
  paged only.

### Steadier, visible tensor-parallel choice in two-Mac clusters

- Keep each pair's last eight link measurements from the last 30 days and plan
  on their median, so one fast or slow load no longer switches a model between
  tensor parallel and a pipeline. Link files from earlier releases still read.
- End a model's line in the setup's model list with a short reason when the
  model supports tensor parallel but is split otherwise, such as "tensor
  parallel: slower here"; models without tensor parallel show nothing extra.
- Explain that Qwen3.8 27B leaves out the pipeline because only tensor parallel
  keeps images, video and logprobs, instead of saying no pipeline fits.
- Read the saved link measurements in `darkbloom-cluster-plan plan` when
  `--link` is not given (or `--link-probes FILE`), say so, and print reduction
  costs in ms or µs.

### Cluster stop ordering

- A paired leader now retires its owned part before asking its follower to stop, preserving the native shutdown channel. Failed retirement or missing peer acknowledgement keeps the login service available for recovery and returns an error.

Require a fresh local supervision acknowledgement before stopping the peer so stale idle status cannot bypass a child start already in flight.

Keep follower lease intent alive through local planned drain; serialize background serve/stop reconciliation and wait for outstanding running leases before publishing stop acknowledgement. A stop the pair could not finish exits with status 1 and the pair's reason, without usage text.

### Stop a cluster Mac whose peer is gone

`darkbloom cluster stop --local-only` stops only this Mac's cluster service and removes its login agent. It never asks the other Mac, for when that Mac is gone for good. Without the flag, a leader still drains the pair first and keeps its service when the member cannot acknowledge. The output says that the other Mac was not asked to stop.

### Two-Mac clusters place tensor parallel first wherever it fits

- A model whose tensor-parallel layout fits both Macs is now set up in tensor parallel even where the speed estimate favored a pipeline; the setup says so ("the model fits, so both Macs share every layer of every token") instead of claiming a gain it does not predict. A setup that loads now still goes ahead of tensor parallel that would not, and predictions are still shown.
- A new pair's first setup is tensor parallel too: before any load has measured the cable, it plans on the same assumed sealed reduction a forced plan uses, labelled as assumed.
- Automatic widening never assumes a link cost: it plans only on the pair's own recent sealed link measurement, and without one it keeps the running setup.
- `darkbloom-cluster-plan plan --tensor-parallel-first` plans the same way; without the flag the plan tool keeps the speed comparison.

### A tensor-parallel cluster registers with the coordinator

- A pair that serves a model in tensor parallel (GLM-5.3-Flash, Qwen3.8-27B) now registers its roster plan with the coordinator. The plan names `tensor_parallel_v1` and no layer cut, as the coordinator requires; before, the member registered the stage end as a cut, refused its own plan, and the pair served only its local API. A setup with unequal tensor-parallel shares is refused at registration until the plan carries its shares.
- The onboarding's start line for a cluster that serves through Darkbloom no longer says public serving is off in this build: it serves its owner's requests, and public requests where Darkbloom has qualified the model and split.
- A plan in `pipeline_prefill_tensor_decode_v1` (pipeline prefill, tensor-parallel decode) also registers: the coordinator lists the mode, and the member no longer refuses its own plan.

### Tensor-parallel shares balanced by each Mac's measured speed

- Time each Mac's own share of a dense Qwen model when it loads in tensor
  parallel (at most about a second and a half, alone, nothing crossing the
  cable), and keep each Mac's newest timing per share and model for 30 days on
  the leading Mac. The next plan balances the shares by those timings: with the
  timings an M3 Ultra and an M5 Max measured, Qwen3.8 27B is planned 1:1
  instead of 2:1 after one load. A Mac short of memory skips the timing, and it
  never fails a load.
- Stop predicting a larger tensor-parallel share faster than a smaller one: a
  Mac's measured shares are no longer drawn toward its whole-model speed, and
  what the pair served corrects all of a Mac's measured shares alike.
- Read the saved share timings in `darkbloom-cluster-plan plan` (or
  `--share-probes FILE`) and name the shares used, as the setup plans.
- A load that serves the speculative head balances its shares on each Mac's measured verify window rather than its single-token step, because its rounds run windows: on the Qwen3.8 27B pair that moves the split from 3:2 to about even.

### Fixed

- Automatic cluster planning considers tensor-parallel placements independently
  of pipeline layer cuts and counts enumerated candidates instead of unused
  pipeline-cut combinations against its search limit. Unsupported runtime modes and rank counts now explain the pipeline
  fallback before requesting a link measurement, without claiming an unmeasured
  speedup. This does not enable tensor parallelism for GLM.

### Cluster validation, tensor batching and media ownership

- Repair local two-Mac setup, installed lane propagation, encrypted peer agreement,
  request-scoped placement and delayed automatic batch replacement without
  weakening native teardown, memory or failed-qualification gates.
- Preserve measured shard rates and independently price native batch capacity;
  exact Qwen3.8 27B retains feature-preserving TP selection with the complete
  native request reservation coexisting with LOAD scratch and allocator demand.
- Preview Qwen27 widths 8, 4 and 2 against current bilateral memory before
  replacing the serving owner, then recheck the exact proposed width after release.
- Pass the indexed devices, recorded keyed pair-link costs and filtered served
  history into automatic replacement, allowing its tensor candidates to be
  considered instead of silently using an unmeasured link.
- Add Qwen27 independent TP histories, grouped collectives, per-request sampling
  and captured logprobs, with checked bilateral cancellation and retirement.
- Coalesce nearby Qwen27 TP token acknowledgments within the existing bounded
  scheduling window so ready rows can decode together; joining, prefill,
  cancellation and retirement continue without waiting for a silent client.
- Reuse mutually held original-grid Qwen27 TP prefixes with bounded resident
  snapshots, fresh per-request histories, separately priced capture/cache banks
  and publication only after bilateral clean retirement.
- Route exact Qwen27 images and video through bounded provider preparation and
  the native vision owner, retaining encoded data and host/native allowances
  until their respective completion fences. Unsupported controls refuse explicitly.
- Bind streamed logprobs to committed content events and repair local HTTP
  reasoning, sampling, usage and tool/constraint parity handling.
- Repair Qwen expert reductions and mixed-router accounting; add Bonsai packed-row
  arithmetic and qualification coverage; preserve Gemma prompt arithmetic,
  catalog aliases and prefix restore/chunk semantics.
- Repair GPT-OSS, MiMo and Nemotron native independent-history batching, paging,
  cancellation and prefix behavior, including existing MiMo speculative/phase
  state accounting. Historical phase support is not TP release qualification.
- Order fast Metal fence waits after current-pass GPU producers through the
  matching native core pin; installed clustered-concurrency validation remains required.
- Retain explicit full-model hardware gates. Component tests and source support
  do not establish universal TP, media parity or release readiness; Qwen27 TP
  text speculation remains unfinished; full-artifact prefix/media qualification
  and final automatic-planner validation remain separate gates.

- Preserve an explicit local fast-synchronization diagnostic choice through both installed TP owner and native worker launches. Only canonical `0` or `1` is forwarded; normal defaults and placement remain unchanged.

Every tensor-parallel worker, widened Qwen rows included, keeps fast synchronization; explicit local synchronization choices still take precedence. Native batching and model capabilities remain enabled.

Authenticated Qwen3.8 27B TP owners now use the same fully priced request-owned execution at one lane and wider capacities. Automatic capacity changes preserve the tensor split, preventing capacity changes from switching the attention path or repartitioning arithmetic. The original exact-output acceptance gate remains required.

- Forward an explicit local eager-fence-commit diagnostic through the installed tensor owner and native worker, reporting its canonical value at startup while preserving the default.
- Report completed decode steps by actual batch width once per retired or failed scope, without request content or extra memory samples.

### Cluster worker protocol 2: prompts cross as packed token IDs

- A cluster reservation carries its prompt as packed little-endian token IDs (base64) with an explicit count instead of a JSON number array, and the leader builds a relayed command's link wire once. A 31.5K-token reservation decodes in about 1 ms per hop instead of about 12 ms, which shortens time to first token on long prompts. Both Macs must run the same release: a Mac on the previous protocol is refused at setup or pairing ("Install the same Darkbloom release on both Macs, then run `darkbloom cluster` again"), never in the middle of a request.

### Preserve truncated reasoning in collected responses

- Keep unfinished prompt-side thinking in reasoning fields for collected Chat and Responses, retrieval and continued history. Preserve explicit parser overrides, native parsed channels and token usage.

### Distributed startup signal restoration

Distributed startup restores both SIGTERM and SIGINT dispositions, including
handler flags and blocked signals, even when one signal was already ignored.
A termination request received before serving starts remains latched.

### GLM cluster prefill and finite-calibration placement

- Scan all structural cuts against current local device bounds and choose a common feasible cut through the existing performance-aware planner.
- Run the selected cut through the installed signed quotation and finite owner path; preserve explicit diagnostic cuts.
- Keep predicted speed, measured-best throughput and calibrated serving eligibility distinct. Public GLM endpoint eligibility is unchanged.
- Raise the registered GLM NVFP4 cluster candidate's prefill chunk cap to 2048 while retaining bounded authenticated logical arrays, raw frames and records. Keep the workspace conservative pending scope-matched native/host peak qualification; other models' default caps and public qualification records remain unchanged.
- Allow finite calibration up to 2048 prompt/chunk tokens with the existing 16-output cap and at most 2064 context. Automatic chunk hints ignore prompts shorter than their configured chunk and match artifact identity when available; fallback uses the current model/worker caps without creating a qualification grant.

### Bounded GLM cluster still-image candidate

- Add bounded encoded PNG ingress, rank-0 native GLM vision loading and causal feature splicing to the private two-rank pipeline, with additive memory charges and cold media prefix isolation.
- Require the explicit local image qualification profile through `darkbloom cluster local glm-5.3-flash --private-glm-image-qualification`; ordinary text serving rejects images before reservation and excludes the vision tower from planning and LOAD.
- Keep video unqualified and audio refused. Full-model image correctness, memory, cancellation and real CLI/HTTP qualification remain required before a serving modality can be advertised.

### GLM-5.3-Flash SDK speedups shared with the single-Mac release

- The SDK's pipelined KDA prefill recurrence now also covers 64 heads on an 80-core M5 Ultra (two
  value-row ranges per GPU core): one Mac and each GLM pipeline stage prefill faster with bit-identical
  outputs; a tensor-parallel rank's 32 heads keep their cut, so tensor-parallel GLM is unchanged.
- The CBv2 MTP loop can submit every draft step as soon as it is built (on for the single-Mac GLM
  profile); the two-Mac GLM path runs its own speculation loop and is unchanged.

### GLM tensor-parallel decode command buffers and sum fences

- GLM tensor-parallel decode steps, MTP rounds and lane rounds encode up to 100 operations a Metal command buffer instead of the rank guard's 16, which prefill keeps; each further buffer cost about 10 µs of GPU time (13.24 to 12.56 ms a decode step on two M5 Ultra, tokens identical).
- GLM tensor-parallel workers let the hyper-connection site wait for each all-sum in-kernel (`MLX_METAL_FENCED_INPUTS`; a launcher value is kept). The fused fence update (`MLX_METAL_FUSED_FENCE_UPDATE`) stays a launcher's choice: its multi-threadgroup path (partials above 32 KB) never signals the CPU, which stalled batched lanes about 0.7 s a round.

### GLM tensor-parallel MTP rounds submit their proposals early

- A GLM tensor-parallel MTP round (solo or batched lanes) submits its NextN priming and proposals as soon as they are built, so the GPU computes them while the host builds the verification forward instead of idling through the whole round's build: a depth-2 round 23.06 to 21.64 ms (95.9 to 102.7 tok/s) and two lanes 115.2 to 121.6 tok/s on two M5 Ultra, tokens and top logits identical. `darkbloom-cluster-tp-check glm --mtp-early none|proposals|layers` compares the modes.

### GLM tensor-parallel greedy MTP rounds split the head's vocabulary

- A greedy GLM tensor-parallel MTP round (solo or batched lanes) reads out only its half of the head's vocabulary rows on each rank and agrees on every window token through the round's existing agreement sum (each rank's half maximum and argmax; rank 0's lower index wins a tie, as MLX's argmax does): a depth-2 round 21.32 to 21.05 ms on two M5 Ultra, tokens and top logits identical. Sampled rounds keep the whole head. `darkbloom-cluster-tp-check glm --mtp-vocab-split yes|no` compares them.

### GLM-5.3-Flash runs tensor parallel across two Macs

- `darkbloom cluster` can now serve GLM-5.3-Flash text requests with both Macs working on every layer (tensor parallel) instead of each Mac holding half the layers. On two M5 Ultra 256 GB it chooses this by itself once the cable has been measured: the setup's test answered at 51 tokens/s against 42 for the layer split, and long prompts prefill at about 3,300 tokens/s against 1,450 (one Mac alone: about 1,800), and decode runs at 53 tokens/s. Every byte between the Macs stays encrypted. A repeated prompt prefix (a chat's history) is reused on both Macs instead of prefilled again. Image requests still use the layer split.
- The cable measurement that decides between the two modes now times the encrypted sum as a running model pays it, not cold: it had read three times slower and kept tensor parallel from being chosen.
- The Macs exchange GLM's per-layer sums at half the size: the model's own 16-bit values instead of the same values widened to 32 bits, with an identical result. Prompts prefill about 14% faster.
- Tensor-parallel decode is faster: the worker lets each GPU command buffer take whole expert banks instead of committing one at every expert layer (about 88 commits a token instead of 22), and MLX spends less host time per kernel launch. On two M5 Ultra, decode went from 53 to about 57 tokens/s through the API (62 in the bench).
- Fixed a hang where the GPU could wait forever on an encrypted sum between two GPU steps.
- What a tensor-parallel setup served no longer resets the speeds the planner learned from a pipeline the same Macs served: it corrects only the tensor-parallel figures. Before, after serving in tensor parallel the planner priced the layer split as fast as one Mac alone and switched back to it. This applies to every model the cluster plans.
- The hardware speed prior no longer counts every routed expert of a mixture-of-experts model as read on each decode step. It counts only the experts a token is routed to, and it does not count replicated weights as divided by a tensor-parallel share.
- Greedy GLM-5.3-Flash requests in tensor parallel now decode speculatively with the model's own next-token-prediction layer, which each Mac now also loads (about 4.2 GB more per Mac): each step checks the layer's guess together with the next token and keeps both when the guess is right, so greedy decode produces more tokens per step (two guesses a step: about 76 tokens/s against 63 in the bench on two M5 Ultra). Sampled requests decode as before.
- Tensor-parallel prefill is faster: each encrypted sum between the Macs is now sealed, sent, opened and added in 256 KiB pieces as they become ready instead of as one block, so the encryption overlaps the transfer (a 15.7K-token prompt prefilled at 3,812 tokens/s against 3,554 in the bench). Every piece is still authenticated, and a piece that does not open fails the request.
- Tensor-parallel decode no longer waits between steps for the serving process's answer to each token (whether to go on). The token is handed over at once and the answer is read once the next step is running, so its round trip overlaps the GPU work (two M5 Ultra through the API: about 73.5 to 77 tokens/s). A stop request still ends the output exactly where it was asked for; one extra step may be computed and is never sent.
- GLM-5.3-Flash decodes and prefills faster on Apple silicon, on one Mac and across two: fewer and faster GPU launches for the hyper-connection, mixture-of-experts and sparse-attention steps, and less CPU time per launch. Outputs are unchanged bit for bit. On two M5 Ultra through the API, decode went from about 78 to 90 tokens/s and long-prompt prefill from about 3,470 to 3,540 tokens/s.

### GLM-5.3-Flash native prerequisites

- Use one peer-status observation for each finite GLM terminal-context decision, avoiding a false transport-loss rejection across an expected peer close while preserving exact acknowledgment consumption, frozen connection identity and durable owner/fence retirement. Encrypted loopback CPU coverage does not qualify model, GPU, RDMA or serving behavior.

### Models load when every model's minimum KV fits

- Loading a model beside others no longer fails with "would leave a model without its fixed request workspace, admission watermark and 1.0 GB minimum KV allowance" while the KV budget still covers every model's minimum. The split gave each model a share in proportion to its per-token KV cost alone. A resident model with a small per-token cost and a fixed per-request workspace, such as Nemotron 3.5 Lightning with its assistant on, could get less than its own minimum and block every further load. Now, when that would happen, each model gets its minimum first and the rest of the budget is split as before; the message now appears only when the minimums together exceed the budget. The model being loaded counts only the 1 GB base minimum until it is built, so Lightning itself can still fail to load, with no KV headroom, when it joins several high-rate models.
- A split that already gives every model its minimum is unchanged. Unloading a model, or a change to the activation reserve, no longer shrinks another model below its minimum.

### The local Responses API continues a conversation from `previous_response_id`

- `/v1/responses` on a single Mac and on a cluster now honours `previous_response_id`: the request continues the earlier input and that response's output, as with OpenAI. A follow-up that sends only a `function_call_output` item resolves its tool call instead of failing with 400, and a later turn remembers earlier ones.
- An ID this process does not hold (never served, sent with `"store": false`, dropped from the bounded in-memory store, or from before a restart) returns 400 with code `previous_response_not_found`.

### Media the model's processor refuses answers 400 on one Mac and on a pair

- An image or video the model's processor refuses now returns HTTP 400 `Invalid media input.` (`invalid_media`) on one Mac and on a two-Mac pair: for Qwen 3.5 and 3.8 a side below 32 pixels (a 16×16 PNG, for one; the processor does not upscale it) or an aspect ratio above 200:1, a video without a decodable track, or more media than a processor takes. It returned the retryable 503 capacity answer, so the coordinator tried other providers that refuse it the same way.

### A request's `min_p` now applies on one Mac too

- A request's `min_p` now applies on one Mac too, as it already did on a cluster pair: tokens less likely than `min_p` times the most likely token are dropped before sampling (values above 1 count as 1). Requests without `min_p`, or with 0, are unchanged.

### One GPU stream per decode graph, and no GPU-on-GPU fence spins

With MLX fast fences (`MLX_METAL_FAST_SYNCH=1`) a widened Qwen 3.8 27B
tensor-parallel owner could stop at its first multi-row plain decode (the c14,
c17 and c39 stalls). MLX cast each batched 4-bit projection's bfloat16 scales
and biases to float32 on the thread's default GPU stream instead of the stream
the caller passed, and mlx-swift runs everything else on its own process-wide
stream, so that decode graph ran on two GPU streams. A fast GPU fence wait is a
kernel that spins on its queue until the other queue's timestamp arrives, and
Metal does not promise that the other queue runs meanwhile, so both queues
stopped. The casts (and MLX's other helper ops that dropped the caller's
stream) now stay on the caller's stream, and a GPU stream never spins on
another GPU stream: it waits on a shared event, while the CPU <-> GPU
collective waits keep the spinning fast path. Synchronization only: tokens are
unchanged. Widened Qwen 3.8 27B owners stay on the event path until a two-Mac
acceptance with fast fences passes on this fix.

### Pair-check reservations keep their media

- `darkbloom-cluster-pair-check` hands each worker the whole reservation when it moves the deadline to that worker's clock. It dropped still images and Qwen image/video input, so those qualification requests reached the workers without their media. The owner and peer-link hops re-time reservations with the same field-preserving copy.

### Faster prompts on Macs without neural accelerators

- MLX's steel affine quantized matmul computes prompt-sized products (256 rows
  or more, 64-aligned outputs) in 64-row x 32-column tiles for 16-bit inputs and
  32 x 64 for FP32 partials instead of 32 x 32 on GPUs without neural
  accelerators (M1-M4, and the M3 Ultra rank of a pair). On the M3 Ultra alone a
  4,096-token prompt took 2.5% less time (27B 12.37 -> 12.06 s, 9B 3.55 -> 3.46 s)
  with the same tokens. `MLX_QMM_STEEL_TILE=32` restores the previous tile.
- Qwen tensor-parallel prompt frames are submitted to the GPU every four layers
  while they are built (`DARKBLOOM_QWEN_TP_PREFILL_STRIDE=0` restores whole-frame
  evaluation). With both changes the 27B pair at 1:1 reached its first token
  1.4-3.1% sooner (4K 8.22 -> 8.08 s, 16K 36.7 -> 35.5 s, 32K 81.8 -> 80.0 s) and
  the 9B pair 1.1-2.3% sooner (4K 2.63 -> 2.60 s, 32K 27.5 -> 26.9 s), with the
  same tokens.
- Diagnostics: `darkbloom-cluster-tp-check qwen-prefill` (one rank's prompt
  frames, layers and projections), `DARKBLOOM_QWEN_TP_PREFILL_FRAME_TIMING=1`
  and `pair-check --worker-environment`.

### Concurrent tensor-parallel requests draft together

- When several speculative requests on a two-Mac tensor-parallel pair draft in the same round, their assistant steps now run as one batch: one head call and one pair of sealed exchanges per draft step for every row, instead of one per row. Six concurrent requests need about a third of the reductions they needed before, and every request still produces exactly the tokens it produces alone.

### Concurrent tensor-parallel requests verify together

- Concurrent speculative requests on a two-Mac tensor-parallel pair now stay in one verify cohort. A request that still has up to one round of accepted tokens waiting joins the next round from its own settled position instead of waiting for its queue to drain, so requests that started a step apart no longer take turns verifying alone. Every request still produces exactly the tokens it produces alone.

### Concurrent tensor-parallel requests share each draft step's weight reads

- On a two-Mac tensor-parallel pair, speculative drafts now use the same batch-invariant kernel as decoding. When several requests draft in the same round, every draft step after the first runs all of them through one assistant pass, and every head call serves all of them, so each weight is read once per step for the whole batch instead of once per request. With eight concurrent Qwen3.8 27B requests, a round's draft work on one Mac fell from about 38 to 24 ms.
- A request proposes the same tokens alone and in a batch of any size, and every request still produces exactly the tokens the model produces without speculation. Proposals can differ from the previous kernels at near-ties, so the share of accepted proposals can shift slightly; the output never does.
- Both Macs must use the same draft kernel or the pair refuses to load. `DARKBLOOM_QWEN_TP_MTP_EXACT_DRAFTS=0` (diagnostic only, never forwarded to an installed rank) keeps the previous kernels. Single-Mac speculative decoding is unchanged.

### Six-request tensor-parallel batches

- Automatic batching on a two-Mac tensor-parallel pair can now choose six concurrent requests, between four and eight, when eight do not fit. Pipeline batching keeps its widths of two, four and eight.

### Qwen tensor-parallel verification keeps its measured weight-read tiles

- Two-Mac tensor-parallel Qwen pairs verify concurrent requests with tiles of at most five vectors per weight read again (tiles of four past five), instead of whole-cohort tiles of eight or sixteen. On two M5 Ultra Macs serving Qwen3.8 27B, four concurrent requests reach about 90 tokens per second together instead of 73, with identical outputs.

### Widened Qwen tensor-parallel owners keep fast fences

Qwen tensor-parallel owners with more than one lane (Qwen3.8 27B, and the Qwen3.5 9B and both 35B A3B rows) keep MLX's fast fence waits instead of the slower event path. The stall that once stopped a widened pair right after a request finished is fixed at its cause: MLX kept a batched step on one GPU stream, and batched rows no longer convert their scales each step.

### Wider automatic batching on two-Mac pairs

- A two-Mac tensor-parallel owner now reserves much less memory per request, so automatic batching can widen past two concurrent requests when the Macs have room. A request no longer reserves its own full-history attention gather (decode and verification read pages in place, and one shared gather serves the single prompt frame a step runs). After a speculative round, a request keeps only its own recurrent rows instead of the whole round's. A long prompt's draft history moves into the assistant's cache as the prompt is read instead of waiting whole for the first draft. For Qwen3.8 27B with 32K-token prompts and 32K-token outputs, two, four and eight requests reserve 16.1, 25.7 and 45.5 GiB per Mac at an equal split, down from 21.4, 40.5 and 86.0 GiB. Qwen3.5 9B and the 35B A3B rows shrink the same way.
- Before replacing a running owner with a wider one, the preview now counts that owner's loaded weights on each Mac as free, because they are released before the wider owner loads. It does so only for a replacement that keeps the same split. The owner's unused request reservation is never counted, and the memory check after release is unchanged. A width that fails that check is not credited again for 10 minutes.
- Every width that automatic batching refuses is logged as one line, `cluster.batch_replan refused lanes=N`. It gives the phase (preview or after release), the reason, and each Mac's need, admissible memory, shortfall, weights and fit, in bytes.
- Every request still produces exactly the tokens it produces alone.

### Qwen27 feature-preserving cluster modes

Keep images, video and committed-token logprobs in the registered Qwen3.8 27B cluster route by admitting tensor parallel before unchanged speed ranking. Replan old pipeline setups instead of silently serving fewer features, retain native link/shape/memory gates, and require matching actual media READY and logprob support before creating the bridge. Other model and GLM mode policies remain unchanged.

### Qwen27 media response formats

- Accept image/video `response_format` requests through the cluster's existing
  Qwen27 media path, using the same JSON prompt preparation and nonstream
  JSON/schema post-validation as standalone serving.
- Preserve forced-media-tool refusals and default processor policy. Streaming
  remains prompt-guided; this does not add token-level grammar enforcement or
  establish full-model media/schema accuracy.

### Qwen27 tensor-parallel greedy choices without full-vocabulary gathers

Qwen27 tensor-parallel speculative decoding no longer moves complete vocabulary rows between the Macs for greedy work. Each draft step and each greedy verification column reduces a rank's vocabulary shard to its maximum and first index (plus a non-finite count when verifying), and one small exchange gives both Macs the same choice: the complete row's first maximum, with the lower index winning ties. Greedy verification also drops its separate choice broadcast. Sampled requests and logprobs still gather complete rows.

### Qwen 3.8 27B pair media: preparation on its own stream, refused alone

- A Qwen 3.8 27B tensor-parallel pair no longer ends both workers when rank 0's
  media preparation fails. Rank 0 prepares a request's image or video patches at
  admission, on a CPU stream of its own while its executor waits, so another
  thread's failed CPU work can no longer fail the preparation (after the main
  merge, MLX overlaps evaluations across threads and hands a stream's stored
  error to whichever caller synchronizes it next; the pair's media requests
  failed this way after a dozen had passed). A preparation that does not
  reproduce the leader's patches refuses that request alone with a retryable
  error and its reason in the worker log, and the pair keeps serving. A vision
  tower failure still ends the workers.

### Qwen27 tensor-parallel speculative depth 3

Automatic Qwen27 tensor-parallel setup now drafts three tokens a round instead of two. On the installed pair the assistant's first and second drafts were accepted 87% and 84% of the time, so a third proposal adds about 0.6 tokens a round for one more draft step; the verify window stays bound by one weight pass. Every emitted token is still the target's own choice.

### Faster concurrent Qwen27 tensor-parallel verification

Concurrent Qwen27 tensor-parallel requests now share each quantized projection's call when verifying their speculative windows, as long as the combined rows stay below MLX's vector-kernel limit for the device. Every request keeps the arithmetic it has alone. Draft proposals no longer need their own broadcast: both Macs read them from the same small exchange. A new `darkbloom-tp-mtp-profile-v1` worker line splits each round's time into draft, build, verify, gather, choose and settle.

### Fewer weight reads for concurrent Qwen27 verification

Concurrent Qwen27 tensor-parallel speculative windows now go through an exact four-bit projection kernel where it is faster than MLX's own calls: it reads each projection's weights once for up to eight verify rows (two four-column windows), where MLX's vector kernel reads them once for every five. On the M5 Max it keeps one output row per thread (up to 20% faster); on the M3 Ultra the row-parallel FP32 partials use two rows per thread (1.5-2.1x faster) and other projections keep MLX's calls. Each row keeps MLX's own `qmv_wide` reduction, so every request still gets byte-identical results to running alone; other GPU families keep MLX's calls.

## v0.10.5

Published 2026-10-30 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.10.5)).

### Upgrade and rollout notes

- The MLX pins move to their forks' `main`: `libs/mlx` and the nested `mlx` from `31f550af` to `72dffa2d`, `libs/mlx-swift` from `4926d3d9` to `c633d221`, and `libs/mlx-swift-lm` from `aee6ebb6` to `2beb401f` (#1645; #1643 needs the same pin). SDK #369 lets a stop string end only the answer and SDK #368 ends a demanded checkpoint range just below the prompt end. Twelve Metal backend files change, including `kernels/fence.metal`, so the tag build's `metallib_hash` differs from v0.10.4's. Complete SSD checkpoints are stored per provider build, because their namespace binds the binary and loaded-metallib hashes: an upgraded provider writes new complete checkpoints instead of restoring 0.10.4's, and a rollback does the same. The NAX head-dim split attention JIT fix that v0.10.3 and v0.10.4 shipped from the `hotfix/0.10.2-jit-nax-dsplit` branches (`mlx` `31f550af`) is in the new `mlx` pin's `jit_kernels.cpp`. All three pins are on their forks' `main`, so no hotfix branch needs keeping.
- No coordinator change is needed before the tag, and no provider-version floor. After the tag, the platform snapshots its provider contracts from the tagged commit and sets `LatestProviderVersion` to `0.10.5`; of the 34 snapshotted inputs, pinned at v0.10.4's `8effff7f`, only `ProviderCore.swift` changes.
- `darkbloom sandbox` drives the Darkbloom Sandbox add-on that `https://api-sandbox.darkbloom.dev/install.sh` installs (add-on 1.1.0 when this was prepared): it runs that installer with `--json-progress` and reads the add-on's `status --json` (`schema` 1). A Mac without the add-on gets only the new subcommand.
- The CI (#1637 and the dev-branch lane) and release qualification (#1659) entries change no provider artifact; the test-only changes #1644, #1653 and #1676 have no entry.

### Darkbloom Sandbox from the provider CLI

- `darkbloom sandbox setup` checks whether this Mac can host Darkbloom Sandbox CI jobs (chip, macOS, cores, memory, disk, network, power and sleep) and how many Linux and macOS jobs it can run at a time, explains that inference pauses while a job runs and that each job pays its price minus a 10% fee into your Darkbloom balance, and asks before installing anything. It then downloads the add-on's installer over HTTPS and shows its stages, including the browser approval link and code. Running it again reports the state, continues an unfinished setup, repairs the add-on or applies new slot counts.
- `darkbloom sandbox status` (with `--json`), `pause`, `resume`, `logs` and `uninstall` drive the installed add-on. `darkbloom status` adds a `Sandboxes:` line while the add-on is installed and waits at most 2 seconds for it.
- Older installers and add-ons keep working: setup runs an installer without progress events with its own output, and `darkbloom sandbox status` shows an older add-on's own status.

### Dev-branch provider lane builds on a dev push

- `.github/workflows/release-dev-branch.yml` now starts on a push to the `dev` branch, with the same `paths:` list as the master push of `release-swift.yml`. Dev builds dev, and master builds master; no workflow dispatches a build of another branch.
- The lane is a caller of the reusable `release-provider.yml` with `environment: dev` and `secrets: inherit`. A dev-branch build is built, signed with the Developer ID, notarized and stapled like a master build, so the installer and the provider self-updater accept it. The version stays `X.Y.Z-dev.branch.<run>`. The ad-hoc build and signing path of the lane is removed.
- The lane has no `workflow_dispatch` and no `ref` input. Its job checks `refs/heads/dev`. It runs only after master's release source gate accepts a `dev` push for environment `dev`.

### GPT-OSS stop sequences apply to the answer only

- A client `stop` sequence on GPT-OSS models such as `gpt-oss-20b` now
  matches only the Harmony `final` message, the text returned as `content`.
  It used to match the private analysis too, so a sequence that appeared
  while the model reasoned (for example `"\n\n"` or `"."`) ended the request
  before any answer: `finish_reason` `stop`, reasoning only, empty content.
  Tool-call arguments are never cut either. Other models keep whole-output
  matching.

### Master release lane publishes no dev release

- A push to `master` no longer publishes a dev release to DevNet. `.github/workflows/release-swift.yml` routes a master push to the `staging` lane only, which still runs only when the `STAGING_ENABLED` repository variable is `true`. A `vX.Y.Z` tag still publishes production.
- The `release-swift.yml` dispatch has no `dev` environment choice. `validation_only=true` runs the `dev` lane as a signed validation build that is never published, in place of the chosen environment.
- `scripts/resolve-provider-release.sh` refuses a dev publication from `master` and a master push routed to dev. DevNet gets its provider releases from the d-inference `dev` branch through `.github/workflows/release-dev-branch.yml`.
- The source gate on `master` (`verify_workflow_source`) admits a push to `dev` for the `dev` environment only, and only for a GitHub-verified commit on `dev` ancestry. The resolver stamps that build `X.Y.Z-dev.branch.N`. A dev push routed to staging or prod and a push from any other branch are refused. The tag and master checks are unchanged.
- `build-and-release` checks the final archived app against the self-updater's designated requirement (Apple anchor, `io.darkbloom.provider`, team `SLDQ2GJ6TL`) before upload.

### Model download cancellation

- Fix a hang when a model download is cancelled before its completion waiter is attached. Keep the cancellation result until the waiter can receive it, preserving partial files for a later resume.

### Faster model weight verification

- Weight hashes read each file on a separate thread one 4 MiB chunk ahead of
  SHA-256, so the uncached reads added for Nemotron Super no longer leave the
  hash waiting on the disk. Every full hash gets faster: startup registration,
  download and prefetch verification, and the fresh hashes before and after
  each load of a model with SSD prefix caching. On an M3 Ultra a full hash of
  `EigenLabs/Qwen3.8-27B-4bit-mtp` takes 2.9 s instead of 4.7 s, with the same
  digest. Weights still bypass the file cache, and the digests are unchanged.

### Prompt-token cache batch hits

- Preserve all prompt-token cache hits present at the start of a request's batch lookup, avoiding unnecessary re-tokenization when promoting an earlier hit rotates the cache generations.

### Drop disconnected response chunks before reconnect

- Drop response frames processed by the chunk queue while no connection is
  bound, so their deferred flush cannot deliver them to a replacement session.

### Faster coordinator reconnect

- A coordinator session that stayed open for 60 seconds or more resets the reconnect backoff. When such a session drops, the provider connects again after the shortest wait (0.5 to 1 second), not after a wait of up to 30 seconds that earlier drops grew.
- When the coordinator side closes the socket with WebSocket code 1012 (service restart), the provider connects again after a random wait of 0 to 1 second. This close does not grow the backoff.
- Other close codes, closes without a code and failed attempts keep the exponential backoff. Registration, attestation and the cancellation of the old connection's requests do not change.

### Release qualification uses production defaults on every branch

The SDK 27 qualification job of the provider release names `DARKBLOOM_RELEASE_ENVIRONMENT: prod`, so its tests see production defaults on the `dev` branch too. The first signed dev build (run 40783649415) failed there because the tests compiled the dev identity.

### Dense Qwen conversations restore almost all of the previous turn

- A dense Qwen 3.5/3.8 request served alone prefills in 4,096-token stripes,
  so its deepest SSD checkpoint was the last full stripe end, up to 4,095
  tokens before the prompt end. The next turn of the conversation
  re-prefilled that gap. Such a request now also ends a prefill range just
  below its prompt end (at least 64 tokens before it, on the 256-token grid)
  when that saves at least 1,024 tokens, and the next turn restores from
  there. In a six-turn conversation from 30K to 55K tokens on Qwen3.5-9B (M3
  Ultra), the summed time to first token of the five follow-up turns fell
  from 57.4 s to 47.9 s, with identical outputs. Busy providers, which
  prefill in 512-token chunks beside decoding requests, and the short-prompt
  fork checkpoint are unchanged.

### Qwen 3.5/3.6 stop looping to max_tokens

- Requests that omit sampling fields now use the model cards' thinking-mode values (temperature 1.0, top_p 0.95, top_k 20, presence_penalty 1.5) on the catalog Qwen3.5-9B, Qwen3.5-35B-A3B and Qwen3.6-35B-A3B builds instead of greedy decoding. On 20 prompts, runaway repetition fell from 7 to 0 (9B), 8 to 0 (3.5 35B) and 3 to 0 (3.6 35B). Explicit request values still win.

### Concurrent SSD restores of one checkpoint

- Requests that restore the same complete checkpoint from SSD now read the file together instead of one at a time. In a CPU-only probe with a 1 GiB checkpoint already in the page cache, the last of eight concurrent restores finished after 0.70–0.78 s instead of 2.70–2.84 s; a single restore is unchanged at 0.35 s.
- A restore rewrites the checkpoint file's modification time only while no other request holds the file, and at most once per `ttlSeconds / 30` (one minute at the default TTL). Requests that restored a checkpoint and then donate the same boundary keep their authenticated receipts instead of re-reading the whole file, which three of four did in a burst of four.
- Writers, duplicate validation and maintenance still hold the file alone, and a queued writer goes before readers that arrive after it. When every restore of a checkpoint overlaps another, as with repeated simultaneous bursts, none refreshes its modification time. Whole-root TTL maintenance therefore checks the loaded cache's own record of the last restore before deleting a file: one restored within the TTL stays, and that restore becomes its modification time. A provider restart in the minute before the next maintenance pass can still drop such a file, and whole-root disk-budget eviction still orders files by modification time.

### Select SSD eviction victims without sorting the whole index first

- Attention-block and complete-checkpoint caches retire the least recently used
  file found by one linear index scan. Only when that file is busy or cannot be
  deleted do they copy the index into a snapshot that yields newer candidates
  oldest-first on demand, instead of sorting every entry up front. For an index
  that does not change during eviction, victims are chosen in the same order as
  before. The pass past busy or undeletable files stays bounded, and
  external-removal reconciliation still returns control to the disk budget
  before another file is removed.
- A store that is closed, or that closes during an eviction pass, ends the
  pass instead of refusing every remaining candidate in turn. It frees
  nothing either way, and other stores are still evicted.

### Attention-block SSD donations write about five times faster

- GPT-OSS and Gemma write one SSD cache file per 256-token block, and each
  block's daily write-budget charge rewrote the shared ledger with a full
  flush. A donation of several blocks now reserves their summed size in one
  charge before its first write. Measured with 64-block donations on an M3
  Ultra (debug build), a donation took 73-78 ms instead of 412-445 ms with 1
  MiB blocks, and 114-118 ms instead of 502-518 ms with 4 MiB blocks.
  Another model's writes are also refused far less often while a donation is
  in flight: when two models donated 64 blocks each at the same moment, 10%
  of the blocks were refused instead of 49%. Charges still precede writes
  and are never refunded, and near the daily cap the leading blocks that fit
  are still written.

### Faster SSD cache maintenance after each checkpoint write

- After every checkpoint or attention-block write, cache maintenance walks the
  whole SSD cache root to enforce its TTL and disk budget. It used to open and
  parse the header of every cache file on each pass. It now remembers each
  readable header until the file changes, so a pass parses only new, changed
  or unreadable headers. With 5,000 cache files a pass falls from 1.84 s to
  0.16 s (debug build, M3 Ultra). TTL, budget and ownership decisions are
  unchanged.

### SSD cache reads skip a copy of each encrypted chunk

- Reading an SSD cache file keeps each encrypted chunk in the buffer it was
  read into instead of copying it into a second one, when one read returns the
  whole chunk, as it usually does from a local file. Reading and decrypting a
  512 MiB file of 4 MiB chunks from a warm page cache took a median 136 ms
  instead of 146 ms on an M3 Ultra (debug build), and a chunk occupies one
  buffer instead of two while it is read.

### Cache hits no longer wait for a whole SSD cache sweep

- A TTL or disk-budget sweep removed its whole batch of cache files while
  holding the locks that a cache-hit lookup on the engine's submit thread
  and a donor's index publication also take. Sweeping 2,000 files in a debug
  build on an M3 Ultra held them for about a second. A sweep now removes 16
  files per hold and rechecks ownership each time, so those waits stayed at
  30 ms or less in the same measurement (28.4 ms at worst), while the sweep
  itself took up to 12% longer in the background.

### Expired checkpoints no longer count as corrupt after a restart

- When a provider restarted more than 30 minutes after its last cache use,
  the complete-checkpoint store removed each expired file through the
  corrupt-file path, so every one was reported in `corrupt_drops_total`.
  Expired files are still removed at startup, but they are no longer counted
  as corrupt, so that counter now reports only files that failed validation.

## v0.10.4

Published 2026-10-28 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.10.4)).

### Upgrade and rollout notes

- Deploy a coordinator that includes [darkbloom-platform#516](https://github.com/Layr-Labs/darkbloom-platform/pull/516) close to this rollout. For a Qwen 3.5, 3.6 or 3.8 request with a JSON `response_format` and no thinking control, a 0.10.4 provider renders the no-thinking prompt, and #516's prompt sidecar plans the same prompt. While a provider and the coordinator disagree (a 0.10.4 provider behind a coordinator without #516, or a 0.10.3 provider behind one with it), those requests' cache receipts fail with `prompt_anchor_mismatch`, and each failure quarantines that provider's cache affinity for the whole model for up to 10 minutes; every request is still served.
- Clients see the Qwen JSON changes: a JSON request without a thinking control answers without reasoning. On `qwen3_5` and `qwen3_5_moe` text requests without tools the answer is grammar-constrained, so an output budget or `stop` string that cuts the JSON value short now ends in a 422 `tool_noncompliance` after the content streamed, instead of a successful truncated answer. While a constrained request decodes, no request in the same decode step speculates with MTP.
- On 0.10.4, Qwen3.5-9B, Qwen3.5-35B-A3B, Qwen3.6-35B-A3B and MiMo-V2.6-Flash providers advertise forced `tool_choice` (`required` and named functions) in `tool_constraint_models`. Coordinators send forced tool choice only to providers that advertise it, so 0.10.3 providers never receive these requests and no provider-version floor is needed. Until an updated provider of the model is online, the coordinator keeps refusing such requests with 400.
- Delta complete checkpoints need no migration and are safe to roll back. Complete checkpoints are stored per provider build, because their namespace binds the binary and loaded-metallib hashes: an updated provider starts with cold complete checkpoints, as after any update, and a provider rolled back to 0.10.3 never restores a 0.10.4 file. A 0.10.3 reader also refuses a delta file as incompatible. `DARKBLOOM_PREFIX_CACHE_SSD_INCREMENTAL_CHECKPOINTS=0` writes complete files again; it is forwarded to the launchd provider job, and like other forwarded settings it takes effect at the next `darkbloom start` (`restart`, updates and watchdog recovery reuse the saved environment).
- A connected provider that the coordinator has not authorized for 15–30 minutes re-registers once it is idle, then again after 30 minutes, 1 hour, 2 hours and every 4 hours while it stays unauthorized. Each re-registration starts a new coordinator verification session. A fleet that loses authorization at once, as in an Apple or coordinator outage, spreads its first re-registrations over 15 minutes. Only current evidence counts: an untrusted or offline status, an expired App Attest lease, no status 90 seconds after connecting, or a refusal received in the last 60 seconds. An older refusal shows as `unconfirmed` and never triggers re-registration, a legacy (MDM) verdict counts as authorized whatever its age, and a coordinator request that arrives after the latest status counts as routed.
- Deploy a coordinator that includes [darkbloom-platform#491](https://github.com/Layr-Labs/darkbloom-platform/pull/491) and [darkbloom-platform#541](https://github.com/Layr-Labs/darkbloom-platform/pull/541) before this rollout. #491 repeats a refusal every 5 seconds while App Attest serving is on, so `Traffic:` names the cause and re-registration can act on it; #541 tells a legacy Mac when its first passing challenge authorizes it. Behind an older coordinator, a refused App Attest Mac shows `unconfirmed` most of the time and is not re-registered, and a legacy Mac that verified after registering shows `unconfirmed` instead of eligible until it receives a request; both are still served or refused exactly as the coordinator decides.
- `darkbloom status` changes its served-requests line (see "Status says which requests the served count covers"). Scripts that match the literal `Requests served:` or read a fixed word position need updating.
- Only the signed Darkbloom Sandbox add-on (`io.darkbloom.sandbox`, team `SLDQ2GJ6TL`) or an operator running `darkbloom addon hold` can hold a provider; other Macs are unchanged. The coordinator side, [darkbloom-platform#514](https://github.com/Layr-Labs/darkbloom-platform/pull/514), is already in production: a held Mac stays connected, leaves supply, earns no uptime or reward credit while held and shows as busy.
- `libs/mlx-swift` (`4926d3d9`), `libs/mlx` and the nested `mlx` (`31f550af`) and `libs/mlx-swift-lm` (`aee6ebb6`) are unchanged from 0.10.3, so no Metal kernel source changes.
- The desktop app (#1615, #1617), CI (#1619, #1631), landing site (#1599) and documentation (#1602) entries below change no provider artifact; the desktop app ships through its own `desktop-vX.Y.Z` releases. #1599 is already in the `v0.10.2` tag and #1615 in `v0.10.3`, releases that left their notes pending.

### Operator check for a missing base reward

- New provider how-to for a $0 `model=base_reward` period while `doctor` is green: console last-1000 check, last-public floor snapshot (not deployed policy), and `darkbloom report` without pasting hostnames or tokens into a public issue.
- `doctor` billing remains local usage reporting. It still does not name a coordinator skip or ranking reason.

### CI can run read-only jobs on Darkbloom Sandboxes

- A route job chooses a Darkbloom Sandbox or the existing Blacksmith runner for each read-only CI job. Routing stays off until the repository variable `DARKBLOOM_ROUTING` is `on`; plane errors, timeouts and unexpected replies keep the Blacksmith runner.
- Release, signing, publication and credentialed jobs, and `master` cache warming, stay on Blacksmith. The component classifier and the `Provider Tests` gate run on GitHub-hosted `ubuntu-24.04`, and routed jobs have job-level timeouts.

### Console tooling removed with the console source

- The console source now lives only in darkbloom-platform; #1625 removed this repository's `console-ui/` snapshot. The tooling that still pointed at it is removed too: the `Console UI Lint & Build` CI job and its `console` change lane, the `make ui-install`, `ui-lint`, `ui-test`, `ui-build` and `ui` targets (`make test` and `make build` no longer run them), the console-only `.githooks` pre-commit and pre-push hooks, the `/console-ui` Dependabot entry, and the console tests' copies of `paged_footprint_wire.json` and `process_memory_wire.json` under `coordinator/tests/protocol/testdata/`. Provider tests keep their own copies of those fixtures.
- The console architecture page and the console section of the configuration reference are removed; console architecture and configuration are documented in darkbloom-platform.

### Providers recover from a stalled coordinator reconnect

- A coordinator connection whose TLS handshake or WebSocket upgrade never completes now fails after 30 seconds and retries with the usual backoff. Before, a reconnect that stalled this way (for example while the coordinator restarted) waited indefinitely: the provider kept showing `Trust: awaiting coordinator status`, received no requests and recovered only after its process restarted.
- `darkbloom stop`, `restart` and `start` now drain gracefully when the provider has no registered coordinator session and no unfinished requests, and report the coordinator acknowledgement as not needed. Before, they failed with `coordinator acknowledgement false`, left the provider draining (refusing work, with automatic restart disabled) and required `--force`.

### Say why a connected provider gets no coordinator work

- `darkbloom status` adds a `Traffic:` line and `darkbloom doctor` a `coordinator traffic` check. Either the coordinator can route work to this connection, or the line says why it cannot, with a fix: not connected; no coordinator verdict minutes after connecting (previously only `Trust: awaiting coordinator status`); an `untrusted` or `offline` status; App Attest authorization expired and not renewed; or the coordinator's reason for not authorizing it. Reasons include a locked login keychain, a stalled Apple App Attest call, App Attest unavailable on macOS 26 or outside a logged-in GUI session, and a connection without a linked account (`darkbloom login`). A connected Mac with a warm model no longer looks healthy while it receives nothing. Neither appears while an add-on holds the connected Mac: the hold, which `darkbloom status` reports on its own `Not serving:` line, is why no work arrives, not the connection's authorization.
- Only current evidence says a connection gets no work. A refusal counts while it is at most 60 seconds old, as when the coordinator keeps repeating it, and not in the first 90 seconds after connecting. An older refusal reads `unconfirmed`, with its age and reason and no fix: the current coordinator sends no status when legacy verification authorizes a connection after the refusal it sends at registration, so legacy-verified Macs are never told they are excluded or need macOS 27. A request the coordinator routed after its latest status reads as eligible.
- The daemon state file records the coordinator connection (`coordinator_connection`: connected, since when it has been up or down, the registrations since the provider started, and `last_request_at`, when the coordinator last sent the connection a request). Failed reconnect attempts do not reset the time, so a long outage reads as one.
- The provider now re-registers a connection the coordinator keeps refusing for 15–30 minutes (a random delay per process), then again after 30 minutes, 1 hour, 2 hours and every 4 hours while the refusal stays current. A refusal sent once at registration never triggers it. It waits until the provider is idle: no accepted or local requests, model loads, Autopilot operation, drain or update. A new registration starts a new coordinator verification session, which clears coordinator states that previously needed a restart, such as verification that stopped after an unclassified failure or waits out an hourly retry. `darkbloom logs` shows when the coordinator starts refusing the connection, when it authorizes it, when its refusal is no longer current, and each re-registration.

### Delta complete checkpoints

- A request that restored a Qwen complete checkpoint with native recurrent state (`native-paged-full-recurrent-v1` or `native-contiguous-full-recurrent-v1`) now writes its later checkpoints as deltas: only the rows the restored file lacks, plus the recurrent state. On a six-turn 30K–55K-token conversation, checkpoint writes fell from 20.0 GB to 5.4 GB with identical outputs and unchanged TTFT on both layouts, so the daily write cap lasts about four times longer. `DARKBLOOM_PREFIX_CACHE_SSD_INCREMENTAL_CHECKPOINTS=0` restores complete files. It also reaches the background provider: `darkbloom start` copies it into the launchd job, and `darkbloom restart` keeps the saved environment.

### Desktop release signs the DMG

The desktop release workflow now signs the DMG with the Eigen Labs Developer ID
before notarizing it. The first dry run built, signed and notarized the app, but
Gatekeeper rejected the unsigned DMG (`source=no usable signature`).

### Desktop app updates itself

Desktop releases now embed an update feed: Release `desktop-latest`, whose
assets each `desktop-vX.Y.Z` release replaces with its zip, blockmap,
`latest-mac.yml` and a version-less `Darkbloom-arm64.dmg`. Installed apps check
it at launch and every 4 hours, download in the background and install on quit.
A release build without a feed is refused, since the feed is fixed at build
time. The workflow verifies the embedded feed URL and that `latest-mac.yml`
matches the published files.

### Forced tool calls on Qwen 3.5, Qwen 3.6 and MiMo

- Qwen3.5-9B, Qwen3.5-35B-A3B, Qwen3.6-35B-A3B and MiMo-V2.6-Flash now
  advertise `tool_choice` `required` and named-function support, so the
  coordinator routes those requests to them instead of rejecting them with
  HTTP 400. Calls stay withheld until they parse and match the declared
  schema.
- A forced call on Qwen 3.5-family models (including Qwen3.8-27B) no longer
  fails when the model writes a newline between parallel calls or around a
  call. Any other text still fails the request.

### JSON response formats answer without Qwen thinking

- A chat request with a JSON `response_format` (`json_object` or `json_schema`)
  on the Qwen 3.5, 3.6 and 3.8 template family now renders the no-thinking
  prompt unless the caller supplies a thinking control (`reasoning.enabled`,
  `enable_thinking`, `chat_template_kwargs.enable_thinking`, any reasoning
  effort or a positive `reasoning.max_tokens` budget). The templates think by
  default, and the reasoning block regularly spent the caller's `max_tokens`
  before the JSON answer began: on Qwen3.5-9B, 47-79% of JSON requests with a
  2,048-token budget returned empty content.
- The coordinator prompt sidecar must mirror this rule for cache planning; the
  regenerated public prompt vectors change only the Qwen-family JSON cases.
- On `qwen3_5` and `qwen3_5_moe` text requests without tools or `tool_choice`,
  the JSON answer is now grammar-constrained, as on exact Flint: only one JSON
  value of the schema's shared compiled subset can be sampled, with declared
  properties as its only keys, and the end-of-turn token is masked until the
  value is complete. With the instruction alone, about 7-9% of Qwen3.5-9B
  answers broke the schema (a near-miss key, a string for an integer, prose).
  A budget that ends first, or a `stop` string that cuts the value short, is
  now a 422 `tool_noncompliance` after the content streamed, instead of a
  successful truncated answer. The prompt is unchanged, so the sidecar needs no
  new rule.
- Schemas outside the subset, tools or `tool_choice` beside the format, image
  or video input and tokenizers that fail the pinned vocabulary checks keep the
  prompt-only behavior; none of them is newly refused. While a constrained row
  decodes, other rows in the same decode step do not speculate with MTP, as
  with a `stop`, logprob or penalty row today.
- A constrained request that omits `max_tokens` no longer fails with "Response
  generation failed". Token constraints were sized with the scheduler's default
  while the engine used the bridge's model-derived default, and the engine
  refuses a mismatched budget. This also fixes Flint requests without
  `max_tokens` on the local endpoint; coordinator traffic always carries one.

### Developer and contact guidance stays in agent documents

- Remove Developers and Contact HTML pages, footer links and XML sitemap entries. Human-facing API links use the official documentation.
- Preserve explicit and negotiated Markdown guidance, with direct document links from the agent index and other Markdown resources.

### Add-on hold hardening

- A model load already running when an add-on hold begins, such as a local
  request's cold load, no longer installs its model afterwards. No load starts
  while held, a running one ends with a retryable 503, and the hold reports
  `held` only once it has unwound.
- Releasing a hold while its 120-second bound is cancelling leftover requests
  no longer cancels or loses track of work accepted after the release.
- A hold that unloads a native MiMo or Nemotron Super model keeps
  `loaded-models.json`, so the next start still preloads it.
- The add-on socket verifies a connection's signer before the connection takes
  one of its 8 slots, so unsigned programs cannot keep the add-on out, and a
  request line must finish within 10 seconds.
- The hold record and `darkbloom addon` mailbox files are read without blocking:
  a FIFO at their paths is refused instead of stalling the provider.

### Reversible add-on hold

- A signed local add-on, such as the Darkbloom Sandbox, can hold the provider
  through the owner-only socket `~/.darkbloom/runtime/addon.sock` while its VMs
  run. The provider stays connected, reports `status: draining` with
  `busy_reason`, `busy_since_ms` and `busy_addon`, lets accepted work finish
  (up to 120 seconds), then unloads every model. Release returns it to routing
  on the same connection.
- Holds have 30–600 second leases. An expired lease ends the hold only when the
  add-on no longer holds `ownership.lock`, and a restarted or updated provider
  comes back held without loading models.
- Updates and Autopilot operations wait for the hold, and reconnects keep it;
  Autopilot reports `addon_hold`. `darkbloom addon status|hold|release`
  inspects or overrides holds for debugging, and `darkbloom status` shows an
  active hold.
- Coordinator handling of the busy fields ships separately; older coordinators
  still stop routing on the draining status.

### Status says which requests the served count covers

- `darkbloom status` now prints `Requests served since the daemon started (… ago): N | output tokens: M` instead of `Requests served: N | tokens: M` with no window. The count restarts with the daemon and includes requests that ended early on a coordinator cancel or a dropped connection, which the coordinator may not pay for, and free requests to your own machine. Status prints how many ended early and points to the console's Earnings page for paid jobs.
- The line still starts with `Requests served` and keeps `|` between the two counts. A script that matches the literal `Requests served:` or reads a fixed word position needs updating.
- `darkbloom doctor` describes the same counts as completed since the daemon started rather than "reported this session".
- The daemon state file records `cancellations_partial_complete` beside the served totals.

### Live model switch with a custom model cache

- `darkbloom switch` now scans the `model_cache_directory` set in `provider.toml`. With a non-default directory it previously rejected every local model as missing or unsupported, and its picker listed installed models as downloads, although the running provider served them from that directory.

## v0.10.3

Published 2026-10-26 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.10.3)).

### M5 providers no longer crash on long Gemma 4 and Qwen prompts

- Provider 0.10.2 exits with `Trace/BPT trap: 5` on Macs with an M5 or newer GPU when one attention call covers at least 1,024 prompt tokens on a model with 256- or 512-wide attention heads: Gemma 4 26B, Qwen3.5-9B, Qwen3.5-35B, Qwen3.6-35B and Qwen3.8-27B. Its log shows `Unable to build metal library from source`, naming the `attention_nax_dsplit` kernel. Other Macs and other models are not affected.
- MLX compiles that kernel at runtime on these GPUs. The upstream MLX merge in 0.10.2 passed it a value head-dim argument it does not take, so the compile always failed and MLX's error stopped the provider.
- `libs/mlx-swift` moves from `eedca444` to `4926d3d9`, and `libs/mlx` and the nested `mlx` move from `ff4bb35b` to `31f550af`: 0.10.2's MLX with the kernel's arguments corrected. `libs/mlx-swift-lm` stays at `aee6ebb6`, and nothing else changes from 0.10.2.
- A provider that keeps crashing installs 0.10.3 when its watchdog next restarts it, about five minutes after a crash, if automatic updates are on. Otherwise run `darkbloom update`.
- The crash loop can trip the KV-backend guard: `darkbloom status` shows `KV-backend guard: ACTIVE`, tripped on v0.10.2, and the provider uses the contiguous backend and refuses packed `balanced`, `k8v4` and `k8v8` KV. The guard binds only the version that tripped it, so it clears when 0.10.3 starts. Clearing it on 0.10.2 does not help, because the crash is not in the KV backend.

## v0.10.2

Published 2026-10-26 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.10.2)).

### Upgrade and rollout notes

- Logprobs on Nemotron 3.5 Super and GLM-5.3-Flash reach coordinator requests only once the model's catalog row lists `logprobs`. List them only behind a coordinator that includes [darkbloom-platform#464](https://github.com/Layr-Labs/darkbloom-platform/pull/464), which sends a logprob request on either model only to providers on 0.10.2 or later, and only after the fleet has converged on this release.
- Prefix caching through the coordinator applies to a model only once its `(model_id, model_aggregate_sha256, prompt_contract_id)` tuple is on the coordinator's cache-routing allowlist (`EIGENINFERENCE_CACHE_ROUTING_ALLOWED_ARTIFACTS`); until then the coordinator sends the model no cache scope and its requests run cold. Add Nemotron 3.5 Super's tuple, and then list `logprobs` on its catalog row, only after the fleet has converged on this release and a signed 0.10.2 build has restored Super's SSD checkpoints after a restart. GLM-5.3-Flash's tuple does not depend on this release, and the 4-bit checkpoints change neither tuple.
- Nemotron 3.5 Super and GLM-5.3-Flash now write 4-bit `balanced` SSD checkpoints by default, under new cache namespaces: each provider's existing exact SSD files for these models miss once after updating, then age out through the normal TTL sweep. A request served from a 4-bit checkpoint is not bit-identical to the same request served without the cache: chosen-token logprobs differed by at most 0.005 nats on Nemotron 3.5 Super and 0.4 nats on GLM-5.3-Flash in qualification, `top_logprobs` alternatives can differ more, and in rare cases the generated text diverges slightly. `native` restores the exact state. To keep exact checkpoints without a code change, set `engine_v2_kv_checkpoint_quantization_by_model = { "<model id>" = "native" }` in the provider configuration, or `DARKBLOOM_CBV2_CHECKPOINT_QUANTIZATION=native` for every model; GLM-5.3-Flash's exact checkpoints use #1587's BF16 layout, which also starts cold once. Nemotron 3.5 Super no longer reserves its 16 GiB resident prefix bank by default.
- A provider keeps its 0.10.1 behaviour until it updates: Nemotron 3.5 Super advertises no prefix cache and refuses logprobs with 400, and GLM-5.3-Flash refuses `reasoning.context`, `reasoning.mode`, hidden reasoning (`reasoning.exclude: true`, `include_reasoning: false`), Anthropic's `thinking` object and a null `reasoning_effort` with 400. The coordinator forwards these controls unchanged, so until the fleet converges such a GLM request fails on a 0.10.1 provider; it is planned for cache routing only behind a coordinator that includes darkbloom-platform#464. A 0.10.1 GLM-5.3-Flash provider also still refuses with 400 a `json_schema` with keywords outside its grammar subset, a JSON `response_format` beside tools, a tool result whose `name` differs from its call and a legacy `function_call` history, and a 0.10.1 MiMo-V2.6-Flash provider a tool result whose `name` differs from its call. A 0.10.1 GLM provider puts the reasoning tokens' entries on its first answer chunk, keeping at most 4,096, and returns none for a reply that ends while the model is still reasoning, so darkbloom-platform#464's `0.10.2` floor keeps GLM logprob requests away from it.
- Operators can see why an updated provider refused a request: `darkbloom logs` names a fixed reason for each refusal before inference and for client errors found while a GLM-5.3-Flash prompt is prepared, for example `Inference failure: invalid request (unanswered tool call)`. A load refused for memory names each resident model it could not evict and why, and `darkbloom status` shows models served outside the enabled model filter, Autopilot placement holds with their expiry and what a load cannot evict now.
- The MLX stack moves to the 2026-10-22 upstream sync, so the release metallib changes and each provider compiles its kernels again on the first start after updating.
- `libs/mlx-swift-lm` moves from `6148b6da` to `aee6ebb6` for these changes: Nemotron 3.5 Super logprobs and complete checkpoints, GLM-5.3-Flash checkpoint layout v2 and capture under load, standard 4-bit `balanced` checkpoints for both models (mlx-swift-lm#363), Super speculation for sampled requests (mlx-swift-lm#357), the decode-step-aware first-token projection (mlx-swift-lm#359), the Super FP8 first-token stall fix (mlx-swift-lm#360), and faster GLM long-context decode (mlx-swift-lm#362). With them come SDK `main`'s merge of upstream ml-explore/mlx-swift-lm `d02948b9` (2026-10-22; mlx-swift-lm#339 with mlx-swift-lm#348 and mlx-swift-lm#349) and mlx-swift-lm#358's mlx-swift pin. `libs/mlx-swift` moves from `67dc7528` to `eedca444`, which keys compiled traces by the task's default stream. With it, `libs/mlx` and the nested `mlx` move from `ad4745a2` to `ff4bb35b`: the fork's merge of upstream ml-explore/mlx `afc03c51` (2026-10-23), plus two fork fixes. One computes float16 and bfloat16 floor division in float32; the other erases a freed compiled closure from every thread's compile cache. These changes touch 56 Metal kernel source files, and the release metallib is rebuilt from them. The SDK's inline Metal kernels for Nemotron 3.5 Super, GLM-5.3-Flash and MiMo V2.6 now compute their sigmoid's exponential with `metal::precise::exp`, as MLX's own sigmoid does. The SDK's only other native change is a vendored xgrammar C++ library, which is not linked into the provider. The provider builds the SDK without its `FoundationModelsIntegration` trait, so the binary links neither xgrammar nor Apple's FoundationModels framework, and its libraries and static initializers are the same as 0.10.1's. The provider's adaptation to the merged SDK API leaves request behaviour unchanged. The SDK and provider test suites pass on the new pins, as do checks of Nemotron 3.5 Super and GLM-5.3-Flash on real checkpoints: correct answers from a cache hit, logprobs, and decode speed.

### Nemotron Super prefix-cache routing

- The managed Nemotron 3.5 Super slot advertises its prefix cache to the coordinator (`prefix_cache_v2_models` for its default SSD checkpoints, `prefix_cache_memory_models` for the opt-in resident bank), bound to the aggregate the provider published for the loaded checkpoint and the checkpoint's prompt-contract identity. Coordinator requests on Super now send lookup and ready receipts and report reused prompt tokens (`prompt_tokens_details.cached_tokens` and `inference_complete` cache usage), so cache-aware routing and cache-read pricing apply to Super once the coordinator's cache-routing allowlist lists its tuple. Previously the coordinator never sent Super a cache scope, so its reserved bank served no coordinator request.
- The local endpoint reports Super's reused prompt tokens instead of always `0`.

### Nemotron Super durable prefix checkpoints

- The managed Nemotron 3.5 Super slot keeps its exact text prefix reuse as complete encrypted SSD checkpoints by default, like the other cache-enabled models: KV, Mamba conv/SSM state and the MTP assistant's prompt history, with older attention rows 4-bit coded under the default `balanced` checkpoint profile and all of it at native precision under `native` (see "Balanced SSD checkpoints for Nemotron Super and GLM-5.3-Flash"), bound to the published artifact and prompt-contract identity. Checkpoints survive provider restarts within the store's TTL, the slot advertises a durable capability (`prefix_cache_v2_models`) so the coordinator can keep durable holders, and the coordinator's repeat hint gates writes against the daily SSD write budget. The 16 GiB resident bank is no longer reserved by default; `DARKBLOOM_PREFIX_CACHE_MEMORY=1` selects it instead (it remains the only tier that reuses image turns), and `DARKBLOOM_PREFIX_CACHE=0` turns both off.

### Half-size exact GLM SSD checkpoints (the `native` fallback)

- GLM-5.3-Flash SSD checkpoints are 4-bit `balanced` by default (see "Balanced SSD checkpoints for Nemotron Super and GLM-5.3-Flash"). Exact complete checkpoints, which `native` selects, now write the latent keys, the index/gate/validity rows and the KDA convolution history at their BF16 activation dtype instead of the FP32 copies the live pool keeps, and widen them back to the same FP32 bits on restore. The accumulated KDA recurrent state stays FP32. A 30,720-token checkpoint drops from 1.24 GB to 0.72 GB (per token 35.4 KB → 18.5 KB), so each donation queues, writes and charges the daily SSD write budget for 18-48 % fewer bytes, a restore stages about 25 % faster on an M5 Ultra, and prompts up to the full 262K context fit the large-memory staging cap.
- Restores also validate the GLM validity flags by visiting only that column (one element in 257) instead of every element, about 50 ms less per 30,720-token restore.
- The export refuses any value BF16 cannot represent exactly, so a restore is never lossy. The exact layout is now `native-paged-glm5next-full-state-v2` and the default 4-bit one `native-paged-glm5next-affine-checkpoint-full-state-v1`; existing v1 files sit in a different namespace from both and expire through the normal TTL sweep. Providers lose their warm GLM checkpoints once on upgrade.

### GLM prefix checkpoints under load

- GLM-5.3-Flash now captures a repeated prompt's checkpoints while other requests are decoding. Their decode tokens shortened every prefill chunk below 2,048, so no chunk ended on the 256-token checkpoint grid and the donor was silently not cached (one of six donors in a concurrent burst on an M5 Ultra). A donor the cache will write now ends a prefill range at its demanded boundaries whatever its company; in the same burst six of six were captured and written.
- GLM checkpoints now land on any 256-token boundary instead of every 2,048: a 32,682-token prompt restores 32,512 tokens instead of 30,720 (hit time to first token 3.1–3.7 s, was about 4.0 s).
- A GLM cache hit served beside decoding requests no longer waits for a full 2,048-token chunk and cold-restarts after three waits; it resumes under ordinary chunking.

### Realistic GLM restore estimates in cache receipts

- A complete-checkpoint ready receipt now advertises what a restore of the file actually costs on this provider, not only its read time at the 1.5 GB/s planning rate. GLM-5.3-Flash restores take about 0.9 s beyond their bytes on an M5 Ultra, so the old estimate was 11–43% of the measured stage (478 ms for a 716 MB checkpoint that restores in 1.1–1.4 s; 125 ms for a 187 MB one that takes 1.0–1.1 s). The estimate now adds a running average of the store's own measured restores beyond their byte price, starting from the measured GLM value (zero for other models' checkpoints), so the coordinator no longer overstates the saving of short cached GLM prompts.

### Balanced SSD checkpoints for Nemotron Super and GLM-5.3-Flash

- Nemotron 3.5 Super and GLM-5.3-Flash now follow the provider's checkpoint precision setting (`engine_v2_kv_checkpoint_quantization`, default `balanced`, its per-model table and `DARKBLOOM_CBV2_CHECKPOINT_QUANTIZATION`) like the other cache-enabled models, instead of always writing exact checkpoints. Their MTP assistants' prompt history now stays exact beside the coded rows, as recurrent state already did, so the MTP head no longer forces native storage for these two models.
- Super codes only older attention rows; the Mamba conv/SSM state, the MTP history and the newest 128 rows stay exact. On an M3 Ultra its 30,720-token checkpoint drops from 457 MB to 285 MB (8,192 tokens: 250 → 204 MB). Restored answers matched the cold answers token for token in qualification, at 0.03–0.46 s more restore time than exact checkpoints and still 5–20× faster than recomputing.
- GLM codes only older latent rows; the index/gate/validity rows, KDA state, MTP history and the newest 128 rows stay exact. On an M5 Ultra its 32,768-token checkpoint drops from 754 MB to 502 MB (8,192 tokens: 301 → 238 MB). Restores answered as correctly as exact checkpoints in qualification but take longer to stage (CPU decode; 2.2 s instead of 0.5 s at 32,768 tokens, against 15.9 s to recompute), and each donation spends more CPU encoding in the background write.
- New layouts (`native-paged-affine-checkpoint-full-recurrent-mtp-v1`, `native-paged-glm5next-affine-checkpoint-full-state-v1`) use their own cache namespace, so existing exact checkpoints for these two models miss once and expire through the normal TTL sweep. Set the per-model table entry or `DARKBLOOM_CBV2_CHECKPOINT_QUANTIZATION` to `native` to keep exact checkpoints.

### Deeper SSD prefix-cache write queue

- Both SSD prefix-cache writers now hold up to six donations (`writeQueueMaxJobs = 6`, was 2) before dropping a new one as `write_queue_full`. More of the prefixes donated while the single SSD writer is busy are now written, so later requests can reuse them instead of recomputing them.
- Memory stays within the existing bounds: queued attention blocks must still fit the unchanged queued-byte cap (1,280 MiB at the default stage cap), and a queued complete checkpoint keeps its donor state and I/O scratch charged to the engine admission or process memory ledger, as before.
- A request that donates complete checkpoints ends its stream and releases its KV memory only after they are written or refused. Under a write backlog each of them can now wait behind up to five other checkpoints instead of one, and up to six donors (was two) can wait at once, each still holding its KV memory.

### SSD prefix cache keeps working and says why when it cannot

- A GLM-5.3-Flash load no longer fails when `DARKBLOOM_PREFIX_CACHE_MEMORY=1` is set: GLM has no in-memory prefix tier, so it now logs that it ignores the setting and keeps its encrypted SSD checkpoints. Other models still honour the setting as before.
- A Mac whose Secure Enclave key was replaced (by the attestation key's automatic repair, or by `darkbloom unenroll` and enrolling again) no longer loses SSD prefix caching for good. The cache key sealed to the old key is replaced at the next model load, and cache files written under it, which could no longer be read, are removed.
- `darkbloom status` adds `prefix_cache=` to each loaded model's line and prints the cause and the fix under a cache that failed to start; `darkbloom doctor`, and so the desktop app's diagnostics, add a `prefix cache` check. A model load whose cache failed logs a line for `darkbloom logs` and the model, cause and fix in `provider.log`.
- The heartbeat's per-model prefix-cache status carries the cause behind an error as an optional `detail` (for example `key_unavailable` behind `cache_init_failed`), which coordinators that predate it ignore. A complete-checkpoint store refused because its cache directory is missing or unsafe now reports `disk_unavailable`, as attention-block stores already did, and a store closed with its unloading slot reports `cache_closed`.

### Nemotron Super and GLM-5.3-Flash logprobs

- Nemotron 3.5 Super now serves `logprobs` and `top_logprobs` (0 to 20 alternatives) on text, image and video requests, through the local endpoint and, once its catalog row lists `logprobs`, through the coordinator, streamed and complete, instead of refusing them with 400. `top_logprobs` outside 0 to 20 is still refused with 400.
- A request with logprobs decodes without speculation; requests decoding beside it keep speculating.
- `logprobs.content` has one entry per generated token in generation order, covering reasoning, answer and tool-call tokens, as vLLM and SGLang return them. Joined, the entry tokens spell the reasoning text, the `</think>` marker that ends it and then the answer text, not the answer alone. Streamed reasoning chunks carry their tokens' entries, and a response that ends while the model is still reasoning (for example when `max_tokens` runs out) still returns them.
- A complete response carries the same entries as the stream, except that a complete response from the local endpoint keeps only the last 4,096. Tool-call tokens lack entries only when nothing follows the call, which is rare for Super: its call turns end with a newline that carries them.
- GLM-5.3-Flash logprobs, which stay disabled until the catalog lists them, follow the same contract.

### GLM-5.3-Flash accepts OpenRouter's reasoning context and mode

GLM-5.3-Flash refused requests carrying OpenRouter's documented
`reasoning.context` or `reasoning.mode` with 400 `invalid_request`.
`reasoning.context` now chooses which returned reasoning the model sees:
`current_turn` keeps only the reasoning returned after the last user turn, as
`clear_thinking: true` does, while `all_turns` and `auto` keep every turn's.
`reasoning.mode: "standard"`, OpenRouter's default, is accepted. Other values
of either field, including `reasoning.mode: "pro"`, and a context that
contradicts `clear_thinking` are still refused with 400.

### GLM-5.3-Flash serves hidden reasoning and Anthropic thinking controls

GLM-5.3-Flash refused several documented request controls with 400
`invalid_request`, and the coordinator counted each refusal as a failed job
for the provider that received it. It now serves them:

- OpenRouter's hidden reasoning (`reasoning.exclude: true`,
  `include_reasoning: false`): the model still reasons, and the reasoning is
  withheld from the response and its logprobs but billed as reasoning tokens,
  as OpenRouter documents.
- Anthropic's `thinking` object, which Darkbloom's Messages API forwards:
  `budget_tokens` selects an effort like `reasoning.max_tokens`, `adaptive`
  enables thinking, and `display: "omitted"` hides the reasoning.
- A null `reasoning_effort`, which OpenAI documents as nullable, is unset.

The prompt is unchanged in every case.

### GLM-5.3-Flash serves structured-output schemas from pydantic, zod and OpenAI strict mode

A GLM-5.3-Flash `response_format` `json_schema` that used keywords outside the
subset Flint compiles into a grammar, such as `$defs` and `$ref`, `anyOf`
nullable fields, `format`, `pattern`, numeric bounds, `maxItems` or an untyped
property, was refused with HTTP 400 before generation. GLM compiles no grammar,
so these requests are now served as on the other families: the schema steers
the answer, which is withheld until generation ends and then checked against
the caller's schema, and a violation is a 422 with no content. The check does
not follow `$ref` references or enforce `format`, and it enforces a `pattern`
only when the pattern is literal text, optionally anchored with `^` or `$`.

### GLM-5.3-Flash serves a JSON `response_format` beside tools

A GLM-5.3-Flash request with a JSON `response_format` (`json_object` or
`json_schema`) and declared tools was refused with HTTP 400 before generation.
It is now served as on the other families: the format governs the answer, which
is withheld until it validates, while a tool call is exposed and validated as
in any tool request. Text the model writes beside a call is not checked against
the format; it is sent unchanged once generation ends.

### GLM-5.3-Flash serves tool results whose `name` differs from the call

A tool result whose optional `name` was empty or differed from its call's
function, such as the unprefixed tool name some MCP clients send, was refused
with HTTP 400. Results pair with calls by `tool_call_id`, and GLM's chat
template never renders a result's `name`, so these histories are now served.

### MiMo-V2.6-Flash serves tool results whose `name` differs from the call

A tool result whose optional `name` was empty or differed from its call's
function, such as the unprefixed tool name some MCP clients send, was refused
with HTTP 400. Results pair with calls by `tool_call_id`, and MiMo's chat
template never renders a result's `name`, so these histories are now served.

### Legacy `function_call` histories keep their result paired with the call

A conversation in OpenAI's legacy function-calling format, an assistant
`function_call` followed by a `role: function` result, was converted to
`tool_calls` but left the result without a call ID, so GLM-5.3-Flash refused it
with HTTP 400 as an unmatched tool result. The result now takes the converted
call's ID, and GLM-5.3-Flash serves the history like its `tool_calls` spelling.

### Nemotron Super first token no longer stalls on prompts of about 80 to 92 tokens

Nemotron 3.5 Super prefill chunks near the FP8 eager reference's 64 MiB bound (most visibly prompts of about 80 to
92 tokens, and long prompts whose last 2,048-token chunk has that many tokens) split one projection into thousands
of small products. The first token of a 92-token prompt took about 12 s on an M5 Ultra on 0.10.1 (about 3 s on the
0.10.2 MLX, about 6 s on an M3 Ultra), and concurrent requests queued behind it. The SDK now regroups those products
into at most 128 per call with the same per-output arithmetic, so the first token arrives in about 0.5 s on an M5
Ultra and about 0.9 s on an M3 Ultra, with the same outputs as before; on M5 Macs, chunks of 87 to 92 rows (and a
few longer bands) take the larger products already used for longer chunks, whose outputs can differ within
rounding.

### Nemotron 3.5 Super speculates for sampled and controlled requests

- Sampled Super requests (temperature above zero) now speculate with the embedded MTP head through exact target-prefix acceptance. Each accepted draft equals the token the target samples with the request's own sampler and seed, so output is unchanged; before, every sampled request decoded one token per step.
- A Super request the engine cannot draft for (a `stop` string, a repetition, frequency or presence penalty, or `logit_bias`) now decodes one ordinary token per step beside requests that speculate. Before, one such request turned speculation off for every request in the same step.

### GLM-5.3-Flash and Nemotron 3.5 Super keep decoding while another request prefills

While other requests decode, GLM now runs eight decode-only steps after each 2,048-token prompt chunk of a
long prompt. Before, a decoding request got about one token per chunk (about a second each on an M5 Ultra)
for as long as another request prefilled: 2.8 tok/s beside an 8K prompt and 1.2 to 1.5 tok/s with two
decoders. With the held steps it measured 19.5 and 7.1 to 7.2 tok/s, while the prefilling request's first
token arrived 6 to 20% later. A request served alone is unchanged, and first-token deadline admission prices
the held steps. `DARKBLOOM_GLM_DECODE_STEPS_BETWEEN_CHUNKS` sets 0 to 64 steps; `0` restores the previous
scheduling.

Nemotron 3.5 Super now runs four decode-only steps after each prompt chunk while other requests decode. On an M5
Ultra a decoder kept 16.3 tok/s during an 8K prefill instead of 5.8 (12.6 instead of 3.9 beside a 32K prefill), and
the prefilling request's first token arrived 15 to 26% later.
`DARKBLOOM_NEMOTRON_SUPER_DECODE_STEPS_BETWEEN_CHUNKS` sets 0 to 64 steps and now reaches the launchd provider job;
`0` restores the previous scheduling.

### Nemotron 3.5 Super on an M5 speculates only while few requests decode

On an M5 the managed Super slot now drafts at depth 3 for one decoding request, 2 for two, 1 for three or four,
and decodes target-only from five (`3,2,1,1,0`; other Macs keep `3,2,2,2,1`). On an M5 Ultra speculation is
20–24% faster alone and ties at two requests, but at four requests depth 2 cost 7–9% and at eight depth 1 cost
13–15% of aggregate throughput against target-only decoding. `DARKBLOOM_NEMOTRON_SUPER_MTP_DEPTH` lists may
now contain `0` (target-only at that width) and still override the default.

### GLM-5.3-Flash decodes faster at long context

GLM's paged attention reads (index metadata, latent history and each query's selected latents) now bind up to 17
memory segments per GPU launch and copy only the pages each segment holds, instead of one full-history launch per
segment after a zero fill. Decode steps and MTP verification rounds also submit GPU work in larger command buffers,
as Nemotron Super already does for plain decode. On an M5 Ultra, one request now decodes at about 73, 62 and 48
tokens per second after 8K-, 32K- and 64K-token prompts, up from about 63, 36 and 19. Outputs are unchanged: every
read copies the same bytes.

### GLM-5.3-Flash speculates for two concurrent requests

GLM's embedded MTP now verifies the draft windows of two decoding requests in one target forward, instead of
turning speculation off as soon as a second request decodes. On an M5 Ultra, two concurrent requests decode at
about 46 tok/s each instead of 38 (aggregate about 91 instead of 75 tok/s). One request, and three or more, decode
as before.

### `darkbloom logs` names why a request was refused before it ran

A request the provider refused before its inference task started (an
unsupported reasoning control, a malformed tool history, a body that does not
decode, a sealed request it cannot open) wrote no readable log line, although
coordinators count it as a failed job. Each such refusal now writes one fixed
line, for example
`Inference failure: invalid request (unsupported reasoning control)`, so the
failed jobs on the console's Jobs card can be matched in `darkbloom logs`. The
line never contains request text, and the refusal itself is unchanged.

### `darkbloom logs` names why a request was refused while its prompt was prepared

GLM-5.3-Flash requests refused as client errors while the provider prepared
the prompt, such as tool histories with an unanswered call or an unmatched
result, history arguments it cannot represent, tool names it refuses, or a
prompt plus `max_tokens` beyond the context window, logged only the bare
`Inference failure: invalid request`. On 0.10.1 they were most of the HTTP
400s a GLM provider returned. Each now names a fixed reason, for example
`Inference failure: invalid request (unanswered tool call)`, so the 400s can be
attributed from `darkbloom logs`. The line never contains request text, and the
refusal itself is unchanged.

### Load refusals and status explain memory a load cannot reclaim

- A refusal that eviction could not resolve (`All N model slot(s) are active`, `… even after evicting every idle model …` or `… and all loaded models are actively serving`, Nemotron Super's `LOAD room` refusals included) now ends with `Not evictable:` when the load could not evict a resident model, naming each such model with its resident GB and each reason: an Autopilot placement hold with its UTC expiry, requests in flight, a local request, an Autopilot pin, an unload or an MTP upgrade in progress, and whether Autopilot adopted the model outside the selected models. Loads that never evict, such as startup preload, are unchanged. The last form says `all loaded models are actively serving` only when every model it could not evict is serving work, and otherwise `no loaded model can be evicted`, for example when only a hold blocks the load.
- `darkbloom status` now shows `Serving outside the enabled model filter` (and why: an Autopilot operation's adoption, the running daemon's selection, which applies a changed `enabled_models` only at its next start, or the live Autopilot lease), `Autopilot placements` with each hold's expiry, `Not evictable for a load now`, and how long ago the last model-load error was recorded.
- `darkbloom autopilot status` now prints adopted models and placement holds with their expiry.
- The daemon state file carries the same eviction exclusions (`eviction_exclusions`) and the ordinary serving selection (`serving_selection`). Loading and eviction decisions are unchanged.

### MLX stack moves to the 2026-10-22 upstream sync

- The `libs/mlx`, `libs/mlx-swift` and `libs/mlx-swift-lm` forks now contain upstream `ml-explore/mlx`, `mlx-c`, `mlx-swift` and `mlx-swift-lm` from the 2026-10-22 sync. `libs/mlx` moves both at the top level and in the copy nested in `libs/mlx-swift` that Cmlx compiles, and the nested mlx-c moves from `5e9be4da` to `004c735f`. The upgrade and rollout notes above give each pin and the release metallib change.
- The provider follows the SDK API changes: `LanguageModel.prepare` takes the request `state` and `PrefillParameters`, image and video inputs carry their payload in `.source`, Qwen 3.5 target weight sanitizing can throw, and the new `Generation.rejectedToolCall` event is ignored by the benchmark like a tool call.

### Desktop app releases

- Add `release-desktop.yml`: a `desktop-vX.Y.Z` tag builds the macOS desktop app, signs it with the Eigen Labs Developer ID used for the CLI, notarizes and staples the app and DMG, verifies them, and publishes the DMG, zip and `SHA256SUMS` as a GitHub Release (not marked Latest). A manual run does the same as a dry run without publishing. Releases are refused while the latest published CLI lacks the `darkbloom desktop` API.

## v0.10.1

Published 2026-10-24 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.10.1)).

### Upgrade and rollout notes

- Run this release behind a coordinator that includes [darkbloom-platform#411](https://github.com/Layr-Labs/darkbloom-platform/pull/411). That coordinator refuses `logprobs` on GLM-5.3-Flash, MiMo V2.6 and Nemotron 3.5 Super with 400 before reservation unless the model's catalog row lists `logprobs`, and plans the GLM requests this release starts serving. Without it, a logprob request can reach a 0.10.0 GLM provider, which fails it with a 500 `generation_failure` that cools every provider of the model.
- Do not add `logprobs` to the GLM-5.3-Flash, MiMo V2.6 or Nemotron 3.5 Super catalog rows for this release. Logprobs on these models are deferred, and the GLM-5.3-Flash groundwork in this release stays disabled.
- A provider keeps its 0.10.0 behaviour until it updates. GLM-5.3-Flash refuses `strict` tools, JSON modes, forced tool choice, variable-frame-rate video and the newly accepted reasoning controls with 400, and drops returned `reasoning` text from history. Nemotron 3.5 Super refuses JSON formats with tools and media bodies above 8 MiB. Coordinators send forced tool choice only to providers that advertise it.
- `libs/mlx-swift-lm` moves from `7bed8216` to `6148b6da` for GLM variable-frame-rate video and the GLM logprob groundwork. Only Swift sources change; `libs/mlx` and `libs/mlx-swift` are unchanged, so no Metal kernel source changes.
- Page-cache accounting applies to every model. Load admission, KV budgets, cold-load capacity, `darkbloom status` and `darkbloom doctor` can count more memory as available than 0.10.0 did on a Mac that holds file cache, and never less.
- New provider installations require macOS 27 or later. An existing installation can still reinstall or repair on an older macOS, with an upgrade notice.
- The provider CLI adds the desktop control API (`darkbloom desktop serve`, `ensure`, `login` and `logout`, run as the user LaunchAgent `io.darkbloom.desktop-api`) and `darkbloom doctor --hardware`. This release does not publish the Electron desktop app: CI builds only an unsigned review package, and public distribution still needs a Developer ID signed, notarized build and an update feed.
- Autopilot changes apply only to Macs with saved Autopilot consent; other Macs are unchanged, on the wire and in behaviour. An opted-in Mac reports every verified catalog build in its cache that it can run as `selected_models` (at most 256), under the same consent `revision`. On the current coordinator that list also counts toward Autopilot reward qualification (two eligible models), admin approval counts and the models an Autopilot operation may load or unload; the platform pricing documentation needs the matching update.
- After start, an opted-in Mac checks its other cached builds in the background and reconnects to the coordinator once, at its first idle moment after in-flight work drains, so the coordinator learns about them. A busy Mac waits, and each restart repeats this.
- Placement holds, routing of adopted models, busy-reason waits and downloads on the operator's behalf take effect only on a coordinator that includes darkbloom-platform#439. The current coordinator ignores the new fields and never requests a download.

### GLM-5.3-Flash serves OpenRouter's returned-reasoning tool requests

- Accept `strict` tool declarations on GLM-5.3-Flash instead of refusing the request with 400 `invalid_request`. GLM does not constrain decoding; every tool call is still validated against its declared schema before it is returned, so a non-conforming call fails the request.
- Render reasoning returned on earlier assistant turns as OpenRouter's `reasoning` string or `reasoning_details` text entries in the template's history, exactly like `reasoning_content`; summary and encrypted entries are skipped. Previously those turns rendered an empty thinking block.
- Read a returned tool call with empty-string `arguments` as a call without arguments (`{}`), as the other native families do.
- Treat `reasoning: null`, null `reasoning` members, `include_reasoning: null` and `thinking: null` as unset, accept `reasoning.summary` levels (the full reasoning is returned), and accept the top-level `thinking` switch as a Boolean or as GLM's own `{"type": "enabled"|"disabled", "clear_thinking": …}` object.
- Contradictory thinking switches, unknown `reasoning` members, `preserve_thinking` and hidden reasoning (`reasoning.exclude: true`, `include_reasoning: false`) are still refused.

### GLM-5.3-Flash serves JSON mode, structured outputs and forced tool choice

- Serve `response_format` `json_object` and `json_schema` on GLM-5.3-Flash text requests instead of refusing them with 400 `invalid_request`. GLM's native engine has no constrained decoding, so the format's instruction steers the model, reasoning streams as usual, and the answer is withheld until generation ends. Only a valid JSON value that satisfies the schema is returned, without markdown fences; anything else fails the request with 422 and no content.
- Serve `tool_choice` `required` and a named function on GLM-5.3-Flash text requests, the way Qwen 3.5/3.8 and Nemotron do: the request's forcing instruction is rendered, the call is withheld until it parses and matches the declared schema, and anything else fails with 422 and nothing returned. Providers now advertise this for `glm-5.3-flash`, so the coordinator no longer refuses these requests with 400.
- A JSON format combined with tools, a schema outside the supported subset, and image or video input with either mode are refused with 400.

### GLM-5.3-Flash variable-frame-rate video

- Serve GLM-5.3-Flash `video_url` clips with a variable frame rate instead of refusing them with 400 `invalid_media`. OpenRouter's `input-video-base64` readiness clip (QuickTime, 211 frames in 10.8 s) was refused this way. Like the reference loader, the processor now indexes frames in presentation order and times frame i at i / the track's average frame rate, then applies the unchanged 2 FPS sampler; constant-frame-rate clips sample exactly as before.

### Faster GLM-5.3-Flash starts

- The managed GLM load's own SHA-256 check of every manifest file is now the published weight hash. Coordinator and local loads no longer read all 182 GB again in a separate weight-hash pass before and after loading, saving about 50 s per start on an M5 Ultra. Every file is still verified against the catalog manifest before the model serves, and a changed file identity during the load still fails it.
- A coordinator-mode start registers GLM's last fully verified hash while every weight file keeps its device, inode, size and modification and status-change times, instead of hashing 182 GB before the load reads them again, saving about 25 s more per restart. Any changed file is hashed in full. The record is `~/.darkbloom/verified-weights.json`, owner-only.
- The load logs its phases: `GLM load glm-5.3-flash: all 42 manifest files SHA-256 verified before serving; auxiliary verification …, core verification …, tensors and construction …, total …`.

### GLM-5.3-Flash GPU wired-memory limit guidance

- `darkbloom doctor` adds a `glm wired limit` check when GLM-5.3-Flash is downloaded, selected or served on a 256 GB M5 Mac. It warns while macOS's GPU wired-memory limits are below the values the production hosts use, prints the exact `sudo sysctl -w iogpu.wired_limit_mb=245760 vm.global_user_wire_limit=261134011596 vm.user_wire_limit=261134011596` fix and a LaunchDaemon that reapplies it at boot, and passes with the current values once they are set. GLM plans about 247 GB of GPU memory at full KV there, while the macOS default allows about 222 GiB, so Metal command buffers can fail with "Insufficient Memory".
- `darkbloom start` prints the same one-line fix when it would serve GLM below those limits. When a GLM load, preload, self-test or coordinator request fails with a Metal out-of-memory error, the provider logs the fix once per process and `darkbloom status` repeats it under a matching load error.
- Advice only: the notice does not change memory admission, KV grants or capacity, and no command runs `sudo` for you.

### Nemotron Super inline video body bound

- Nemotron 3.5 Super now accepts media request bodies up to 40 MiB, enough for one part at the shared 25 MiB inline-media cap as base64 and every body the provider's transports deliver. The former 8 MiB bound refused linked videos larger than about 6 MB as invalid media once the coordinator inlined them, including OpenRouter's 6.9 MB readiness video.
- A Super media body above the bound now fails as `media_too_large` instead of `invalid_media`.
- Super's worst-case media charge for capacity quotes grows with the bound: 4.67 GiB for one image (was 3.62), 4.54 GiB for one video (was 3.49) and 25.6 GiB for sixteen images (was 24.5). On small KV grants the default prefix bank keeps that larger charge free and can be 512 MiB smaller.

### Nemotron Super JSON response formats with tools

- Nemotron 3.5 Super now serves a `json_object` or `json_schema` response format in a request that also declares tools, instead of refusing it with 400. Tool calls are returned as `tool_calls`; an answer without calls must be valid JSON for the format, or the request fails with 422. A required or named `tool_choice` still needs its call.

### Typed refusals for unsupported logprobs on native engines

- Refuse `logprobs` on MiMo V2.6, and token constraints on either native engine, with 400 `invalid_request` before any reservation. The engine's own refusal reached the coordinator as a 500 `generation_failure`, which counts as provider sickness: two such requests cooled every provider of the model and its requests without tools were shed as 429 "no provider … is available right now" for five minutes.
- Add groundwork for GLM-5.3-Flash logprobs in its native engine. It is not enabled: a coordinator that includes darkbloom-platform#411 refuses `logprobs` on GLM-5.3-Flash with 400 until the model's catalog row lists the capability, and this release does not add it.

### Page cache no longer blocks model loads

- Count the file-backed page cache and volatile purgeable pages as available memory in load admission, KV budgets, cold-load capacity, `darkbloom status` and `darkbloom doctor`. Cached files left by `darkbloom models download` or weight hashing are dropped by macOS without compressing or swapping any process memory; they previously counted as used whenever they were active pages, so a 256 GB Mac reported 170.8 GB usable with about 250 GB of page cache and refused GLM-5.3-Flash's 185.4 GB cold load until `sudo purge`.
- The available figure is the larger of the former free + inactive measure and free pages plus page cache, so it is never stricter than before. The page-cache measure counts no anonymous or compressed memory. `DARKBLOOM_MEMORY_AVAILABILITY=free-only` still counts free pages only.
- Weight hashing and verification (startup registration, download and prefetch verification, revision publication) and the managed GLM load drop the files' cached pages after reading them. Their uncached reads never added pages, but pages already cached by the download's own writes stayed resident: about 250 GB after downloading GLM-5.3-Flash.

### Many-file model download progress

- Redraw the foreground model download display (`darkbloom models download` and the `darkbloom start` picker) in place as a compact block: one bar per file being transferred and a total row with files completed, bytes, rate and ETA. A model with more files than the terminal has rows, such as an 88-shard checkpoint, previously redrew below itself several times a second and scrolled without end.
- Fit every row to the terminal width with aligned columns. Narrow windows shorten file names (keeping shard numbers), then drop the per-file rate, before dropping the bar; rows wider than an 80-column terminal previously wrapped and caused the same endless scrolling with only a few files.
- Print each finished file once, as it completes, in aligned columns instead of listing every file again at the end. Output without a terminal no longer prints each file twice.
- Time each file from when its transfer starts, and again after a fallback restart, so shards that waited in the queue no longer report a low rate and an inflated ETA.

### Installer requires macOS 27 for new providers

- The provider installer now stops a new install on macOS 26 or earlier before downloading anything, with a prompt to update macOS in System Settings › General › Software Update. A Mac that already has the CLI or a provider config can still reinstall or repair, with a notice to upgrade.

### Autopilot placements, downloads and busy reasons

- On a Mac with saved Autopilot consent, Autopilot can now use every model the Mac has downloaded that is a verified catalog build it can run, not only the models selected when Autopilot was enabled. The set is recomputed when the provider starts (models beyond the saved selection are checked in the background after it connects; with consent, start first fetches the catalog, waiting up to 10 s), when a download is verified and when a build is replaced or removed. There is no new consent step and no setting to change; the provider reports at most 256 models, saved selection first.
- On a Mac with saved Autopilot consent, Autopilot can also download catalog models on the operator's behalf. This is on by default; operators can limit it with `darkbloom autopilot downloads enable [--max-storage-gb N] [--max-models N]` (it asks for the limits on an interactive terminal; blank means no limit), turn it off with `darkbloom autopilot downloads disable`, or set `[backend.autopilot_downloads]` in the provider config. Changing it does not change Autopilot consent. A download runs in the background without pausing serving, keeps at least 50 GiB of disk free, stays within the limits, never loads the model by itself and never deletes files. A verified download joins the set and is remembered across restarts in `autopilot-downloads.json` beside the config; deleting a downloaded model frees its share of the limits. A refused download reports `autopilot_paused`, `model_not_supported`, `model_limit_reached`, `storage_limit_reached`, `insufficient_disk`, `catalog_unavailable` or `download_failed`; with downloads off or without consent the reply stays `model_not_selected`. `darkbloom autopilot status` shows the downloads setting, limits and usage, and the downloaded models the running provider adds.
- A cached inventory model loaded by a successful Autopilot operation keeps serving after the operation's control lease ends. The adoption ends when the model leaves memory for any reason, when consent is revoked, Autopilot is disabled or the model leaves the Autopilot set, when its build fails verification, and at restart. Adoption permits serving only; publication and revision updates still need the ordinary selection or a live lease.
- An operation can hold its loaded model for up to 24 hours (`hold_seconds`); a later operation's hold replaces it. Ordinary cold loads and the idle timer skip a held model, and after the hold expires the idle timeout restarts from the expiry. Cold loads into free memory and other models' idle policy are unchanged. A load that would have to evict a held model fails with the existing capacity refusal, and cold-load capacity no longer counts held weights as reclaimable. Another operation can still unload a held model. A hold or adoption ends as soon as its model's weight hash can no longer be verified.
- A `provider_busy` refusal now names its first cause, and Autopilot heartbeats report every current busy reason, when the first began, adopted and held models, and the new capabilities.
- A watchdog acts on transitions that last longer than their bound. An Autopilot operation running for 10 minutes is cancelled and fails as `transition_stalled`, even if the step it was waiting on finishes afterwards. A coordinator preload running for 10 minutes is answered `failed` with `transition_stalled`, and a new request starts afresh. A startup preload stuck on one model for 10 minutes, counted from when that model started, stops before its next model. Preloads are never interrupted, so other requests waiting on the same load are unaffected. Stalled loads, model switches, advertisements, reslices and reconnects are counted and reported, never forcibly cleared; a retried load is timed afresh.
- Without saved Autopilot consent, nothing changes: no new heartbeat fields, placements, downloads or watchdog actions, and the reported model list is the saved one. All new protocol fields are optional, and coordinators that do not know them ignore them.

### Desktop control API in the provider CLI

- Add `darkbloom desktop serve` and `darkbloom desktop ensure`, an authenticated loopback control API run as a user LaunchAgent (`io.darkbloom.desktop-api`). `ensure` replaces a stale or version-mismatched service, the service restarts itself after its binary is replaced, and `darkbloom stop --uninstall` removes it.
- Add `darkbloom desktop login` and `darkbloom desktop logout` for a separate, read-only dashboard session with bounded expiry. Sign-in prefers the scoped `desktop_account` device-code purpose and accepts an existing coordinator's standard grant; provider credentials, linkage and serving are never changed.
- Reject incompatible runtimes and streamed snapshots by protocol version, and refuse actions that need desktop commands an older installed runtime does not have.

### Desktop hardware load

- Serve whole-machine load to the desktop app over the authenticated control API: per-core CPU load with tier and cluster layout, GPU utilization and memory, ANE activity, memory pressure, thermal state, and Darkbloom's share of GPU time. Sampling runs in the desktop API process only while the app is looking, without root, and never reaches heartbeats, logs or the coordinator.
- Add best-effort GPU power and frequency plus estimated DRAM and ANE bandwidth; values stay unknown (`null`) until a counter has been seen moving. `darkbloom doctor --hardware` prints the same report.

### macOS desktop app

- Add a fresh Electron frontend (`desktop-app/`) using the landing brand: onboarding, Home, My Macs (Overview, Models, Cooling, Stats, Settings), Studio, Earnings, Leaderboard, Updates and Help. Closing the window keeps menu-bar access and provider activity; at login it starts hidden. GUI updates use only a feed configured at build time (`DARKBLOOM_DESKTOP_UPDATE_URL`), never provider releases.
- Keep Electron on the same `darkbloom` CLI backend. Swift owns coordinator requests, shared caches, browser account sign-in and sign-out, catalog refresh, Autopilot enrollment, pinning and model operations; the renderer only sends validated actions over the authenticated loopback API.
- Make Models Autopilot-first with manual selection on runtimes without Autopilot, keep-in-memory controls, download progress and bounded pin capacity. Recommendations rank compatible models by seven-day network inference earnings; personal earnings stay separate.
- Show account earnings (daily charts, model and Mac breakdowns, exact CSV copying, separate inference and base-reward income), live per-model request activity, settled-token milestones, and a This Mac chip view lit by measured load. Unavailable values are shown as unavailable rather than zero.
- Add isolated control-API tests, frontend journey tests, desktop packaging and CI. Public distribution remains subject to signed-runtime, update-feed and notarization qualification.

### Desktop onboarding and CLI install

- Make **Install the Darkbloom CLI** the first onboarding step, starting only on click with plain-language progress, Cancel and Retry; then check the Mac, link the account and start serving. Ineligible Macs stop at the check with reasons and a waitlist.
- Require macOS 27 for new installs; a Mac already running the CLI on an older macOS keeps serving with an **Update macOS** next step.
- Open the link page only on request, show returning users "Connecting to this Mac…" instead of first-run onboarding, and confirm eligible Macs on fresh installs by catalog size when nothing is downloaded yet.

### Desktop accessibility, layout and copy fixes

- Keep keyboard focus in place across navigation and inside dialogs, announce Home status changes once instead of every refresh, and make light and dark themes readable with visible focus rings.
- Fix layouts at narrow widths, singular counts, page scroll position, plain-language copy, a single "Start serving" vocabulary, and dialogs that could not be dismissed over window-drag areas.
- Guard model, Autopilot, link and Settings actions against double submission or invalid input; ask before unlinking; show stale cooling and fan readings as unavailable; and ask signed-out linked Macs to sign in instead of loading earnings indefinitely.
- Fix Leaderboard loading and refresh, Earnings labels, Studio endpoint model and key handling, Stats completed-request traffic, release notes that showed tag signatures, update status from release history, and the menu bar icon size.

### Desktop signed preview build

- Add an opt-in, Developer ID signed Darkbloom Preview DMG with a bundled desktop API, separate application state, and managed API startup and shutdown. Provider operations stay on the verified installed runtime; normal release signing requirements are unchanged.
- Recover after a crash or force quit by stopping the leftover bundled API (verified by recorded pid and exact command) before starting a new one, and report the installed runtime's version rather than the bundled API's build version.

### Console desktop sign-in approval

- Approve Darkbloom Desktop sign-in codes on `console.darkbloom.dev/link?purpose=desktop_account`: the link page now sends the code's purpose (`desktop_account` or `provider`) with the approval, so desktop sign-in no longer fails with "authorization purpose does not match this code". Provider linking is unchanged. This ports the link page from darkbloom-platform#23 into the console that still serves `console.darkbloom.dev`.

### Release notes without tag signatures

- Publish provider release notes from the original tag annotation without its
  SSH or PGP signature, preserving multiline paragraphs and blank lines. A signed
  tag's signature block was included in the published notes (provider 0.9.20
  shows it as encoded bullet points); it stays available from git as verification
  data.

## v0.10.0

Published 2026-10-23 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.10.0)).

### Upgrade and rollout notes

- Request normalization moves from v8 to v9 for every model, so every `prompt_contract_id` changes. A coordinator attaches a cache scope only when a provider's advertised contract matches its own, so a 0.10.0 provider under a v8 coordinator, or an older provider under a v9 coordinator, serves coordinator requests without prefix-cache or prompt-token reuse and without cache-aware routing until both run v9. Ordinary serving continues across the mismatch. Run this release with a v9 coordinator, add v9 tuples to the coordinator's cache-routing allowlist, and expect existing prefix caches to start cold.
- MLX moves from `cb77239b` to `ad4745a2` both in `libs/mlx` and in the copy nested in `libs/mlx-swift` that Cmlx compiles; `libs/mlx-swift` moves from `6923a80f` to `67dc7528` and `libs/mlx-swift-lm` from `14661d9b` to `7bed8216`. The quantized and NAX Metal kernels that every quantized model uses change, so the release metallib changes and the first start after updating compiles kernels again.
- Flint, Nemotron 3.5 Super and GLM-5.3-Flash serve coordinator requests only after each model is published and registered. Register Super only behind a coordinator that enforces its provider-version floor at 0.10.0, and GLM-5.3-Flash only behind one that requires the `glm5_next_v1` capability; without those gates a coordinator would route them without their load quotations, prompt contracts and media estimates. Flint needs the coordinator's v9 Flint prompt framing, and older providers cannot serve it.
- Two changes listed under GLM-5.3-Flash native prerequisites apply to every model: model-weight hashing reads around the file cache, and a request refused because the Mac's serving concurrency is full gets HTTP 503 before any response headers.
- `darkbloom start` does not forward these rollback switches to the LaunchAgent, so they affect only foreground processes: `DARKBLOOM_TTFT_FUSED_CAUSAL_PREFILL`, `DARKBLOOM_TTFT_QWEN_MTP_CHAINED`, `DARKBLOOM_TTFT_QWEN_MTP_CARRY`, `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MB`, `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MS` and the `DARKBLOOM_NEMOTRON_SUPER_*` settings.

### Native Flint support

- Add native Recursive Flint loading and CBv2 serving for the official group-64 affine INT4 artifact with INT8 embeddings and native BF16 KV. Live KV and checkpoint precision must both be native.
- Enforce the loaded artifact context limit for prompt plus reserved output before request admission.
- Preserve automatic reasoning, separate reasoning output, validate complete schema-aware tool frames and retain nulls in tool history. Media and unrepresentable raw `</arg_value>` history return errors; Flint OpenRouter parameters below covers reasoning controls, `stop` and JSON `response_format`.
- Enforce native reasoning/tool boundaries in every Flint request, including requests without tools, with split-token marker handling, EOS protection and prepared tool-choice/cardinality rules. JSON and schema checks remain mandatory in the parser and post-validator.
- Keep the caller's messages for required and named Flint tool choices instead of adding a generic tool-only instruction; the native constraint and validators enforce the call. This fixes paged named-tool requests that repeated a call inside unfinished reasoning until the output limit and failed. The request-normalization identity advances to v9 for all models; see Upgrade and rollout notes.
- Bound protocol state and vocabulary caches. Constraints add host/masking work; Flint serving speedups below restore chained decode. Unconstrained diagnostics do not establish production safety, answer quality or throughput.
- Omit unused prefill vocabulary projections while preserving the full trunk and every KV write. Dense/expert NAX execution is captured; a speedup and the prefill/decode targets remain unproven.
- Credit Prince Canuma's MIT mlx-vlm implementation and Recursive's Apache-2.0 rec reference, including its protocol grammar design, with full licenses retained in the SDK notices. Physical qualification remains scoped to the accompanying evidence; MTP, reduced KV and model publication are outside this change.

### Flint OpenRouter parameters

- Accept Flint reasoning effort, `reasoning.enabled` and thinking switches with no effect, since Flint always chooses whether to reason. Malformed values are still rejected. `reasoning.exclude`, `include_reasoning: false` and `reasoning.enabled: false` now hide Flint's reasoning in chat completions, the Responses API and coordinator streams; those tokens are still counted and billed, and they no longer appear in coordinator logprobs.
- Support up to four `stop` sequences on Flint, matched only against the visible answer after reasoning; reasoning and tool calls never trigger a stop.
- Enforce JSON `response_format` (`json_object` and `json_schema`) on Flint's answer after optional reasoning. Requests with tools and a response format return only the formatted answer. Output that is cut off or invalid returns 422 instead of a successful completion.

### Flint paged-only defaults

- Flint now loads on paged attention with the default provider configuration and never falls back to contiguous. An explicit contiguous selection, the paged kill switch or a paged construction failure refuses the load instead of serving the unqualified contiguous path.
- Flint now uses native KV and checkpoint precision even when the provider-wide checkpoint default is `balanced`; an explicit per-model or environment request for reduced precision is still refused.

### Flint serving speedups

- Pin the SDK with Flint decode and prefill speedups: larger decode command buffers, fewer paged decode dispatches and uploads, a fused MoE expert combine, batched sliding-window prefill attention, and constrained decode chaining. Outputs are byte-identical to the previous build.
- Flint's protocol and stop constraints keep decode pipelined: the next step no longer waits for the host to build its mask, and repeated constraint states reuse a cached device mask.
- `RecursiveSI/flint-int4` now serves at the automatic paged width (8 concurrent requests) on M5 Pro, Max and Ultra.
- The pinned SDK change edits shared paged-attention, sampler and engine-loop code, so every paged model runs it; the byte-identical output check covers Flint.

### Flint decode fusions

- Pin the SDK with exact Flint decode fusions (fused q/k/v and gate/up projections, fused routed gate/up banks, a single MoE combine-and-residual kernel and compiled router steps): about 40% fewer GPU dispatches per decode token with byte-identical outputs.

### Nemotron 3.5 Super native owner and media discovery

Staged Nemotron Super VL checkpoints no longer advertise media capability merely
because their configuration includes a vision tower; only the exact serving
identity in the next entry advertises media.

Add an unregistered native text binding with explicit LOAD recheck, bounded
calibrated prefill and request retirement ownership. Synthetic fixtures exercise
text and causal image installation through the real bridge, image cancellation
and retirement, plus live loopback HTTP authentication/SSE/restart. The image
owner binds the installation and separate media/KV reservations. Its CPU
decoder accepts PNG of every colour type and bit depth (byte-exact with the
reference loader) and baseline/progressive JPEG (ImageIO samples within
measured bounds), applies EXIF/XMP orientation as Pillow does, and bounds
declared geometry before allocation; the SDK resize is bitwise equal to CPU
PyTorch on the golden fixtures. Inline images use the `data:image/png;base64,`
or `data:image/jpeg;base64,` label; content selects the format. Image media
reservations include a derived tower and projector working-memory bound for the
largest image. The owner speculates with the embedded MTP head, verified by one
exact captured target window per round
(`DARKBLOOM_NEMOTRON_SUPER_MTP_VERIFICATION=serial` keeps one target step per
draft); synthetic fixtures show token-exact output and exact rollback in both
modes. The managed production slot in the next entry serves local and
coordinator requests through this owner and sets speculation and concurrency
itself, superseding the opt-in image hook and the
`DARKBLOOM_NEMOTRON_SUPER_MTP` and `DARKBLOOM_NEMOTRON_SUPER_MAX_CONCURRENT`
switches the owner first used. Full-checkpoint quality and image formats other
than PNG and JPEG remain unqualified. Portable fixture harnesses preserve reproducible
continuation and require measured admission and reservation calibration before
enabling serving.

The owner serves text as well as images. Prompts match the reference
chat template and tokenizer byte for byte on a 30-case golden corpus (tool
schemas in request order, tool-call history, images with `<img>` placeholder
spans, reasoning on/off). Reasoning follows the reference `ultra_v3` parser:
`enable_thinking` defaults on and streams `reasoning_content`. Text requests
return validated `tool_calls` and validated `response_format` JSON. Image
requests still refuse tools and structured output; image prompts carry the
reference `<img>`/`</img>` span around each image's placeholders. A request
that arrives while the owner is busy gets 429 before any response starts, and
with speculation installed image requests run target-only beside speculating
text.
Each request's reservation now includes a decode row; a KV grant too small for
the configured requests fails the load with the minimum grant it needs. The plain owner
batches text decode row-exactly, and the speculative owner (rectangular
verification) serves up to eight concurrent requests verified in one exact captured window per
round, each committing its own accepted prefix; serial verification stays one
request. `DARKBLOOM_NEMOTRON_SUPER_MTP_DEPTH=auto` lets the engine pick each
step's depth up to three. Synthetic fixtures show token-exact output against
solo plain decode. Prompts prefill in fixed chunks (`DARKBLOOM_NEMOTRON_SUPER_PREFILL_CHUNK`,
default 2048 tokens), at most one chunk per step beside every decode or verify
row, optionally with decode-only steps between chunks
(`DARKBLOOM_NEMOTRON_SUPER_DECODE_STEPS_BETWEEN_CHUNKS`); a request's chunks are
the same as when it is served alone. The prefill activation charge is one
owner-wide lane, reserved before the first request and held until retirement
(the pinned checkpoint charges the SDK's measured whole-chunk bound), instead
of a prefill workspace in every request's reservation.
`DARKBLOOM_PREFIX_CACHE_MEMORY=1` opts the owner into
exact text prefix reuse: a resident recurrent checkpoint bank sized from the KV
grant and the machine (half of what the grant leaves beside every request's
fixed bytes, the prefill lane and one image, and half of what the memory cap
leaves beside the load, at most a quarter of the grant and 16 GiB, none below
1 GiB: 16 GiB for a lone slot on 192 GB and up; or
`DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES`) whose budget is reserved from load until
retirement. The managed slot turns it on whenever that size is
non-zero. Checkpoints sit only at multiples
of the prefill chunk, where a restored request continues a cold prefill bit for
bit on synthetic fixtures; prompts shorter than one chunk restore nothing. On
the speculating owner a checkpoint also holds the assistant's prompt history, so
a restored request speculates exactly as a cold one. An image request reuses
only checkpoints bound to the same evaluated image features at the same
positions.

### Nemotron 3.5 Super served natively

- Discovers and advertises exactly `nvidia-nemotron-3.5-super`: the complete
  pinned NVIDIA NVFP4 checkpoint with its embedded MTP head. The registry id
  with an unpinned `config.json` or index is withheld; every other
  `nemotron_h_omni` id stays unsupported, as before. It advertises image and
  video input; capacity quotes for media probes charge their images' whole
  reservation, a one-part probe the larger of one image and one video.
- Loads into a shared slot through a managed owner: the ordinary eviction and
  re-slice, one LOAD claim covering the installation, the head, the
  speculating owner's round work once and the configured requests' KV
  headroom, each counted once (the load's transient only where it
  exceeds that serving room, since freed load buffers are returned before
  serving), every shard verified against its pin, an owner-wide prefill
  lane of the measured chunk peak (8.5 GiB at 2,048 tokens), a measured
  2 GiB activation reserve (its requests, lane and media
  charges hold its activations), and a refusal naming the minimum when the
  grant cannot serve every request. Defaults: exact rectangular speculation for up
  to eight requests, drafting three tokens for one decoding request, two for
  two to four and one beyond (the fastest depth measured at each width on the
  full checkpoint); `mtp_mode = "off"` or `DARKBLOOM_CBV2_MTP=0` serves the
  plain owner, and an explicit `engine_v2_max_concurrent` bounds the width.
  When available memory cannot hold that owner (a 128 GB Mac running other
  work), the load serves the widest narrower one that fits instead of
  refusing: no prefix bank, then four, two or one concurrent requests, then
  one with 1,024-token prompt chunks, with every measured bound and the full
  context kept, and logs what it chose. Super loads keep no OS reserve beyond
  3 GiB of admission slack and the 2 GiB activation reserve (a
  `memory_reserve_gb` raised above its 4 GiB default stays free), so the model
  loads with 85.6 GiB available (about 104 GiB for the default), and a
  configuration that barely fits steps down instead of losing its admission
  after the weights are installed. If memory still drops while the weights
  install (other applications swapping on a 128 GB Mac), the load keeps the
  installed weights and serves the widest narrower configuration that still
  fits instead of failing and reading the checkpoint again. The provider
  accepts, evicts for and preloads Super on that same rule: an idle
  co-resident model is evicted when that lets the planned owner (or the
  widest reachable fallback) load,
  instead of the request being accepted and then refused with 503, and a load
  that cannot fit even after evicting every idle model is refused before it
  is accepted. MLX's cached buffers are returned before the load steps down,
  the speculation round is reserved beside the KV grant rather than taken
  from it, a load whose grant beside other models cannot serve one request
  fails instead of leaving the slot loaded and serving nothing, and a
  resident slot quotes image and video probes against the memory their
  reservation actually uses. Its advertised memory is now the narrowest
  owner's LOAD size, 83.6 GiB on every Mac (was 69.8 GiB on 128 GB,
  shrinking with RAM); the coordinator's cold-load routing, which still
  subtracts the 10% load reserve, sends a cold Super load only to a 128 GB
  Mac with about 99.4 GiB available.
  Either owner reuses exact prompt prefixes when the grant holds its bank; a
  restored speculative request drafts from the same prompt history as a cold
  one, and an image turn reuses only checkpoints of the same image features.
- Coordinator and local-endpoint chat completions use the reference prompt
  template, reasoning channel, tool and structured-output validation,
  cancellation and usage of the owner. Prefix reuse is partitioned by the
  authenticated cache scope and reports no cache use. `logit_bias` and
  `logprobs` are refused with 400. Reasoning effort is `none`/`off`/`0`,
  `medium` or `high` (top-level `reasoning_effort` or `reasoning.effort`);
  other values are refused with 400. OpenRouter's
  `chat_template_kwargs.thinking` switches thinking like `enable_thinking`,
  and Responses `reasoning.summary` (`auto`, `concise`, `detailed`) is
  accepted with the full reasoning returned. `reasoning` fields the template
  cannot honor (`max_tokens`, `exclude: true`, other members unless null)
  and `chat_template_kwargs` beyond `enable_thinking`, `thinking`,
  `medium_effort`, `truncate_history_thinking` and `force_nonempty_content`
  are refused with 400 instead of being ignored.
- Coordinator tool requests whose schemas hold `{}` or boolean subschemas
  are served (they were refused with 400); the local endpoint still refuses
  a client-sent internal schema marker. `force_nonempty_content` applies to
  streamed responses too: reasoning that never closes is repeated as
  content at the end, as vLLM does. With no tools declared, a literal
  `<tool_call>` in an answer is returned as text instead of failing. A
  `seed` of 2^63 or more no longer refuses a tool request; history tool-call
  arguments that are not a JSON object, and requests with more than 4,096
  content parts, are refused with 400. Prompts keep a string's leading
  U+FEFF and add no separator before an image after text ending in CRLF,
  and reasoning markers followed by a combining mark are recognized.
- Serves inline JPEG and PNG images (`data:` URIs) on the same slot. On the
  default speculating owner each image request runs target-only, with no
  draft state, while text keeps speculating; its media reservation, including
  the largest image's tower and projector bound, is taken before decoding and
  a reservation that does not fit is refused with 503. A second concurrent
  image request gets 429. Activation overflow on the Super model saturates as
  on deployment engines instead of becoming NaN, so images whose embeddings
  exceed the text-calibrated scales are answered instead of decoding as
  `<unk>`; non-finite image features fail the request.
- Image ingress refuses with 400, before the media reservation and any
  decode, a source whose resize workspace exceeds the SDK's 256 MiB (above
  about 33 megapixels, for example 8192 × 8192, which was reserved and decoded
  first), a PNG with more than 64 compressed text or ICC chunks or more than
  16 MiB inflated from them, and a JPEG whose scans would decode a coefficient
  again. ImageIO is given only the primary JPEG image, and a request reserves
  its largest image's decode workspace once instead of once per image.
- A busy owner refuses a request with 429 once the request is decoded,
  before its prompt is planned or rendered. An answer held for validation
  (JSON content with thinking off, forced or tool-call-only answers) starts
  its stream at the first generated token, so a streamed one that fails
  validation ends with an error event instead of a 422 status. Text requests
  no longer wait while an image is prepared, and a GPU fault while checking
  image features fails the request instead of stopping the provider. An image
  body over 8 MiB, visual tokens beyond the context or an image prompt beyond
  it is refused with 400 instead of the retryable 503.
- Serves one inline MP4 or QuickTime video (`data:video/mp4;base64,` or
  `data:video/quicktime;base64,`) as the only media of a request, as NVIDIA's
  reference serving samples it: 2 frames per second, at most 256, paired into
  tubelets with each pair's timestamps in the prompt, and EVS pruning of
  redundant visual tokens at rate 0.5 (`DARKBLOOM_NEMOTRON_SUPER_VIDEO_PRUNING`,
  `0` disables). Its media reservation (at most 3.5 GiB, below one largest
  image's) is taken before any frame decodes; a second video, a video with
  images, another container, a codec other than H.264 or HEVC, frames of
  more than 8,847,360 pixels (4096 × 2160, in any shape), more than 36,000
  frames, more than 37.6 billion decoded pixels (every frame up to the last
  sampled one decodes; ten minutes of 30 fps 1080p fits), extreme aspect
  ratios and undecodable movies are refused with 400, as is a movie that
  keeps the decoder busy past its allowance (at most two minutes).
  Cancelling a video request stops waiting on its decoder at once. A
  malformed pruning rate fails the load before installing. The checkpoint's
  video embedder is now loaded, adding 3,932,160 bytes to the resident
  installation.
- Video decoding no longer crashes when a request is cancelled or its decode
  allowance runs out mid-frame: the reader was cancelled from another thread
  while a read was blocked in AVFoundation. Reads and the reader's
  cancellation now run in order on one queue, so the reader stops once the
  read in progress returns.
- A load right after a Super unload re-samples free memory for up to two
  seconds while macOS returns the unloaded pages, instead of refusing.
- A wedged Super slot leaves serving at once and retires without stalling the
  capacity refresh: its bridge shuts down before its requests drain, within
  twice the engine's 10-second shutdown timeout (past it the slot's memory
  stays charged and Super loads are refused until that retirement completes
  or the provider restarts), and the model reloads only after a 120-second
  cooldown. Until it may load again, Super requests are refused before they
  are accepted, also while the slot retires, and nothing is evicted for
  them. The owner's prefill lane, decode rows and round work count as
  resident memory in every KV grant and heartbeat, so Super and models
  beside it no longer advertise token budget the shared memory budget
  refuses.
- Plain decode steps of the Super owner commit larger Metal command buffers
  (thread-scoped limits in the pinned MLX), and full SSD prefill windows run
  batched, with tokens unchanged: one plain request decodes at 42.9 tok/s
  instead of 34.6 on the full checkpoint. Speculative rounds are unchanged.
- Prompt processing frees each Mamba layer's temporaries within the layer
  instead of at the end of the chunk, with tokens unchanged: on the M5 Ultra
  a 24K-token prompt grows MLX memory by 2.6 GiB instead of 5.6 GiB, four
  parallel 12K prompts by 5.3 instead of 9.2 GiB. Weight hashing and shard
  loading read around the file cache, so loading no longer leaves a second
  cached copy of the checkpoint resident beside the loaded weights.
- Faster on M5 GPUs, with tokens unchanged in decode: speculative rounds
  submit the verify window in parts and use the fused decode kernels, so
  one request decodes realistic prompts at 79 tok/s instead of 70 on the M5
  Ultra. Prompt processing on NAX GPUs runs the experts on dedicated NVFP4
  NAX kernels with a fused expert route and decodes the dense projections'
  weights inside the NAX GEMM, and the Mamba layers' scan runs as a chunked
  NAX kernel: 2,881 tokens/s instead of 1,556 on a 12K prompt, within the
  teacher-forced accuracy gate (top-1 78.09% vs 78.12%, perplexity 2.7275
  vs 2.7294). The runtime-compiled NAX kernels need macOS 27; earlier systems
  keep MLX's prebuilt NAX kernels.
- Serves paged attention KV only: the segmented native paged backend, charged
  by the engine's process-memory owner, with the decode rows reserved for the
  owner's lifetime. Contiguous KV is no longer supported:
  `DARKBLOOM_NEMOTRON_SUPER_KV_BACKEND=contiguous`, any value other than
  `paged`, or `DARKBLOOM_CBV2_PAGED_KV` disabling paged KV fails the load
  before anything is installed; the owner never falls back to contiguous
  storage. Exact prefix reuse works on it: the bank keeps its own copy of a
  donor's prompt KV and a restore writes it into fresh pages.
- Serves its whole verified context, 262,144 tokens, prompt plus output (was
  16,384); the coordinator, not the provider, decides whether a long prompt's
  prefill time suits a request. The speculating owner charges each request its
  draft history per token of its own prompt and output instead of for the
  whole window, and its round work once instead of per request, so eight
  requests claim 15.7 GiB of KV headroom beside any prefix bank (was 26 GiB at
  16,384 tokens) and the default load still fits a 128 GB Mac.
- Registered for Apple M5 Max (128 GB) and M5 Ultra (`apple_m5`, at least 128 GB
  of unified memory); only 256 GB is measured on hardware.
  Coordinator-side registration remains a separate step; see Upgrade and
  rollout notes.

### GLM-5.3-Flash native prerequisites

- Add the GLM-5.3-Flash target, trained MTP, media and bounded loader, with synthetic regression coverage. Full-model qualification remains a separate gate.
- Add a low-level GLM5 tool parser with schema-aware values and response-wide validation before tool-call emission, plus loaded-model-gated prompt controls. These do not advertise function calling, constrained decoding or media support for an unqualified model.
- Recognize the chat template shipped in `EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp`, the official template with numeric attribute access written as `[0]` subscripts, so the ordinary pinned Swift-Jinja renders it without a dependency patch. It reproduces every official-template golden byte for byte.
- Price raw same-directory GLM5-Next discovery and managed loads with the raw source size plus native-copy, tokenizer and a measured `ceil(source / 32)` residual allowance, instead of disk × 1.2. The published NVFP4 artifact (181,752,181,866 bytes) therefore fits a 256 GiB Mac with the unchanged activation and minimum-KV headroom, where disk × 1.2 did not. Bounded metadata-only cache/provenance directories remain discoverable; nested integrity files and symlinks remain refused. Malformed layouts and separate-tokenizer compositions do not receive a loadable generic fallback.
- Add an explicit default-off, manifest/aggregate-pinned local GLM qualification selection; it never advertises the local download to the coordinator or changes default cohorts. It serves GLM only through its owned embedded-MTP engine, which the default `mtp_mode = "auto"` enables without any setting; target-only GLM loads, fallbacks and in-place recovery are refused, and local startup skips GLM with a message when `mtp_mode = "off"` or `DARKBLOOM_CBV2_MTP=0` disables MTP. Coordinator-connected mode sizes GLM for an enforced 262,144-token context, never the full model context. Size GLM sparse KV using its actual asymmetric FP32 rows, preserving the engine's separate three-generation KDA request charge.
- Expose retained GLM faults on local metrics (`darkbloom_glm5_next_retained_fault`, `darkbloom_glm5_next_retained_owner_objects`, `darkbloom_glm5_next_retained_resident_bytes`). An unproven GLM retirement keeps its pending-load lease, roots, ownership and activity without refund, and its unpublished bytes are excluded from fleet KV grants. A GLM slot whose unload, eviction or shutdown cannot prove retirement is charged its KV claim, keeps a frozen grant and is skipped for eviction. Other families still load and reclaim when capacity remains, but cannot grow into that memory; when the retained grant held the whole KV budget, their loads are refused.
- Load local GLM with the native serving execution policy and record it in the encrypted checkpoint identity. GLM prefill chunks and steps are each at most 2,048 tokens, with solo stripes off: paged prefill rows read each layer's latent history once instead of retaining one selected-latent read per query token, so a 2,048-token step's priced scratch fits the post-load envelope with four concurrent requests at 8K and 32K context; at the 262,144-token coordinator bound a 256 GiB host runs at most two or three. Local GLM selects its native paged KV backend automatically and refuses rather than falling back to contiguous; the encrypted SSD prefix store defaults on for the pinned GLM identity (`DARKBLOOM_PREFIX_CACHE=0` opts out). A GLM engine that refuses to activate reports the native reason, such as the step-scratch bytes needed and available, in the load error. A published GLM engine holds standing wired residency for its weights, bounded by the same safe ceiling as MiMo and released only after proven retirement; without it, 512-token prefill chunks measured 263–367 instead of 1,246 tok/s on a 256 GiB M5 Ultra. `DARKBLOOM_GLM_PERSISTENT_WIRED_RESIDENCY=0` rolls it back. On Neural-Accelerator GPUs routed-expert prefill uses the NAX expert kernel for NVFP4 banks too (real NVFP4 artifact: 1,955 instead of 1,585 tok/s at 2,048-token chunks, 1,486 instead of 1,246 at 512-token chunks; decode unchanged). Prefill chunks past position 2,048 use the native sparse-attention prefill kernel (native profiler, 8,192-token prompts at 2,048-token chunks: 2,000 instead of 1,340 tok/s; perplexity within noise, +0.018%).
- Refuse local GLM requests that exceed the enforced context with HTTP 400 before native admission, and default an omitted `max_tokens` to half that bound. Omitted sampling fields use the artifact's `generation_config.json`. `reasoning_effort` accepts `minimal`, `low`, `medium`, `high`, `xhigh` and `max`, mapped to the template's low/high/max levels as the platform does.
- Prepare GLM image input natively: the GLM prompt policy renders interleaved image parts, the vision tower runs one image at a time with fused attention on the GPU (query-tiled elsewhere; a 7,921-token image's tower drops from 28 s to 1.4 s) and checked evaluation, and the resulting causal spans carry no position state. The media reservation charges prepared pixels, the full-frame tower working set and each image's 8000-token cap. Images are served by the embedded-MTP serving engine, which accepts prepared causal media: image rows decode target-only and never reuse cached prefixes. A GLM load now requires the reviewed shipped chat template, and a selection file with the unsupported `tokenizer` field is refused.
- GLM MTP now verifies up to three drafted tokens per round in one target forward (rectangular verification, adaptive depth) by default, including with the GLM prefix cache, and sampled requests speculate through exact target-prefix acceptance. GLM MTP output is not token-identical to target-only greedy decoding: the multi-token verify forward can flip near-tie tokens. `DARKBLOOM_GLM_RECTANGULAR_VERIFY=0` restores serial single-proposal verification; the variable is forwarded to the launchd provider job.
- Reserve the GLM MTP layer's memory per request in proportion to that request's reserved tokens (a fixed amount plus bytes per token) instead of for the full model context, and price its index scratch from the actual selection path (the native sparse decode kernels pool in kernel; absorbed attention never expands selected latents). Under the serving policy with 2048-token steps and depth-3 verification this is 4.14 GB plus 33,900 bytes per reserved token, about 13.0 GB at 262,144 tokens instead of about 22.8 GB for every request.
- Serve GLM-5.3-Flash in coordinator-connected mode as catalog model `glm-5.3-flash`, downloaded through the normal model-revision path and loaded by the same managed native load, embedded MTP, paged KV, prefix cache and wired residency as the local opt-in. The coordinator catalog entry, the revision receipt and the loaded bytes must agree on one aggregate, and the reviewed shipped template stays mandatory. The enforced context is 262,144 tokens; a larger catalog `max_context_length` refuses the load. GLM loads only on Apple M5 Max or M5 Ultra with at least 256 GB of unified memory: the provider reports the new runtime capability `glm5_next_v1` only there, the build requires `apple_m5`, `mlx_nax` and `glm5_next_v1`, and other Macs report their chip and memory in the refusal. GLM requests reserve target KV (33,836 bytes per token; 8.87 GB for a full request), native step scratch and embedded-MTP state per actual reserved token, alongside the fixed recurrent and MTP charges, and the running-row cap is the largest the engine's step-scratch activation check admits; the slot reports that combined rate as `kv_bytes_per_token`, must hold one full-length request to publish, and refuses a request larger than its whole pool as capacity instead of queueing it.
- Retain GLM native owners and wired-memory policy entries after backend residency start/end faults. Refuse publication after a failed start and wait for pending ticket work before reporting clean retirement; unsupported platforms skip ticket creation before backend work. Keep the bridge engine, KV claim and activity guards through residency settlement so an end fault cannot erase the retained-memory charge.
- Reject malformed GLM tool suffixes instead of exposing parser fallback text, and report unproven compatibility shutdown through a fixed diagnostic while retaining resources.
- Add provider-hosted GLM aligned-read, descriptor-cache-policy and tiny-artifact loader regressions. They require the matching immutable SDK loader/reader implementation; native cases remain subject to exact-composition qualification.
- Build single-Mac GLM-5.3-Flash on the single-Mac native stack (`Layr-Labs/mlx` #37, `mlx-swift` #58 and `mlx-c` #16, merged from `work/glm53-flash-release`). It carries the quantized tile-bound, allocation-cap, page-backed footprint and 512-thread launch fixes the GLM path needs, without the two-Mac JACCL, sealed all-sum and collective startup-wait changes, so this release does not depend on the cluster pull requests. Compared with v0.9.22 the MLX quantized and NAX Metal kernel sources change; see Upgrade and rollout notes.
- Report why a complete-checkpoint SSD prefix store (the only GLM prefix cache) was not built instead of silently serving uncached: the provider logs one public line naming the model and a typed reason such as `key_unavailable` with the Keychain/Secure Enclave status (an ad hoc signed build has no keychain access group), and local `/metrics` adds `detail="<reason>"` to the `error` `prefix_cache_status`; the heartbeat reason stays `cache_init_failed`. DEBUG builds only can take a persistent cache key from an operator-created 32-byte, mode-0600 file named by `DARKBLOOM_DEBUG_CACHE_KEY_FILE` for qualification; release builds do not contain that path.
- Accept OpenRouter's GLM reasoning controls: `reasoning.enabled: true`, `reasoning.exclude: false`, `include_reasoning: true`, `enable_thinking: true` and `chat_template_kwargs` `enable_thinking`/`thinking: true` are no-ops that leave the prompt unchanged, and a positive `reasoning.max_tokens` without an effort selects `low` (up to 1,024), `high` (up to 8,192) or `max`. GLM thinking can be turned off with `reasoning.enabled: false`, `enable_thinking: false`, `chat_template_kwargs` `enable_thinking`/`thinking: false` or effort `none`/`off`: the prompt ends with an empty `<think></think>` block, as the template writes for an assistant turn without reasoning, and the answer is content only. Thinking-off combined with a thinking-on switch, an effort level or a reasoning budget gets HTTP 400. Hiding generated reasoning (`reasoning.exclude: true`, `include_reasoning: false`) still gets HTTP 400 with the fixed local message "GLM-5.3-Flash returns the reasoning it generates; reasoning.exclude true and include_reasoning false are unsupported. To turn thinking off, send reasoning.enabled false, enable_thinking false or reasoning_effort none." and code `unsupported_value`.
- Hash model weights with uncached (`F_NOCACHE`), page-aligned reads before and after a load, so integrity hashing no longer pulls a second copy of the weights through the file cache. On a 256 GB M5 Ultra the cached pre- and post-load hashes of GLM-5.3-Flash's 181.7 GB pushed about 150 GB of the just-loaded weights into the memory compressor (memory pressure warning) and stalled the first request. Digests are unchanged.
- Pin the SDK with GLM-5.3-Flash's bitwise kernel speedups for one Mac (mlx-swift-lm #314): KDA prefill recurrence and long-step convolution, MoE NAX tile plan, shared experts inside the routed prefill launches where MLX itself would not split K (65 rows and more), faster MoE gathers and decode router, one-launch hyper-connection sites, DSA decode selection and prefill projections. On one M5 Ultra the greedy output is byte-identical to the previous pin (provider endpoint 14/14, SDK fixed-depth MTP 30/30 token sequences) while prefill is 12–13 % and decode 16–18 % faster. The MTP history work is now charged per prefill chunk, so each GLM MTP request reserves 4.89 GB fixed instead of 11.31 GB.
- Bring three bit-identical GLM-5.3-Flash speedups that previously reached only the deprecated contiguous forward to the paged path that serves it (mlx-swift-lm #314): decode and verification steps reuse a shared all-true validity mask and build their token embeddings in one launch; prefill attention projections on Neural-Accelerator GPUs run a native GEMM kernel that matches MLX's bit for bit; and each sparse-attention layer stages its KV rows in one launch. Output is bit-identical to the previous pin. Paged decode and MTP verification keep the absorbed attention: the split-K sparse decode attention stays off on the paged path because its output is not bit-identical to the previous pin. The prefill projections give bit-identical logits on a 15,901-position perplexity panel.
- A request refused because the Mac's serving concurrency is full, or (GLM) because the slot is full or the request can never fit it, now gets HTTP 503 with the fixed capacity message before any response headers, for streaming and non-streaming requests, instead of a 200 stream ending in a `server_error` "Response generation failed" frame. Coordinator-connected requests still receive a retryable `capacity`/503 `token_budget_exhausted` error, now sent before the stream with the usual capacity-rejection fields.
- Keep running GLM requests alive when memory is nearly full: a step whose scratch reservation is refused is now deferred instead of failing every row of the step; the requests admitted in that step wait for capacity and new admissions pause until a running request leaves (mlx-swift-lm #314). On one M5 Ultra with the SSD prefix store, three ~60K-token requests previously all failed when the second finished prefill; now the running ones continue and the third waits.

### GLM-5.3-Flash video input

- Serve GLM-5.3-Flash `video_url` parts (inline `data:video/mp4` or `data:video/quicktime`) instead of refusing them with 400. The processor reads every frame of the constant-frame-rate track but converts and keeps only the 2 FPS official sample (RGB8, within its 512 MiB decoded-frame cap), and places each sampled frame pair as an image-token span with its timestamp; video rows decode target-only and never reuse cached prefixes, like images. The media reservation adds each video's token ceiling and, once, the processor's decoded-frame cap (videos decode one at a time). Variable-frame-rate clips, clips whose sampled frames exceed the decoded-frame cap and clips whose visual tokens exceed the shared 28,532-token prepared-pixel cap are refused with 400.

### MiMo tool-schema ingress parity

- Preserve original MiMo Chat function-tool schemas across provider/local prompt rendering, serving, recount and benchmark preparation, including typeless enums and Boolean properties.
- Keep existing hosted-tool fallback, malformed-declaration refusal, reserved-schema metadata checks and other model families' normalization.
- Add public scripted-generation regressions; full-model and live platform qualification remain separate.

### GPT-OSS bf16 activations and KV

- A bf16 GPT-OSS checkpoint such as `gpt-oss-20b` now keeps bf16 activations
  and native K/V on every layer. The expert SwiGLU clamp used float32 bounds,
  which promoted every layer after the first to float32; its scalar bounds now
  take the activation dtype. Float32 models are unchanged.
- `gpt-oss-20b` native full-attention K/V falls from 49,152 to 24,576 bytes per
  token. A slot grant holds about twice as many GPT-OSS tokens, and the
  heartbeat `kv_bytes_per_token` halves. Admission, paged storage and
  checkpoint identity already use the observed native K/V types.
- Measured cold TTFT falls 21-26% on an M5 Ultra (512-8,192-token prompts)
  and 14-18% on an M3 Ultra (2,048-32,768 tokens). Aggregate decode at batch 8
  rises from 153 to 519 tokens/s on the M5 Ultra and from 275 to 314 on the
  M3 Ultra.
- Output is not bit-identical to the float32 path. On 6 teacher-forced samples
  of 256 tokens, mean token NLL moved from 3.8146 to 3.8123 and top-1
  agreement with the float32 path was 93.3%.
- GPT-OSS SSD complete checkpoints written with float32 layer types use a
  different checkpoint namespace and are not restored. Matching prompts
  prefill cold until new checkpoints are written; the old files expire.
- The 3.5 GiB `gpt-oss-20b` activation floor is unchanged. It was measured on
  the float32 path.

### Wider mixed-step prefill for Gemma 4

- Gemma 4 prefills prompts in 2,048-token chunks with a 4,096-token step budget, including while other requests are decoding, instead of 512-token chunks beside decode. Busy engines reach the first token sooner and decode each stream faster; solo prefill chunking, KV capacity, paged ring sizes, load quotations and activation floors are unchanged. On contiguous KV (Gemma 4 artifacts other than the catalog's paged `gemma-4-26b-qat-4bit`, or with paging disabled), a solo prompt whose 2,048-token chunk cannot reserve KV now waits or is preempted instead of retrying with 512-token chunks, as the former 2,048-token stripe did.
- Gemma 4 image and video requests keep 512-token chunks, so their attention memory is unchanged.
- A decode token that shares a step with a long prompt now waits for a 2,048-token chunk instead of a 512-token one: typical inter-token gaps shrink, the slowest grow.
- GPT-OSS and dense Qwen3.5/3.8 also reached the first token sooner with the wide geometry, but at eight 32k-token prompts it raised their activation peaks further above their memory floors, so they keep the 512-token chunk and 2,048-token step by default. Nemotron 3.5, Bonsai, MoE Qwen, Qwen3-VL, Qwen4, MiMo and other families keep them too.
- Set `DARKBLOOM_CBV2_PREFILL_CHUNK=512` and `DARKBLOOM_CBV2_STEP_TOKENS=2048` to restore the previous Gemma 4 geometry, or `2048` and `4096` to opt another family in; `darkbloom start` forwards both to the background provider. Either override disqualifies reviewed serving and deadline profiles, like other `DARKBLOOM_CBV2_*` settings.

### Qwen3.8 forced tool calls

- The embedded-MTP Qwen3.8-27B build now advertises `tool_choice` `required`
  and named-function support, like the original build it replaced, and forced
  calls accept the catalog's default `qwen3_5` parser instead of failing with
  an invalid request.

### Qwen3.8 unsupported reasoning effort is a client error

Qwen3.8-27B requests with thinking enabled and an effort its template does not
accept, such as `high` or `minimal`, now fail before rendering with the typed
HTTP 400 that Flash-Next already returns. Text requests previously surfaced as
a provider 500 `template_render` failure; media requests hit the same raise
inside vision preparation and were reported as a retryable 503
`capacity_busy`. Typed request errors from media preparation now keep their
own status.

### Qwen and Bonsai histories without a user query are a client error

Qwen 3.5, 3.6 and 3.8 and Ternary Bonsai 2 requests whose history has no user
turn beyond `<tool_response>` wrappers (for example only a system message, or
system plus assistant) now fail before rendering with a typed HTTP 400. They
previously reached the template's "No user query found in messages." raise
and surfaced as a provider 500 `template_render` failure.

### Tool calls stream while they are generated

Chat streams now send `tool_choice: "auto"` calls from Gemma 4, Qwen 3.5, 3.6
and 3.8, GPT-OSS and framed-JSON models as OpenAI `tool_calls` fragments while
the model generates them. The call's `id`, `type` and function name arrive as
soon as the name is generated, followed by argument fragments. A response that
started with a tool call previously had no content until the whole call and the
end of generation were produced, so its time to first token included the
entire call. Each call is still validated against its declared tool and schema
when it completes. Required and named tool choices keep validating before
anything is shown.

Long tool calls in the Gemma, GPT-OSS and framed-JSON formats no longer cost
provider CPU time that grows with the square of their length: parsing a 64 KB
Gemma file write took about 20 s of CPU and now takes about 0.1 s.

Qwen3-VL Instruct, whose generation prompt carries no think marker, now
streams its answer instead of buffering it until the end.
`DARKBLOOM_TTFT_STREAM_TOOL_CALLS=0` and `DARKBLOOM_TTFT_THINK_CONTENT_SEED=0`
restore the previous behaviors.

### Faster prompt preparation and admission

- Prompt preparation reuses the token IDs of chat-template pieces (the text
  between special tokens) already seen in the same prefix-cache scope, so a
  follow-up turn of a long conversation no longer re-tokenizes its history.
  Token IDs equal the previous path's; a load-time self-check and sampled
  background comparisons disable reuse on any mismatch, including a prompt
  the previous path would have rejected. On an M3 Ultra a
  27–38K-token follow-up turn now prepares in 5–8 ms instead of 102–264 ms,
  and new long prompts prepare 2.3–3.4× faster, encoded on several cores.
  `DARKBLOOM_TTFT_PROMPT_CACHE=0` restores the previous path.
- Gemma 4 and GPT-OSS chat templates rescanned the whole history for every
  message, so render time grew with the square of the history length: 0.72 s
  for 1,603 Gemma messages on an M3 Ultra, on every request. Cached
  prompts now render through equivalent linear-time forms of those loops
  (26 ms for the same history), checked against the served template at load
  and in the background comparisons. A 610-message, 44–46K-token agent loop
  now prepares a follow-up turn in 15–21 ms instead of 213–346 ms. In an
  end-to-end tool loop of about 400 messages and 18–22K tokens, every request
  reached its first token 45–152 ms sooner on Gemma 4 and GPT-OSS.
  `DARKBLOOM_TTFT_TEMPLATE_LOOPS=0` keeps the served template.
- The Jinja null sanitizer returns plain string, number and Boolean leaves
  without reflection: 5.4 ms instead of 12.5 ms for a 603-message history.
- For requests without tools or legacy function calls, the decrypted request
  body is parsed once for the chat request and its extension fields instead
  of five times.
- A request waiting for a cold model load (other than native MiMo) no longer
  holds the coordinator work queue: resident models' requests, cancels and
  attestation challenges proceed while it loads, and a cancel for it still
  applies when its admission returns. A request for another model that is not
  resident still waits for that load, so its capacity check sees the memory
  the load takes. A request for the model being loaded that fails that check
  while the load runs is checked again once the load returns, as before.
  `DARKBLOOM_TTFT_COLD_LOAD_RELEASE=0` restores the serial queue.

### Startup shape warmup

- After a new install or a macOS or MLX kernel update, the first long prompt for each model paid seconds of on-demand Metal kernel compiles: an 8K-token first request took 4.4 s instead of 2.9-3.0 s (Gemma 4 QAT) and 4.1-4.2 s instead of 3.4 s (GPT-OSS) on an M3 Ultra, and 3.2 s instead of 1.1 s and 5.3 s instead of 1.6 s on a shared M5 Ultra. Startup preload now warms the kernels that long prompts, the served batch width and MTP verify use, after each model loads and passes any self-test, before the provider registers or the local listener opens. A short probe skips the warmup when the compiled-kernel cache is already warm (about 0.2-0.3 s per model); on a cold cache the warmup takes 5.4-7.4 s per model before registration or the listener. If the served batch width grows later (power or thermal posture recovers, or more KV memory frees up), the next idle moment warms the wider width too. The warmup trains no rates, yields to any request, stays within 20 seconds per model and logs its outcome. This release changes the MLX kernels, so the first start after updating takes the cold-cache path. Set `DARKBLOOM_TTFT_SHAPE_WARMUP=0` to disable it, or `always` to skip the probe.

### Fewer GPU stalls while serving

- The proactive MLX buffer-cache sweep no longer flushes between busy engines' steps while admission headroom is healthy. It waits for five seconds of whole-Mac idleness and then flushes without reporting device activity, so deadline quiescence and idle calibration survive it; a request that arrives during that flush is admitted after it instead of starting on a pool being emptied. While engines serve it flushes only when the reusable pool crowds out admission headroom, and a refused engine-owned KV charge or native MiMo media reservation now signals the same shortfall-gated reclaim as request reservations. Load gates drop that pool and resample before evicting a resident model. `DARKBLOOM_TTFT_IDLE_CACHE_SWEEP=0` restores the old sweep; refusals keep signalling while segment retention is on.
- Paged KV pools keep up to an eighth of their slot grant (at most 2 GiB) of free segments across requests and reinstall them for the next admission instead of allocating, zero-filling and fencing new 64 MiB segments. New segments wrap zero-fill-on-demand host pages, so admission no longer drains queued GPU work under the process-wide MLX eval lock. Retained segments are uncommitted (no grant, floor or ledger charge), are dropped on a refused admission or on process memory pressure (any refused charge, a pressure sweep or a macOS memory-pressure event) and return to the allocator after 30 s of engine idleness. The provider, standalone and managed Nemotron Super load gates release them before evicting a resident model or refusing, and startup preload releases them before skipping a model. Cold loads count them as reclaimable only until that release: segments a busy engine has not dropped by the end of the release's wait never justify evicting an idle model, and pre-accept releases them and resamples before admitting a request on them. `DARKBLOOM_TTFT_SEGMENT_RETENTION=0` restores release-time trimming and device-filled segments; `DARKBLOOM_TTFT_SEGMENT_HOST_ZEROS=0` keeps retention with device fills.
- `darkbloom start` forwards all three rollbacks to the background provider, so they also reach launchd-managed providers.

### Qwen MTP decode without seed steps

- Qwen 3.5, 3.6 and 3.8 requests with the inline MTP head decode as ordinary chained steps while more than one request is decoding, because the head speculates for one decode row only. These steps previously ran unchained, each with a vocabulary-wide policy top-two reduction and an extra host readback. The head's history is still fed from every committed position, so speculation resumes without a seed step when one request remains.
- The final prompt position seeds the first speculative round, so speculation starts right after the first token instead of after one extra target-only step.
- Rollback: `DARKBLOOM_TTFT_QWEN_MTP_CHAINED=0` restores the seed steps and `DARKBLOOM_TTFT_QWEN_MTP_CARRY=0` restores the post-first-token seed step, in processes that receive them (LaunchAgents do not forward them).
- Add opt-in `benchmark --runtime-generation --runtime-concurrency <sizes> [--runtime-stagger]`: one production slot per batch size, with per-token arrival times, chained steps and MTP counters as JSON, plus model, prompt, precision and assistant provenance. Malformed size lists, and staggered runs whose `--max-tokens` is below 3×B, are refused before the model loads; a slot narrower than its batch, a `length` terminal before the row's quota, a `stop` without a configured stop token or an early stop in stagger mode exits with status 2 instead of passing as a measurement.

### Faster Qwen Gated DeltaNet prompt prefill

- Run Gated DeltaNet prompt chunks of 16 or more tokens for Qwen3.5, Qwen3.6, Qwen3.8 and Bonsai 2 models on kernels that compute four value rows per SIMD group. On M5 Ultra the per-layer recurrence is 1.45-1.70x faster (Qwen3.5-9B geometry, 4,096-token chunk: 3.160 to 1.930 ms), which is estimated to save 3-4% of Qwen3.5-9B cold time to first token at 8K-32K prompt tokens. Decode, MTP verification, masked updates and shorter chunks keep the existing kernel.
- A new kernel runs only where it reproduces the existing kernel bit for bit, so outputs and recurrent checkpoints do not change: the first prompt chunk of each model geometry checks this on the GPU and keeps the existing kernel where no candidate matches. On M3 Ultra, Qwen3.5-9B cold prefill takes 1.1-1.3% less time at 2K-32K prompt tokens; speed on other M1-M4 GPUs is unmeasured. `DARKBLOOM_TTFT_GDN_BLOCKED=0` restores the existing kernel. `darkbloom start` forwards it to the background provider, so the rollback also reaches launchd-managed providers.

### Fused causal prompt attention

- Attend a full-attention prompt chunk with one fused causal attention call instead of 128-query blocks when MLX serves its head geometry with a fused kernel: head_dim 64, 72, 80, 96 or 128 on every Apple GPU, and head_dim 256 on M5 (NAX) chips for chunks of at least 1024 tokens. That includes the full-attention layers of GPT-OSS and Nemotron 3.5 Lightning on every chip and the head_dim 256 full-attention layers of Qwen-family models in M5 solo prefill stripes; sliding-window, softcapped, vision-span, live packed paged KV and Gemma 4 layers are unchanged.
- On M3 Ultra, GPT-OSS 20B cold time to first token drops from 19.5 s to 17.4 s at 32K prompt tokens and from 3.41 s to 3.30 s at 8K. On M5 Ultra, Qwen3.5-9B peak memory at 32K prompt tokens drops from 13.86 GB to 12.03 GB because its head_dim 256 layers no longer materialize attention scores.
- GPT-OSS teacher-forced scores are bit-identical; Qwen output on M5 can differ within bf16 rounding; Nemotron 3.5 Lightning and the other qualifying models were not measured. `DARKBLOOM_TTFT_FUSED_CAUSAL_PREFILL=0` restores the blocked path in a foreground process; the provider LaunchAgent does not receive it.

### Deadline admission estimators

- Charge decode in first-token deadline projections once per batch step, priced from the step shape the decode rate was measured at (rows, confirmed tokens and draft width per step), instead of summing every running row's tokens against a per-request rate. Each measured step's duration is smoothed together with its shape, so requests measured at different batch widths never pair one width's rate with another's rows, and the rows of the step that produced the first token, which the decode rate does not time, are left out. An MTP round is priced by the tokens it was measured confirming rather than its full draft width. Rows the live MTP planner cannot speculate (beyond its batch gate, or with no depth left inside the automatic verification envelope) are charged their one target token instead of the full draft width, no row is charged more depth than that envelope allows, and a full-slot MTP stretch with no live depth is projected in one jump like plain decode. A request carrying a reviewed deadline calibration keeps the per-row charge its error envelope was measured against.
- Stop one slow "isolated" prefill sample from locking an ordinary engine out of deadline admission until restart. The aggregate prefill rate is never priced below one eighth of the startup calibration's idle rate, and isolated evidence that expired while the whole Mac was idle at nominal posture is priced at no less than that rate. Evidence older than 30 minutes on an idle Mac is treated as absent, with or without a calibrated rate, so a calibration slowed by another process cannot lock admission either. The Mac counts as idle only when no other request on any resident model and no model load, encoder preparation or cache transfer is in progress. A fresh measurement for the request's prompt size still applies below that floor, so a short calibration never vouches for a long prompt. Published rates are unchanged.
- Keep measurement age and expiry tied to the newest observation when older completed work arrives later, and stop a late older cold sample from restarting the combined prefill estimate.
- `DARKBLOOM_TTFT_ADMISSION_FIXES=0` restores the previous estimators. `darkbloom start` forwards it to the background provider, so the rollback also reaches launchd-managed providers.

### SSD restore no longer waits behind another request's prefill

- Restoring a complete prefix checkpoint from SSD no longer blocks on MLX's
  process-wide eval lock while the engine runs another request's prefill
  chunk. On an M5 Max with Qwen 3.8 27B, staging a 0.96 GB checkpoint during a
  concurrent prefill dropped from 2.6–3.8 s to about 0.35 s.
- Added the opt-in `ModelCheckpointRestoreContentionLiveTests` real-model
  regression, which requires SSD restore to reach its demanded boundary, never
  to produce its first token later than cold prefill, idle or contended, and to
  stage as fast contended as idle.

### Deeper SSD checkpoint restores on large-memory Macs

- On Macs with at least 48 GiB, complete-checkpoint SSD restores now default
  to a 7 GiB / 15 s staging cap instead of 1 GiB / 1 s. With Qwen 3.8 and MTP
  the deepest restorable prompt prefix rises from 8,192 tokens to about
  94,000. On an M5 Max 128 GB a 20k-token fork's first token dropped from
  about 17 s to 6 s (27 s cold). Explicit
  `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MB` / `_MS` settings still win in
  processes that receive them (LaunchAgents do not forward them), attention
  block caches keep their defaults, and the daily SSD write cap is unchanged.

### Local Responses continuation and reasoning

- Continue local Responses requests with `previous_response_id`, preserving input, reasoning and correlated tool history. Reject non-null invalid ID types and unavailable IDs with HTTP 400 before model acquisition; null remains absence.
- Bound continuation history with an application-local LRU. Response retrieval uses a separate in-memory object store, so a retrievable response can have expired continuation history; neither store survives application restart. `store: false` suppresses both new saves.
- Select omitted local reasoning parsers by model type while preserving explicit overrides. Keep unfinished prompt-side thinking in reasoning fields for collected Chat and Responses, retrieval and continued history, with the paired SDK parser repair; native parsed channels and token usage remain authoritative.

### Provider start and terminal hangups

- Stop the interactive model picker (`darkbloom start`, `darkbloom switch`) when its terminal goes away. It previously kept reading a closed input and used a full processor core until the process was killed; it now cancels as Esc does, restores the terminal mode and leaves the provider unchanged.
- Drain a provider started by hand (`start --local`, or `start --foreground` in a terminal) when its terminal window closes, the same cooperative stop as Ctrl-C and `SIGTERM`, instead of ending the process at once. The launchd-run provider and a start made with `SIGHUP` ignored (for example under `nohup`) behave as before.

### Picker serving-set reserve

- Use the complete ordinary model selection's activation reserve in the catalog picker, so measured-only choices are not rejected using the unknown-model floor. Recheck existing choices when adding a model raises that reserve. Preserve the conservative Autopilot enrollment check and runtime memory safeguards.

### Fan helper startup discovery

- Retry an unusable startup fan or GPU sensor inventory every 30 seconds while the helper is enabled and awake. Restore previous ownership before accepting recovered hardware and require a fresh provider lease before engaging fans; transiently invalid startup sensor readings no longer leave the helper permanently unsupported. The fix is in the root fan helper: after updating, run `sudo darkbloom fan enable` so the installed helper matches the new app bundle.

### Interrupted watchdog launch recovery

- Recover a candidate's launch receipt when the watchdog exits after starting it but before recording success. A running candidate that never produces a heartbeat then reaches the existing startup timeout; missing launch evidence does not count as a failed start.
- Preserve unproven launch intent across health observations before restart. Require comparable saved and current launch evidence so an old serving process cannot acquire a false failed-start timeout when baseline evidence is missing or partial.

### Watchdog restart acknowledgement

- When a provider job disappears between the watchdog's launchd check and kickstart, report that no restart occurred and restore the previous crash-loop backend guard. Keep stopped or uninstalled jobs unloaded instead of recording a restart that launchd refused.

### Installer release file modes

- Extract the release bundle under umask 022 with `/usr/bin/tar`, so a restrictive caller umask no longer leaves installed app files owner-only. Private state created elsewhere by the installer is unchanged. New installs get it once the coordinator serves an installer that includes it; `darkbloom update` and the self-updater extract separately and are unchanged.

### Staging build environment

- Add `staging` as a third provider build environment beside production and dev. It has its own install identity (`darkbloom-staging`, Secure Enclave helper `darkbloom-enclave-staging`, app `Darkbloom Staging.app`, install dir `~/.darkbloom-staging`, config dir `~/.config/darkbloom-staging`, local port `8002`, LaunchAgent `io.darkbloom.provider.staging`, keychain prefix `io.darkbloom.staging`, encrypted-cache namespace `darkbloom-staging`) and the staging coordinator `wss://api.staging.darkbloom.dev/ws/provider`, so a staging provider runs beside production and dev on the same Mac. It shares the production model CDN like dev, and the signing identifier, keychain access group, MDM identifiers and fan helper stay shared across all three environments.
- Select the staging identity from a `-staging.N` version in the installer and the release tooling. Build it with `DARKBLOOM_RELEASE_ENVIRONMENT=staging` (`DARKBLOOM_ENV_STAGING`).
- A staging run uses only `STAGING_*` secrets. A tag never resolves to staging; master pushes publish staging only when `STAGING_ENABLED` is set (next entry).

### Master push publishes dev and staging provider releases

- A push to `master` now publishes a staging provider release in parallel with the dev release (DBLM-771: staging tracks main), gated by the `STAGING_ENABLED` repository variable. Staging is a normal Developer-ID dev-family release signed with the same certificate as dev and prod, versioned `X.Y.Z-staging.N` by the workflow run number. The gate defaults off (variable unset), so a master push builds and publishes dev only.
- Refactor the provider release pipeline into a thin caller (`.github/workflows/release-swift.yml`) and a reusable workflow (`.github/workflows/release-provider.yml`, `on: workflow_call`) that encapsulates the whole resolve, build, qualification, signing, R2 staging and publication chain for one environment. The caller routes each trigger to its lanes: a master push runs the `dev` and `staging` lanes in parallel, a `vX.Y.Z` tag runs the `prod` lane, and a dispatch runs the chosen environment. A plain matrix cannot carry each lane's artifact id and digest across the dependent jobs, so each lane is a separate call of the reusable workflow.
- The dev and prod paths are preserved exactly: the same signing, notarization, serialization groups (`release-dev` for dev, a per-run group for prod), version stamping and publication idempotency. prod remains tag-gated — `scripts/resolve-provider-release.sh` refuses prod on any non-tag trigger — so a master push can never reach the production signing identity. Accepted cost: with staging enabled, one master push runs two full build, sign, notarize and publish lanes (dev and staging are different binaries, identity is compile-time). Staging publication is not operational yet: without the `STAGING_*` secrets the lane fails when it resolves them, after build and qualification, and the publication step accepts only `dev` and `prod`. Keep `STAGING_ENABLED` unset until both are in place.

### Experimental dev-branch provider lane

- Add `.github/workflows/release-dev-branch.yml`, a dispatch-only lane that builds a provider from any branch or commit and publishes it to the dev coordinator as a self-signed (ad-hoc) release, without merging to master. It is dev-only: no tag path, no production environment, no production signing identity, and no production secret. It stamps the version `X.Y.Z-dev.branch.<run>` so it stays distinct from the master dev lane.
- Relax the installer signature check for pre-release versions only: for a version carrying `-dev.` or `-staging.`, `scripts/install.sh` accepts an ad-hoc or otherwise non-Apple-anchored signature while keeping the bundle identifier pinned and every other check in force. Production versions keep the full Apple-team requirement unchanged. The dev coordinator serves the relaxed installer only after the platform-served copy is re-snapshotted.
- The lane has not completed a run. The shared build step accepts only the dispatching `master` commit, and the installer still requires an Apple-signed fan helper, so it cannot yet deliver a branch build.

### Model publication

- Publish an already uploaded revision through the Register Model workflow without R2 credentials, preserving model metadata and prices.
- Document model-bucket access checks and the Bonsai 9B publication incident.

### Fixed-input scheduler-prefill benchmarks

- Add opt-in `benchmark --scheduler-prefill --prefill-fixed-prompt` to repeat seed offset zero for warmup and measured iterations. Default measured prompts retain their rotation; other benchmark modes reject the flag.
- Record prompt mode, warmup offset and per-sample offsets in backward-compatible optional report fields. Fresh engines, disabled prefix caching and the existing prefill stripe remain unchanged.
- Initialize the serving allocator limits before scheduler-prefill model loading and log the applied cache limit, matching the throughput sweep and serving paths.

### SSD test working-volume selection

- Honor the selected test working volume in SSD-prefix and bridge write fixtures,
  and report directory setup errors directly. Production cache safeguards remain
  unchanged.

### Threat review reliability

- Distinguish completed scans requiring human review from failed or incomplete
  scans. Preserve change context across source batches and reconcile Sol's local
  questions before its final decision, within existing spending limits.
- Add content-free failure diagnostics with validation codes, JSON positions,
  model/batch correlation and Bedrock request metadata. Raw responses, prompts,
  source text and credentials are excluded from diagnostic artifacts.
- Keep unresolved cross-file questions for human review and restrict each
  model's integration citations to its reviewed source. Preserve diagnostic
  progress across interruptions without allowing logging failures to hide reports.

### Threat review failure recovery

- New reviews use the current trusted scanner with the PR base threat model,
  preventing old PR bases from retaining obsolete review code.
- Request native Bedrock JSON output and nonempty batch analysis while retaining
  strict local validation and the existing model, spend and merge policies.
- Recover bounded report/cache write conflicts without repeating paid requests;
  distinguish state, GitHub and OpenRouter failures in content-free diagnostics.
- Give final integration reviewers bounded exact source evidence from their own
  reviewed scope, retaining explicit omissions and human-review decisions.
- Preserve Bedrock cache-read/write input accounting and enforce finding-text
  and analysis limits on raw characters, including whitespace padding.
- Stop further model calls after backup cost-accounting failures even if the
  primary provider recovers, retaining validated findings.

### Threat-review recovery and evidence retention

- Repair one otherwise valid response with empty/oversized analysis or incorrect
  primary acknowledgment per scan, within existing limits. Distinguish replayed
  source IDs and constrain integration acknowledgments; retain earlier findings
  and uncertainty. A second failure remains incomplete.
- Extend bounded retries for explicit state-branch conflicts without repeating
  paid calls. Persistent conflicts still stop the review.
- Retain validated advice and original diagnostics when native usage accounting
  or final-result delivery fails. Stop further spending on unknown accounting;
  reject final results from another workflow run or attempt.
- Record repair status and original request metadata in safe diagnostics and PR
  feedback. Distinguish a closed/merged PR from a technical review failure.

### Automatic threat-review completion and human handoff

CI sizes native review allowances from source batches, selected independent depth
and cross-file integration rounds, retaining one shared response repair and an
emergency ceiling. Generous native defaults allow up to 500 calls and 16,384
output tokens per call with ten minutes per native response. Maintainers can
lower the call and output limits through Actions variables. A longer bounded
scan deadline leaves time to save findings
and publish a human-review handoff when the scan cannot complete.

Normal reviews send critical source directly to Sol instead of repeating it with
Opus first. All source still receives Sonnet review and cross-file integration;
clean tests/docs avoid filename-only depth, and integration findings target their
cited batches. Global uncertainty requires human review without a blanket rescan.
Production attestation filenames are not mistaken for Swift test suffixes;
critical source outside explicit support trees takes precedence over filename hints.

Paid manual dispatches and GitHub job reruns are disabled. Incomplete reviews
explicitly require a human and cannot grant merge clearance. Advisory mode and
existing OpenRouter spending limits remain unchanged.

## v0.9.22

Published 2026-10-15 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.22)).

### Native Bonsai 9B preparation

Preserve native tool/reasoning framing and artifact sampling defaults for the Bonsai 9B candidate. Honor its image minimum within the existing serving budget. Honor explicit tanh/exact GELU declarations in native Qwen3.5 vision blocks, preserving the existing fallback for missing or unknown declarations. Select paged attention and encrypted SSD prefix caching by default for its exact identity, retaining operator opt-outs and runtime security/capability checks. Reject requests beyond the checkpoint's native context limit before inference.

Request MTP by default in automatic mode for the exact Prism/Eigen 9B identities and architecture. Resolve a validated catalog assistant asynchronously, with an explicit local path taking precedence, including the inspected affine 4-bit/group-64 head while retaining F16 rollback compatibility. Preserve the checkpoint's original base-weight precision, default to exact acceptance, and cap draft depth at two. Preserve drafter-required rectangular verification when runtime eligibility permits, with the existing target-only fallback. Plain inference remains available without the optional sidecar. Actual-artifact qualification and publication remain separate gates.

Return a structured HTTP 503 invalid_request_error when local POST admission has closed for a graceful drain. Preserve CORS headers, health checks, preflight requests, and ownership of already admitted responses.

Recognize the exact Prism and Eigen Labs 9B identifiers through the same request, cache and local MTP policies; artifact publication and coordinator activation remain separate.

### M5 paged serving concurrency

- Serve up to 8 concurrent requests per model by default on M5 Pro, M5 Max and M5 Ultra for models that the default `auto` backend selects for paged KV, when `engine_v2_max_concurrent` is absent from `provider.toml`. Other chips, contiguous models, models paged only by an explicit backend or live KV quantization setting, explicit global or per-model concurrency settings (including a `4` written by older releases) and reviewed profiles are unchanged; the coordinator's per-model quality cap still bounds admission.
- Fall back from that width to the configured width under Low Power Mode or thermal pressure, as reviewed profiles already do. `darkbloom status` and `doctor` describe the M5 default.

## v0.9.21

Published 2026-10-14 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.21)).

### Fixed

- Keep one-token startup health-check timings out of serving throughput estimates, and bootstrap supported loaded models, including ordinary dense and MoE Qwens, with bounded, preemptible measurements so slow first-use samples do not leave warm providers waiting for their first jobs.

### Dev provider builds have their own identity

- A dev build is now `darkbloom-dev` in `Darkbloom Dev.app`, installed in `~/.darkbloom-dev` with its configuration in `~/.config/darkbloom-dev`. It uses the LaunchAgent labels `io.darkbloom.provider.dev` and `io.darkbloom.watchdog.dev`, the default direct-mode port `8001`, its own encrypted KV cache directory (`darkbloom-dev/kv3`, also under a configured cache directory), its own log subsystems and its own keychain items. Downloaded model weights stay shared, but each install selects its own active revision. A dev provider and a production provider can run on the same Mac.
- The installer selects the dev identity when the release version contains `-dev.`. Production names, paths, ports, labels and keychain items are unchanged.
- An earlier dev install in `~/.darkbloom` cannot update to a dev build with the new names. Install the dev provider again with the dev `install.sh`.
- With both installs on one Mac: each install accepts only its own coordinator's MDM profile and names the other's; crash and jetsam reports match the exact process name; the fan helper keeps fans under control while either provider holds a lease, and `fan disable` / `fan uninstall` warn that they affect both; `doctor` warns when the other provider is running. The shared APNs app identity and `DARKBLOOM_*` shell overrides are documented limitations.
- Production change: provider OOM detection now matches only the exact process name `darkbloom`. Jetsam and memory-crash reports for `darkbloom-enclave`, the fan helper or any other process whose name contains `darkbloom` no longer count as provider OOM events. A crash report matches when its `app_name`, `name` or `procName` equals the process name.
- The fan helper is now version 2. It keeps one lease for each provider session. `fan status` and `doctor` report an older installed helper with the command that updates it (`sudo <cli> fan enable`), and `fan enable` refuses to replace a newer running helper with an older one.

### Automatic dev provider releases

- A push to `master` that changes the provider or its release tooling now builds, signs, notarizes and publishes a dev provider release. Tags still publish production releases unchanged.
- Every dev build has the version `X.Y.Z-dev.<run number>`. `darkbloom --version` shows it, and dev providers update to each newer dev build. Dev runs never receive `PROD_*` secret values.

### Provider repository ownership

- Remove centralized coordinator/backend, admin, integration-harness and deployment implementation from this repository; retain the Swift provider, local native runtime and landing site. The console source snapshot and its existing build, lint, test and hosting configuration remain unchanged. New backend, console and admin development belongs in the sibling platform repository; release/model registration remains an external API operation. Source ownership changes do not change deployed endpoints or authorize deployment.

### Agent-readable website discovery

- Give the Darkbloom website a stable canonical identity, structured product and organization metadata, and a public sitemap.
- Add readable product, pricing, contact and integration guidance, including Markdown responses and recovery links for agents.
- Publish a source-reviewed consumer API description while preserving API authentication and the existing browser experience.

### Community headlines and story browsing

- Introduce the homepage with “AI, powered by your Macs.” and the live grid with “Many Macs. One network.” Highlight the trailblazers and people contributing to the network.
- Browse stories by dragging or scrolling horizontally over their media or text, with keyboard navigation and native vertical scrolling preserved.

## v0.9.20

Published 2026-10-12 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.20)).

- Raise the default SSD cache write budget from 750 GB to 4 TB (4,000 decimal GB)
  per rolling day. Saved limits and environment overrides continue to take precedence.

### Responsive provider App Attest handling

- Process App Attest challenges, received authorization updates and connection invalidation while inference or model work is suspended. Keep model-work ordering and existing proof, expiry, key-reuse and revocation checks.

### Provider build environment

- A dev provider release now defaults to the dev coordinator `wss://api.dev.darkbloom.dev/ws/provider`. It does not fall back to the production coordinator. Dev and prod builds read models from `https://models.darkbloom.ai`. Local builds, tests and production releases keep the production defaults. `provider.toml`, CLI flags and `DARKBLOOM_R2_CDN_URL` still override the defaults.
- The LaunchAgent now forwards `DARKBLOOM_R2_CDN_URL` to the daemon. `darkbloom doctor` prints the build environment, the coordinator and the model CDN. `runtime-smoke` prints a `build-environment-runtime-smoke` line first.

### Provider cache storage controls

- Add `darkbloom cache set --daily-write-gb ... --directory ...` and `cache status` for persistent write limits and optional external cache storage. Validate local APFS storage, require encryption for external volumes, pin the volume UUID and refuse unavailable or replaced disks without falling back. Keep encryption keys and the rolling-day write ledger on the Mac; switching disks does not reset usage. Changes apply after restart.

### App Attest diagnostic wording

- Identify the `darkbloom doctor` key-generation countdown as a local safeguard and explain that the coordinator may retry later.
- Report generation attempts and the last recorded invalid-key attestation failure without inferring that every new key failed its first attestation. Recovery and authorization policies are unchanged.

### Autopilot consent journal contention

- Let independent provider sessions record Autopilot consent concurrently instead of serializing the fleet behind the inventory write lock. Preserve per-session ownership, account-erasure fences, and exclusive protection for identity merges and reward settlement.
- Keep canonical-machine ownership lookups scoped to materialized ancestor IDs so PostgreSQL does not scan the complete provider-session history on each consent observation.

### Changelog fragments and release history

- Keep pending release notes in separate per-change Markdown files instead of having every pull request edit the shared changelog. Release preparation validates and renders the selected notes without modifying files automatically.
- Group historical notes under their first published source tags, split entries added in later versions, and retain candidate qualification and deployment limitations. Source inclusion is not proof of production activation.

### Member-only automatic security clearance

- Limit scan-only merge clearance to verified active Layr-Labs organization members. Non-members, bots and unavailable membership require independent formal human review. Use a separate read-only membership token and retain ordinary CI and current-revision checks.
- Surface fixed validation-failure reasons in incomplete review reports without exposing raw provider output.

### Native inference and quantized checkpoints

- Default live attention to native precision and independently request balanced encrypted-checkpoint storage for eligible native paged and contiguous engines. Preserve explicit live `balanced`, `k8v4` and `k8v8` settings; checkpoint compression does not force paging or reduce native serving-memory reservations.
- Add separate checkpoint configuration, environment and benchmark controls, plus effective live/checkpoint precision and actual layout in local diagnostics. Unsupported storage layouts, persistent assistant state, MiMo, native-block diffusion and Qwen4 selected-index state retain native encoding.
- Encode and restore older checkpoint rows with bounded CPU conversion, preserving exact recent rows and native recurrent/auxiliary state. Distinct layout/profile identities reject incompatible data. Restoring a native format does not recover precision discarded on disk or guarantee identical output or latency.
- Add matched-geometry encrypted-checkpoint qualification with real native-memory, cancellation, tenant-isolation and restart evidence. Keep exact-native replay controls separate from lossy output observations.
- Retain adaptive target-prefix MTP for explicit live-packed execution using measured unchained decode as its baseline; native targets retain their chained baseline. Preserve whole visual-block admission, native-owner feasibility accounting, and packed historical frontier restrictions.
- Enforce paged model capabilities independently of legacy prefix reuse, and reject invalid checkpoint precision settings on the native Diffusion path without enabling unsupported compression.
- Preflight live-packed Diffusion kernels before engine construction and include the native-recent feasibility bound in reported request capacity without adding runtime reservations.

### Supervised App Attest worker candidate

- Add a default-off, same-signed-executable App Attest worker candidate. Keep the inference key in the parent process, bind proof replies to their originating socket, and retire the owned worker before replacement without restarting inference.
- Fence update installation and restart on confirmed worker retirement and current lifecycle ownership. After a failed update, fresh verification can retry cleanup of the retained owner; terminal shutdown cannot reopen it.
- Preserve the exact worker opt-in in background `darkbloom start`; keep native diagnostic/fault flags out of the daemon. Reject the unused component-only transport-resumption scenario rather than reporting unproven success.
- Record artifact-bound native suspended-worker, loaded-engine assertion-callback recovery, and separate composed two-minute resumption passes. These results do not qualify later rebuilt artifacts or the full OS/security-transition and fleet-rollout matrix.

### Provider endpoint resumption

- Add protocol-1 endpoint-custody responses for same-process reconnects, using a fresh nonce per socket and the existing in-memory encryption key. Requires the matching platform implementation; does not grant local trust or extend Apple proof lifetimes.
- Make `darkbloom logout` drain and stop the provider before removing credentials, and attempt revocation of the saved provider token. Report unconfirmed remote revocation explicitly.
- Bind saved tokens to their issuer and roll back failed credential saves. Preserve revocation URL authority, ignore unbound stale PID occupants, and allow local logout when configuration is malformed.
- Enforce resume control-frame limits before decoding, while preserving large ordinary inference frames.
- Add an isolated signed-app diagnostic for native loaded-engine endpoint resumption. Reject runs that exit before their completion marker; align the retained threat model with the authoritative platform policy.

### Automatic official provider release registration

- Trusted CI tests, builds, signs and notarizes, then automatically registers the exact official build through the existing scoped release API before publication. Per-release hardware qualification and manual approval are no longer prerequisites; runtime Apple proof, receipt verification and permanent revocation remain enforced.
- Require verified signed annotated production tags in reviewed master ancestry and trusted master for dev/manual/recovery runs. Release jobs use existing repository secrets without environment approval attachments; shared security settings are unchanged. CI and repository writers are trusted for build identity, not proof that runtime Apple APIs work.
- Deploy the matching platform persistence change first. Publication retries reuse immutable signed artifacts without rebuilding or re-signing. No new endpoint, signing authority, hardware service, provisioning or automatic version bump is introduced.

### Provider release version ownership

- Validate provider packaging and retained-build recovery against `ProviderCore.version`, the signed release tag and the built binary. The frozen coordinator display version no longer blocks provider releases; signed-source, SDK qualification and immutable-artifact checks remain required.

## v0.9.19

Published 2026-10-08 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.19)).

### Demanded prefix reuse

- Retain bounded demanded checkpoint capture, retention and continuation from MLX-LM PR #289 within the newer merged SDK pin, including native cancellation retirement and typical MTP acceptance. Rebuild and validate the combined SDK and provider; earlier full-model measurements retain their recorded dependency pins and acceptance settings.
- Retain a distinct demanded shared-prefix checkpoint even beside the deepest checkpoint, within the existing three-boundary and memory limits. Give authenticated repeated checkpoints access to the reserved SSD write share on their first local appearance; unique extensions continue to use the novel share.
- Preserve the demanded native-contiguous frontier between the first and latest checkpoints, account for its actual backing allocation before capture, and retire displaced native owners through the tracked fence. A small MiMo fixture verifies reopened fork parity with real MTP off and on; full-model hardware qualification remains separate.
- Capture one aligned demanded boundary in eligible dense Qwen and the verified current Nemotron Lightning and Bonsai text prompts below the normal solo stripe, so repeated short prefixes can be published for reuse. Nemotron and Bonsai require their exact catalog IDs, weight aggregates and actual recurrent classes; Bonsai remains MTP-ineligible. Keep novel requests and other serving layouts on their existing geometry, and price the extra range in the first-content projection.
- Preserve the original proposed long-prefill endpoint when the benchmark-only demanded partition splits a range. Share bounded request-local continuation with first-content projection and restore it on rollback; abandon it on incompatible actual progress. Serving long stays disabled pending same-donor adjacent-frontier, output and cost qualification.
- Bound COMPLETE donation hashing by the checkpoint being written, preserving its authenticated address and backend endpoint rules while avoiding unused suffix work. Native-media addresses and ordinary lookup remain unchanged.
- Reuse immutable compiled prompt templates within the bounded contract cache and avoid fixture-only body/token copies during production planning. Keep request dates, prompt data, proof identity and render limits isolated.
- Reconcile first-content input-token budgets from current verified exact counts matching each serving renderer before preflight and dispatch, preserving the original arrival time, account/alias policy and earlier caller deadlines. Missing or conflicting renderer identity keeps the fallback clock; calibrated uncertainty and provider recount cannot extend the budget.

### Bounded cache holder matching

- Reduce dense cache-routing query copies by retaining the deepest compatible endpoint for each provider and tier. Preserve shorter valid fallbacks, complete hint values and matching/valid-holder counts; bounded scratch overflow restores the original path. The original source-bound synthetic dense workloads measured 43–46% lower CPU query time and 97–98% fewer cumulative allocated bytes; these are not new measurements of the merged coordinator or evidence of production cache-hit or model TPS gains.

### Autopilot daily earnings floor

#### Autopilot reward recording and authorization

- Evaluate reward authorization at the declaration's original server receive time, preventing later grants from qualifying an earlier day. Record consent independently of baseline computation and batch PostgreSQL cohort lookups so fleet size does not multiply socket-path database round trips.

- End new Autopilot floor accrual after November 7, 2026 UTC for every machine, regardless of opt-in date. November 7 settles at midnight November 8; pending rewards for earlier eligible days remain payable without resetting baselines or ordinary base rewards.
- Add a separately funded daily inference-earnings floor only for machines with saved Autopilot consent. Freeze the first-ever opt-in baseline from the exact preceding 168 hours, including sponsored inference. Machines with shorter earnings history use comparable mature machines with the same chip, performance tier and memory; no matching cohort leaves the baseline pending. The daily floor is 110% of the seven-day daily average, rounded down to whole micro-USD, and remains frozen through Autopilot off/on.
- Require trusted macOS 27 or later, at least two distinct downloaded eligible models and saved Autopilot consent at daily close, plus at least 90% uptime across each UTC day. Merge overlapping sessions and identity aliases when measuring uptime; unqualified days receive no top-up and do not consume the independent pool.
- Persist authenticated consent evidence, baseline and canonical-machine daily receipts across reconnects and identity aliases. Historical opt-in dates were not recorded by older software: unknown history requires an evidenced admin backfill, never a guessed deployment/reconnect date or a reset through off/on. Backfill does not create earlier consent or reward days. Earlier positive evidence linked after freezing exposes `history_conflict` and holds further payments without rewriting the baseline or finalized receipts.
- Add admin inspection, absolute pool-cap funding and baseline-repair endpoints. The independent cumulative pool starts unfunded, does not reset automatically and never pays a partial shortfall; pending funding retries recalculate income, while finalized days remain final. Payments default off and do not activate live Autopilot control. Provider publication and production activation remain separate approvals; existing accounting archives do not yet cover the new financial tables.

### Machine model diagnostics

- Extend the authenticated admin machine view with per-session reported pins, resident models, hardware, snapshot freshness and the running provider's Always ready/idle-timeout configuration. Unknown reports remain distinct from empty pin sets or disabled settings. These read-only diagnostics do not activate Autopilot, change pins or idle policy, or guarantee ready capacity.

### Machine-scoped Autopilot

- Persist each canonical machine's desired Autopilot mode in the database, defaulting to shadow. Admins list and edit machines through authenticated endpoints without a coordinator restart; live control still requires verified identity, provider consent and acknowledgement, with global shadow and pause overriding intent. Other machines retain ordinary serving and hypothetical planning; memory, pins and donor safeguards remain enforced.
- Distinguish desired machine mode from current session activity, and report live-cohort, acknowledged-live and shadow populations separately. Mode revisions revoke stale grants, failed policy reads remove live authority, and demotion preserves accepted-operation recovery. This change does not deploy or activate a production cohort by itself.
- Keep capacity freshness checks current across policy reads and durable command delivery, so slow database operations cannot extend a provider snapshot's lifetime.
- Keep lease enqueue from waiting on a concurrent socket close while holding registry/provider locks; shutdown still stops admission before draining queued frames, and in-flight cancellation waits for the transport fence.

### KV admission estimates

- Reduce ordinary engine concurrency when fixed recurrent or MTP workspace would otherwise consume its KV grant before any request can run. Heartbeats and local admission use the same memory-limited width; load and reserve-raise preflights preserve a serviceable workspace-aware grant, without lowering activation or minimum-KV safeguards.
- Estimate cold-model KV cost from fresh native reports for the same artifact and verified runtime instead of always using the generic bytes-per-token fallback. Live slot budgets remain authoritative; missing evidence retains the fallback, and provider memory checks still decide whether a load or request actually fits.
- Share cold-rate evidence once per fleet sample instead of scanning peers for every provider. Unused on-disk advertisements do not trigger forecast work, and registry read leases do not span donor walks.

### Withdrawal funding queue

- Queue confirmed withdrawals when Stripe payout funding is insufficient. Earnings stay reserved, the coordinator retries automatically, and Billing shows a Queued status. International exchange estimates refresh when queued payments are sent; uncertain Stripe outcomes keep their existing payment identity and funds reserved. Funding waits do not shorten the return-check and account-erasure protection windows after Global Payouts dispatch.

### Bedrock review and conditional merge clearance

- Support an explicitly approved ongoing OpenRouter budget with daily and per-attempt caps, retaining historical charges and unknown reservations. Preflight now rejects exhausted budget capacity even when provider funding is available.

- Limit scanner checkouts to trusted scripts and threat definitions so preflight does not spend its timeout fetching unrelated repository content.
- Preserve exact source coordinates in review excerpts and keep summaries below strict output limits. Require human review when the final model still reports uncertainty.

- Add attributed Bedrock review with bounded OpenRouter fallback, explicit usage reporting, and optional current-revision merge clearance. Medium/high findings, incomplete scans, and review-control changes require an independent formal security override. Cloud and merge-policy activation remain a separate verified rollout.
- Validate the enabled Sonnet 5.5 profile for the first pass and matching OpenRouter backup, retaining Opus 5.5 and Sol 6.1. Exercise the full production response schema in the bounded Bedrock smoke test and record the deployed configuration.

### SSD Write Endurance (Historical Preparation)

This candidate contains the SSD write-endurance correction below. The version
bump does not publish, register or deploy the release; full artifact qualification
and publication remain separate gates.

- Enforce the SSD prefix-cache write budget across cache instances, model reloads and provider restarts using a persistent root-wide rolling-day ledger. Charge serialized cache-file bytes, including encryption framing, before writing; exhausted budgets retain read access and report `write_rate_limited`.
- Forward `DARKBLOOM_PREFIX_CACHE_DISK_GB` and `DARKBLOOM_PREFIX_CACHE_SSD_MAX_WRITE_GB_PER_DAY` into newly installed launchd provider jobs.

### Provider restart and drain status

- Let `darkbloom restart` and `darkbloom stop` finish their graceful drain on a provider that has served native MiMo requests. The drain tried to retire the native owner once; after any served request that attempt only starts joining the finished request's consumer, so the drain reported `timedOut` with 0 unfinished requests within milliseconds, the command failed, and the service was left draining with automatic restart disabled. The drain now retries the retirement within its own deadline and reports `drained` once the owner retires.
- Report a provider that has stopped serving on `darkbloom status`. After a `stop`, `restart`, `start` or `update` drain that timed out, was interrupted or never relaunched, the old process stays alive and refuses new work, so the console shows it offline while `status` printed only `Daemon: running`. A `Not serving:` line now names the drain state and the commands that finish or interrupt it.

### Cache reliability

- Preserve healthy SSD checkpoints when missing-file reconciliation alone satisfies the disk limit, and retain same-tag publications across reconciliation. Keep AR allocation refusals cold until the SDK can prove native retirement completion before a shorter retry.

- Preserve negotiated healthy preload incumbents across interrupted response bodies and readiness-probe transport failures. Keep malformed completed reports fail-closed, and do not acknowledge newcomers or retain explicitly failed members after an uncertain partial attempt.
- Align preload model-ID validation with the registration request bound so an already accepted long identifier cannot disable unrelated verified contracts. Keep the explicit artifact allowlist and tokenizer capacity limits unchanged.
- Preserve negotiated preload incumbents through uncertain control transport completion, and keep configured catalogs above 128 models usable without expanding cache-routing allowlists or native tokenizer capacity.

- Bound retained cache-attempt bookkeeping by logical bytes as well as record count. Detach retained metadata, preserve receipt and dispatch ownership checks, and fall back to ordinary inference when the optional cache record cannot be admitted. Under byte pressure, reclaim up to 64 completed attempts' late-receipt grace records, never live ones, before refusing, and report retained bytes, refusals and reclamations as aggregate cache status fields and gauges.
- Preserve healthy verified prompt contracts when unrelated artifacts or preload members fail. Bind Go participation to the current catalog, child and exact verified set; keep strict preload reports, fresh partial-readiness confirmation, bounded retries and Rust replacement/cancellation ownership.
- Account for optional cache-planning decisions across the inference endpoints, recorded when a request's plan is first computed (during admission preflight for public requests), and keep planning within the original first-content deadline. Preserve eligibility, inference contexts and independent retry/receipt ownership. Legacy plan metrics keep their definitions; one population grows: a media request to a verified, preloaded model is now counted once as `ineligible` in `exact_cache_plan_total` / `exact_cache.plan` because the planner is consulted to record its decision, with no routing or billing effect.
- Align cache-planning client concurrency with sidecar workers and reserve health/control connection headroom under nondefault worker configurations. Bound waiting requests and payload bytes within the original deadline, preserving cancellation, independent health/control traffic, exact prefix identities and fail-cold behavior.
- Select a bounded, demand-driven tokenizer preload set when the verified catalog exceeds the configured loaded-contract capacity. Keep the full verified set within capacity, current Registry eligibility, fair replacement and failure backoff; do not raise the sidecar limit or wait for preloading on inference requests. Negotiate incremental tokenizer preload so healthy acknowledged contracts remain usable during a retry or selection change without exceeding loaded-contract capacity, keeping legacy fallback explicit and failing closed on protocol loss.
- Allow one bounded, fully authenticated shorter complete-checkpoint restore after a proven pre-allocation capacity refusal. Retire failed native/host owners before retrying, retain request/epoch fences and original remaining read/time budgets, and leave generic allocation, corruption and cancellation cold. No capture-cap, precision, encryption or first-attempt admission change.
- Reject substituted FIFO cache entries without blocking encrypted-cache read or touch operations; preserve descriptor-based path checks and regular-file behavior.
- Preserve surviving encrypted SSD checkpoints and routing announcements during routine active-store capacity/TTL eviction. Coordinate durable writes and index commits with retirement to prevent rename-to-index races without global invalidation. Keep destructive epoch fencing for unsafe changes, native authentication and bounded stale-hint invalidation.
- Refuse and retry SSD epoch checks when parent-directory opens or metadata status probes fail transiently, preserving the existing store's ownership. Continue disowning proven missing, substituted, malformed or oversized records; verify the original capability again when connected retirement observes an eviction.
- Use actual malformed files in the resident-preflight corruption fixture, retaining its no-I/O and corruption assertions; cover confirmed missing-parent status and typed `ENOENT` reads separately.

## v0.9.18

Published 2026-10-07 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.18)).

### Typical MTP acceptance

- Default eligible sampled target-prefix MTP requests to typical acceptance (delta `0.2`) when `[backend] mtp_acceptance` and the model override are absent. Sampled output is approximate, not distribution-exact; explicit `exact` restores exact acceptance and invalid values remain safely exact. Greedy behavior, native MiMo exact acceptance, disabled MTP and model eligibility are unchanged. Benchmark acceptance still defaults to `exact`; the recorded single-host B=1 runs do not qualify sampled quality or fleet-wide speed.
- Add per-model typical MTP draft acceptance for sampled requests (`[backend] mtp_acceptance`, `mtp_acceptance_by_model`), ported from mlx-serve PR #427. Greedy requests are unchanged; slot posture telemetry reports `mtp_acceptance`.
- Pin the merged SDK implementation from `mlx-swift-lm` main; its file tree matches the engine revision used in the recorded acceptance benchmarks.

### 0.9.18 Release Preparation (Historical)

The next provider release is prepared from changes merged since `v0.9.17`.
This is not signed-artifact qualification or a release announcement. Included
changes are detailed in the retained topic entries below:

- [Provider service replacement](#provider-service-replacement) (#1315), [shared-host memory admission](#shared-host-memory-admission) (#1264), and [system tool output readers](#system-tool-output-readers) (#1327).
- [Authenticated legacy enrollment](#frozen-legacy-mdm-authorization) (#1344), including the signed CLI eligibility check. Older providers cannot use the new authenticated reenrollment contract; coordinate the bridge rollout before publication.
- [Native queued cancellation retirement](#native-queued-cancellation-retirement) in the pinned SDK and [provider lifecycle coverage](#provider-test-coverage) (#1253).
- [MLX gather row tiles](#mlx-gather-row-tiles) (#1237), including the compiled nested MLX and regenerated Swift kernels. Changed numerical paths require fresh qualification; earlier full-model results do not qualify this candidate.
- Honor an explicitly configured `TMPDIR` for anonymous runtime metallib snapshots, preserving unlink-before-copy and digest binding. Invalid or unwritable explicit directories fail without falling back elsewhere (#1322).
- The merged [DevNet installer binding](#devnet) is included; pending provider build-environment and release-qualification PRs are not.

The bundled coordinator build fix aligns the digest-pinned Go builder and local
toolchain at Go 1.26.8, satisfying the unchanged `go.mod` minimum of 1.26.0.
Release Integrity now rejects missing pins, local/container drift and toolchains
below the module minimum. The bundled [upgrade safety changes](#coordinator-upgrade-safety)
add migration budgets, early trust preflight and a default-off soft-delete
mutation gate. Coordinator deployment and provider publication remain
separate approvals; see the [candidate rollout checks](docs/operations/provider-release.md#0918-candidate-rollout).

### Coordinator upgrade safety

- Add `EIGENINFERENCE_MIGRATION_TIMEOUT` (default `15m`) for the positive total `--migrate-only` deadline, and `EIGENINFERENCE_CONCURRENT_INDEX_LOCK_TIMEOUT` (default `1m`, minimum `1ms`) for all concurrent index builders on dedicated connections. Ordinary SQL DDL retains its 3-second lock and 10-minute statement defaults.
- Preserve invalid indexes and fail with operator inspection guidance, including legacy earnings indexes; never automatically drop a potentially active external build. Schema versions and financial semantics are unchanged.
- Validate production App Attest serving prerequisites before database access or migrations, reusing the later pre-freeze validator. Explicit development and actual opted-in memory-store startup remain exempt; database-only maintenance intentionally skips full application validation.
- Default `EIGENINFERENCE_SOFT_DELETE_MUTATIONS_ENABLED` to `false`, blocking new erasure confirmations (including `force`) and owned-provider removal with 503 `soft_delete_mutations_disabled` after authorization. Plan/status/cancel and accepted scrub/outbox work continue. Prior tombstones or erasures still require compatible fallback code; disabling the flag does not restore old-image compatibility. Production env refresh preserves explicit opt-ins.

### MLX gather row tiles

- Backport row-tile selection for `gather_mm` and `gather_qmm` in the provider's pinned MLX dependencies, with matching regenerated Swift kernel sources. Rebuild with a source-matched metallib; earlier full-model measurements do not qualify performance on these pins.

### Account erasure

- Keep upstream error text out of erasure-outbox manual-action logs; retain safe correlation IDs, target, state and attempt count, with details available in restricted outbox records.
- Exclude pending-erasure users from provider-email exports after machine-owner ranking, and retain a private `resend_contact` cleanup obligation before clearing the account email. Resend contact, segment and scheduled-broadcast cleanup remains manual.
- Route late memory-store referral settlement credits through the erasure-aware credit path, matching PostgreSQL: erased referrers stay at zero balance and receive a refused-credit audit record instead.

- Preserve successful account-erasure results when the caller cancels after commit, so confirmation and scrub still disconnect providers and clear runtime caches.

- Clear unshared APNs token proofs, pending challenges and push bookkeeping from runtime memory after erasure; fence delayed cache publication while preserving live shared keys and fresh ownership.

- Fence delayed App Attest proof and receipt writes, APNs token persistence, session backfills and admitted log uploads against completed erasure. Preserve shared live device ownership, clear the frozen runtime MDM cohort by account, and keep late Checkout referral codes local and tied to their original owner.

- Fence in-flight credential creation, provider persistence, financial admission and delayed Stripe responses against deletion. Preserve late external IDs for cleanup, strip late telemetry locations while retaining accounting, and remove frozen MDM cohort/hardware-interest records. Shared identities are removed after the last owner is erased; replayed refused refunds remain idempotent.

- Add admin account erasure (GDPR): `POST /v1/admin/accounts/{account_id}/erasure/plan` (dry run and a 15-minute confirm token), `POST …/erasure` (soft delete; `force` scrubs at once), `GET …/erasure` and `POST …/erasure/cancel`. The confirm call must repeat the token and the account email, and refuses while a withdrawal is in flight.
- The soft delete revokes the account's API keys and provider tokens, disconnects its providers and starts a grace period (`EIGENINFERENCE_ERASURE_GRACE`, default 30 days). A Privy login during the grace period gets 403 `account_pending_deletion`; after the scrub the same login creates a new account.
- The scrub removes emails, labels, serial numbers, MDA chains, locations, raw logs, App Attest proofs, referrer codes, Stripe IDs and the named wallet addresses in one checked transaction, forfeits the balance with an `erasure_forfeit` ledger entry, and queues the deletion of every Stripe account and recipient the account used. Rows of a Secure Enclave or App Attest key another account shares are kept. IDs and financial records stay.
- The confirm call repeats the account ID and the planned wallet list. A Stripe payout paid within 30 days still blocks erasure. After the scrub, any late credit is kept out of the balance and listed for review as `refused_credits`.
- An outbox worker deletes the Stripe Express account, closes the Global Payouts recipient, redacts Checkout Sessions with Stripe Redaction Jobs (public preview; waits when transactions are under 90 days old) and writes one `erasure_log` record to Datadog (tag `erasure_log:true`). Definitive refusals, exhausted retries, stuck jobs and Checkout Sessions Stripe cannot find (each on its own row, the rest of the batch continues) end in `manual_action` for an operator; `GET …/erasure` shows each row's state. Each delivery claims its row just before contacting Stripe; expired workers cannot overwrite newer progress or create duplicate manual-action rows. Permission failures, invalid-account responses and ambiguous 404s retain the Stripe account ID for manual resolution rather than reporting deletion as complete.

### Pull-request stack tooling

- Add a checked, signed same-tree ancestry repair for dependent PRs after each parent squash, with atomic non-force pushes and optional retargeting. Document linear bases, manual reconciliation on content differences, and renewed signature, CI and approval checks; the tool does not merge PRs or automate conflict resolution.

### Personal data in coordinator logs

- Stop writing email addresses, IP addresses, device serial numbers and MDA UDIDs to coordinator process logs, which are forwarded to Datadog. Log lines name accounts by `account_id` (`user_id` in the access log) and providers by `provider_id`; the access log no longer has a `remote` field and the MDM webhook debug line no longer includes a body preview. Logs written before this change are not affected.

### System tool output readers

- Fix a hang in provider code that runs a system tool and reads its output, such as hardware detection for `darkbloom beta`, `autoupdate` and `models location`. When every Swift concurrency thread waited for a tool at the same time, the output readers got no thread, so the wait did not end. With a timeout, the call failed as timed out. Each output reader now has its own serial queue.

### Generated API-key queries

- Generate the coordinator's API-key queries with sqlc from the checked-in schema; `make sqlc-check` fails CI when the generated code or the schema file is stale. API-key behaviour does not change.

### Coordinator schema migrations

- Apply the coordinator's Postgres schema as numbered goose migrations instead of re-running every DDL statement at each boot. The first boot applies and records the existing schema as version 1; later boots apply only new versions. SQL migration statements stop waiting for a lock after 3 seconds and make up to three attempts, and coordinators that start together take turns on an advisory lock.
- Fail startup without recording the baseline when a required schema statement fails, so a later startup retries missing columns. Preserve current consumer-settlement, legacy MDM cohort, small-model interest and Stripe refund-index schema changes as subsequent versions.
- Check in the schema as `coordinator/store/postgres/schema/schema.sql` and test that the migrations build exactly that schema. New schema changes go in a new numbered migration file.

### Soft-delete schema

- Prepare account erasure: add `deleted_at` to users, API keys, provider records and provider tokens, hide soft-deleted rows from every live read, let a Privy user sign up again after erasure, index the erase paths, and cascade referrer code changes to referrals. Account erasure and ordinary provider removal write `deleted_at` behind the [mutation gate](#coordinator-upgrade-safety). After these migrations run, roll back only to compatible goose-based coordinator images.

- Exclude soft-deleted users from small-model interest exports before pagination, and exclude deleted users and provider records from initial legacy MDM cohort qualification. Repeated cohort reads preserve the frozen snapshot.
- Suppress stale registry-supplied provider locations in memory-store usage flows when the stored provider record is soft-deleted.

### Stripe refund clock skew

- Refund a rejected Stripe withdrawal when the coordinator clock is ahead of the PostgreSQL clock. Before, the refund check missed the withdrawal debit, refused the refund, and the recovery loop and `payout-audit --apply-refund` retried without success. The check still credits each withdrawal at most once and still refuses a ledger that does not show the exact debit.

### Nightly Linear workflow

- Package one-time Codex setup and a nightly playbook that reconciles work from Codex, Claude Code, and Pi with each teammate's Linear. Reuse existing issues and route unclassified deliverables to Others.
- Fetch shared skills from the configured repo branch on every trigger while keeping personal settings and recovery state local. Include offline updater tests; teammate installation and live automation remain separate rollout steps.

### Stale cache allowlist entries

- Report cache-routing allowlist entries that a model revision has left behind. Publishing new weights or a new template under the same model ID changes the artifact tuple, so the model silently lost cache routing and its cache hits fell to zero until an operator appended the new tuple. `GET /v1/cache/status` now counts such models as `artifact_allowlist.stale_models`, with matching Prometheus and Datadog gauges, and the coordinator log names each live tuple once. Routing behaviour and the allowlist's exact-match rule are unchanged.

### Mac CI cost controls

- Cancel superseded pull-request CI and integration runs without cancelling default-branch pushes. Bound provider unit-test stalls with the existing diagnostic watchdog, and reuse compatible integration build caches while retaining every test gate and parallel job.

### Archived analytics reader

- Add bounded asynchronous historical SELECT submission, polling, pagination and cancellation over pinned archive catalogs. Keep query results private and source retirement disabled while preparing the 14-day completed-detail storage plan.
- Allow explicit recapture generations, shard large completion catalogs, enforce replay deadlines and verify reused BigQuery catalog contents before publication.
- Pin and validate prior coverage before republishing, rejecting altered or duplicate catalog rows rather than incorporating them into a new verified digest. Unverifiable legacy catalogs fail closed without changing reader aliases.
- Add an opt-in validated local snapshot path for leaderboard, network totals and network series with source freshness checks and 503 responses when unavailable. Persist accepted source cutoffs and generation checksums in a separate private state file; snapshot mode fails closed if that file is missing or corrupt.
- Refresh database-backed network totals every 5 minutes with a 15-minute stale-success ceiling and cache successful network series for 5 minutes. Preserve shared top-200 leaderboard caching, failure cooldowns and the 30-second stats refresh.
- Reconcile aligned usage buckets across public series and reject reused BigQuery external tables whose manifest, configuration or schema differs from the verified publication.
- Replace the earlier telemetry-only retirement proposal with a 14-day completed-detail target covering telemetry and accounting. Keep active state and financial replay fences operational; continuous capture, broad reader migration and source retirement remain unimplemented and disabled.

### Provider test coverage

- Report Swift product, CLI and benchmark coverage separately in CI, merging isolated test-process profiles without replacing test failures with coverage results.
- Expand provider and standalone lifecycle, tiny-model loading, CLI/service/fan, SSD-cache and benchmark harness regressions with temporary state and scripted host boundaries. Keep real tiny-model execution distinct from full-checkpoint quality and performance qualification.

### Provider email campaigns

- Add the `provider-emails` operator command to preview provider software/macOS update audiences, sync owner groups to Resend, render and test notices, and create unsent broadcasts for review. Preserve unsubscribe preferences and remove owners from managed groups when their reported machines meet the target.
- Serialize campaign reply-to addresses in the Resend broadcast API's array form while keeping the campaign configuration's single-address input.

### Autopilot inventory reporting

- Add an admin-only connected Autopilot inventory report with exact per-model last-reported approval counts, deduplicated approval totals and a models-per-provider distribution. Distinguish unpaused, paused and stale connections without exposing provider identities or claiming fresh disk verification, residency or routing eligibility. The read does not depend on the operation ledger.

### Open Sales Program

- Add an Open Sales Program page to register and share a code, apply a referrer, and track referred consumers and earned rewards. Preserve referral links through sign-in and invite redemption.
- Reward referrers with 5% of their referred consumers' collected token spend as withdrawable earnings funded by Darkbloom. Consumer prices, provider earnings, and platform-fee credits remain unchanged.
- Settle consumer charges and referral credits atomically per request, excluding free or uncollected usage and preventing duplicate rewards. Keep attribution immutable and prospective; retire the old platform-fee-share setting.
- Include only the paid portion of token-promotion requests in referral earnings, atomically with promotion settlement.
- Exclude execution on the consumer's own machines, explicit self-routing, and selected-machine routing from referral rewards and eligible-spend totals, including paid owner-preferred fallbacks. The same exclusions apply to the paid portion of promotion requests. Request billing, provider payouts, and promotion grant use are unchanged.
- Require Privy sessions for referral mutations and retry uncertain settlement without releasing reserved service funds or repeating live-request accounting. Reconcile pending settlements during graceful shutdown.

### Routing scan cost

- Compact retained routing evidence, reuse bounded private reservation storage, borrow forecast inputs, project alternate-selection values once, and aggregate pending work once per provider snapshot. Public scan and quote lifetimes, selection policy, admission, retirement and billing behavior are preserved.

- Reduce the per-request provider scan cost after the coordinator reorganization. Autopilot eligibility reads the clock only for a provider holding a matching control grant, candidate ranking reads the projected pool in place, and candidate storage fills one allocation size class. Routing outcomes are unchanged.

### Canceled PostgreSQL debits

- Keep a PostgreSQL debit uncommitted until its statement succeeds, preventing a timed-out row-lock wait from later becoming a charge. Lost commit acknowledgements remain uncertain and must not be blindly retried.

### Shared-host memory admission

- Add opt-in `DARKBLOOM_MEMORY_AVAILABILITY=free-only` to exclude inactive pages from shared-host admission and KV headroom. Sampling failures fail closed in this mode. Preserve the default reclaimable-page policy and document what the memory reserve measures.

### Verification concurrency

- Keep a reconnected provider's verification job eligible after its old worker releases the claim. A delayed challenge callback no longer restores the stale running snapshot and postpones verification until claim expiry.
- Read one synchronized trust-level snapshot for registration metrics and telemetry while verification updates run concurrently.

### Provider service replacement

- Wait for launchd to confirm removal of the previous provider service before installing or starting its replacement. Preserve stop/uninstall intent and report failed or timed-out removal without starting another service.
- Treat bootstrap operation-in-progress errors as failures instead of reporting a successful start.

### DevNet

- The dev coordinator host is now `api.dev.darkbloom.dev`. The old dev host `api.dev.darkbloom.xyz` is retired. The provider does not accept an MDM server on `darkbloom.xyz` as a Darkbloom MDM server, and `deploy/provider-fleet/update-fleet.sh dev` uses the new host.
- An installer served by a coordinator other than production (for example dev) now writes that coordinator's `[coordinator] url` into `~/.config/darkbloom/provider.toml` and keeps the file's other settings, so `darkbloom start`, `login`, `update`, the LaunchAgent and the watchdog connect to it instead of production. The production installer removes that `url` line (and creates no file), so a Mac bound to dev returns to the production default. A running provider changes coordinator at its next `darkbloom start`.
- Add `coordinator/cmd/devnet-seed`, which fills an empty dev database with fake accounts, API keys, provider sessions, usage, ledger entries and balances. It refuses a database whose `users` table has rows.
- The dev VM boot path now sets `EIGENINFERENCE_IPAPI_KEY`, as `deploy/gcp/refresh-env.sh` already did.

### Leaderboard availability

- Add a concurrent BRIN time index for recent provider-earnings rankings, enable range autosummarization, and keep planner statistics current. Return an uncached 503 when ranking queries fail instead of showing and caching an empty leaderboard.
- Share one top-200 ranking fill across caller limits and equivalent window aliases. Coalesce concurrent misses, pause failed fills for 10 seconds, and include the remaining retry delay in leaderboard 503 responses.

### Cache reliability

- Remove caller-supplied top-level `user`, generic `metadata`, `safety_identifier` and `prompt_cache_key` from provider-bound inference bodies across direct, queued and retried requests. Preserve nested content, inference controls, coordinator response metadata, authenticated account ownership and cache controls; this does not anonymize prompt content.

### Frozen legacy MDM authorization

- Freeze a durable authenticated account/SE-key/serial cohort of already successfully MDM-verified devices on the first upgraded coordinator startup after revocation replay. Restarts preserve even an empty cohort; new accounts/devices and new associations cannot expand it. Gate identity recovery, scheduling, live/late MDM results and cached trust reuse. No grace period has been chosen and no expiry is implemented.
- Require a linked provider Bearer token and fresh signed SE-key proof for `/v1/enroll`; reenrollment is limited to the existing key under its frozen account. New identities require qualified App Attest, with no unsupported-OS fallback. Generic copied profiles can still enroll directly in MicroMDM; the restriction guarantees coordinator MDM authorization, not prevention of that direct enrollment.
- Require App Attest for noncohort owner self/prefer routing as well as public serving. Validate enabled production App Attest serving with full rollout before the startup freeze; invalid configuration fails closed without freezing membership.
- Require macOS 27 or later and current qualified App Attest authorization for base rewards for every provider, old or new, including machines with both MDM and App Attest evidence. The OS claim must belong to that same authorization; missing, malformed or older versions fail closed. Legacy MDM-only machines remain eligible for grandfathered serving but not base rewards. Existing economics guards and inference/work earnings remain unchanged, with no retroactive reward clawback.
- Check authenticated frozen account/key eligibility in `darkbloom enroll` even when a legacy profile is already installed; a successful check preserves that profile without reinstallation. Clarify that new providers need macOS 27 or later and current qualified App Attest, not an OS-only grant; consumers have no macOS 27 requirement.
- Update the enrollment HTTP integration fixture to verify a linked test token and canonical P-256 proof instead of expecting anonymous profile downloads.
- Drain eligible account-scoped historical inventory in 100-row batches before the first cohort freeze, within the existing 30-second startup deadline; errors or cancellation leave no new freeze marker. Preserve existing evidence and alias rules, exclusion of insufficient history, and the inability of later aliases to widen a frozen cohort.
- Keep the production cutover fail-closed while allowing explicit development and actual opted-in memory-store startup without freezing a cohort; deployment classification defaults to production and does not use telemetry tags.
- Retry transient provider-token store failures instead of misclassifying credentials: WebSocket registration closes with retryable 1013 and enrollment returns 503. Invalid or revoked credentials remain unauthorized.
- Stop anonymous installer profile requests; defer eligible legacy reenrollment until after installation through account login and the signed CLI eligibility check. Existing management is preserved, and new-provider macOS 27+/qualified App Attest guidance remains explicit.

### Native queued cancellation retirement

- Fix a pre-existing SDK race exposed during prefill-deadline validation: concurrent cancellation could remove a queued native request without retiring it, leaving its reservation charged. Use one cancellation decision for retirement and queue removal; retain exactly-once completion and reservation release after retirement.

### Budgeted advisory PR review

- Give PR authors Sonnet feedback before selective Opus/Sol 6.1 depth, reuse unchanged analysis, and debounce follow-up pushes. Show clean results, coverage, cost and saved historical findings in the advisory comment.
- Reserve shared spending before every provider request; cap normal/deep attempts, PR/day, repository/day and the ten-PR pilot. Preserve partial findings and unknown-cost reservations after failures. Paid scanning defaults to disabled; maintainers can preconfigure activation before merge after state-writer and funding verification.
- Keep findings citable across large diff fragments and publish a compact history link when the full report exceeds comment capacity.

- Add a manual activation preflight that verifies signed state writes and provider funding without paid model calls or changes to the spending ledger. Support a repository-scoped App writer with short-lived tokens; keep private funding details out of public preflight logs.

### Console chat request budget

- Refuse oversized chat requests locally with guidance to reduce images or conversation length. Check the full UTF-8 request and optional encrypted envelope before sending, retain the user's message and images, and apply the same check on retry. Existing per-file and image-count limits remain unchanged.

### Canceled queue waiters

- Stop canceled waiters held by a scheduling pass from returning as queued demand and occupying slots needed by fresh requests. Drop completed entries during queue pop and stale cleanup while preserving live FIFO order, timeout notifications, and reservation cleanup.

### Durable hardware interest

- Save Earn-page notification interest against the authenticated account before showing confirmation. Both notification buttons preserve pending hardware through sign-in, expose cancellation and retry, and recover confirmed status from the server after reload.
- Add per-account memory/Postgres upserts and a bounded admin-only export joined to current email. Hardware updates replace the account's previous selection; legacy anonymous browser markers no longer claim registration. No email delivery is added.

### Bounded non-streaming responses

- Bound coordinator retention of non-streaming provider output by aggregate bytes and frame count, including empty frames and the first chunk. Oversized attempts are cancelled and fail with 502 before successful settlement; streaming behavior is unchanged.

### Idle provider routing recovery

- Let idle providers with missing or stale measurements compete using fleet-median prefill and decode rates, replacing each rate independently while preserving reviewed profiles and deadline confidence. Expire independently dated decode estimates after 30 minutes only on loaded, idle providers with no pending work. Selection is not guaranteed, and physical admission remains unchanged.
- Back off failed exploration attempts and retain corroborated slow-rate evidence across reconnects, without treating deadline refusals as provider-health faults. Median-priced requests also feed back when they have no deadline or contain vision input. The TTFT calibrator does not learn from median-priced predictions.
- Deduplicate retained observations across reconnects, preserve newer healthy clears during identity merges, and treat explicitly missing performance evidence separately from an undated legacy EWMA. Replayed or invalid metadata cannot manufacture slow-rate corroboration.

### CI and contributor workflow

- Report coordinator statement coverage from the e2e tests as its own job-summary row, and keep the lane data as the `coordinator-e2e-coverage` artifact. The e2e lanes instrument the production coordinator packages only, as the coordinator test runner does, and both coverage reports use `scripts/coordinator-statement-coverage.sh`. The tests and their pass/fail rules do not change.

## v0.9.17

Published 2026-10-02 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.17)).

### Provider 0.9.17

- Keep the normal startup selection and explicit `--model` override authoritative while Autopilot is waiting or observing in shadow. Cached planning inventory can no longer make ordinary routing load unselected models.
- Separate cached candidates from serving advertisements in Autopilot protocol 3; retain full shadow planning and require an acknowledged live lease before additional models become loadable. Older coordinators keep the selected models serving without activating the new protocol.
- Preserve normal selected-model successor updates independently of Autopilot inventory, and show the serving selection in My Macs instead of observational candidates.

## v0.9.16

Published 2026-10-02 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.16)).

### Provider 0.9.16

- Offer the Autopilot yes/no choice on every normal interactive start, using the saved choice as default and retaining the normal startup model and memory selector, including explicit `--model` selection.

- Fix enrolled providers appearing stopped, rejecting graceful stop/restart, and accumulating false failed-start rollbacks because their Autopilot snapshot could not be decoded. Preserve heartbeat readability for a watchdog still running 0.9.15 during upgrade.
- Name each model during cached-inventory verification and report a busy model immediately instead of silently waiting behind a background revision update. Saved enrollment and the running provider remain intact when ordinary startup verification fails.

### Status page placeholder

- Add a standalone static status-page placeholder: "The status page will return in the future." Publishing it requires a separate hosting change; the existing Instatus content is preserved.

## v0.9.15

Published 2026-10-01 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.15)).

### Provider availability wizard

- Add `darkbloom start --schedule` for optional interactive background setup and `darkbloom schedule` for editing saved settings without starting or stopping the provider. Support saved windows, overnight/weekend presets, custom add/edit/remove, inspection, disabling and custom config paths.
- Offer preloading at window opening or on-demand loading using the existing startup-preload setting, preserving model selections and idle policy. Reject invalid enabled schedules before serving, merge overlapping/adjacent windows, honor local-calendar DST boundaries and keep full-week availability connected continuously.

### Self-service bank payout migration

- Add an explicit Global Payouts cutover for all supported bank destinations. Existing Connect users complete their own bank setup; history, earned balances and legacy account references are retained. US bank setup uses local transfers.
- Separate legacy Connect credentials and connected-account webhook verification from Checkout. Current and legacy Checkout events settle atomically without duplicate deposits.
- Recover verified rejected-transfer refunds atomically, require exact Stripe payout evidence during cutover, and check financial-account funding plus fees before new payout debits. Add a bounded audit tool and explicit, operator-verified historical refund repair.

### Nemotron parser and artifact defaults

- Absorb stray `</think>` markers in Nemotron Lightning content without changing other native-channel families or interpreting markers inside tool arguments.
- Apply Nemotron's artifact-declared sampling defaults only to omitted request fields; explicit values still win. Admit the hybrid8 and rollback concrete build IDs without changing the catalog or activating either build.

### Nemotron prompt fidelity

- Preserve function-level `strict` for Nemotron tool prompts and align the pinned Nemotron template's scalar/JSON filters with Transformers. Other model families retain their existing rendering and tool normalization. This repairs prompt fidelity, not all reasoning-off tool-selection failures in Q4.
- Keep numeric Nemotron values identical between provider rendering and exact-cache planning, including exponent formatting and the SDK's integral-number conversion. Apply non-Nemotron `strict` stripping to native media tool inputs as well as text; pinned metadata-only parity gates cover the reference and numeric edge cases in CI.
- Advance prompt normalization to v8 and renderer identity to v4 across provider and coordinator, retaining normalization v7 policies. This invalidates prompt-contract/cache identities for all families; regenerate sidecar contracts and allowlists together before rollout. No model weights, sampling defaults, tool-choice policy, or inference kernels change.

### MiMo SSD prefix-cache hits reuse the prefix

- Fix: every native MiMo V2.6 SSD prefix-cache hit was discarded. The bridge stages a checkpoint under a placeholder engine request ID and mints the real ID just before submit, and the SDK's native import check compared engine IDs, so each staged checkpoint was refused (`unsupportedConsumer`) and the request prefilled its whole prompt again. The pinned mlx-swift-lm binds a stage to its submission receipt instead. On a 256 GiB M3 Ultra, a repeated 6K-token prompt now reaches its first token in 4.5 s instead of 13.1 s, and a 12K-token prompt in 4.6 s instead of 27.3 s, with byte-identical output (MTP off and auto).
- Report `prompt_tokens_details.cached_tokens` from the standalone server only when the engine actually reused the prefix. A matched checkpoint whose adoption failed or was skipped previously still reported its matched tokens. Coordinator usage already came from the resolved lookup and is unchanged.

### Experimental model Autopilot

- Add default-off experimental Autopilot enrollment at provider startup. Yes or `--autopilot` skips the picker, discovers/verifies all eligible already-downloaded active network models, and records shadow consent without activation or downloads. Exclude arbitrary local/off-catalog, retired, ineligible and unverified builds; empty inventory fails before restarting. Preserve all saved serving, preload, idle and other preferences.
- Default coordinator Autopilot to observation only. It records hypothetical plans without residency reservations, fences or commands; explicit `EIGENINFERENCE_AUTOPILOT_OBSERVE_ONLY=false` enables a separately approved live rollout. Preserve the enable switch and runtime admin pause.
- Add Autopilot status, pause/resume, pins and disable; session-bound live control, selected-model boundaries, request-shape planning, retained load timings and durable operation records. Active control preserves files, local work and donor capacity.
- Keep approved cached inventory static across ordinary restarts. Explicit `--autopilot`, `autopilot enable` or `autopilot models` refreshes verified eligible cached models without picker/downloads; `--all` remains network-gated and enrollment with `--model` requires opt-out. A later live rollout chooses cached models to improve utilization, not guaranteed earnings.
- Deduplicate unchanged shadow proposals as first-write decision records, not a per-tick time series; the current summary stays fresh even when an unchanged decision ages out of recent history. Distinct state/session/revision decisions remain retained; live command IDs are unchanged.
- Reject coordinator unload victims outside the approved cached inventory while preserving guarded local superseded-model cleanup. Filter invalid UTF-8 ID bounds before verification, then validate the normalized verified inventory count before saving consent or draining; invalid inventory cannot stop the existing daemon or install a replacement.
- Preserve an enrolled provider's pause during ordinary start, `enable` and inventory refresh; resumption requires explicit `resume`. Validate saved inventory all-or-nothing before persistence/drain, including transient verification failures; only explicit refresh may prune excluded builds.
- Apply current full Autopilot settings at each new scheduled window. Disabling between windows restores ordinary saved model selection even if unchanged; other runtime inputs remain frozen.
- Queue pending-operation uncertainty before removing a disconnected provider, persisting outside registry/provider locks. Connection loss never implies rollback or a confirmed terminal resident set.

### Automatic MiMo Calibration (Historical Preparation)

- Calibrate idle native MiMo engines after model loading and refresh stale phase evidence with uncached built-in prompts. Measure short and 4k text plus affordable batches within the existing concurrency cap; retain the production MTP and memory configuration.
- Give customer requests priority across models: cancel calibration and wait for real native retirement before admission. Keep probe work out of served-request/token counters; publish actual phase measurements and optional peak-concurrency workload buckets through existing heartbeats.
- Align `ProviderCore.version` and the coordinator latest-provider display fallback at `0.9.15`. Publication, signed-artifact qualification and coordinator rollout remain separate operations.

### Provider prefill evidence recovery

- Let an idle native text provider renew expired isolated-prefill measurements through one short request under its original first-content deadline. Serialize the final idle check and native registration, then restore ordinary concurrency after prompt completion while retaining service and memory ownership until actual engine retirement. Back off failed or cache-only recovery; busy, loading, media and large requests retain predictive admission.
- Reseed measured phase EWMAs after an evidence gap while preserving sample identity/counts. Unchanged heartbeats cannot manufacture current prefill evidence.

### Native media prefill observations

- Retain native MiMo target-decoder prefill rates in dedicated numeric workload buckets, separated by computed suffix, context, reuse and overlap. Encoder preparation remains outside this timer. These observations support media calibration without mixing media into text rates or changing first-content deadlines.
- Price prepared native media from fresh observations of the same engine and observed prompt range. Keep queued text at its own conservative rate. A single idle native request can gather missing evidence under the original deadline, retaining ownership through real retirement. Failed or ineligible attempts back off for two minutes; an eligible sample opens the next shape after retirement.
- Pin the provider SDK to merged `mlx-swift-lm` main commit `e31a173` (#208) for native-media deadline evidence.
- Keep deadline-rate evidence invalidated when native media fails during later retirement, even after successful preparation; preserve the qualified text policy's separate recovery requirements.

### Native media prompt accounting

- Estimate concrete MiMo image/video/WAV prompt work from bounded media metadata and verified processor configuration. Reconcile fetched-media input quota and deadline token terms from the original request arrival; retain heuristic fallbacks and provider admission safeguards.

### Exact rectangular MTP for native MiMo

- Make exact rectangular verification the default MiMo MTP strategy. Rectangular verification scores all draft columns in one `[1, 1+k]` forward, but MLX's 2–7-row affine matmuls on M3-class GPUs use `qmv_wide`, whose reductions differ from one-row decode, so the bulk trunk was never output-identical. Scalar-dense rows (row-local router, serialized attention) with a new row-exact multi-row projection that keeps one-row `qmv_fast` arithmetic while streaming each weight once reproduce serial decode exactly. On a 256 GiB M3 Ultra, greedy MTP-on decode measured about 49 tok/s at short prompts and 46–48 tok/s at 4K prompts, against about 44.9 / 42.8 tok/s with MTP off and about 39 / 37.7 tok/s with serial MTP; 20K and 50K prompts decode at parity with MTP off. Greedy and reasoning outputs and audio responses were identical to MTP off. Media rows stay target-only, and a serving engine that cannot arm the scalar-dense scratch never drafts.
- `DARKBLOOM_MIMO_RECTANGULAR_VERIFY=0` (or `false`/`no`/`off`) or `DARKBLOOM_MIMO_RECTANGULAR_SCALAR_DENSE=0` selects serial-target scoring; `DARKBLOOM_MIMO_ROW_EXACT_PROJECTION=0` keeps exact verification with one matmul per row. All three are forwarded to the launchd provider job. The native paged profile stays serial-target.

### Native MiMo decode kernels and adaptive MTP

- Enable the native MiMo short-forward decode kernels by default: fused residual/RMS norms, distinct-expert MXFP4 decode and the FP32 router GEMV. Each matches the stock operation it replaces for its supported one-request 1–7-row shapes and falls back everywhere else. They were exact-`1` opt-ins that no LaunchAgent forwarded. On a 256 GiB M3 Ultra with MTP off, single-stream decode rose from 41.5–42.0 to 45.2–45.6 tok/s (short prompts) and from 40.4–40.7 to 42.8–43.4 tok/s (4K prompts), with greedy output identical on 8 short and 5K/9K-token prompts. `DARKBLOOM_MIMO_FUSED_DECODE_NORMS`, `DARKBLOOM_MIMO_DECODE_EXPERTS` and `DARKBLOOM_MIMO_DECODE_ROUTER_GEMV` accept `0`/`false`/`no`/`off` as rollbacks and are forwarded to the launchd provider job.
- Keep native MiMo's adaptive MTP from launching serial-target draft rounds. Serial scoring evaluates every draft column with one ordinary target forward, so those rounds cannot outpace target-only decode; one process that locked onto depth-3 serial rounds decoded greedy requests at 25–27 tok/s. MTP stays on and active with live assistant history; explicit rectangular verification keeps its adaptive depth.

### CI and contributor workflow

- Explicitly enable SSD caching for the exact-cache E2E development checkpoint and establish repeat demand before expecting a donation. The gate now requires exact cached output, account isolation and recovery to pass; CI no longer ignores its failure.

- Set up Homebrew in the macOS integration and benchmark workflows with `scripts/setup-macos-homebrew.sh` instead of the `Homebrew/actions/setup-homebrew` action. The organization Actions policy does not allow that action, so both workflows stopped at startup. The script uses an installed `brew` or installs Homebrew from a pinned, checksum-verified installer.

### Coordinator first-content routing

- Read serving-slot metric attribution from the already-selected provider after dispatch, avoiding a redundant registry lock that could delay first content. Keep backup and terminal-fault attribution rules intact.

## v0.9.14

Published 2026-09-30 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.14)).

### MiMo SSD Prefix Caching (Historical Preparation)

- Enable encrypted text-only COMPLETE-prefix SSD checkpoints by default for exact `mimo-v2.6-flash-mopd` and `EigenLabs/MiMo-V2.6-Flash-MOPD-MLX-4bit-mtp` identities. Keep verified artifact/runtime identity, tenant isolation, native ownership, memory admission, SSD limits and cold fallback.
- Preserve image, audio and video serving through the existing joint contiguous path; media requests remain uncached. RAM retention, native paging and rectangular verification remain separate opt-ins.
- Forward `DARKBLOOM_MIMO_COMPLETE_PREFIX` to the launchd provider job. Unset or empty uses the model default; exact `1` enables this gate and any other nonempty value disables. Unlisted IDs also require affirmative `DARKBLOOM_PREFIX_CACHE`; `DARKBLOOM_PREFIX_CACHE=0` still disables all prefix caching. Apply shell overrides with replacement `darkbloom start` so its saved plist is refreshed.
- Align `ProviderCore.version` and the coordinator latest-provider display fallback at `0.9.14`. Publication, full-artifact cache qualification and coordinator rollout remain separate steps.

### MiMo media memory and text isolation

- Complete native MiMo vision work one frame and transformer block at a time, reserving the largest live working set instead of every layer and video frame together. Preserve retained media/features, KV, codec and OS/activation safeguards.
- Match vision scratch to the selected fused Metal kernel and complete audio encoder/RVQ stages before reusing their workspace. Reserve actual audio tiles rather than charging a maximum tile and every layer simultaneously.
- Report media-preparation memory refusals as `media_memory_unavailable`. Keep bounded failover while leaving text-capacity clamps, health breakers and reputation unchanged. Genuine native completion faults retain their existing quarantine behavior.
- Add exact OpenRouter JPEG/MP4/MOV fixture coverage and media-refusal-to-text-serving regressions.

## v0.9.13

Published 2026-09-30 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.13)).

### MiMo Memory Admission (Historical Preparation)

- Accept bounded AAC audio in MP4/MOV and mono/stereo PCM8/16/24/32 and Float32 WAV input from 8–192 kHz for MiMo audio. Preserve sample rate and channels for the native resampler, reserve all decoded/resampled samples, and qualify the authenticated path with the genuine audio codec before release.
- Accept OpenRouter's Boolean `chat_template_kwargs.thinking` alias in the provider and coordinator normalizer, preserving canonical control precedence and reasoning history.

- Budget native MiMo grouped-prefill candidates across the configured concurrency, including fixed target rings, MTP workspace, the engine watermark and minimum useful KV space. Fall back to a smaller or ungrouped profile when the full reservation does not fit.
- Reduce native MiMo concurrency after memory-grant shrinkage instead of reserving workspace for unavailable slots. Preserve retained engine reservations, enforce the same cap on provider submission, and refuse new loads or reserve raises that would strand an existing native engine below one serveable request.
- Price native MiMo pixel preparation from actual request geometry rather than the machine-sized configured ceiling. Count video attention scores independently per temporal frame; preserve full lazy-graph, allocator, and native ownership safeguards.
- Correct native MiMo image/video admission to charge all retained RGB plus the largest sequential decode workspace. Release temporary image/frame objects each iteration and convert video BGRA directly to RGB; video no longer reserves a decoded raster for every unsampled source frame. Preserve transport, pixel, native-workspace, KV and OS memory gates.
- Align `ProviderCore.version` and the coordinator's latest-provider display fallback at `0.9.13`. The coordinator keeps enforcing reported token budgets and per-model concurrency; no admission bypass or production configuration change is included. Publication remains a separate operation.

### Native MiMo standing wired residency by default

- Enable native MiMo standing wired residency by default. Without a standing residency set every command buffer must make the ~161 GiB weight payload resident again; on a 256 GiB M3 Ultra the driver kept unwiring it and single-stream decode measured ~0.4 tok/s (the request failed at 234 s), versus 37.8 tok/s with residency, identical requests and weights. The existing bounded ceiling still leaves max(16 GiB, 10%) of physical memory unwired and never grants load admission. `DARKBLOOM_MIMO_PERSISTENT_WIRED_RESIDENCY=0` (or `false`/`no`/`off`) restores the previous behavior and is now forwarded to the launchd provider job; the former opt-in value `1` remains valid.

## v0.9.12

Published 2026-09-30 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.12)).

### First-content evidence exploration

- Let an idle, loaded provider compete beside feasible peers after the 5-minute measurement-age threshold, using connection age when measurements are undated. This breaks the evidence-first exclusion of newly connected and long-idle providers without guaranteeing selection or measurement recovery. Hedge and fresh-feasible requests still require feasible evidence.
- Treat outstanding service-retirement leases and reported service usage as busy even when slot counters are idle, and recheck exploration eligibility at atomic reservation. Older providers can still qualify using their existing slot telemetry.

### CI and contributor workflow

- Run provider unit, SDK and prompt-parity checks on independent workers with compatible build caches, retaining MiMo fixture preparation and isolated native gates.
- Separate prerequisite-dependent MiMo qualification from ordinary provider tests, retaining required prepared-fixture checks and explicit qualification gaps. Normalize the rollback test's filesystem identity and synchronize the zombie-stream timing test with the initial cancellation.
- Pin the production prompt fixture's EOF format during regeneration; parity still compares the complete corpus bytes and unchanged token/contract expectations.
- Keep documentation freshness stamps date-only, preserving existing dates, immutable source links and historical evidence. Historical source validation reads committed provenance rather than requiring a hash in the stamp.
- Document topic-local changelog updates and conflict resolution that preserves other PRs' entries, keeping release assignment separate from ordinary contributions.

### Cache routing state persistence

- Preserve a write-behind copy of SSD cache holders and observed demand across coordinator restarts while routing reads stay in memory. Restore is bounded by TTL, index caps, clock-skew checks and the cache-key generation; holders bind only to matching live provider capabilities, retaining measured stage-cost deadlines. Disconnects park holders, and shutdown joins provider sockets and the periodic writer before the final bounded flush. No prompts, raw chain hashes or memory-tier holders are persisted.
- Keep revisioned mutations pending until database acknowledgement. One serialized writer snapshots without draining; each successful chunk clears only matching revisions, and failures leave unwritten changes pending. The refactor adds no store schema, wire fields or configuration knobs.
- Durably invalidate validated misses and shorter-hit boundaries even before a holder is restored. For overlapping sessions sharing a durable row, only strictly newer surviving evidence can retain it; otherwise delete the durable copy conservatively while older live holders remain usable until expiry or ordinary invalidation.
- Replace an overflowing holder backlog in O(1), wake the writer and interrupt its batch for a durable reset. Retain a process-lifetime cutoff rejecting older or equal delayed receipts, restored rows and parked rows; reset demand-write deduplication too. A durable marker lets the next boot finish an interrupted reset, but crashes before that marker and concurrent coordinator writers remain limitations.
- `EIGENINFERENCE_CACHE_ROUTING_PERSIST=false` disables persistence. `GET /v1/cache/status` exposes restore and write-behind health under `lifecycle.persistence`; see [counter semantics](docs/reference/api-contracts.md#exact-cache-status) and [restart precautions](docs/operations/cache-routing-rollout.md#persistence-during-restarts).

### Native MiMo V2.6 (Historical Preparation)

- Preserve valid QuickTime PCM tracks in memory-backed audiovisual ingress by pinning the SDK's validated-container URL suffix correction. Input bytes, audio samples, memory ownership and decoder limits are unchanged.
- Keep unrelated resident model slots available when a MiMo owner is retained after a fault. Preserve the MiMo quarantine and process-wide new-load/reclamation fences, and report no cold-load credit while those fences apply.
- Add native `mimo_v2` target and embedded three-head MTP integration with strict source-bound loading, actual native/bridge/consumer ownership and typed retirement. Retain required-fence failures; logical memory settlement is not physical release.
- Add exact native MiMo ordinary dispatch with owned visual/audio policies and bounded encoded ingress. Required sidecars retain separate authenticated ownership. API/media qualification, unsupported formats, speech output and coordinator capability parity remain explicit gates.
- Prepare opt-in text-only COMPLETE-prefix store/loaded-owner integration and bounded performance/residency candidates, preserving native precision, checkpoint topology, fallback paths and memory safeguards. Paging, media-prefix reuse and composed cache/lifecycle qualification remain separate gates.
- Admit exact native MiMo through its dedicated ordinary loader and request its inspected embedded MTP heads by default under `mtp_mode = "auto"`. Preserve explicit `off`, the process-wide kill switch, actual owner/budget/head validation and serial-target verification. Preliminary rectangular MTP measurements include a real greedy-output divergence; that mode remains unqualified and off by default. No catalog publication, deployment or model-limit change is enabled.
- Enable eligible native-rounded MiMo NAX attention and admitted block grouping by default, with process-start rollback controls and memory-budgeted larger solo-text stripes. Preserve explicit overrides, unsupported-device fallback and other model families; candidate runtime qualification remains open.
- Compose explicit serial-MTP paging with authenticated text-prefix restoration and native retirement; retain rectangular and paged-media refusals. These source additions still require full-artifact cache, state and lifecycle qualification.
- Integrate current upstream cache ownership and add separately issued target-only native paging, joint contiguous text-prefix/media ownership, and admitted scalar-shape verification candidates. A selected 114-method component cohort passes; full-model/API, complete MTP state, paging composition and production defaults remain unqualified.
- Resolve linked snapshot directories through the normal scanner without copying weights or changing cache selection order; preserve rejection of invalid and non-directory entries. Explicit revision selections use the same canonical filesystem identity as legacy discovery.

### Deadline projection diagnostics

- Report a closed reason for unbounded provider deadline projections in the existing per-attempt profile. Distinguish scheduler state, cache geometry, capacity guarantees, missing phase rates and invalid duration without changing admission or reconstructing causes for older records.
- Reject SDK-recognized `input_audio` parts for unsupported or unknown architectures with HTTP 400 before model acquisition, prompt rendering or media decoding. Native MiMo dispatch uses provider-owned model metadata and still requires its actual loaded audio profile; generic text/vision paths do not gain audio support.

### Prompt accounting and first-content admission

- Share verified model/template prompt counts across preflight, retries and provider reconciliation while preserving the original deadline, completion limits and billing usage. Match count and cache evidence to the candidate provider's advertised template contract; keep unsupported counts explicitly uncertain.
- Apply qualified prompt-count upper bounds to ordinary deadline forecasts even without a timing profile. These bounds can exceed the previous heuristic, so a tight-budget request previously considered feasible can now be classified as predicted late. Exact tokenizer counts take precedence when available.
- Keep unmeasured prompt-rendering modes outside calibrated fallback estimates, and independently recheck deadline-profile confidence, qualified scheduler limits and cooled applicability in both runtimes before accepting catalog cells. Treat nonempty work reports without original prompt work as unknown.
- Respect cache-planning sampling and throttle denials during count-only fallback, and let retries recover cache/count planning after temporary planning-capacity exhaustion. Ignore malformed advisory prompt-work metadata without dropping an otherwise valid inference request.
- Remove the fixed 50% prefill and decode throughput reduction from coordinator feasibility and provider deadline admission. Use the resolved processing rates directly, preserving original deadline expiry, queued/cache work, count bounds, contention and memory gates. This avoids refusals caused solely by doubling predicted processing time; observed rates remain estimates and do not guarantee on-time delivery.
- Add optional workload-bounded measured deadline calibration with exact MTP identity and ordinary rate fallback for stale, unmatched or incomplete evidence and unqualified runtime overrides. The timing catalog remains empty; removing the fixed rate reduction is active without it. Preserve measured idle/thermal/power prerequisites and posture-bound rate freshness without delaying requests. Correlate whole-Mac work through pre-submit and retirement before pricing contention.
- Add production-path qualification receipts with actual MTP and individual mixed-prefill step timings; profile promotion remains tied to reviewed hardware and held-out prediction evidence.

### Advisory threat-model review

- Restore PR threat-model review through OpenRouter. Scan every changed file with complete before/after text and a cross-file pass against the full threat model. Findings update one advisory comment; incomplete coverage is explicit, clean first scans stay quiet, and model/service failures do not block merging. The workflow executes only the trusted base revision.
- Combine independent Opus 5.5 and GPT-6 Astra full scans through the same OpenRouter key. Attribute findings to their reviewers, preserve differing advice, and retain completed feedback if the other model fails.

### SSD cache write budget

- Raise the default SSD prefix-cache write budget from 150 to 750 GB/day. Explicit environment overrides and unlimited mode remain available.

### Automatic model artifact revisions

- Reject cached or staged revisions with unmanifested integrity files, so an added template, tokenizer or weight file cannot be activated under the original approved hash.

- Return retryable publication errors when alias refresh fails, and accept retained approved hashes during drained model replacement. Retired and unapproved hashes remain rejected.

- Preserve model writer locks across cache removal and refuse removal during an active download or update. Revalidate replacement and rollback snapshots under the activation lease before draining. Keep a first verified download discoverable if the process exits immediately after publishing its snapshot.

- Restore missing or damaged revision receipts only after re-verifying cached bytes, avoiding repeated activation of an already-selected revision. Preserve rollback through valid linked model cache directories.

- Keep a revision's stored download source on `publish-revision` retries, including retries after a committed promotion returns 503. Explicit mirror edits through normal registration remain supported.

- Let each revision declare a different pinned Hugging Face repo, commit and subdirectory through publishing flags or the API, with checksum-verified R2 fallback. Preserve retirement and original upload attribution across registration retries, report failed live refreshes or provider desired-state sends as retryable errors, and retain updates for eligible alias lineage builds.

- Add automatic artifact revisions for existing model IDs: publish immutable R2 bytes and a manifest once, then supporting providers resume/verify downloads, drain accepted requests and activate with rollback. Retain approved older hashes during convergence; add explicit inactive-revision retirement. Share the idle-upgrade lifecycle with Gemma MTP.

### Provider measurements and placement

- Publish prompt-completion observations through coalesced event heartbeats, with sample age/count, workload buckets and cross-model contention. Keep engine decode capacity, delivered streaming and end-to-end throughput separate.
- Add exact reviewed serving profiles, per-engine mixed-prefill policy and a shared whole-Mac service allowance. Show explicit per-model concurrency overrides in status and doctor diagnostics. Unknown profiles retain existing limits; no M5 B8/B16 expansion is certified by this change.
- Size warm pools using actual prompt/generation work and qualified batch curves, keep one model-load planner, retain load hysteresis and use fresh WebSocket RTT in first-content forecasts.
- Extend arrival benchmarks through width 16 and add a qualification receipt evaluator that rejects missing performance, correctness, memory and lifecycle evidence.

### Coordinator first-content routing

- Rank eligible providers by cache-adjusted first-content forecasts by default, prefer credible deadline-feasible choices, and spread near-equal choices by whole-machine service work within a 100-ms band. Preserve physical prompt/output reservations and explicit owner routing.
- Preserve valid prefill observations through 20,000 tokens/s. Track accepted capacity and observed performance freshness separately; missing or stale evidence stays unknown.
- Revalidate reservations and retained alternatives against the original request deadline. After two predictive refusals, require fresh feasible evidence; bound quote fanout to two and launch at most one feasible backup.

### Cached prompt pricing

- Bill prompt tokens a provider serves from its prefix cache at a per-model `cache_read_price` instead of the input price, on the same `cached_tokens` count the consumer receives in `usage.prompt_tokens_details`; a malformed cache report bills at the full input price. Rows without an explicit rate derive half the input price; `cache_read_price` is accepted by `PUT /v1/admin/pricing`, `PUT /v1/pricing` and model registration (`0 ≤ cache_read_price ≤ input_price`).
- Advertise the same rate to OpenRouter as `pricing.input_cache_read` in the provider feed, so a service-account debit equals the feed's per-token math (previously the feed declared `"0"` while cached tokens were billed at the full input price). No cache-write SKU: caching is provider-initiated.
- Publish `cache_read_price` on `GET /v1/pricing`, persist `cached_tokens` on usage rows and `GET /v1/payments/usage`, and surface the rate in the console model catalog and the admin models table. Reservations are unchanged (worst case assumes no cache hit); settlement refunds the discount and emits `billing.cache_read_discount_micro_usd`. The `*_usd` strings returned by `PUT /v1/admin/pricing` and `PUT /v1/pricing` drop the trailing " per 1M tokens" to match `GET /v1/pricing`. Cost arithmetic saturates instead of wrapping on absurd provider-reported counts.
- `/v1/completions` and `/v1/messages` report a validated cache hit in usage, streamed or not: `prompt_tokens_details.cached_tokens` for completions (streams: on the final chunk), and `cache_read_input_tokens` (excluded from `input_tokens`, as Anthropic counts it) for messages (streams: on `message_delta`). The console model catalog resolves an alias's prices from its embedded `/v1/models` pricing, so aliases show input, output and cached-input rates.
- Requests settled against a model-token grant keep pricing every prompt token at the input rate (no cache-read discount on that path) and record `cached_tokens = 0`.
- The coordinator refuses to start if `usage.cached_tokens` or `model_prices.cache_read_price` cannot be added at boot (for example a lock timeout behind a long query on `usage`), instead of booting with price lookups and usage inserts failing.
- On deploy every existing price row — platform and provider custom — starts billing cache hits at half its own input price until an explicit `cache_read_price` is set; the feed's `input_cache_read` moves from `"0"` to that rate.

### Provider readiness diagnostics

- Explain cold model-load memory failures in `darkbloom status`, a color-coded `darkbloom doctor` readiness summary, and the owner My Macs page. The provider reports live no-eviction usable memory and serving headroom separately from the eviction-aware routing capacity; older providers remain compatible and show unknown rather than a guessed verdict.

### Model Download Cache Recovery (Historical Preparation)

- Recover downloads and background prefetch when a model cache entry is a dangling symlink, including links to unavailable external drives. Preserve the original link under a hidden `.models--<id>.unavailable-link-<UUID>` sibling and download into a real directory in the selected cache. Valid directory links and regular files are preserved.
- Align `ProviderCore.version` and the coordinator display fallback at 0.9.12. Publication remains a separate release operation.

## v0.9.11

Published 2026-09-28 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.11)).

### Coordinator legacy-compat cleanup

- `EIGENINFERENCE_MIN_PROVIDER_VERSION` now also excludes providers that report no version from routing. The reference `deploy/environments/prod.env` now says 0.9.5 instead of 0.7.5, but that file changes nothing on the host: the live value in `/etc/d-inference/env` must be raised to at least 0.9.5 by a human, after a fleet-version census, before this coordinator is deployed (`docs/operations/coordinator-deploy.md`). Every registration attestation must carry a fresh timestamp, including from a provider that reports no version.
- The one-shot `backfill_withdrawable_balance_v1`, `backfill_usage_totals_v1` and `backfill_earnings_summary_v1` migrations are retired. Production already ran them. The coordinator now refuses to start on a database whose `balances`, `usage` or `provider_earnings` rows never went through them (or whose `balances` lacks `withdrawable_micro_usd`), naming the missing marker; boot a coordinator built from v0.9.10, which still runs them, once to apply them. An empty database records the markers at first boot.
- Remove the Python-era wire fields: `python_hash`/`runtime_hash` (registration, attestation response, signed status), `hypervisor_active`, and the `python_runtime_locked`/`dangerous_modules_blocked` privacy flags. Providers that still send them keep working. `POST /v1/releases` now rejects `python_hash`/`runtime_hash`; `/v1/runtime/manifest` and `/v1/me` no longer return them.
- Drop compatibility paths for providers below the new floor: the pre-0.6.7 vision penalty strip and the `desired_models` version gate. The tool-call 503 no longer cites a provider version.
- Security: remove the unauthenticated `GET /v1/provider/earnings?wallet=…` lookup, which returned any account's balance and ledger to anyone holding its ID (threat model T-031). It now returns 404; earnings stay available through the authenticated account endpoints.
- Remove the retired `POST /v1/telemetry/events` route (it only ever answered 410); it now returns 404. The coordinator has no client telemetry ingestion and no server-side field allowlist.
- Attestation challenges fail closed: for a provider with an attested key, a missing `status_signature` or an omitted `secure_boot_enabled` fails the challenge instead of being accepted as advisory.
- An `inference_error` without `failure_code` is counted as drift and fails closed as `generation_failure`; status, reason and cause no longer reclassify it, and a bare 429 no longer means queue full.
- App Attest serves protocol 3 only. Registrations announcing protocol 1 or 2 get no shadow frames and are counted as `rollout`/`provider_upgrade_required`; stored enrollments from before protocol 3 never resume.
- `inference_request` no longer carries an empty plaintext `body` object.
- Provider releases trigger only on `vX.Y.Z` tags; the `vX.Y.Z-swift[.N]` alias is gone.

#### Provider

- `provider.toml`: the retired boolean `[backend] mtp` key is ignored with a startup warning. A bare `mtp = true` or `mtp = false` without `mtp_mode` is treated as the `mtp_mode` default, `auto`; to keep MTP off, set `mtp_mode = "off"`. `config_version` is ignored and no longer written, and loading a config never rewrites it (no stamp migration, no coordinator-URL rewrite, no copy from legacy locations). Only `~/.config/darkbloom/provider.toml` or `--config` is read.
- Self-update and `install.sh` install only signed `Darkbloom.app` bundles: flat-only and pre-paged artifacts are refused, and the `eigeninference-enclave` alias is no longer created. `install.sh` no longer migrates `~/.dginf`/`~/.eigeninference`.
- Model downloads fail closed for a catalog entry without a verified manifest (`r2_prefix` + `aggregate_sha256`).
- Removed: `darkbloom-enclave wallet-address`; Rust-era credential, launchd-label and Secure Enclave v1 key fallbacks; the provider's App Attest shadow protocols 1 and 2 (protocol 3 only).
- The bare `runtime-smoke` self-bootstrap for pre-0.8.10 updaters is gone: an updater from 0.7.8–0.8.9 may fail the packaged smoke check (it fails only on hosts where MLX touches Metal early) and then needs an `install.sh` reinstall. Those versions are below the 0.9.5 routing floor anyway.

### Prefix Cache Hit Rate (Historical Preparation)

- Align `ProviderCore.version` and the coordinator display fallback at 0.9.11. The new inference-request field is optional in both directions, so the coordinator and providers can be upgraded in either order; upgrade the coordinator first to keep the 0.9.10 rollout order.

Production ran exact prefix-cache routing at 100% and measured a 1.4–5.2% hit rate per model. See the [analysis](docs/reports/2026-09-26-prefix-cache-hit-rate-analysis.md) and the [rollout procedure](docs/operations/cache-routing-rollout.md). Coordinator and provider changes are independent on the wire: an older provider ignores the new request field, and an older coordinator leaves providers on their previous donation behavior.

#### Provider

- Keep the SSD cache epoch across budget eviction, TTL expiry and corrupt-file removal. Only a whole-root rebuild at load mints a new epoch, so the coordinator no longer forgets a provider's remaining checkpoints each time one file is removed.
- Raise the SSD prefix-cache TTL from 15 to 30 minutes (default equals maximum; the environment override can only shorten it). Recorded as the SEC-035 re-acceptance in the threat model.
- Write a complete checkpoint only on evidence of demand: the coordinator's `cache_repeated_prefix_tokens` at or above the 1,024-token floor, or a prior local sighting. Fleet-novel checkpoints report `skipped_novel` and touch neither disk nor the write budget. The first request for a prefix is served cold and not written, the second is written, the third can hit.
- Capture GPT-OSS 20B and Gemma QAT checkpoints at every 1,024-token boundary regardless of prefill chunk size, including inside a solo stripe, and retain at most three per donor: the first boundary, the boundary at the observed shared-prefix length, and the deepest.
- Report a file that disappeared under a reader as an absent miss rather than corruption; let expiry proceed when a root's only registered store has lost ownership.
- Capture recurrent (Qwen, Nemotron, Bonsai) complete checkpoints at every 256-token-aligned prefill range end, whatever chunk produced it. The uniform-chunk rule disarmed capture when decode company left mid-prompt, so long Qwen prompts published only the boundaries before the first chunk change; measured on real weights, dense Qwen3.5-9B state is bit-identical across chunk partitions and the MoE varies cold already ([report](docs/reports/2026-09-27-qwen-chunk-partition-parity.md)). Files written under the old rule stay valid; adopters resume under ordinary chunking.
- Retain the coordinator's fork target for recurrent donors too: first boundary, deepest boundary at or below `cache_repeated_prefix_tokens`, and the rolling latest, with a fixed 1,024-token adjacency drop for every layout.
- Count recurrent donors whose capture a packed prefill cohort disarmed, once per request, in the heartbeat's `recurrent_capture_disarmed_packed_total` (DogStatsD `provider.prefix_cache.recurrent_capture_disarmed_packed`).
- Enable SSD prefix caching and the paged KV backend by default for the exact catalog ID `Qwen3.5-9B`. Providers reported `config_disabled` for it and served it on contiguous KV under `auto`, so it could not join cache routing; the coordinator's `EIGENINFERENCE_CACHE_ROUTING_ALLOWED_ARTIFACTS` tuple for it is a separate operations change.

#### Coordinator

- Prefer a proven cache holder inside the existing 3-second near-tie band instead of collapsing the band whenever a cache credit exists. New selection path `cache_credit` and opportunity reason `selected_near_tie`.
- Bound the proof fence to 60 seconds, doubling per consecutive mismatch to a 10-minute maximum, and drop only the mismatched prompt's holders. Previously a mismatch fenced the capability until the provider's epoch changed and dropped every holder for the model.
- Drop a provider's deeper holders when it proves a hit at a shorter boundary (`shorter_hit`).
- Size the holder index (250,000) and observed-demand index (1,000,000) for a 30-minute window and expire holders from an expiry-ordered heap in bounded passes.
- Forward observed repeat demand to providers as `cache_repeated_prefix_tokens`.

#### Prompt sidecar

- Mirror five provider prompt transformations that caused proof mismatches: tool-call argument key order, integral doubles in arguments, extra keys in tool `function` objects, Harmony channel framing in assistant history, and `output_text` content parts. Prompt-contract IDs are unchanged. Decline to plan for decomposed Unicode object keys and for Harmony control tokens that share a grapheme with a neighbour.

#### Operations

- Rollout procedure for sidecar capacity, plan QPS, holder TTL and the Nemotron Lightning and Bonsai 2 allowlist tuples. The sanitized production env reference now matches the live cache-routing values.

## v0.9.10

Published 2026-09-27 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.10)).

### Live Switching and App Attest Recovery (Historical Preparation)

- Align `ProviderCore.version` and the coordinator display fallback at 0.9.10. Upgrade the coordinator before publishing the separately qualified signed provider; the source bump does not advance the registered latest release.

- Confirm live model-switch success only after a same-session coordinator receipt proves routing resumed with refreshed capacity. Report a missing receipt as unconfirmed. Serialize autoupdate config changes with model-selection writes so toggling updates cannot restore stale hosted models.
- Restore model prefetching before the switch readiness receipt can trigger a refreshed desired-build snapshot. Keep scheduled serving within its original window when model validation and hashing take time.
- Preload selected models on every provider start, regardless of idle-memory policy, including standalone `--local` mode. Coordinator starts remain bounded by the startup timeout; local mode finishes preloading before listening. Slot and memory limits still apply.

- Add explicit model-cache selection through `darkbloom models location`, with interactive confirmation, read-only `--check`, one-time `--from-env` import, and `--reset` to the legacy default. No beta flag, automatic restart, or weight movement.
- Preserve existing providers' cache locations until an operator explicitly saves a path. Ambient Hugging Face/XDG variables never redirect runtime discovery, downloads, hashing, or removal; imported paths stay pinned when the environment changes.
- Preserve filesystem traversal through symlinks and diagnose empty selected caches without mistaking incomplete download folders for models. See the [location command](docs/provider/cli-reference.md#darkbloom-models-location).

- Replace provider reputation ratings with total, successful, and failed job counts. Remove the composite score calculation and owner API field; historical job failures no longer imply reduced routing priority in the dashboard.
- Add `darkbloom switch` to replace the running provider's hosted model selection after a graceful drain, without process restart, coordinator reconnect or re-attestation. Reuse the catalog picker, reject invalid selections as a whole, preserve accepted work on timeout, and persist confirmed selections for launchd restart, watchdog recovery and subsequent scheduled serving windows.
- Live model switching preserves owner-only off-catalog inventory, handles an already-idle `--timeout 0` without skipping coordinator settlement, and lets shutdown preempt read-only weight verification. Switch requests are consumed once across schedule windows; replacement start saves configuration before draining or stopping the current provider.
- Restore the exact prior model-selection config when replacement-start setup fails, without racing other config writers. Carry validation fingerprints with switched model hashes so unchanged cold models avoid redundant hashing; metadata changes and mandatory fresh integrity checks still rehash.
- Keep model-switch routing fenced until the provider reopens local admission and confirms readiness after its commit acknowledgement. Settle queued writer reservations and coalesce overlapping drain barriers without dropping the latest waiter. Refresh desired alias builds after replacement. Live rollback preserves absent selection keys and concurrent settings; missing custom configs use their resolved startup settings rather than another config file.
- Resume model-switch routing only after refreshed serving capacity arrives; retain removed-model queue cleanup through same-session retries. Scheduled windows resolve an empty saved model list as all eligible local models.

#### Public model demand

- Add model demand and fulfillment to Stats, with 24-hour, 7-day and 30-day windows, shared-scale request bars, sorting, expandable outcome counts, per-model timeline charts, an exact interval table, and CSV export. Separate capacity rejections, predicted latency limits, actual timeouts, service errors, client departures and unknown outcomes; HTTP 429 is an overlapping diagnostic.
- Scope new public routing-admission observations explicitly and persist revision-aware hourly aggregates for 31 days. Delay publication by at least one hour and suppress cohorts with fewer than 20 requests or 3 consumer accounts. Label recorded-request coverage and partial collection history; token demand and network-wide completeness claims remain unavailable.
- Preserve compact outcome conflicts and original receipt/model/consumer identity after the detailed diagnostic ledger expires; contradictory replays remain unknown rather than rewriting historical fulfillment counts.
- Count full request queues as capacity rejections and queued first-content deadline expiry as timeouts in public model-demand history, rather than reporting either as unknown.
- Exclude suppressed hourly cohorts from model summaries and all history resolutions so subtraction cannot recover hidden counts. Label counts, percentages, tables and CSV as published observations rather than complete window demand.
- Count provider token/KV/context-budget exhaustion (`unservable_token_budget`) as capacity rejection in public model-demand outcomes.
- Count preflight structural token-budget refusals (`prompt_too_long`) as capacity rejections while preserving validation exclusions. Prune expired model-demand aggregates in bounded transactions, retaining the partial cutoff hour and completed batches when a later batch fails.
- Exclude prompts beyond the model context window from public demand, and count models too large for the advertising fleet and capacity-confirmed dispatch exhaustion as supply rejections.

#### App Attest dead-key recovery and release-recovery fixes

- Retain APNs receipt history through day-long push storms, and keep optional lifecycle diagnostic reads outside proof archival storage admission.

- Preserve explicit update/stall restart provenance through later termination callbacks, and clarify the untrusted diagnostic boundary for consumers and the threat model.
- Keep coarse lifecycle comparisons unknown when ambiguous, reserve report-upload space for diagnostics, finalize idle scheduled shutdown markers, count validated late APNs replies without reauthorization, and fail signing checks on environment mismatch.
- Treat APNs delivery as indeterminate when no push was observed, require actual update-start evidence, and bound diagnostic log reads and parsing memory.
- Keep doctor/report log collection bounded even when termination is ignored; show APNs history on legacy macOS, restrict rotation recovery to the correct account, and distinguish historical push snapshots from current ages.
- Correct App Attest diagnostics for hung security probes, unknown boot security, late APNs tokens, failed WebSocket writes, terminating push loops, full-day key churn, and non-stalled busy replies.

- Replace App Attest keys the Secure Enclave can no longer use. After two consecutive DeviceCheck code-0/2 (or uncoded) assertion failures since the key's last verified assertion, the coordinator asks for a fresh attestation instead of another assertion. Released 0.9.8 and 0.9.9 providers answer by retiring the dead key and enrolling a new one, which must pass the full attestation, receipt, build-qualification and assertion checks. Rotations are durable, limited to one per machine per hour and four per 24 hours (limits carry over when two machine records are merged), controlled by `EIGENINFERENCE_APP_ATTEST_KEY_ROTATION_PERCENT` (default 100), and never revoke or deny serving.
- Serialize App Attest rotation admission with machine merges and resolve stale machine IDs before checking the shared budget, preventing overlapping old/new identities from bypassing rotation limits.
- Back off fresh-key enrollment for 6 hours after a machine's third `invalidKey` attestation failure in 24 hours, instead of generating a new key every few minutes. Reconnects, coordinator restarts and releases do not cut the backoff short.
- Keep retrying the APNs code-identity check on a live connection after the first three pushes go unanswered, at most once per hour through the existing per-device push budget, instead of waiting for a reconnect. Machines that missed the check after a release now recover without a restart.
- Stage the durable Apple device-attestation chain for macOS 27 App Attest candidates too. It attaches only after hardware trust, when it re-verifies to Apple's root and binds this connection's Secure Enclave key; serial restore and serial dedupe stay skipped for candidates.
- Provider: report `launch_session`, `boot_time` and `operation_stalled_seconds` on App Attest `ready` replies (outside the signed transcript). A DeviceCheck call that never answers is reported after 15 minutes and triggers one graceful self-restart when idle, at most every 6 hours, never while a stop or OS shutdown is draining the provider. An attempt that cannot restart does not close admission again on the next check: it waits 15 minutes after an unfinished drain, and 6 hours when its restart marker cannot be saved. `darkbloom doctor` adds an APP ATTEST section with the local key state, launch session and advice for unsupported Macs.

#### App Attest failure diagnostics

- Provider: App Attest `ready` replies add closed, bounded diagnostics outside the signed transcript: process start time, whether the previous run shut down cleanly and why this one started, console-user presence, SIP and sealed-system-volume status, a signing and provisioning-profile check, local key history and APNs push receipt history. Failed attestations and assertions add the native error chain (closed domain buckets and signed 32-bit codes, such as CryptoTokenKit −3 over AKS −536362989). None of it affects authorization; the coordinator drops invalid values without rejecting the message.
- `darkbloom doctor` adds App Attest checks with targeted advice. Local key/history refreshes after every proof, and displayed ages advance between exchanges. Unknown signing or profile checks remain indeterminate instead of passing. Local `devicecheckd` observations are explicitly device-wide, not proof that Darkbloom's key failed.
- `darkbloom report` appends the local App Attest snapshot, APNs push history and closed-pattern, device-wide `devicecheckd` matches, and still uploads when provider logs are empty or unreadable. From a standard account it explains that macOS lets only administrators read the system log. Under `sudo` it reads the invoking user's canonical or legacy credentials without migrating them, plus the user's state file and provider config; an explicit token-path override takes precedence.
- Coordinator: record each APNs code-identity push's outcome (`code_attest.push{outcome}`) and whether the provider answered it (`code_attest.push_reply{result}`), including across reconnects, with no provider, device or token identifiers in metric tags.
- Admin: `/app-attest/diagnostics` breaks the unexplained failure groups down by these fields, classifies dead keys by OS change, reboot or process restart, and summarises rotation outcomes and APNs push receipt.
- Derive reboot/restart diagnostics from provider timestamps in the latest verified assertion context, never by comparing the Mac clock with the coordinator clock; unavailable baselines remain unknown. Rotation recovery follows canonical machine merges when locating replacement proofs.

#### Operations, CI, and community

- Point development GCP defaults and documentation at `darkbloom-dev`; production deployment settings are unchanged.
- Refresh the console's Slack community invite after the previous invite expired.
- Report coordinator and prompt-sidecar coverage in CI job summaries without adding a coverage pass threshold.

## v0.9.9

Published 2026-09-24 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.9)).

### App Attest recovery and snapshot accuracy

- Distinguish signed-app availability failures and synthetic Apple callback/proof errors with closed, privacy-bounded diagnostics. Keep the result and trust policy unchanged; native `NSError` codes remain separate.
- Align `ProviderCore.version` and the coordinator display fallback at 0.9.9. Deploy coordinator and console fixes before publishing the separately qualified signed provider.
- Retire failed or interrupted one-time App Attest enrollment keys instead of retrying them indefinitely. Preserve server-unavailable retries, cached enrollment proofs, accepted assertion credentials, account identity, and persisted generation limits.
- Preserve the original attestation key and hash across server-unavailable retries, reconnects and protocol upgrades, as Apple requires. Later serving assertions remain fresh and bound to the current process endpoint.
- Recover from expired cached-enrollment transactions on a live connection without accepting stale proofs or retrying identity/binding violations. Correct obsolete shadow-only rollout and rollback instructions.
- Accept authenticated macOS CDhash attestation extensions when Apple omits the extension flag; retain complete certificate, nonce, Mac ACL, key, transcript and serving-policy verification.
- Retain bounded Apple error domain/code diagnostics without error descriptions, user-info dictionaries or raw identity data.
- Show public network verification counts and filters at their source snapshot instead of expiring cached App Attest rows into a false zero. Owner serving controls retain live expiry.
- Exclude private-only providers from the unauthenticated attestation roster and its shared cache. Preserve owner access and document public legacy-key linkability and private audit-data destinations.
- Accept fully signed, measured macOS App Attest assertions when Apple omits the extension flag, and recover serving authorization after a fresh, completely archived proof despite an earlier recorded frame refusal. Repair the startup inventory-backfill race only for current authenticated sessions while retaining genuine disconnects and revocations.
- Distinguish an eligible Apple proof from a successfully granted serving lease in App Attest operations, with bounded failure reasons for identity, storage and runtime gates.
- Recognize Apple's signed 20-byte SHA-256 CandidateCDHash only when it uniquely matches the same active, durably qualified signed artifact's full 32-byte CodeDirectory hash; all independent release, receipt, revocation and runtime checks still apply.
- Retry only a completed Apple key-generation callback that returned an error with no usable key ID after a persisted one-minute cooldown, within the normal provider's generation budget. Timeout, cancellation, busy admission, and crash keep the one-hour marker; the budget also bounds possible internally created but inaccessible keys. Retry a definite assertion `serverUnavailable` once with the same key and challenge.
- Recheck a first App Attest grant after one, five and ten minutes while Apple risk-receipt renewal is still unverified; a fresh assertion, verified risk metric and every existing serving check remain required. macOS 27 alone never grants authorization.
- Reprobe a live connection's generic or server-unavailable Apple App Attest failure after one, five, then every ten minutes instead of leaving its accepted key idle for an hour. Storage failures retain their slower backoff; signed policy failures remain terminal.

## v0.9.8

Published 2026-09-22 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.8)).

### Graceful lifecycle and App Attest recovery

- Align `ProviderCore.version` and the coordinator's `LatestProviderVersion` fallback at 0.9.8. Deploy coordinator drain-barrier support before publishing this provider; qualify the exact signed artifact independently before advancing the registered release.

- Extend graceful draining to replacement starts, standalone/foreground handoffs, manual update activation, and planned APNs/model-inventory reconnects. Background update deadlines defer without force-cancelling work; failed pre-publication setup restores recovery, and restart recognizes explicit owner self-route authorization.

- Drain accepted inference and local response writes before normal provider stop/restart, confirm terminal usage with the coordinator, preserve model selection, and report recoverable timeouts separately from explicit force.

- Replace the static landing page with the Darkbloom Next.js site from eigen-homepages, preserving the old legal URLs with redirects.
- Recognize the 2026 M6 and M5 Pro Mac minis and M5 Max Mac Studio for base-reward memory caps and complete the new desktops' earnings-calculator choices. Recognize M5 Ultra for serving bandwidth while withholding its disputed identifier from base rewards. Report M6 as its own chip family with conservative MTP and model-capability gates pending physical qualification.
- Retry generic Apple App Attest API failures with the existing bounded backoff instead of leaving a live connection permanently pending. Failed exchanges remain unqualified; fresh proof and all serving-policy checks are still required.
- Retry a first verified App Attest assertion early while Apple's risk receipt is pending. A successful receipt still requires a fresh assertion, machine identity, build qualification, and all serving-policy checks; missing risk evidence never grants serving.
- Keep the interactive `darkbloom unenroll` administrator profile inventory in the foreground terminal group so `sudo` can hide password input and complete the read. Background jobs, denied authentication and noninteractive reads withhold removal guidance without changing profiles or authorization.
- **Privacy descriptions** — Describe encrypted network hops and plaintext processing at the coordinator and provider, distinguish qualified MDM-optional App Attest authorization from legacy MDA evidence, and remove unsupported memory-wiping and recipient-key forward-secrecy guarantees.
- Unify App Attest and legacy verification labels, dispatch-time chat proof summaries, live authorization expiry, and network method counts without changing legacy trust fields or exposing private Apple evidence. Keep owner lease fields and geography counts on the same live authorization snapshot, and label unsupported App Attest protocol versions accurately.
- Operations helpers encode admin JSON fields, return a failure after any fleet host fails while still visiting remaining hosts, and isolate smoke-test response files.
- **Admin email login** — Encode Privy OTP email/code fields as JSON strings so quoted addresses and escape characters cannot break or reshape the upstream request.
- Preserve Responses `instructions` as a leading system message in serving and prompt-cache preparation, and include them in admission/billing estimates. Retain inline media and tool history; reject invalid instruction types.
- Route forced media tools and media-bearing tool results only to providers advertising the model's native capability; preserve aliases, queued/retried requests and legacy refusals. Native DiffusionGemma retains tool-result assets in actual call order without changing its sampler.
- Reject malformed or negative top-level output-token budgets before coordinator defaulting and admission on all inference endpoints; preserve omitted, null, zero and valid positive budget behavior.
- Preserve ordered inline image/video content and media-bearing tool results when lowering Responses requests for inference. Retain vision admission and inline-only Responses URL policy; media remains ineligible for the separate text-only prompt-cache planner.

- Add an opt-in native DiffusionGemma sampler candidate preserving exact RNG constants, request-local key order and validated state commits, with original-path fallbacks and benchmark-only dispatch evidence.
- Add an opt-in native DiffusionGemma soft-conditioning projection candidate using the existing affine matrix arithmetic and unchanged weights, with original training/transform/stream fallbacks and benchmark-only dispatch evidence.
- Add opt-in DiffusionGemma benchmark route observations, separating first-iteration dispatch evidence from disarmed timing iterations without changing serving controls or generation.
- Add native DiffusionGemma committed-block serving and image/video-frame discovery, including multimodal template validation. Keep text-only declarations disabled for media and preserve existing load and memory safeguards; catalog publication and release qualification remain separate.
- Preserve DiffusionGemma's native tokenizer whitespace default without rewriting artifact metadata or changing other processors; explicit cleanup settings remain authoritative.
- Fail unexpected nonempty DiffusionGemma reasoning before exposing it when thinking is disabled, while preserving empty native envelopes and never promoting tool examples from an unclosed thought.
- Avoid restoring the sorted expert-output intermediate on eligible native DiffusionGemma inference paths. Preserve the existing weighted-reduction order, model weights and denoising controls; retain legacy training, shape, precision and stream paths plus an explicit rollback.

- Persist independently approved App Attest builds and revocations; refresh qualification without per-release coordinator restarts, with bounded failure/expiry and stale-grant fencing.
- Stage immutable signed provider artifacts before publication. Block unqualified releases before updater/latest aliases advance; retry the separate publication job using the same signed bytes, without rebuilding or notarizing again.

## v0.9.7

Published 2026-09-20 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.7)).

### MDM-optional providers and account-scoped SLAs

- Align `ProviderCore.version` and the coordinator's `LatestProviderVersion` fallback at 0.9.7. Publication, coordinator deployment and App Attest serving/removal activation remain separate rollout steps.

#### Model verification I/O

- Enable reusable-buffer reads and up to four independent file readers by default for model integrity verification, preserving complete SHA digests, failure handling and load-time checks. Explicit overrides retain the original reader and serial hashing for rollback.
- Pin MLX Swift and MLX Swift LM to their merged Bonsai constant-reuse, carry-scheduling and HTTP-validation updates. Preserve the existing MLX core/C pins and native Qwen4 support.

#### Bonsai performance and API stability

- Enable encrypted SSD prefix-cache eligibility by default for the three exact supported Bonsai 2 MLX identities. Preserve the global cache opt-out, fresh load hashes and runtime capability/identity gates; resident RAM retention stays opt-in. Signed persistent-restart qualification and coordinator artifact allowlisting remain separate rollout steps.

- Complete late local Chat/Completions failures with a sanitized SSE error event instead of truncating the HTTP body. Preserve cancellation, pre-header errors and the direct SDK throwing contract; this does not change model generation or turn failed tool calls into successes.

- Enable qualified earlier compact-carry submission and exact FP16-to-FP32 constant reuse by default on eligible Bonsai paths. Unset and exact `1` enable each path; explicit `0` restores its prior behavior and other explicit spellings remain disabled. Keep all shape/dtype/fault gates, generic cache rollback, published weights, native precision, architecture, context limits and absent-MTP capability unchanged.
- Record matched M3 Ultra/M5 Max prefill, decode and memory measurements, including prefill tradeoffs and the real retained-constant cost. Dependency review, post-merge repinning and deployment remain separate actions; this performance draft is not a release.
- Qualify early provider-local rejection of negative output-token limits through the SDK service, preserving explicit zero and valid requests. Coordinator validation and model numerics are unchanged.
- Preserve the fixed SDK input-validation error through local chat interception, and explicitly admit the qualified Bonsai XML family to nested-reasoning routing for both text and media. Preserve opaque argument bytes and existing other-family policies; do not guess string unescaping.

#### Account-scoped first-content SLA

- Apply the first-content SLA only to authenticated accounts selected by `EIGENINFERENCE_FIRST_CONTENT_SLA_ACCOUNTS`; configure the intended account privately in the deployment environment. Direct users and other service accounts have no first-content timeout, including no 600-second fallback; queue limits, client cancellation and post-content response timers remain.
- Preserve configurable model timing for selected accounts, including Bonsai’s 9s + 5ms/token coordinator cutoff, and support explicit public-model policies before alias resolution.

#### MDM-optional provider authorization

- Warn on stderr for every CLI invocation below macOS 27, including help/version, while preserving commands and JSON output. Add prominent setup/dashboard upgrade notices, distinguish older from unknown reported OS versions, and retain legacy service during the transition.
- Show current App Attest authorization on the owner dashboard without demanding legacy MDM verification; expire cached grants locally if polling fails and preserve independent legacy proof fields.

- Retry first-proof App Attest readiness outages with a bounded early assertion retry (one minute, then five minutes, capped at the normal ten-minute cadence); recheck the complete proof, identity and serving policy after recovery.

- Reflect App Attest revocation in untrusted status, availability and fleet counts without duplicate decrements or legacy-challenge recovery. Require a coordinator decision received within 10 seconds before offering MDM removal, even when the daemon keeps rewriting its state file.

- Skip new MDM enrollment in the installer and CLI on macOS 27 or later; guide users through App Attest approval. Explain that upgrading avoids MDM and Darkbloom MDM will be deactivated soon. Keep existing profiles and coordinator authorization/removal gates intact; pending App Attest never falls back to automatic MDM enrollment.

- Fence successful admin revocations even when the request deadline expires, and fence freshly verified revoked credentials before their first serving grant. Preserve bounded leases/refresh records through unknown readiness results without extending authorization.
- Preserve legacy identity/MDA recovery for providers outside the authenticated rollout cohort and on older macOS. Restore a previously missing historical baseline after a later canonical merge without double-counting live work.
- Count only authorized inference handoffs as provider dispatches; rejected frames clear provisional timing, and cancellation while waiting for authorization preserves the healthy connection.
- Commit pending base-reward allocations atomically and reallocate after a late authorization/identity rejection, preserving prior finalized payments and pool/account caps. Resolve same-account endpoint continuity while session inventory catches up.

- Consolidate App Attest session, archive, receipt, inventory and authorization workers under `coordinator/appattest/service`, with their unit tests. Keep only API wiring/authentication/release adapters; retain storage and scheduler locking with their owning packages.

- Make plain `darkbloom unenroll` offer full exit or App Attest migration, with an explicit macOS 27+ requirement and fresh coordinator approval for migration. Cancel/EOF makes no changes; full exit stops the provider service before optional cleanup, and the cleanup prompt explicitly lists Secure Enclave signing keys.

- Add independently enabled App Attest serving alongside complete legacy MDM/MDA and APNs verification. Require qualified signed code, current encrypted-endpoint assertions, durable evidence, valid receipts and fresh revocation state; preserve legacy trust flags.
- Fence every new inference handoff on expiry, revocation, connection/endpoint replacement and policy changes, including queued requests and retries. Durable revocation refresh has a bounded lifetime; database failures cannot extend permission.
- Preserve verified canonical machine history across reconnects and credential rotation, without allowing a claimed serial to evict another provider. Extend base rewards to qualified App Attest-only machines with canonical duplicate/epoch settlement protection and preserved historical balances.
- Add coordinator-derived authorization diagnostics and `darkbloom unenroll --keep-serving`. Require fresh removal readiness, preserve local identity/account data and identify only Darkbloom's enrollment profile before guiding the user through System Settings; company management is retained.
- Keep serving/removal disabled by default and retain explicit signed-artifact/security-transition qualification before activation. DeviceCheck's separate two-bit API is not required.

### Model token promotions

- List Bonsai first in the chat model dropdown. Show its “Free” badge only after a confirmed claim for that exact model with available tokens; hide it while grant status is unknown, on lookup errors, or when the allowance is exhausted or fully reserved.

- Enable thinking by default in frontend chat requests.

- Configure one-time, model-specific token grants before registration. Eligible users explicitly claim non-expiring tokens shared across their account keys, with an atomic campaign cap and signup cutoff. Prepare the Bonsai draft for 250 claims through September 19 by accounts created through September 18 (Los Angeles time). Exhaustion falls back to paid credit, with clear console allowance/error states.
- Reserve and settle free tokens, paid credit and provider earnings atomically; retain platform-priced provider payouts on sponsored traffic, protect same-account serving, and recover orphaned reservations.
- Recover usage, key spend and fee accounting after promotion settlement retries; release holds after deterministic failures and reject zero-token payouts.
- Bound sponsored provider earnings to exact token prices, carrying fractional micro-dollars atomically instead of funding a minimum payout for each tiny request.
- Give Bonsai 2 a 10-second plus 5-ms-per-input-token upstream first-content SLA, retaining coordinator response headroom. Add exact-model overrides for both SLA terms.

## v0.9.6

Published 2026-09-18 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.6)).

### Ternary Bonsai 2 onboarding draft

- Compact Bonsai's retained recurrent convolution carry after prefill, preserving exact FP32 state bits without retaining whole chunk buffers. Other model families and single-token decode are unchanged.
- Apply the existing serving allocator guard before throughput-sweep model loading; bound freed-buffer retention and report active/cache memory separately without changing model precision or KV limits.
- Add the `prism_hadamard_qwen35` native CBv2 adapter for the unchanged Prism Bonsai 2 27B affine 2-bit pack, including its real vision tower and explicit absence of MTP heads. Preserve signed-Hadamard transforms, FP16 packing, paging safeguards and matching provider/coordinator prompt semantics. Register `hadamard.json` as an integrity-bound config asset. Qualification and catalog/release activation are separate; this draft does not deploy the model.

### Flash-Next Signed-App Resource Recovery (Historical Preparation)

- Wait for the SSD write-behind consumer task to finish when draining after shutdown, so the final payload is released before teardown completes. Preserve reusable drains while the pipeline is running; cover the shutdown handoff with 10,000 regression cycles and both SDK 27 CI lanes.
- Resolve native Qwen Metal preambles from the signed app’s `Contents/Resources`, including installer symlinks; prevent developer build paths from hiding missing packaged files. Model weights and kernel bytes are unchanged.
- Exercise all Qwen Metal preambles in `runtime-smoke` before signing, after notarization, and through the existing installer/updater smoke. Add relocated-app, missing-resource, symlink-escape, and standalone-development regression checks.
- Require provider 0.9.6 or newer for `qwen3.8-flash-next`, excluding the crashing 0.9.5 bundle without changing other models. Keep the 262144-token native context and memory safeguards. Cold SSD-offload accounting requires the separately deployed coordinator.

## v0.9.5

Published 2026-09-17 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.5)).

### Qwen 3.8 Next/native Qwen4 follow-up

- Recognize the exact `qwen3.8-flash-next` registry ID alongside the legacy developer ID for native Qwen4 media, paging/prefix, tool and reasoning policies. Keep artifact/configuration checks and developer-only path overrides intact.
- Use native model context in listing and runtime policy, with a 262144 fallback only for the known artifact identities. Remove the extra 82K bridge clamp; retain lower-only operator overrides, checked prompt-plus-output budgets, physical-memory safeguards and coordinator SLA admission.
- Mirror the registry-ID prompt semantics in Rust and bump the shared Swift/Go/Rust normalization contract to v6. Old contracts fail cold rather than receiving cache credit under different semantics.
- Gate the registry ID on provider 0.9.5 or newer across request shapes; legacy and other models keep existing version floors. Align the provider version and coordinator display fallback without retagging 0.9.5 or deploying this draft.
- Leave SDK, model weights, quantization, embedded MTP and numerical kernels unchanged. Physical full-context and composed API qualification remain separate from policy-level tests.

#### Release reliability and build reuse

- Make model-free Qwen4 standalone admission tests use controlled memory, including
  low-headroom refusal and recovery, while retaining production memory safeguards.
- Run optimized SDK 27 compilation alongside SDK 27 prompt parity and tests; gate
  signing on both and verify the source-bound unsigned artifact before signing.
- Warm compatible Swift, Rust and Metal caches on master for release tags, preserve
  unchanged source timestamps, and report cache reuse without skipping validation.


- Pin the native Qwen4 SDK to merged upstream PR #149. The approved SDK source tree is unchanged; this dependency update introduces no new model, numerical or performance changes.
- Stage native Qwen4's bounded MTP catch-up, consistent carry-only initialization of cold/restored unprimed heads and grouped selected-page KV reads as a paired SDK/provider default candidate. Preserve already-primed caches, target parameters, ordered attention arithmetic and explicit rollback controls; full default-posture qualification is required before promotion.
- Derive eligible Qwen4 SSD-offload load estimates from validated native copy bounds instead of generic 20% padding. Preserve all compute/MTP/vision payloads and the existing OS, activation and KV safeguards; other layouts retain their previous policy. Recheck actual headroom for at most two seconds after owned Qwen4 retirement, without granting speculative reclaim credit. Physical full-model qualification remains required.
- Discover hidden SwiftPM resource bundles during paged-backend preflight while retaining sealed-app boundaries and rejection of conflicting source bytes. No model arithmetic or weights change.
- Preserve reasoning with its following function calls when the standalone Responses API replays prior output as input. Keep explicit message/tool-result boundaries, argument bytes and media unchanged; no model, MTP, sampling or cache-algorithm change.
- Preserve both upstream Hugging Face mock isolation and the Qwen native-GPU test gates when composing the provider CI runner.
- Snapshot verified converter metadata before shard conversion so later license, tokenizer or template mutations cannot enter a successful pinned conversion.
- Preserve all semantic Qwen4 configuration fields across Codable round-trips. Bind and validate PLE resources in both model factories, keep legacy request state in each cache, and reject unsupported generic generation recoverably.
- Run the ordinary Qwen4 benchmark through native CBv2, with normal EOS handling, explicit target-only/cache-off scope and complete duration accounting. Preserve other models' JSON5 configuration support.
- Materialize Qwen4 fused expert weights through the existing bounded loader hook after relinquishing staging owners. Retain explicit physical-memory, reload and deadline qualification gates.
- Keep unsupported generic SDK sampling controls explicit without changing native provider support. Align the provider version and coordinator display fallback at 0.9.5; publication and rollout remain separate approvals.
- Enable the existing Qwen4 full-KV parallel attention, 32 value partitions and early layer submission by default for eligible decode/MTP verification. Preserve explicit `0` rollback, compact-KV opt-in, wider-prefill fallbacks and unchanged model weights, arithmetic and MTP policy.

### App Attest and Console Follow-ups

- Forward the latest distinct per-model warm-pool planning snapshot through the coordinator telemetry emitter so Datadog can show target sizing, measured demand, candidate availability and blocker counts. Keep provider identities and request data out of the event.

- Stop minting an unrestricted console API key after you create a My Machine only key. Chat adopts the key you just created; `POST /v1/auth/keys` inherits `self_route_only` when every active key on the account is already machine-only. Logout, chat 401, and untracked mint drop a leftover console key id so a stale id cannot pin chat to the untitled secret.

### Combined Streaming Usage

- **Combined streaming usage** — Preserve validated cached-token and reasoning-token details when a Chat stream carries usage on its finish event. When a dedicated usage event follows, enrich only that event; do not duplicate details, invent usage, or change content, token totals, signatures or terminal identity.

### Qwen 3.8 Next (Flash-Next) Support (Historical Preparation)

- Record the human-reviewed candidate and final 118-cell local API pass,
  account-scoped cache/usage fixes, default long-prefix cache qualification,
  full affected-suite results and matched speed checks in the
  [native API/cache qualification report](docs/reports/2026-09-15-qwen38-native-api-qualification.md).
  Existing opt-in multirow and semantic-quality limitations remain explicit.

- Align final non-streaming reasoning-item status with streaming Responses;
  preserve the root incomplete/complete status, original text, usage and
  provider attestation fields.
- Preserve the Chat stream's response ID and creation timestamp on terminal
  coordinator metadata while retaining signature/hash values and the distinct
  job ID. Include `input_tokens + output_tokens` as Responses `total_tokens`;
  cached/reasoning details are not counted again and billing is unchanged.
- Add a real-coordinator/native-unified API matrix with authenticated metrics
  from the same provider. Replace the generic plaintext test's ASCII-density
  heuristic with an exact known-answer/UTF-8 check, preserving normal surrounding
  whitespace without rewriting engine output.
- Require a declared native function header or framed JSON at each forced-tool
  frame opening. Reject prose in that header boundary while preserving literal
  argument content and mandatory final validation; no output repair is added.
- Preserve original messages for exact owned native Qwen4 text required/named
  calls through Swift serving/accounting and the Rust prompt sidecar. Advance
  normalization to v5; previous identities fail cold for exact-cache credit.
- Preserve per-request rotary position semantics in mixed text/image batches,
  including hidden-returning MTP history paths. Keep singleton admission and
  speculative caps unchanged; longer-prefix batching qualification remains open.
- Add qualified opt-in full-KV parallel attention and early layer submission,
  plus canonical media-prefix positions for appended-text reuse. Preserve
  native state, PLE fill/fault ownership, MTP and existing fallback behavior.
- Require native tool framing after the rendered reasoning boundary for
  required/named Qwen4 text calls. Keep argument values model-generated and
  retain strict postvalidation and target-only constraint safety gates.
- Record bounded speed gains and unresolved quality/release gates in the
  [September 15 draft update](docs/reports/2026-09-15-qwen38-performance-stability.md).
- Mirror parallel-aware required/named tool instructions for other paths in
  the coordinator's prompt sidecar. Regenerate immutable prompt vectors and
  preserve ordinary serving across mixed prompt-contract versions.
- Preserve non-reasoning Qwen 3.8 Next function-call history on the standalone
  Responses endpoint and emit Responses SSE lifecycle/item events, including
  incomplete and failed terminals. Add actual cold-load admission regressions
  covering the Nemotron standalone-guard lesson.
- Drain native completion before the final empty-pool memory refund; retain
  strict allocator and scoped-stream ordering tests.
- Reject unsupported thinking efforts for the owned Next artifact with a
  typed HTTP 400 before template rendering. Preserve native low/medium/xhigh
  controls, disabled-thinking precedence and other models' templates.
- Make required/named tool instructions respect allowed parallel calls. Retain
  the singular contract when parallel calls are disabled; do not contradict
  a request for several independent calls with singular forcing instructions.

No provider version bump, model publication, catalog activation, release or
deployment is implied by this support update.

- Add native Qwen4 text serving with retained embedded MTP, SSD-backed learned
  PLE tables, native paged state and complete-checkpoint support. Scope automatic
  paging/cache defaults to the exact owned serving identity; preserve artifact,
  runtime, dtype and cache-identity gates.
- Enforce a lower-only local context limit over prompt plus reserved completion,
  reject overflow with a sanitized client error, keep unsupported media out of
  the text path and preserve request-owned cache usage and connection cancellation.
- Carry validated SSD-offloaded weight declarations through provider/coordinator
  admission and add repository-owned pinned conversion/provenance tooling.
- Record current component/synthetic checks and remaining fresh-build, real-model,
  cache/restart, API and hardware qualification in the
  [native support reference](docs/reference/qwen4-next-support.md).
  Full production qualification remains separate from the reviewed support update.

## v0.9.4

Published 2026-09-15 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.4)).

### App Attest Recovery and Retirement Readiness (Historical Preparation)

- Fix the released 0.9.3 App Attest callback-timer abort. Require the callback completion/expiry smoke in the optimized signed bundle, installer and updater; distinguish callback failures from Metal failures.
- Keep App Attest off by default, require an explicit stable account cohort and provider 0.9.4 or newer. Existing APNs/MDM serving and the supported macOS floor remain unchanged. Production App Attest remains paused until a separately approved rollout.
- Retry transient shadow failures, including temporarily saturated control-lane sends, without disconnecting serving providers; bound actual uncancellable Apple operations and fence late callbacks.
- Recover cached enrollment receipts through a separately validated renewal path, retain original failure records, and reconcile interrupted evidence without advancing counters. Receipt renewal requires the dedicated server credentials.
- Associate machine identities through fresh account-bound App Attest assertions, including reconnects after legacy-key rotation. This does not rewrite balances or certify physical-device uniqueness.
- Negotiate App Attest protocol 3 to bind app-measured machine model, RAM, CPU/GPU counts and the existing verification key to the signed transcript. Preserve old transcripts and cached enrollment recovery across upgrades; move the unchanged base-reward memory-cap catalog out of the MDM package.
- Record versioned prospective authorization outcomes, revocation, current-connection freshness, qualified builds and receipt/risk readiness. The private dashboard shows exact cohort denominators and blockers for a later MDM retirement.
- Capture SDK 27 Apple-signed CodeDirectory measurements and require an exact qualified binary/code-hash pair for prospective build approval. Release builds and their provider tests select SDK 27 / Swift 6.4 and record the full CodeDirectory SHA-256; missing or unsupported measurements stay unknown. macOS can identify the exact code without a bundle-version extension.

## v0.9.3

Published 2026-09-15 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.3)).

### App Attest shadow rollout and provider reliability

Source changes since `v0.9.2`. App Attest remains observational, with APNs and MDM authoritative.

#### Prefix-cache reuse and routing

Provider changes require a new signed bundle; coordinator changes require a
coordinator deployment.

##### Provider

- **Checkpoint write priority** — Limit first-seen checkpoint writes to a continuously refilling 90% share of the existing write budget, reserving capacity for prefixes observed again within the cache TTL. Every write still consumes the original total budget; authenticated durable duplicates consume no additional write budget. Novel-share exhaustion reports `write_priority_limited`, while total-budget exhaustion remains `write_rate_limited`. TTL, disk-space reserves and the overall write cap remain unchanged.
- **Maintenance recovery** — Reconcile removed checkpoint index entries inside the destructive epoch barrier for whole-root external mutations so later reconciliation does not rotate the model epoch again solely for those removed entries. Single-entry eviction and corrupt-file removal update only their known index entries, avoiding a full filesystem scan after each victim during budget reduction. Surviving valid checkpoints remain reusable.

##### Coordinator

- **Qwen prompt parity** — Match the provider's Qwen-family handling of required and named tool calls, including catalog aliases and Qwen3-VL, to avoid mismatched thinking controls in cache proofs.
- **Repeated-prefix routing** — Prefer a stable cache-capable provider for repeated prefixes only among otherwise equivalent cost, queue and pending-work candidates. Exclude capabilities quarantined after a failed cache proof from this preference, even when heartbeats continue advertising them. Revalidate at reservation and rescan if affinity eligibility changed after selection. Preserve ordinary serving when no unfenced cache candidate is available, along with capacity, deadline, trust and proof gates. Profiler rows identify this preference as `prefix_affinity`.
- **Cache opportunity diagnostics** — Report per-model reasons and numerical counts for repeated-prefix demand, usable holders and routing selection. These diagnostics distinguish routing opportunities from actual cache hits and measured latency savings. Add a [consumer guide](docs/consumer/prefix-cache.md) for preserving shared prompt prefixes.

#### Doctor and attestation reliability

- Prevent large process lists from blocking `doctor` and `verify`. Capture contention and sleep-probe output without pipe backpressure and apply an execution deadline; preserve diagnostic output and failure handling.
- Match the coordinator's canonical status bytes for mixed-case model IDs and template names, including Unicode separators. Preserve signed fields, omission rules and signature verification.

#### App Attest coexistence

- Add stable server-assigned machine identities, verified legacy aliases, historical backfill and macOS adoption inventory. Keep existing operational serial, routing, and accounting rules.
- Retain complete attestation and assertion submissions, initial and renewed receipts, verification context and outcomes in a private durable archive. Add an authenticated admin dashboard and complete-record downloads.
- Bind account scope and locally derived OS/build status with protocol 2. Recover lost enrollment responses, cap key generation across accounts, and bound Apple callback waits. DeviceCheck's separate device-bit service stays deferred.
- Bound shadow archive, rejection, and disconnect work against the shared database pool; count saturation as a coverage gap. Recover after missing Apple callbacks without restarting the provider. Continue renewing existing receipts when new shadow exchanges are disabled.
- Repair missed inventory disconnect records from durable liveness history after contention or restart. Use only bounded, validated endpoint keys for shadow enrollment, and label original-field and decoded-proof checksums explicitly.
- Include App Attest frames rejected by the 48 KiB decoder limit in refusal telemetry and the machine-inventory census, without retaining oversized proof payloads or blocking normal provider messages.

- Add negotiated App Attest shadow enrollment and fresh connection assertions, with independent certificate/policy verification, durable counters, and coverage/latency observations. APNs and MDM remain authoritative; shadow success or failure changes no routing, trust, payments, or supported OS floor.
- Keep the CLI and app launch flow; add profile-authorized App Attest signing alongside APNs in release and validation workflows. Actual macOS 27 acceptance requires the final signed app on physical hardware.
- Accept macOS Developer ID profiles granting only the App Attest CDhash opt-in, including array grants. Preserve existing APNs/keychain entitlements; validate the attested environment on the coordinator even when the optional environment entitlement is absent.

### GPT-OSS SSD Caching

- **GPT-OSS 20B SSD prefix caching** — Enable authenticated complete paged checkpoints by default for exact `gpt-oss-20b`. Restore native full-attention rows and sliding-window state under the existing tenant, model, prompt and runtime identity gates. Keep resident retention opt-in; global cache disable and contiguous fallback serve cold. Other GPT-OSS IDs remain opt-in.

## v0.9.2

Published 2026-09-11 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.2)).

### Gemma QAT Caching, Adaptive MTP and Nemotron Lightning (Historical Preparation)

Source changes since `v0.9.1`. Provider changes require a new signed bundle.
The provider wire protocol remains compatible with the 0.9.1 coordinator;
coordinator and console changes below require their own deployments. The
[rollout review](docs/reports/2026-09-10-provider-092-rollout-review.md) records
compatibility checks and outstanding runtime qualification.

#### Provider

- **Gemma QAT SSD prefix caching** — Enable authenticated complete paged checkpoints by default for exact `gemma-4-26b-qat-4bit`. Preserve tenant, model, prompt, binary, metallib and numerical-state identity checks, the global cache disable and cold fallback. Other Gemma artifacts remain opt-in. A new binary starts a new checkpoint identity; existing 0.9.1 checkpoints are not reused across the upgrade.
- **Adaptive Gemma MTP** — Automatically resolve the catalog assistant for that exact QAT target and select ordinary decode or one draft token from measured committed output and elapsed time. Include seed work, reset workload learning when requests finish or IDs are reused, and track compilation warmup by exact verification shape. Support target-prefix sampling for temperature/top-p/top-k/min-p, with ordinary decode for unsupported transforms and explicit diagnostic verification controls retained.
- **Assistant activation while serving** — Download and verify the optional assistant while the current engine serves. Reserve staging memory and retain its target against eviction; publish reduced capacity immediately and restore survivor KV grants after discarded preparation. After network rollout jitter, close only that model's new admissions, advertise `reloading`, and finish accepted work before swapping. Racing requests receive transient 503 `slot_state` refusals. Timeout or cancellation discards the candidate and reopens the original engine without cancelling accepted requests. Standalone follows the same bounded drain without fleet jitter; insufficient memory preserves target-only serving.
- **Assistant download sources** — Honor catalog-declared immutable Hugging Face assistant revisions with checksum-verified R2 fallback and jittered fetch retries. Existing R2-only metadata remains valid; shipping this binary does not apply the separate catalog patch. Standalone uses its configured coordinator catalog authority.
- **Nemotron Lightning serving** — Admit the three explicitly qualified registry/Hugging Face IDs on the existing network and standalone paths; reject other `nemotron_h` artifacts. Enable native paged KV and complete encrypted prefix reuse with native activation/KV precision and FP32 persistent Mamba state. Declared embedded MTP uses request-owned assistant state, exact prefix checkpoints and adaptive depth up to seven; checkpoints include Nemotron numerical controls.
- **Native reasoning and tools** — Separate Nemotron reasoning before tool parsing and validate required/named calls before publishing them through the existing encrypted response stream. Keep Gemma grammar enforcement and explicit per-model capability advertisement. Fix standalone Lightning admission to use the model's exact identity before the existing memory gate.
- **Shared inference dependencies** — Pin the merged MLX core, C, Swift and SDK chain for explicit mutable Metal-kernel inputs, request-owned paged MTP, recurrent rollback, checkpoint ownership and typed native generation events. Release CI includes nonzero/no-skip synthetic SDK gates; real-model gates remain separately identified.

#### Companion coordinator and console changes

- **Warm-pool headroom** — Grow warm replicas from measured headroom before a failed request, using measured occupancy growth, per-model headroom limits and bounded load bursts. Requires a coordinator deployment; the provider release does not activate this policy.
- **Earnings navigation** — Keep earnings accessible after removing all linked Macs and display the supported payout-coverage notice. Requires a console deployment.

#### Qualification and rollout

The reviewed source has passing component and integration evidence, but final
combined-artifact model qualification remains incomplete. The amended Gemma
admission-drain path still needs matched B1 on/off, B4 branched-prefix and real
HTTP activation/download-failure checks. Earlier greedy MTP coding outputs
show a repeated source-ID correctness defect absent from the ordinary-decode
controls on that prompt; no general answer-quality equivalence or cache
corruption conclusion is claimed. Published-chain Nemotron connected-serving
and restart qualification also remain open. See the rollout review before
fleet publication; source compatibility alone is not a release-ready verdict.

## v0.9.1

Published 2026-09-09 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.1)).

### Cache reliability and recovery

Source changes since `v0.9.0`. Provider changes require a new signed bundle;
coordinator and console changes require their own deployments.

#### Provider

- **Request completion during recovery** — Keep completion/error delivery working after cache shutdown or deallocation, deliver each terminal once, and drain accepted cache evidence before its terminal. Preserve secondary-tier terminal suppression.
- **Duplicate checkpoint reuse** — Keep an existing complete checkpoint when another request reaches the same prefix with a different valid prefill chunk size. Reauthenticate its original bytes, metadata and complete encrypted payload; preserve identity, tenant, state-layout and corruption checks.
- **Checkpoint write recovery** — Preserve unrelated valid checkpoints when atomic creation of a new checkpoint fails, allowing a later donation to retry without an unnecessary cache-epoch reset. Existing files that fail reauthentication still revoke their cache evidence.
- **SSD disk budget** — Size the shared cache at half of currently available disk space without a fixed 100 GiB ceiling. Keep a fixed 20 GiB low-disk write reserve instead of 5% of the whole disk, and check the full pending donation against space above the reserve. Preserve encryption, eviction, daily write limits and ENOSPC handling.
- **Cache failure attribution** — Distinguish complete-checkpoint host-memory, epoch, maintenance, disk-space, unsafe-path, I/O and eviction outcomes in bounded provider/coordinator telemetry.
- **Telemetry shutdown** — Stop queued slot-posture callbacks after cancellation and wait for the sampler during shutdown, preventing telemetry after teardown returns.
- **Deadline diagnostics** — Report the received prediction policy, reservation ceiling and encoded deadline budget alongside the provider's prediction and decision, distinguishing refusal from acceptance followed by expiry.

#### Companion coordinator and console changes

- **Cache prompt parity** — Match provider JSON response-format instructions and Qwen/Harmony system-turn folding in cache planning so structured-output requests do not generate false prompt-anchor mismatches. Exercise the real service preparation path in shared tokenizer/hash parity tests.
- **Per-model cache reporting** — Add internal breakdowns of provider-reported hits/misses, cached and avoided-prefill tokens, accepted V2 proofs, cache-selected terminals and timing samples. Measure saved-prefill percentages with matched prompt-token denominators for each population; retain invalid/missing usage separately from misses. Add bounded receipt rejection and prompt-length/hash mismatch diagnostics while preserving aggregate public status.
- **Cache evidence continuity** — Preserve unchanged models' holders and receipts when another model loads or changes, retain proof-mismatch fences across unrelated capability updates, and distinguish proof mismatch from ordinary holder changes.
- **APNs reconnect recovery** — Persist verified same-process continuity for bounded coordinator reconnects without refreshing the original Apple proof timestamp. Preserve encrypted resume challenges, token/process/binary binding, new-process freshness checks and Apple push budgets. Stamp final continuity after the socket is offline while keeping periodic updates online-only.
- **Indexed startup recovery** — Recover history through indexed identity lookups instead of scanning every historical session before serving. Select the newest prior session, exclude live/incomplete records and late async writes, preserve live attestation requirements, and publish provider records and reputation atomically. Retry transient store failures within a shared deadline; pending recovery cannot route, and exhausted recovery closes the new registration before evicting an existing session. Preserve legacy missing-reputation behavior while refusing failed reads.
- **Earnings-summary preparation** — Pin missing history before the durable attempt marker and resume per-key additions safely alongside live settlement. Keep base-reward money separate from inference counts/tokens and maintain summaries on record-only inserts as well as account settlement. Add a database-only migration command for approved pre-cutover preparation.
- **Startup measurements** — Add startup phase timings and a read-only post-stop observer that separates candidate health/readiness and per-model routable capacity from optional disposable-test inference. Keep successful inference distinct from answer correctness and omit response text, usage and credentials from reports.
- **Routing deadlines and admission** — Refresh remaining time after registry/provider lock waits before reserving a retained backup, skip expired reservations and shrink an enabled prediction ceiling. Estimate unreflected pending prefill from each request's own prompt size, excluding requests that already produced content, while preserving the proxy for unknown cache work and reflected queues.
- **Incoming request accounting** — Add an unsampled request-outcome ledger and bounded admin inspection with explicit coverage and completion evidence. Record recovered HTTP errors and parsed streaming mode, and distinguish completed, incomplete and error response terminals after successful writes while preserving contradictory evidence and earlier content progress.
- **Partial network geography** — Keep the stats overview available when request-location or route analytics time out. Refresh geography independently, expose unavailable sections, preserve valid empty maps and restore geography after recovery.

## v0.9.0

Published 2026-09-07 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.0)).

### Stats request-flow refresh

- Restore Stats refreshes on large usage windows by aggregating request origins before looking up provider locations. Preserve weighted coordinates, request/token counts, and the top-50 flow limit while avoiding large temporary sorts.

### Provider console entry

- Open the provider workspace directly from the console home page, removing the Consumer/Provider selection page. Keep chat and API access in workspace navigation.

### International bank withdrawals

- Add a Stripe Global Payouts route enabled by default in the next production release for additional bank-payout countries, including India, alongside existing Connect withdrawals. Providers review a local-currency estimate before confirming.
- Keep Connect withdrawals independent of browser confirmation storage. Stop automatic retries for ambiguous payouts requiring manual review and show their reserved-funds status in history.
- Show recipient deposit limits and retain quoted Stripe fees for operator review. Continue reconciling existing payouts after funding-account changes and safely release unsubmitted confirmations when payouts are paused.
- Use one earned-balance ledger across both routes, recover confirmations after browser reloads, preserve definitive rejections across refund failures, and reconcile bank returns exactly once. Prune expired unconfirmed quotes. Display sent transfers separately from bank receipt.

### GPT-OSS prefill and decode

- Skip unused GPT-OSS prefill vocabulary projections, fuse compatible 20B expert gate/up weights with bounded load materialization, reuse unchanged quantized constants, and enable the measured width-2880 MXFP4 decode path on M4 Max. Keep rollback controls and unsupported-shape fallbacks.

- Add sequential, provenance-pinned GPT-OSS profiling with full-shape warmups, raw decode token timing, memory measurements, common-window aggregate B=2/B=4 decode rates, and mixed-length arrival workloads. Preserve failed and diagnostic runs separately from valid baseline measurements; raw evidence and paired comparisons distinguish measurement from optimization.

### Hugging Face model downloads

- Add an optional, commit-pinned Hugging Face artifact to each registry version. Foreground model downloads and background prefetch prefer HF, verify the existing per-file SHA-256 and aggregate hashes, and fall back to R2 on download or integrity failure. Existing registry entries keep using R2.

### Qwen non-thinking streaming

- Stream Qwen answers as they are generated when the rendered prompt already closes its thinking block, including image and video requests that default thinking off. Preserve incremental reasoning, explicit parser overrides, and token usage.

### Paged Attention and Qwen Caching (Historical Preparation)

- Preserve provider startup and process diagnostics in the connected cache-routing test, so a two-provider registration failure remains diagnosable before any request runs.

- Prepare automatic paged attention for the three Qwen artifacts, GPT-OSS 20B and Gemma 4 QAT. Scope default SSD caching to Qwen independently of the attention backend; preserve explicit cache opt-in and all backend rollback controls. Model acceptance and operational release validation remain incomplete.

- Verify explicitly enabled Gemma 4 QAT draft tokens with ordinary target-forward shapes to avoid the observed width-dependent token change. Keep assistant drafting and explicit offline rectangular diagnostics; the serialized verification can reduce speculative throughput.

- Retain two-pass attention numerator partials in FP32 through final normalization, avoiding low-precision cancellation and intermediate overflow. Update the shader ABI and generated Swift sources together; model regression validation remains pending.

- Fix recurrent target scoring to use request-owned state and normal peak admission on both KV backends. Preserve ordinary serving dispatch and release state, KV and capacity after failed diagnostics.

- Accumulate affine quantized matrix-vector bias inputs in the wider accumulator type. Regenerate the embedded shader source alongside the Metal library; GPU regressions cover low-precision input cancellation across quantization widths and dispatch shapes.

- Add manual signing/notarization validation without deployment environments or release publication, and exclude the 0.9.0 validation branch from console UI Git deployments. Keep signing/runtime/model approval gates separate.

- Bind GPT-OSS and Gemma optimization settings to SSD checkpoint identities, so changing an optimization or rollback control cannot reuse a checkpoint from the previous numerical configuration.

- Add bounded exact-token ordinary scoring through `darkbloom benchmark --teacher-forced-input`, with explicit model/backend identity, repeated numerical observations and instrumentation controls. These observations do not certify model quality or speculative verification.

- Bound speculative draft depth by useful remaining output slots for every fixed, adaptive and exploration offer. Avoid drafting when only the next target token can be emitted; preserve carry/history and rollback handling.

- Add production-derived single-slot benchmark grants and a cancellation probe that requires a completed donor, actual SSD restoration and exact recovery output. Preserve explicit envelope controls and complete failure evidence.

- Preserve measured SSD restore costs across later Ready estimates for the same checkpoint, without extending measurement freshness or crossing provider/capability changes.

- Add complete native paged checkpoint restore for recurrent Qwen and historical attention windows, with bounded direct export, explicit metadata/auxiliary ownership and cancellation-safe retirement. Real-model release validation remains pending.

- Include excess SSD restore time in coordinator routing costs, so an expensive cache holder can lose to a faster cold peer. Preserve useful-hit discounts, full-request admission and positive-benefit telemetry.

- Expose native allocator padding and released reservation allowance in provider telemetry; avoid scanning unrelated SSD checkpoints on prefix lookup. Verify real allocator ownership and exact capacity refusal.

- Add immutable allocator sizing projections for admission without allocation, locks or error callbacks.

- Reserve native paged allocations using allocator-owned per-buffer bounds, then settle to measured backing bytes. Preserve shared backing ownership, rollback and completion-before-refund checks; provider SSD integration and model performance validation remain pending.

- Add native checkpoint page adoption with typed stage ownership, atomic grant publication and generation-safe retirement. Atomically reserve model loads and bind optional native memory owners to the shared process ledger; production codec and serving-factory integration remain in progress.

- Reject runtime KV dtype mismatches before paged writes and propagate evaluation faults through normal request retirement, preserving native precision and ownership cleanup.

- Report coherent process-memory commitments, materialization, debt and owner counts through optional heartbeat observations. Preserve capture age on replay, validate accounting identities and emit bounded diagnostic metrics without changing routing or capacity authority.

- Capture active, cached and peak MLX memory counters under one allocator lock, so admission can read a coherent accounting snapshot without synchronizing streams.

- Keep live memory reservations charged during prolonged capacity rejection. Remove age-based refunds while preserving bounded diagnostics and background allocator-cache reclamation.

- Report queue-captured paged ownership and allocator refusals through provider heartbeats, coordinator metrics and console types. Preserve capture age, optional instrumentation and reload-safe counter deltas; grant-only updates cannot freshen allocator observations.
- Add private native-page checkpoint filling and bounded byte-preserving export across BF16, FP16 and FP32. Live SSD adoption and the complete paged codec remain under implementation.

- Add runtime B1/B2/B4 benchmark controls with explicit production-bounded KV grants, complete row outcomes, sampled capacity/memory, and strict comparison checks.

- Add an opt-in segmented KV store with native BF16/FP16/FP32 pages, transactional growth, stable buffer identities, and bounded Metal bindings. Verify transfer, allocation rollback, sliding-window and multi-bucket attention mechanics; production backend selection remains unchanged while model and capacity validation continues.
- Account segmented native buffers under each engine's admission budget, including grant shrink, private growth and retirement. Evaluate first-prefill page writes through the normal step roots so native storage is released before its budget is refunded.
- Measure loaded models' native KV types before explicit paged construction and preserve per-layer precision in storage and slot sizing. Enable gated segmented Qwen execution with recurrent/MTP rollback coverage; default selection and complete SSD restore remain contiguous.

### SSD prefix checkpoints

- Preserve native SSD lookup receipts and cache usage when a streamed request is canceled after output; settle only delivered tokens.

- Retain prefix receipts through the provider event pump so successful submission cannot discard routing evidence before durable publication. Preserve terminal and cancellation cleanup.

- Record strict normal-Qwen3.5 paged SSD comparisons at output caps32 and128 after the useful-tail policy. Preserve exact same-budget output identity, natural stopping and the remaining cross-budget numerical difference.

- Record a strict initial Qwen3.6 paged B1 SSD pair with coherent idle observations and normal MTP. Preserve the failed earlier snapshots and distinguish original-native measurements from the later useful-tail policy.

- Reconstruct connected-test reasoning once when SSE includes equivalent compatibility aliases. Reject conflicting values and replay captured streams with different chunk boundaries without weakening output equality.

- Observe published idle snapshots at known benchmark retirement boundaries with a bounded deadline. Preserve timeout/cancellation evidence and keep observation waits outside request latency measurements.

- Record strict initial paged B1 SSD-cache pairs for exact Qwen3.8, GPT-OSS 20B and Gemma 4 26B artifacts. Preserve setup failures, correct the documented local assistant layout, and retain the remaining five-model release gates.

- Require actual off/on cache pairs and retirement evidence in both benchmark arms. Preserve the first Qwen3.6 paged SSD semantic pair and the stricter rejection of stale control snapshots; remaining release gates are pending.

- Bind isolated benchmark cache roots and requested key mode explicitly, reject mismatched actual key mode, and retain cache-construction status on refusal. Preserve production key and native eligibility guards.

- Add an opt-in connected HTTP cache gate using real provider transport and the Rust prompt sidecar. Verify routing, native reuse, tenant isolation, continuation, tools, cold vision, restored cancellation and recovery with exact-artifact paired reports. Helper tests pass; real-model HTTP results remain pending.

- Let production segmented paging use the normal admitted slot KV grant and follow shrink/regrow updates. Delete obsolete eager-pool fractions, caps and minimum checks while preserving native buffer limits, live ownership and shared memory admission.

- Bind complete paged SSD checkpoints to loaded Qwen recurrent and GPT-OSS/Gemma historical-attention capabilities, with exact native storage identity, shared process admission and bounded host I/O ownership. Keep resident payload caching opt-in and paged rollout gated on real-model validation.

- Bind cache plans and prepared receipt owners to one configuration generation. Revoke queued cache scope on reconfiguration or cancellation while preserving ordinary encrypted inference, deadline budgets and authenticated late-receipt cleanup.

- Raise the default shared SSD cache ceiling to 100 GiB, limited to half the volume’s currently available space. Preserve explicit disk-budget overrides and the low-disk write guard.

- Store eligible complete dense Qwen prefix checkpoints on encrypted SSD by default, including supported affine-quantized models, when verified runtime identity and the cache key are available. Preserve attention KV, recurrent state, and normal MTP history. Stream only the matched checkpoint into memory reserved for the active request, with bounded transfer buffers and no retained cache tensors while idle.
- Extend the complete-checkpoint codec to Qwen MoE targets with the same validated attention and recurrent state layout. Add native dtype, fresh-engine restore, branch, isolation and provider wiring tests; full-size model rollout validation remains pending.
- Capture one UTC template date per request across coordinator planning, provider rendering and retries, enabling exact GPT-OSS prompt contracts. Keep unsupported clock formats cold and version the shared normalization and renderer semantics.
- Correct Qwen tool-result grouping and preserve boolean tool arguments. Align coordinator JSON rendering and decimal parsing with the provider, version the renderer contract, and verify exact prompt tokens across all five release models and additional Gemma variants.
- Share immutable parsed tokenizers across verified prompt contracts, while preserving per-contract integrity checks and releasing unused tokenizers. Reduce sidecar memory and construction work without changing prompt tokens or contract identities.
- Bind durable checkpoints to verified weights, prompt contract, runtime, and numerical settings. Validate checkpoint geometry and authenticated segments before adoption; cancelled or incomplete donations cannot publish ready evidence.
- Index verified prefix holders by content across machine epochs, so lookup visits matching holders and enforces the configured per-tier machine limit. Preserve tenant, artifact, expiry, restart and capacity checks.
- Suppress resident cache routing evidence when the provider selects complete SSD checkpoints, including temporary gaps in durable readiness.
- Price verified cache reuse by saved prefill time after staging, capped by the request's prefill work. Preserve load, queue, decode, health and capacity costs; select the cheapest adjusted candidate when cache credit applies. Optional credit caps distinguish absence from explicit zero.
- Route using actual committed checkpoint endpoints, including endpoints below the full prompt boundary. Negotiate the new receipt semantics with the coordinator and preserve compatibility with older peers.
- Allow operators to restrict network prefix caching to exact model, weight, and prompt-contract identities before planning or issuing reusable cache scope. Preserve existing eligibility when the optional list is absent; an explicitly empty list disables participation.
- Report SSD cache use, I/O, donation outcomes and maintenance through typed heartbeat telemetry, with sample age and reload-safe counter deltas. Expose aggregate artifact-list status and keep heartbeat snapshots independent of filesystem sweeps.
- Require `DARKBLOOM_PREFIX_CACHE_MEMORY=1` for resident recurrent checkpoints or paged KV sharing. Retain bounded checkpoint compaction and useful-prefix SSD selection for these explicit memory modes.
- Stream eligible attention-only SSD blocks into evaluated native tensors with bounded decryption buffers and explicit staging reservations.

### Coordinator and provider hot-path cleanup

- Rank routing candidates without temporary lists and assemble streamed tool arguments without repeatedly copying accumulated output. Share SSE sanitization framing and remove unreachable accumulator repair paths.
- Decode provider chat-template controls once, sharing the local request decoder and eliminating batch item reserialization.
- Skip standalone SSD-only weight hashes for known configurations that cannot reuse durable prefixes. Preserve verified pre/post-load hashes for complete Qwen SSD checkpoints, connected attestation, and conservative fallback for unknown configurations.
- Separate inference event handling from token accounting, share terminal cleanup, reuse chosen-token logprob decoding, and remove the unused incremental KV reservation API.

### Stats location refresh

- Restore public stats refreshes on large usage tables by aggregating locations per provider before combining location totals. Preserve distinct-provider and token counts and request-weighted coordinates without sorting every usage row. Keep the selective cutoff's query plan local to the analytics transaction.

### Coordinator performance Tiers 2 and 3

- Cache repeated user and model lookups, batch route telemetry writes, and credit balances in one database statement. Invalidate model caches without allowing older in-flight reads to republish stale entries.
- Coalesce streaming output within a byte cap and parse request bodies once.
- Reduce routing scan work with per-model provider indexes, maintained medians, reusable snapshots, bounded version memoization, and coalesced swap and queue-drain planning.
- Commit reservations under the registry read lock and the selected provider's lock. Keep fault tracking on per-identity gates, with validated rebind and sweep handling; retain `EIGENINFERENCE_RESERVE_COMMIT_MODE=global` as the reservation rollback switch.
- Preserve newer rejection state when capacity-accept bookkeeping arrives late.
- Make scheduler, attestation timestamp, and reputation persistence test fixtures deterministic.

### Provider lifecycle and bounded coordinator work

- Keep genuine provider 502 faults across version changes; only coordinator-marked disconnect flushes are eligible for reset. Count first-scan TTFT rejections in request outcome telemetry.
- Evict capped zombie tracker entries in constant time, preserving recent activity without per-insertion full-map scans.
- Fragment large provider WebSocket messages, bound queue-drain work, and keep control traffic responsive.
- Fence typed draining refusals at ingress before releasing the request slot; preserve newer recovery heartbeats. Graceful restarts remain health-neutral, and late disconnect errors follow identity enrichment without re-quarantining an upgraded provider.
- Correlate cancel sends and terminals atomically, bound version history and telemetry tags, and retain MLX metrics on HTTP-only Datadog deployments.

### 2026-09-04 console redesign

- Provider onboarding specifies macOS 26 or later.
- Added a Consumer/Provider entry page, dedicated `/chat` route, contextual workspace navigation, and public provider onboarding shared with the empty fleet. Linked providers return to their fleet and recorded earnings, including when their Macs are offline; failed discovery never implies an empty account.
- Scoped fleet requests to the current account, cancelling late results on sign-out or account changes.
- Redesigned console navigation, chat composition, searchable model discovery, settings, and API integration examples.
- Redesigned network stats as one continuous overview: an explorable geography
  map, side-by-side request and token charts, graphical model-capacity lanes,
  linked silicon and memory charts, and an expandable provider directory.
- Stats refresh every 30 seconds. Source timestamps survive cache hits; the
  console proxy coalesces requests and bounds fresh caching to 30 seconds. The
  coordinator retains successful snapshots for up to five minutes on refresh
  failures; older source snapshots are marked stale. The page pauses refreshes
  while hidden and distinguishes unknown capacity from zero.

### Coordinator performance Tier 1

- Bound recent in-process usage history with lazy allocation; aggregate dashboard earnings across every row in the rolling windows.
- Refresh public stats and network totals in the background. Preserve unexpired successful data on store failures, return 503 when unavailable, and accept genuinely empty windows.
- Remove capacity-accept bookkeeping from the first-byte path while preserving newer rejection strikes and cooldowns; avoid redundant provider cancels after settled completion.
- Reduce verification polling, coalesce dashboard cache misses, serialize totals queries across windows, batch reputation reads, and throttle successful reputation writes. Add lock-wait/scan instrumentation and preserve unevaluated rejection servability as null.

### 2026-09-03 documentation overhaul

- **Every page under `docs/` rewritten or verified against the code at
  `5d400cf75`** — each page now carries a freshness stamp
  (`> Last updated: <date> · commit <sha>`) naming the code commit its claims
  were checked against; frozen records (`docs/reports/`, `docs/releases/`,
  `docs/legal/`) keep the date and commit of their own last substantive
  change. Claims cite code by path and symbol, not line number. Facts that
  drifted from the code were corrected in place (examples: challenge
  freshness is 16 min not 6; the prefix cache is built only on
  explicitly-paged slots; eviction is two missed 30 s sweeps against a 90 s
  timeout; explicit `max_tokens` is not clamped; the platform fee is stated
  once, in `docs/architecture/billing.md`).
- **Tree reorganised by page type** with `docs/README.md` rewritten as an
  llms.txt-style map (one line per page) and an index per directory.
  `architecture/` holds explanations only — `architecture/operations/*`
  became `architecture/{billing,model-registry,routing,scheduling,telemetry}.md`
  and `architecture/prefix-cache.md`, `architecture/components/admin-ui.md`
  are new; `reference/` gains `configuration.md` (every environment variable
  of the coordinator, provider CLI, console and admin UI, with defaults and
  the symbol that reads it) and `telemetry-inventory.md`; plans and ADRs live
  in `design/` with a status line each (`design/README.md`); dated frozen
  records live in `reports/` (`reports/README.md`; twelve reports that were
  sitting uncommitted are now in the tree); `glossary.md` gives one name per
  concept. Merged as duplicates: `architecture/payments.md` →
  `architecture/billing.md`, `provider/security-model.md` →
  `provider/attestation.md`, `reference/ssd-kv-cache-hybrid-models.md` →
  `reference/ssd-kv-cache.md`; PR screenshot folders removed. Security
  diagrams redrawn from the code (`docs/assets/diagrams/*.mmd` → SVG/PNG).
- **One home per fact** (follow-up to an organisation audit of the new tree)
  — every constant, default, limit and status code is now stated on one owner
  page (`reference/api-contracts.md`, `reference/configuration.md`,
  `reference/pricing-model.md`, the owning `architecture/` page) and linked,
  by identifier, from every other page; operator procedures and SQL recipes
  left the explanation pages for `operations/cache-routing-rollout.md` and
  `operations/profiler-queries.md`; `developer/release.md` became
  `operations/provider-release.md` (it registers releases with production);
  six plan and decision memos moved from `reports/` to `design/` with a
  status line each (`design/README.md` lists all seventeen with status and
  date); `provider/attestation.md` is now the operator how-to for reaching
  and keeping `hardware` trust, and `consumer/privacy-expectations.md` a
  short list that links the encryption page instead of restating it.
- **Docs tooling** — `scripts/docs-stamp.sh` writes or refreshes the stamp
  (`--from-git` for frozen records); `scripts/docs-check.sh` fails on a
  missing or malformed stamp, a relative link that does not resolve, a cited
  code path that does not exist, or a page no index links to. `make
  docs-check` / `make docs-stamp`; `make test` runs the check; CI gains a
  "Docs Lint" job. `docs/AGENTS.md` states the rules for humans and agents:
  one job per page, one canonical home per fact, cite the code, stamp on
  every edit, and the page skeleton for each page type.
- **Root pointers** — `README.md`, `CONTRIBUTING.md`, `AGENTS.md` and
  `CLAUDE.md` point at the new paths, and the "coordinator never sees
  plaintext" claim was replaced by the hop-by-hop encryption model documented
  in `docs/architecture/security/encryption.md`. Code comments that named
  moved docs were updated (comment-only edits in `coordinator/`,
  `console-ui/`, `provider-swift/`).
- **Re-verified against `ac60c5ada` (#816)** — the runtime manifest's
  union-across-active-releases semantics, the `GET /v1/runtime/manifest`
  shape and the `EIGENINFERENCE_KNOWN_TEMPLATE_HASHES` override are stated
  once, in `docs/architecture/security/attestation.md#runtime-manifest`, and
  linked from the provider-release and release-policy runbooks.

### 2026-09-02 system profiler

- **Runtime manifest accepts every active release** — `SyncRuntimeManifest`
  now unions template hashes (including `mlx_metallib`) across ALL active
  release rows instead of keeping one value per template name. Registering
  v0.8.16 on 2026-09-03 replaced the v0.8.15 metallib hash in the manifest, so
  ~1,180 providers still on v0.8.15 failed their next attestation challenge
  (`provider runtime integrity mismatch in challenge response`, 1,184 times)
  and the fleet was unroutable for the ~30–40 minute self-update window.
  Registering a release can no longer deroute the previous release's fleet;
  deactivating a release remains the way to retire its hashes, a hash no
  active release ships still fails closed, and `GET /v1/runtime/manifest`
  lists every accepted hash per template. The post-mutation convergence paths
  and the `EIGENINFERENCE_KNOWN_TEMPLATE_HASHES` override use the same set
  semantics.

## v0.8.16

Published 2026-09-03 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.16)).

### 2026-09-02 system profiler

- **Per-request profiler** — the coordinator records one prompt-free row per
  dispatched attempt in `request_profiles` (joins `inference_routes` on
  `(request_id, attempt)`): microsecond offsets from middleware entry for every
  coordinator stage (auth, parse, reserve, media, preflight, plan, reserve lock
  wait/scan/admit, queue, encrypt, writer submit/dequeue/wire, provider ack,
  chunk ingress, first content, headers, flushes, `[DONE]`, client-gone,
  cancel, completion ingress, settlement), the routing decision context
  (gate rejections by closed reason, top-4 candidates, runner-up, best idle
  alternative, near-tie size, selection path, heartbeat age at decision,
  predicted vs raw TTFT, calibration ratio, queue position/drain trigger), and
  a validated provider profile: the provider now sends an optional `profile`
  object on `inference_complete`/`inference_error` (decrypt/parse/admission/
  model-load wait/prompt prep/engine submit & admitted/first & last delta/
  terminal build & send/cancel stage, plus the engine's own
  `CBv2RequestTiming`: admission, KV allocation, prefill chunks, prompt
  computed, first token, decode steps and batch rows, MTP accept counts,
  pauses, detokenization delay, prefix-cache lookup/adoption). Numbers,
  booleans and closed enums only; validated, folded and stored from a separate
  closed struct; never routing-, billing- or health-affecting.
- **Fleet snapshots** — `fleet_snapshots` samples every provider slot each
  minute (running/waiting, budgets, KV bytes, EWMAs, MTP totals, eligibility
  reason, cooldown/breaker/clamp flags, heartbeat age, cumulative cancel
  counters, low-power/thermal posture) plus a coordinator row (queue depth by
  model, in-flight, sink depth/drops, zombie-frame count). Heartbeats carry new
  optional `telemetry` sub-objects; `eval_in_flight_ms` finally has a producer.
- **Egress and attempt accounting** — non-streaming 200 bodies stamp the same
  first/last flush and bytes-out fields as SSE relays; attempts that never reach
  a provider close only their terminal half at the failure site so the record is
  built after the handler returns; a speculative primary cancelled for the
  first-content timeout keeps its timeout outcome even when the backup wins the
  ingress race.
- **Review hardening** — heartbeat-reported counts are clamped to the snapshot
  column range so one bad heartbeat cannot abort a fleet sample batch; the
  recorded TTFT calibration ratio is the one the candidate was scored with;
  routing replays count `no_provider` / `model_too_large` explicitly; terminal
  usage is recorded at ingress (outside billing) and each provider-profile
  consistency check runs independently; a speculative loser's discarded empty
  completion still closes its attempt row.
- **Operations** — admin browse/NDJSON export for both tables
  (`/v1/admin/profiles`, `/v1/admin/snapshots`), a manual `request_waterfall`
  view, retention sweeps (14 d / 30 d), a dedicated batched profile sink with
  `telemetry.sink_dropped{sink}` / `telemetry.sink_depth{sink}` metrics,
  `inference.unknown_request_frames{kind}`, knobs `EIGENINFERENCE_PROFILER=off`
  and `EIGENINFERENCE_PROFILE_SAMPLE_RATE` (default 0.1; slow, failed, retried,
  backup and client-gone requests are always recorded), routingsim NDJSON
  loaders for profile and fleet exports, `request_rejections.request_id`
  populated with a coordinator-minted id. `X-Timing` keeps its legacy keys
  (clamped, `timing_anomaly` flag) and gains additive `pre_handler_us`,
  `preflight_us`, `route_reserve_us`, `queue_pure_us`, `writer_us`,
  `socket_us`, `provider_ack_us`. Docs: `docs/architecture/system-profiler.md`,
  `docs/reference/telemetry-inventory.md`; threat model T-051.

### Activation Floors and SDK Updates (Historical Preparation)

The final tag pins `mlx-swift-lm` at `c4089870a24b082a9d70f31dc853380e9cff92ca`;
the intermediate pin in the preparation notes below is retained as history.

- **Per-model activation floors + measured resident weights** — the flat
  5.5 GiB activation reserve is now resolved per serving set from measured
  per-model floors (gpt-oss-20b: 3.5 GiB — its load requirement drops from
  20.0 to 18.0 GB, which narrows the 32 GB flap band reported in #653 by ~2 GB; the
  24 GB catalog tier stays borderline until the admit-time weight padding and
  the small-box `memory_reserve_gb` default are revisited, #653/#683), and the coordinator's
  POST-load token-budget estimate uses measured MLX residency for measured
  text-only artifacts (gpt-oss-20b: 11.5 GiB steady vs the 13.5 padded
  estimate) via `servabilityColdWeightsGiB`, version-gated at 0.8.16.
  ADMIT-time gates — provider load gate and the coordinator's cold-load
  admit — deliberately keep the padded disk×1.2 figure: it covers the load
  transient (shard staging), which steady residency does not. Vision-capable models (the qwens, the gemma VLM builds) keep the
  flat floor and padded weights until vision-inclusive measurements exist;
  measured text baselines and the full sweep live in
  `docs/reports/2026-08-30-activation-floor-measurements.md`.
- **Serving-set reserve race hardening** — epoch-stamped reserve pushes
  (cross-actor delivery is not FIFO), in-flight loads join the reserve
  basis, failed-load cleanup holds the load gate through its awaits,
  shrink paths regrow survivor grants, and failed-self-test retirement is
  fail-closed end to end: durable failed-hash record (slot-bound hash or
  refuse-all sentinel) consulted at every prefetch guard, a retirement
  tombstone spanning foreign-owned drains, registration convergence on the
  announce-undo, and new-inference rejection on both resident-slot fast
  paths while a retirement drains.
- **MLX-LM pin advances past the 0.32.2 core bump** — on top of #790's
  `libs/mlx-swift-lm` pin (`81dd564`, which already carried Qwen3-VL CBv2
  DeepStack #125 and the dense Qwen3.8 MTP artifacts #118), this release
  moves to `30da946`: the gather-QMM sorted-hint lane
  ([#126](https://github.com/Layr-Labs/mlx-swift-lm/pull/126)), vision batch
  performance ([#127](https://github.com/Layr-Labs/mlx-swift-lm/pull/127)),
  a serving-correctness batch
  ([#128](https://github.com/Layr-Labs/mlx-swift-lm/pull/128)), and the
  bench-harness hybrid-trunk paged fix
  ([#129](https://github.com/Layr-Labs/mlx-swift-lm/pull/129)).

## v0.8.15

Published 2026-08-29 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.15)).

### Qwen3.8 Dense VLM and MTP (Historical Preparation)

Correction: this release also added `runtime_capabilities` and
`code_attestation_resume_challenge`; the candidate's no-new-fields
statement below was incorrect.

- **Exact Qwen3.8 dense VLM artifact** — Providers serve
  `EigenLabs/Qwen3.8-27B-4bit` at immutable revision
  `301e9e2767fd0efcfab7883004720ba3c9a552a1`. The dense Qwen3.5 text target
  is extracted from the loaded VLM wrapper for ContinuousBatchingV2 while
  retaining shared immutable weights, recurrent/KV sizing, causal visual spans,
  request-owned M-RoPE state, cancellation, deadline, and MLX fault boundaries.
  Image processing remains one tower invocation per image. API video remains
  one full T×H×W tower invocation per video followed by ordered frame-output
  splitting; console/UI video upload is not enabled.
- **Exact separate Qwen3.8 MTP artifact, model-specific default on** —
  `EigenLabs/Qwen3.8-27B-MTP-4bit` at immutable revision
  `329261c5e0b3f9c233485e682cb3b67b88c20a55` is loaded only as a proposal
  assistant; the target remains authoritative for acceptance and output.
  Absent MTP config enables this exact target only. Explicit `mtp_mode = "off"`
  (including `darkbloom beta disable mtp`) and the
  `DARKBLOOM_CBV2_MTP=0` process kill switch independently restore target-only
  decoding. Explicit `on` remains available for other supported targets.
  Missing, malformed, unavailable, incompatible, or memory-inadmissible
  assistant state falls back to target-only decoding with a stable reason.
- **Unified Qwen template and tool controls** — Remote encrypted text/vision,
  local single/batch, and prompt recount paths share one template-control
  value. Nested `reasoning.enabled` wins over top-level or
  `chat_template_kwargs.enable_thinking`; only `none`, `off`, and `0` disable
  through `reasoning_effort`, `minimal` is preserved, media defaults thinking
  off only with no explicit control, and `preserve_thinking` is forwarded.
  Forced Qwen tool calls remain withheld until XML parsing, function selection,
  and schema validation succeed; the exact concrete model advertises the
  capability only for the `qwen3_coder` XML parser contract.
- **Capability-gated rollout and integrity** — The exact concrete model is
  restricted by the shared provider capability evaluator to Apple M5 with the
  approved NAX runtime. `video_preprocessor_config.json` is included in model
  integrity manifests. Provider version advances to `0.8.15`; no protocol
  fields are added.

## v0.8.14

Published 2026-08-27 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.14)).

### Qwen3-VL and Automatic MTP (Historical Preparation)

- **Qwen3-VL 30B-A3B production serving** — The exact
  `qwen3_vl_moe` architecture is admitted through the contiguous
  ContinuousBatchingV2 path. Text decode uses per-row M-RoPE positions; image
  prefill carries causal visual spans, every DeepStack level, and the model's
  embedding activation dtype. Homogeneous routed-expert gate/up projections are
  fused at load time, reducing each MoE layer from three gathered projections
  to two while retaining a strict split fallback for heterogeneous
  quantization. Paged KV, video, packed prefill, prefix reuse, compiled decode,
  and MTP remain fail-closed for this family.
- **Qwen 3.5/3.6 inline MTP defaults to automatic** — New
  `mtp_mode = "auto" | "on" | "off"` keeps Gemma opt-in while valid inline
  `qwen3_5_moe` artifacts activate by default. Explicit `off` and
  `DARKBLOOM_CBV2_MTP=0` remain independent rollback controls. Config schema
  v3 migrates the legacy generated `mtp = false` default to `auto` so upgraded
  providers receive the policy, retains legacy `true` as `on`, and preserves a
  new explicit `mtp_mode = "off"` override.
- Provider and coordinator fallback version authorities move together to
  `0.8.14`; there is no new wire protocol.

## v0.8.13

Published 2026-08-26 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.13)).

### Qwen3.5 Video and Grounded Captions (Historical Preparation)

- **Qwen 3.5 video + grounded image captions** — Qwen vision prefill no
  longer fail-closes video as `invalid media input`. The tower runs one
  video (full T×H×W grid) at a time and carves the contiguous
  `<|video_pad|>` run into per-frame spans. Image decode applies EXIF
  orientation on the full raster (not a JPEG thumbnail). Media requests
  default `enable_thinking=false` unless the client sets
  `reasoning.enabled`. Qwen decodes media once and uniformly samples at most
  8 video frames at no more than 512² pixels each, bounding its unfused
  vision score tensor to 512 MiB. Coordinator remote-media fetch is bounded
  by the leftover first-content clock minus an inference reserve, and media
  bypasses the text-only estimated-TTFT hard gate while retaining the same
  request-absolute deadline. Its incomplete estimates do not train text TTFT
  calibration or emit synthetic warm-pool pressure.
- **Current MLX-LM main pin** — `libs/mlx-swift-lm` advances to `fe01df9`,
  containing the merged Qwen prefill/decode optimization
  ([mlx-swift-lm#120](https://github.com/Layr-Labs/mlx-swift-lm/pull/120))
  and bounded video-tower input fix
  ([mlx-swift-lm#123](https://github.com/Layr-Labs/mlx-swift-lm/pull/123)),
  plus Qwen3-VL 30B-A3B support
  ([mlx-swift-lm#122](https://github.com/Layr-Labs/mlx-swift-lm/pull/122)).
- Provider and coordinator fallback version authorities move together to
  `0.8.13`; there is no new protocol.

## v0.8.12

Published 2026-08-25 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.12)).

### Release Notes

> **Post-publication status:** `v0.8.12` was tagged, published, and registered
> before the Qwen media fixes above. Those fixes therefore ship in v0.8.13.

- **Default atomic first-token deadline admission on** — Explicit typed TOML is
  authoritative: `"off"` disables and `"enforce"` enforces regardless of the
  legacy environment. An absent key inherits that environment, where only exact
  lowercase `off` disables and every other value securely enforces. Optional
  serialization preserves absence. Edit `provider.toml` and use ordinary
  `darkbloom restart` for rollback, restore, or legacy-environment inheritance;
  the linked report gives the exact settings.
- **Keep the safety envelope unchanged** — Forecasting still requires a
  propagated deadline, an initialized isolated cold-prefill EWMA, a text-only
  request, phase-specific rates, and an authoritative capacity-guaranteed
  scheduler projection. Multimodal requests remain outside forecast admission.
- **Keep cap-0 a functional serving rollback** —
  `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS=0` still restores unlimited partial
  prefill interleave. That posture cannot produce the proven bounded projection,
  so it bypasses forecast admission and uses ordinary submission while hard
  absolute expiry remains active. It does not rewrite the deadline-mode setting.
- Provider and coordinator fallback version authorities move together to
  `0.8.12`; there is no new protocol.

Release rationale, limitations, compatibility, and rollout gates:
[`docs/reports/2026-08-25-v0.8.12-prefill-deadline-admission.md`](docs/reports/2026-08-25-v0.8.12-prefill-deadline-admission.md).

## v0.8.11

Published 2026-08-25 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.11)).

### Release Notes

> **Post-publication status (2026-08-25):** `v0.8.11` was tagged, published, and
> registered as the active provider release. The candidate notes below are
> retained as the pre-publication decision record; their blocker/no-shipment
> language describes the state when they were written. The shipped resolver
> still defaulted atomic deadline admission to `off`; v0.8.12 is the activation
> change.

#### Candidate integration status

- **v0.8.11 enables FCFS partial-prefill scheduling globally** — Production
  resolves `maxConcurrentPartialPrefills` to `1` for every CBv2 model. Operators
  can immediately restore the historical unlimited interleave with
  `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS=0`; other explicit non-positive or
  malformed values also fail open to unlimited behavior.
- **Deadline conservation and atomic admission plumbing ships
  provider-default-off** — Remaining first-content budget propagation is
  additive and fail-open for older peers. The queue-excluded prefill EWMA,
  engine atomic forecast API, and provider wiring are integrated, but forecast
  enforcement remains disabled unless exact mode `enforce` is selected.
  Default-on FCFS is the separate global scheduling policy above.
- **FCFS evidence remains a release blocker** — Cap 1 can improve mean burst
  TTFT, but it can also remove Qwen packed-prefill cohorts and head-of-line-block
  short prompts. The only real-model attempt was aborted after approximately
  27 minutes at 13% battery and produced no artifact. No signed-candidate
  cap-0/cap-1 report or representative non-Qwen evidence exists yet.

#### Coordinator candidate fixes

- **Enforce one request-absolute first-content deadline** —
  Queueing, provider acceptance, boilerplate/preamble frames, speculative
  dispatch, and blocked provider writes must not reset the clock. Expiry must
  cancel in-flight work and return the existing retryable `429` contract
  without feeding provider-fault breakers unless the provider received a full
  attributable wait window.
- **Price routing from live prefill behavior** — The base request-cost
  term now uses the same measured-preferred prefill resolver as TTFT estimation,
  falling back to the static registration rate when no observation exists.

#### Provider candidate fixes

- **Default partial-prefill concurrency to one with an immediate rollback** —
  The production factory applies cap 1 globally. Exact environment override
  `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS=0` restores unlimited interleave without
  a code change.
- **Honor the coordinator's remaining first-content clock** —
  A positive wire budget becomes one provider-local monotonic deadline. The
  provider refuses expired pre-submit work and releases any partial
  admission/cache resources instead of restarting the budget at model load or
  engine submission when enforcement is enabled. Default-off and absent
  metadata paths remain fail-open; coordinator cancellation remains the
  authority after submission.
- **Add an honest FCFS evaluation harness** — The opt-in five-workload matrix
  compares caps 0 and 1, cryptographically records the selected checkpoint,
  omits local model paths, records source/binary/build/hardware/OS/power/thermal
  posture, and evaluates the documented 5% throughput and TTFT thresholds. Its
  schema distinguishes simulation, unsigned local evidence, and evidence
  captured by the signed packaged main executable. Signed Qwen evidence remains
  model-family evidence only and never sets global release certification.
- **Add a fail-closed signed-artifact FCFS command** — Run the exact packaged
  candidate with:

  ```bash
  "$SIGNED_APP/Contents/MacOS/darkbloom" benchmark \
    --scheduler-prefill-decision \
    --model "$QWEN_MODEL_ID" \
    --expected-model-aggregate-sha256 "$QWEN_MODEL_AGGREGATE_SHA256" \
    --expected-registered-binary-sha256 "$REGISTERED_DARKBLOOM_SHA256" \
    --expected-version 0.8.11 \
    --source-sha "$SOURCE_SHA" \
    --decision-iterations 10 \
    --kv-backend auto \
    --output "$QWEN_SIGNED_REPORT"
  ```

  It accepts no weights path and resolves the canonical registry ID internally.
  It exits successfully only after packaged signature, identifier/team,
  registered binary hash, version, model hash, posture, and policy checks pass.

#### Release requirements

- Pass coordinator/provider focused tests, protocol symmetry, mixed-version
  behavior, full builds, system E2E, signed artifact checks, and rollback gates
  recorded in
  `docs/reports/2026-08-24-qwen-openrouter-timeout-fix-and-release.md`.
- Do not ship the default-on FCFS policy until an externally captured
  signed-candidate artifact passes the cap-0/cap-1 criteria on representative
  Qwen hardware, plus equivalent latency/throughput/head-of-line evidence for
  every affected non-Qwen CBv2 family or a separately reviewed model-scoped
  policy. The unsigned local harness cannot satisfy this requirement.

---

The entries below are earlier shipped releases. At the time the v0.8.11
candidate notes above were recorded, the latest shipped provider was `v0.8.10`.

## v0.8.10

Published 2026-08-22 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.10)).

### Release Notes

#### Provider (Swift)

##### Fixes

- **Seed retained optimization latches before packaged-child exec** — The v0.8.9 curl installer could download and verify the signed bundle but reject it with `safe R1 was not latched as requested` on hosts where MLX initialized Metal before `runtime-smoke.run()`. Installer, self-updater, and paged preflight children now receive the exact retained three-key environment (`DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL=18`, `MLX_GEMMA4_FUSED_WEIGHTED_UNSORT=1`, `MLX_GATHER_QMM_EXPERT_SLICES=1`) at process launch, while the child still poisons/reapplies/verifies the values and AOT kernels. Existing installations remain untouched on any failed verification.

## v0.8.9

Published 2026-08-21 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.9)).

### Release Notes

#### Provider (Swift)

##### Fixes

- **Emergency Qwen3.6 runtime rollback** — Restores the v0.8.7 `mlx-swift-lm` pin (`ab73a827`) and removes v0.8.8's default-on GDN four-input projection fusion and direct weighted-expert reduction. In the fixed one-hour production comparison, Qwen success fell 85.52%→65.79%, p50 decode fell 38→26 tok/s, client timeouts approximately doubled, and the hard TTFT gate emitted 612 429s (602 marked counterfactually serveable). M1/M2 providers regressed even though they cannot use affine `qmv_wide`, isolating the Qwen runtime changes as the first rollback target. Gemma's merged `qmv_wide` MLX/MLX-Swift pins remain enabled for continued benefit and separate attribution.
- **Restore the retained runtime-smoke contract** — Removes the retired Qwen process-global reduction key from serving projection, launchd passthrough, signed-child validation, and benchmark-report expectations. Provider artifact verification returns to the three retained Gemma controls.

## v0.8.8

Published 2026-08-21 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.8)).

### Release Notes

#### Provider (Swift)

##### Performance

- **Default-on small-batch quantized matvec (`qmv_wide`)** — Ports upstream MLX #3764 (`548dd80e`) into the Darkbloom MLX fork and regenerates MLX-Swift's embedded JIT Metal sources. On generation-15+ Apple GPUs, affine BF16 W4/W8 dense projections with `2 <= M < vector_limit` reuse each decoded weight group across the small activation-row tile; M=1 remains on QMV, matrix-sized inputs remain on QMM, and gathered expert projections are unchanged. Source-built metallib and release-artifact checks require representative W4/W8 ordinary and batched symbols. Local M4 Max directional medians preserved B=1 and improved Gemma B=4 aggregate decode 195.93→216.94 tok/s at 512 context (+10.72%) and 143.18→155.72 tok/s at 8K (+8.76%); B=2 was +4.49%/−1.00%. The attempted 32K comparison is intentionally unclaimed because both benchmark arms entered a persistent degraded host/device state.

##### Default posture

- `qmv_wide` is an automatic Metal dispatcher route, not a beta flag: eligible generation-15+ affine `2 <= M < vector_limit` projections take it by default. Gemma layer-18 submission, coupled weighted-unsort/safe-R1, expert-tile trust, solo-prefill stripe, prompt narrowing, and packed-prefill defaults remain enabled for existing and new provider configurations.

## v0.8.7

Published 2026-08-20 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.7)).

### Release Notes

#### Provider (Swift)

##### Fixes

- **Restore Qwen3.5/3.6 system-history normalization** — The compatibility fix released on the `v0.8.5` branch was absent from master and therefore from `v0.8.6`, causing Qwen's published template to reject OpenAI-compatible histories with a late system turn (`System message must be at the beginning`). Production Qwen 422s rose from 3.46–4.95% on `v0.8.5` to 27.73–33.95% on `v0.8.6`. Text-only system turns are again folded into one leading system message before generic tool-history validation; structured/media system content remains fail-closed.

## v0.8.6

Published 2026-08-20 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.6)).

### Release Notes

#### Provider (Swift)

##### Performance

- **CBv2 prefill stack, default-on** — Cold prefill 6,406.8 → 4,636.9 ms at 8K on the M4 Max prod artifact (**~1,766 tok/s, +38% vs v0.8.5 defaults**); 4×8K burst aggregate 1,312 → ~1,500 tok/s (+13–17%) with token-checksum parity across every arrival pattern. Four independently escapable levers (#646, mlx-swift-lm#111):
  - *Expert-tile `trust` serving default* — skips the per-chunk descriptor retract drain (80 stream drains/chunk); exact `MLX_GATHER_QMM_EXPERT_SLICES=1` restores the drain posture. (#638)
  - *Solo-prefill stripe (2048)* — when exactly one live text request holds the scheduler, its chunk widens 512→2048 (weights streamed 4× less often, full 32-row expert tiles). Armed per-plan; any company disarms to plain 512s; KV-capacity failure shrinks once, never preempts; the stripe budget belongs exclusively to the armed row. `DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE=0` disarms. **Known trade: ~12% TTFT regression under Low Power Mode — throttled/battery providers should export the escape.**
  - *Recurrent prompt narrowing (Qwen LM head)* — intermediate chunks return a one-element handle instead of the `[1,512,248320]` logits tensor (242.5 MiB/chunk); the frontier chunk norms + projects exactly one row. `DARKBLOOM_CBV2_PREFILL_NARROWING=0` restores byte-old behavior.
  - *Packed prefill (Qwen3.6)* — equal-length prompt chunks from concurrent requests run as one `[B,L]` forward with per-row recurrent state (one weight stream per cohort; text-only v1).
- **Mean-TTFT prefill serialization** *(opt-in)* — `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS=1` caps rows receiving prompt work per step (FCFS): burst TTFTs become a staircase instead of everyone waiting for the makespan. Paused rows hold no slot (a stalled consumer cannot head-of-line block admission). (#646)
- **Adaptive persistent-history MTP promoted onto master** *(still behind the `mtp` beta flag)* — the v0.8.5-described capture-verify stack's adaptive width selection and persistent head KV now ship in the release pin. (#641, mlx-swift-lm#110)

##### Benchmarks / Tooling

- Scheduler-prefill report schema 3 (records the effective stripe posture); Gemma contbatch wrapper schema 6 — baseline pins refuse pre-default-flip reports so the posture change can never masquerade as a code delta. 14 review-hardening scheduler fixes with regression tests; measurement methodology + posture discipline in `docs/reports/2026-08-19-solo-prefill-stripe-experiment.md`. (#646)

### Adaptive Persistent-History MTP

- **Qwen3.6 MTP: adaptive persistent-history capture-verify stack** *(behind the `mtp` beta flag, default off)* - Selects one rectangular k=0...4 per scheduler plan/decode-row bucket from request-local acceptance probabilities and shared marginal-cost evidence, obtains policy confidence with a lazy hierarchical Metal top-2 reduction, and keeps complete committed context in request-owned MTP-head KV; leading trusted history now appends K/V only, so each round computes full head output only for its final row. Target verification remains one `[B,1+k]` forward with target-prefix-authoritative acceptance at any temperature. Widths 1/2 use captured recurrent state; S>=3 runs one full-window recurrence, commits the final state directly on full acceptance, and retains compact transformed inputs for lazy strict-prefix replay instead of full per-position recurrent stacks. Request-owned head/history and recurrent replay residency are charged exactly by admission. A combined production-bundle **DEBUG canary validation** on this M4 Max measured median target 7.657386s vs MTP 3.813989s (**2.0077x**); this is validation evidence, not release throughput. (#616, mlx-swift-lm#106/#108/#110)

## v0.8.5

Published 2026-08-15 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.5)).

### Release Notes

#### Provider (Swift)

##### Performance

- **Qwen3.6 E=256 expert-tile prefill route + fused gate_up** - Instantiates the Gemma4 descriptor/tile kernel family for Qwen's 256-expert shapes (mlx `d3c82db`), fuses the routed gate/up projection into one gather (`SwitchGLU(fuseGateUp: true)`, per-layer and per-load with heterogeneous-quantization split fallback across every checkpoint key space), and adds the opt-in `trust` refinement that skips the per-chunk retract drain. Measured on M4 Max, prod artifact: routed MoE block -26.3% at T=512; end-to-end prefill 1243→1364 tok/s default, 1433 with `trust` (+15.2%) at 8k; 2k +7.4%, 32k +6.6%. (#617, mlx-swift-lm#107)
- **mlx gpu::eval use-after-free fix** - A stale `MTL::CommandBuffer` captured across `eval_gpu` could crash any primitive that syncs mid-eval (deterministic SIGSEGV on the E=256 route; previously survived on allocator luck). (mlx#5/#7)

##### Fixes

- **Inline-MTP inspection resolves HF-cache symlinks and rejects loudly** - Symlinked snapshots (the standard HF `blobs/` layout) silently disabled inline MTP: `inspectInlineArtifact` required regular files and reported nothing. Inspection now resolves links and validates targets; every genuine rejection logs a concrete reason and path. Untrusted operator-path inspection stays symlink-rejecting. (#618)

##### Observability

- **MTP posture and acceptance on the local `/metrics` endpoint** - `mtp_enabled`, `mtp_active`, `mtp_rounds_total`, `mtp_tokens_proposed_total`, `mtp_tokens_accepted_total`, and `mtp_inactive_reason{model,reason}` (including `inline_artifact_invalid`) in both `--local` and unified serving modes - acceptance was previously observable only in Datadog Logs. (#619)

#### Coordinator

##### Fixes

- **Expose exact Hugging Face repositories in model feeds** - Registry metadata can now override `hugging_face_id` independently of the internal routing ID. Both `/v1/models` and `/v1/models/openrouter` honor the override for concrete and aliased models, with an authenticated `hugging-face-id` admin action for existing registry rows. (#620)

---

### Provider Privacy Fixes

- **Keep inline video plaintext off disk** — The provider decodes coordinator-inlined MP4/QuickTime bytes through a bounded, memory-backed AVFoundation asset, retains the byte owner through metadata probing and frame sampling, and rejects external asset references. Exact-name legacy `vlm-<UUID>.mp4` files are purged once after single-instance lock acquisition on both coordinator-connected and standalone launch paths.

- **Close unintended provider-derived plaintext egress paths** — Provider inference failures cross the WebSocket and client boundary only as closed-vocabulary codes/reasons, while browser/provider free-form telemetry and automatic provider log reporting are retired. The explicit `darkbloom report` support command remains operator-initiated, preserves macOS unified-log privacy redaction, supports local `--dry-run` review, and uses authenticated upload plus admin-only retrieval.

## v0.8.4

Published 2026-08-13 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.4)).

### Release Notes

#### Provider (Swift)

##### Fixes

- **Stream Qwen3.6 reasoning deltas immediately (TTFT fix)** - Qwen3.6-style chat templates pre-open the `<think>` block at the prompt tail, so model output carries only the closing tag and the streaming think parser buffered the entire block before emitting anything: measured prod TTFT was `755ms + 12.51ms x reasoning_tokens` (r = 0.9878) while the first byte arrived in ~76ms. The engine now probes the rendered prompt tail (`ReasoningPromptProbe`) and injects one synthetic `<think>` open ahead of model output — gated on an active think-format parser and streaming — so `reasoning_content` streams per chunk and TTFT reflects real first-token latency. Text and VLM paths; the marker never reaches the prompt, the consumer, or the TB-007 hash domain. (#614)

---

## v0.8.3

Published 2026-08-13 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.3)).

### Release Notes

#### Provider (Swift)

##### Features

- **Qwen3.6-35B-A3B VLM with inline MTP** - Adds production-path text, image, and tool inference for the combined Qwen artifact. The runtime preserves request-owned recurrent and three-axis mRoPE state, causal vision attention, exact rollback, and source-matched target/assistant memory accounting. MTP remains depth-one, serial, and exact-target-verified; video, prefix reuse, paged KV, compiled decode, packed prefill, and rectangular MTP remain fail-closed.

##### Release Safety

- The model is registered as beta/ready without an alias or active-version promotion. Provider rollout and model promotion remain separate reviewed operations after the signed `v0.8.3` bundle passes a controlled fleet canary.

---

## v0.8.2

Published 2026-08-12 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.2)).

### Release Notes

#### Provider (Swift)

##### Performance

- **Gemma 4 26B-A4B v0.8.2 optimization stack** — Layer-18 lazy prefill submission; coupled weighted-expert-unsort + safe-R1 expert-QMM gate (both default-on via `[gemma_optimizations]`); the VLM wrapper's directly shared text tower; packed multimodal prefill inside q=128 query blocks; source-matched metallib enforced across CI/release/packaged smoke. Final performance and retention deltas are pending a same-tree A/B measurement on the reviewed release tree. Earlier gitignored measurements predated the final kernel edits and are not release evidence. Dropped before the final cut: expert gate/up packing, dense gate/up packing, standalone weighted-unsort, standalone R1. `0cc5fc9c9`


---

## v0.5.0

Published 2026-05-25 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.5.0)).

### Apr 26 - May 25, 2026 development snapshot

The cited development commits first enter the stable `v0.5.0` tag. This
snapshot is not a final-artifact specification: `serve` was not a shipped
Swift subcommand, `BatchedEngine` superseded `BatchGenerator`, and the
production hard-fail-on-Swift-tests setting was removed before this tag.

26 commits since `aa74499`.

#### Coordinator

##### Features

- **DB-backed model registry** (#203) -- Model catalog is now stored in Postgres with R2-hosted manifests. Includes readable prefixes, runtime limits, runtime parameters, hardened validation, and provider inventory preservation across catalog updates. `50e8887b`
- **Token-budget routing with engine-level admission** (#171) -- Replaces heuristic-based routing with engine-reported capacity signals. Providers report real `activeTokens`, `maxTokensPotential`, and token budget usage. Coordinator uses EWMA observed TPS, fleet median fallback, and token-budget admission. 5 new fields on `BackendSlotCapacity` (backward-compatible). 25+ new tests. `78314b4e`
- **Speculative TTFT dispatch** (#171) -- Parallel dispatch to a backup provider at 50% of the TTFT deadline. First provider to deliver a token wins; loser is cancelled. No double-billing. OpenRouter TTFT SLA enforcement (5s base + 1ms/input token). `78314b4e`
- **Early 429 with Retry-After for capacity signaling** (#171) -- Returns 429 instead of 503 when fleet is at capacity (no uptime penalty on OpenRouter). `GET /v1/models/capacity` endpoint for observability. `ModelCapacitySnapshot` with per-model routable/warm/cold providers, aggregate TPS, estimated TTFT, and token budget headroom. `78314b4e`
- **Coordinator-driven model preload protocol** (#110) -- New `load_model` / `load_model_status` WebSocket messages allow the coordinator to push model warm-up requests to providers ahead of demand. `56b050b4`
- **Datadog observability stack** (#143) -- DogStatsD, APM, journald log collection on dev GCE VM. Structured metrics: attestation counters, model_type tags, provider-count gauges, completion-tokens counter, fleet version/binary hash observability, billing histograms (reservation, settlement, provider credits, platform fees), store latency, input token metrics. `56b050b4`
- **X-Timing latency decomposition header** (#136) -- Single JSON header with per-phase microsecond breakdown: `parse_us`, `reserve_us`, `route_us`, `queue_us`, `encrypt_us`, `dispatch_us`, `provider_us`. `56b050b4`

##### Bug Fixes

- **Structured JSON 404 for unimplemented /v1/* endpoints** (#168) -- Catch-all handler returns `application/json` errors instead of Go's default `text/plain` 404. Prevents OpenAI SDK parse failures on `/v1/embeddings`, `/v1/moderations`, etc. Added openai-go SDK compatibility tests. `e108da5f`
- **OpenAI error response `code` and `param` fields** (#144) -- `errorResponse` now populates `code` and `param` per the OpenAI API spec. `insufficient_quota` canonical code, `param="model"` on model errors. All 202 existing call sites backward-compatible. `e108da5f`
- **Require country for Stripe payout onboarding** (#179) -- `2e262b73`
- **Stripe dashboard metadata** -- `35582c82`
- **Prevent double-decrement on untrusted provider disconnect** (#143) -- `MarkUntrusted` race fix: hold write lock through counter decrement. Heartbeat no longer revives untrusted providers. `56b050b4`
- **Skip Python/dangerous-modules check for Swift runtime** (#143) -- Private text routing gate correctly bypasses Python-specific checks for Swift providers. `56b050b4`
- **Fix planner pending leak** (#171) -- Changed `planner.complete()` to `planner.cancel()` in request completion path. Without this, pending entries accumulated until `maxQueuedRequests` (128), permanently bricking the provider. `78314b4e`
- **Refund provider-specific extra on generic dispatch** (#171) -- All 14 failure paths after `reserveAdditionalForProvider` now refund the delta in `handleGenericInference`. `78314b4e`
- **activeRequests counted per-model, not per-provider** (#171) -- `ModelCapacitySnapshot` now counts only pending requests matching the specific model. `78314b4e`
- **Link test providers to user account** (#174) -- Ensures payout destination check passes for test providers. `f4219c4f`

##### Breaking / Protocol Changes

- **Go module path changed** -- `github.com/eigeninference/coordinator/internal/X` -> `github.com/eigeninference/d-inference/coordinator/X`. Module path is now `github.com/eigeninference/d-inference`. `coordinator/internal/` flattened to `coordinator/`. `56b050b4`
- **Bundle filename changed** -- Coordinator now accepts `darkbloom-bundle-<platform>.tar.gz` (was `eigeninference-bundle-`). `56b050b4`

---

#### Provider (Swift)

##### Features

- **Swift provider runtime shipped** (#110) -- Full `darkbloom` CLI with `serve`, `start`, `stop`, `status`, `doctor`, `models`, `benchmark`, `login`, `logout`, `enroll`, `update`, `verify` subcommands. Production inference via MLX-Swift on Apple Silicon. GPU-only enforcement. Rename from `eigeninference` to `darkbloom` with backward compatibility. `56b050b4`
- **Continuous batching** (#110) -- All concurrent requests merged into one batched forward pass per step via `BatchGenerator`. Bit-identical against single-stream greedy. Near-linear throughput scaling (B=4/B=1 = 3.8x on Qwen, 2.9x on Gemma MoE). `56b050b4`
- **Multi-model concurrent serving** (#167) -- `953b8f02`
- **MLXLMServer adoption for OpenAI protocol** (#208) -- `ca8983c4`
- **BatchedEngine migration** (#207) -- `BatchScheduler` migrated from `BatchGenerator` to `BatchedEngine`. `80fc0ee7`
- **Idle-timeout model unload** (#110) -- Provider unloads model after 60 minutes idle (configurable). Next request lazy-reloads. `56b050b4`
- **Persistent Secure Enclave key** (#146) -- Replaces ephemeral CryptoKit SE keys with persistent Security framework keys in the macOS data protection keychain. Bound to signing team's keychain access group. .app bundle with embedded provisioning profile. `56b050b4`
- **Token budget engine-level admission** (#171) -- `BatchScheduler` reports real token budget usage. EWMA decode TPS tracker. Engine-level admission gate rejects with `token_budget_exhausted`. Dynamic token budget sized from model weight bytes and available memory. `78314b4e`
- **Architecture-aware kvBytesPerToken** (#171) -- Computed from config.json metadata (layer count, KV heads, head dim) instead of weight-bytes heuristic. Handles hybrid attention (Gemma 4), GQA/MQA, recurrent layers (Qwen3.5), and VLM wrappers. 4x reduction on Qwen3.5 models. `78314b4e`
- **Rust-to-Swift bridge auto-update** (#110) -- Rust provider auto-updates to Swift bundles, rewrites launchd plist, handles .app bundle layout. `56b050b4`

##### Performance

- Greedy fast-path optimization: `nil` sampler for temperature=0 uses vectorized fallback (+6-13% decode TPS). `56b050b4`
- mlx-swift-lm double buffering, UInt32 token tensors. `56b050b4`
- Release-mode BatchGenerator B=4 matches mlx_lm Python reference (Qwen: ~1130 vs 1119 tok/s; Gemma: ~186 vs 181 tok/s). `56b050b4`

---

#### Console UI

- **Refresh earn calculator and landing page** (#185) -- `ed6d655e`
- **Fix Next.js version vulnerability** (#172) -- `2f65bb41`
- **Analytics tracking fix** -- `f7dab6fa`

---

#### Testbed / E2E

- **Integration test suite** (#136) -- 12 E2E tests with real Swift provider (Postgres + coordinator + provider per test). Tests: NonStreaming, Streaming, Concurrent, Encryption, Billing, Payout, Referral, InsufficientBalance, InvalidModel, AttestationHeaders. `56b050b4`
- **Load generator and profiling** (#136) -- Configurable concurrency, streaming, benchmark CI with PR comment posting. Heavy-load 100-concurrent 10KB benchmark. Latency regression assertions. `56b050b4`
- **Performance test suite** (#110) -- Warm/cold TTFT, encrypted E2E, batched throughput, decode-TPS bracket tests for Qwen 0.6B and Gemma 26B MoE. `56b050b4`

---

#### Security

- **Harden release registration and binary hash policy** (#99) -- Release download URL derived from allowlist. `b5dd0488`
- **Harden release workflow protections** (#103) -- `e515244f`
- **Rust-to-Swift cutover hardening** (#110) -- Post-codesign verification of entitlements, provisioning profile validation (team ID, access group, expiration), MLX wheel pinning, prod hard-fail on Swift tests. `56b050b4`
- **STRIDE threat model** (#110) -- 40 threats across 9 trust boundaries. Automated PR review workflow via Claude API. `56b050b4`
- **Typed response structs for OpenAI endpoints** (#166) -- `7fbfa9fc`

---

#### Billing

- **Remove deprecated Solana/wallet-based provider payouts** (#178) -- `fe994fc9`

---

#### CI / Infrastructure

- **Migrate CI workflows to Blacksmith** (#182) -- `ff8527a4`
- **CI runs on any PR** (#119) -- Not just master/main. `98a3a024`
- **Remove racing deploy-dev-coordinator workflow** (#137) -- Eliminates race condition with Cloud Build. `cf4c0efa`
- **DEV_/PROD_ prefixed repo secrets** -- Environment-scoped R2 + coordinator secrets for release isolation. `56b050b4`
- **Native Postgres fallback for CI** -- Docker/colima replaced with `initdb + postgres` on macOS runners. `56b050b4`
- **Correct version comments for SHA-pinned actions** (#160) -- `85cedc7e`

---

#### Housekeeping

- **Remove unused dependencies** (#112) -- `7ccc592f`
- **Remove stale Python integration test** (#109) -- `e6d63a86`
- **Bump mlx-swift and mlx-swift-lm submodules** (#206) -- Re-homed to Layr-Labs forks. `5919dac1`
- **Darkbloom license agreement** (#173) -- `dde67b28`
- **Update README** (#176) -- `7451a473`
