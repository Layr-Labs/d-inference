# Read-only retrieval of two rank-phase sidecars

Private prospective helper, 2026-09-14. Root executes actual SSH. This accepts
only a completed `remote_qwen_long_prefill_rank_phase_launcher` receipt with an
explicit SHA256. It never reruns inference or changes the remote files.

Before either read, admission binds the epoch, ordered rank directories, both
successful/reaped local launcher SSH clients, exact rank configurations, ten
saved rank files, the two-record native namespaces, exact source-bound stderr,
shared v4 agreement, full recorded-request fingerprint, and stage/source fields.
The source/bundle manifest hashes and archived launcher files are retained pins;
this does not replay all source, bundle payload, model, resource, or numerical
audits. The original launcher remains the authority for those completed checks.

The rank0 and rank1 files are read sequentially from their exact owned
`rank_directories[rank] + '/phase-trace.json'`. The shared remote reader,
bounded SSH supervisor, and local byte IO are copied byte-for-byte from the
frozen solo reader. The response decoder body is extracted unchanged: its
caller supplies the rank-specific remote path and expected `rank0`/`rank1`
identity. The old solo namespace is not extended or weakened.

Each remote read permits a regular single-link mode0600 file owned by the
reader, with no-follow directory/file opens and stable descriptor metadata,
bounded to 512KiB. SSH retains its 20-second per-read deadline, 512KiB plus4097-byte
stdout cap, 16KiB stderr cap, and at-most 2-second local cleanup wait. Success
requires empty SSH stderr. Thus two successful reads have two separate bounded
calls; no cross-process clock comparison is performed. Local reader SSH client
reaping does not prove remote waitpid or native process retirement. Files are
not explicitly modified remotely; ordinary reads may update access timestamps.

Both sidecars must pass for the overall receipt to pass. A failure stops the
remaining reads, preserves any earlier exact copy, and retains separate primary
and cleanup errors. The local controlling evidence is checked again after each
read. Partial output is never silently upgraded to a successful pair.

```sh
python3 retrieve_rank_sidecars.py \
  --run /absolute/completed/rank-phase-run \
  --launcher-receipt-sha256 EXPLICIT_COMPLETED_RECEIPT_SHA256 \
  --output /absolute/new/pair-retrieval
```

The fresh output contains `rank-0/phase-trace.json` and
`rank-1/phase-trace.json` as exact mode0600 bytes, per-rank SSH output/error
captures, the exact `remote-reader.py` payload, and `receipt.json`. No existing
output is overwritten. Pair admission does not analyze event sequences, clocks,
phase intervals, native numerical values, throughput, GPU overlap, or physical
transfer; the frozen phase and numerical oracles remain separate.

The 15 new CPU/fake tests cover both policies, rank/epoch/role/request agreement,
configuration/source/output pins, exact warnings, both client completion,
swapped paths, partial retrieval, failure/error retention, and post-read local
mutation. Process/socket calls are blocked. The shared transport/file sources
retain their separately completed 23-test solo-helper evidence; these are not
claimed as 23 newly rerun tests. Python3.9 syntax checks cover all local Python
files. No actual rank output or phase sidecar was accessed by the author before
this source freeze, although root's native execution had already completed.
