# Prospective read-only phase sidecar retrieval

This private helper retrieves one sidecar after a successful
`remote_qwen_long_prefill_solo_phase_launcher` run. The completed launcher receipt
must be supplied with its explicit SHA256. Its archived launcher files, native
stdout/stderr/configuration, and source/bundle manifest hashes are checked before
and after retrieval. This is a narrow follow-up to the completed launcher; it
does not repeat the model payload, full source, resource, or numerical audits.

The only remote path read is the receipt's exact owned
`remote_paths.native + '/phase-trace.json'` on its admitted SSH host alias. The
fixed Python payload opens every directory and the leaf with `O_NOFOLLOW`, then
requires a regular, single-link file owned by the reader, exact mode0600, and
1..524288 bytes. It checks descriptor identity/size/modification metadata before
and after its bounded read. No file is created, replaced, removed, or explicitly
modified remotely. Ordinary reads may update filesystem access timestamps.

SSH stdout is capped at 528385 bytes (4096-byte metadata line, newline, raw
sidecar); stderr is capped at 16384 bytes and must be empty for success. The
local SSH call has a 20-second deadline and a separate at-most 2-second cleanup
wait. Failure kills only that newly owned local SSH process group. Primary
failure and cleanup errors stay separate. The helper reports local SSH client
reaping; it does not assert remote waitpid, remote interpreter retirement, or
native process reaping. It never starts a model/native worker or reruns inference.

The fresh output directory contains exact `phase-trace.json` bytes,
`ssh.stdout.bin`, `ssh.stderr.log`, the exact fixed `remote-reader.py` payload,
and `receipt.json`. Existing output paths are refused. A failed attempt retains
its partial local evidence and failure receipt. A copied sidecar is qualified
only when that receipt passes; later admission failure can leave the already
copied bytes beside a failed receipt.

The trace's recorded-request fingerprint, profile, and `solo` role must match
the pinned ready/final native records. It must carry the production local clock
and diagnostic flags. Event sequence meaning, phase intervals, model quality,
numerical equivalence, physical transfer, GPU overlap, and throughput are not
audited here. Those remain separate analysis.

Root executes after reviewing the frozen source and completed receipt:

```sh
python3 retrieve_phase_sidecar.py \
  --run /absolute/completed/run \
  --launcher-receipt-sha256 EXPLICIT_COMPLETED_RECEIPT_SHA256 \
  --output /absolute/new/retrieval
```

The prospective suite uses fabricated archives, fake process/selectors, and
owned temporary regular files. Actual subprocess/socket creation is blocked.
Its remote-reader file tests execute the pure reader in the local interpreter;
there is no SSH or native candidate access. Python3.9 syntax is checked with
`ast.parse(feature_version=(3,9))`. The manifest records the exact tested source
and separate frozen launcher/phase schema dependencies. No actual retrieval was
executed by the author before this source freeze.
