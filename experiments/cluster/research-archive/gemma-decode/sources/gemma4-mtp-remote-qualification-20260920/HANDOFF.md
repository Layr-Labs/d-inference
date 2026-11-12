# Tiny actual-JACCL pull qualification

Source only. No compiler, CPU fixture, GPU/model, deployment or SSH execution by the author. One closed `--qualify-remote-mtp REMOTE_JOB` branch in the existing GemmaResidentBenchmark entry; no Package or default model dispatch change. Requires explicit target48/rank1 and assistant24/rank0, the existing remote input with P128/C64/O16/depth2 metadata, capturefalse and actual JACCL. No target or assistant weights are loaded; this uses synthetic integer-valued BF16 snapshot roots and two native Int32 token scalars, not a simulated Gemma forward.

Five concrete cases:
1. Actual seven snapshot transfers at frontier3, exact receiver content checks, queued ACK before one C asynchronous GPU submission, actual GPU/CPU status fences, later pull of41/42, and finish only after roots retire.
2. Frontier1031 exercises full-head concatenation and the full1024 sliding extent; queued work is canceled before pull. The receiver still completes/fences both scalars and drops roots before its exact canceled response. The five-slot/depth-two scalar ledger is unchanged.
3. Seven actual receives followed by one precisely typed injected post-receive check exception. All nine receive/concat roots remain in retained staging through the catch and actual fence. The sender remains rooted until a separate fixture-only fault-observed checkpoint. This is not an injected GPU, socket or driver failure and does not claim that qualification.
4. Actual fixed16KiB frame with stale sequence must hit the exact channel scope/order error. Reuse of that poisoned channel must refuse before a new receive.
5. Actual fixed16KiB frame with nonzero padding must hit the exact codec padding error, followed by the same poisoned-channel refusal.

Fixture-only observation barriers use existing strict fixed16KiB framing and the same original Collective; no second socket or owner. Every case retains the original group and actual roots. A single bounded terminal failure slot retains failed fixture roots until the original process ends; normal success fences/releases all roots. It permits no retry or production channel reuse. The original300-second entry alarm, continuously draining315-second physical parent, canonical inherited-FD gate and process/journal/alias cleanup remain unchanged. Inner fixture lifetime55s begins after JACCL construction. Actual fresh outer checks and fresh native/OS checks remain each invocation, with6GiB floor+4GiB headroom+128MiB native+2MiB host and2GiB allocator headroom. Individually rounded sender/receiver terms plus retained snapshot/comparison allowance must fit128MiB; no unbounded allocations or serving floor changes.

Root source check/composition, after all other work is retired:
```
python3 compose.py
python3 compose.py --output FRESH_COMPOSITION --apply
python3 ../gemma4-mtp-remote-integration-20260920/BuildV2/run.py --sources FRESH_COMPOSITION/sources.json --output FRESH_BUILD
```
This applies exactly four Runtime additions and the reversible Entry selector to the actual108-file diagnostics predecessor, producing112 exact source records. Frozen predecessors and failed receipts remain untouched. The native build's actual binary/resource hashes are late bindings. The separate qualifier physical harness accepts only this exact flag/result contract and source union; it cannot use the real remote cohort operation.

Result schema `gemma4_remote_mtp_pull_qualification_v1` reports the five exact group labels, three snapshot frontiers,21 completed snapshot transfers, two queued acknowledgements, one completed pull and two canceled/unpulled proposals. It leaves model forward, real assistant proposals, throughput, numerical comparison, encryption, public serving and physical process retirement false. Physical retirement is established only by the retained external evidence join.
