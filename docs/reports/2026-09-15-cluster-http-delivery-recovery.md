# Installed distributed HTTP cancellation and recovery

> Last updated: 2026-09-15 · commit `605651bb9`

The new development build cancels an actual two-Mac Qwen9B request when its
client disconnects during prefill. Both workers disappear and ownership journals
are empty 1.58 seconds after the close. After-content cancellation and a fresh
normal 128-token response also pass. Sustained serving and release qualification
remain open.

## Build and installed configuration

Both the 24 GB and 48 GB M4 Pro Macs use
`installed-distributed-http-delivery-runtime-20260915`. The Provider debug binary
is `c4083695c07ed7da819284e48de3aeb8786940b43271fa6e974b469c26f10350`;
the unchanged native Release worker is
`ffcbd7de0ccc5a8b35881f9dd5ed5b6fcb8a2f5bdc7e7b63fa1e46bd9c79bba5`.
The actual private Provider build passes 149 tests in 24 suites, including 26
new HTTP lifecycle tests. Its 21 changed files were promoted exactly, with
seven pre-change backups; all 13,730 entries in its source inventory match the
resulting working tree. The commit stamp alone does not identify these
uncommitted changes.

The package contains ten pinned runtime/resource files. Both installations
verify their file hashes, owner command and native capability description.
Actual `cluster configure` saves the new leader and follower references, and
stopped `cluster status --json` and `cluster doctor --json` pass on both hosts.
These stopped checks do not claim native readiness.

The selected model remains registered Qwen3.5 9B 4-bit, layers 0–3 on the leader
and 4–31 on the follower, 512-token chunks, one-chunk lookahead, greedy decoding,
thinking disabled and MTP off. The cluster ID is
`darkbloom-product-qwen9b-http-delivery-20260915`; canonical configuration hashes
are `d787ce64ed4249048c195ab02cedefcda50558fe69b7d7063e08c33f373da588`
and `2228dec1f648ca8aa973eb3adde9d08d97dd11ed8a2e182c2f740285a5fc0144`.

## Actual disconnect observations

Each row starts a fresh installed session. The external development Mac sends
authenticated HTTP over Tailscale; native inference uses the Thunderbolt RDMA
link. The 8K prompt's complete prepared token sequence matches the actual Swift
tokenizer before the timed request.

| Case | Client close from request send | Provider terminal / retired from its own request origin | Cleanup observed after client close |
|---|---:|---|---:|
| 8,192 tokens, before content | 0.519825 s | `cancelled` at 1.288030 / 1.391215 s | 1.578006 s |
| 42 tokens, after two nonempty fragments | 3.498980 s | `cancelled` at 3.518527 / 3.636955 s | 1.580239 s |

The before-content request has zero committed output tokens and more than
16 seconds of first-token budget remaining at terminal. It therefore exercises
prompt cancellation, unlike the previous installed build's `prefill_stall`
cleanup at about 18.9 seconds after close. The historical failure remains in the
[preceding disconnect report](2026-09-15-cluster-installed-diagnostics-disconnect.md).

Neither new case uses a parent stop or forced kill. Both actual CLI processes
exit with runtime status 1; postflight finds no native workers and empty device
journals on both hosts, and the temporary Thunderbolt alias is restored.
Retirement evidence combines the Provider's actual retired event with process
and journal observations; separate per-rank ACK transcripts are not retained.
Expected Hummingbird shutdown diagnostics remain in stderr.

The after-content client receives its first fragment at 3.408023 seconds and
closes after the second. The server reports four committed tokens. Fragments
are not token counts, and these observations do not independently measure
tokens generated after cancellation. Client and Provider elapsed times use
their own origins; they are not subtracted across machines.

## Fresh normal response

After those two controlled disconnect sessions, a third session serves a normal
42-token prompt with 128 requested outputs. The external first-content time is
0.370661667 seconds against a 10.042-second deadline; total client time is
4.224234917 seconds. Reported output is 128 tokens with `length` finish, terminal
usage, DONE and actual body EOF. This is an individual development observation,
not a representative performance result or a speedup comparison.

Actual CLI status before and after the request reports ranks 0 and 1 ready,
membership epoch `9a57ed01-a88b-4e3a-841c-fe5e6459532c`, distinct observation
nonces and remaining admissions decreasing from 16 to 15. Status checks are
outside client timing. The enclosing session stops normally with exit 0 and
no forced kill; both workers are absent, journals empty and the alias restored.
This establishes fresh-session recovery after the sequence, not automatic
in-place recovery or session rotation.

## Resources and evidence

All samples pass the unchanged AC, zero-swap, normal-pressure and six-GiB
actual-free-memory guards.

| Procedure | Samples, leader / follower | Minimum actual free GiB, leader / follower |
|---|---:|---:|
| Before-content disconnect | 44 / 41 | 6.861420 / 27.256729 |
| After-content disconnect | 51 / 47 | 6.740463 / 26.851669 |
| Fresh normal response | 51 / 48 | 6.819748 / 26.789841 |

Raw evidence is under `/Users/developer/DarkbloomDev/cluster-research/`:

- `distributed-http-terminal-delivery-tested-handoff` and
  `distributed-http-terminal-delivery-main-integration-20260915` retain the
  passing build, promotion and full source-equality association.
- `installed-distributed-http-delivery-{product-bundle,deployment,configuration,operator-checks}-20260915`
  retain packaging, both installations and actual operator checks.
- `installed-http-cancellation-http-delivery-20260915/harness/physical-1` and
  `physical-2` retain raw disconnect streams, Provider lifecycle observations,
  causal reviews and 23/21 exact source inputs.
- `installed-product-http-delivery-qualification-20260915/physical-1` retains
  the normal response, before/after status, resource observations and 22 exact
  source inputs.

Local TCP tests separately pass full-close detection, continued reading after
a write-half-close and typed terminal delivery with a fabricated inference owner.
Actual connected deadline-error delivery remains a separate check. Cold 8K
TTFT, broader peer failures, automatic session replacement, coordinator capacity,
MTP generation and larger models remain in the
[execution plan](../design/distributed-cluster-execution-plan.md). No release or
OpenRouter qualification is established here.
