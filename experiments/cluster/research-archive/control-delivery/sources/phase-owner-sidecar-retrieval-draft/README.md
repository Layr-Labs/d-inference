# Bounded solo-owner sidecar retrieval

This private helper reads the two sidecars from a completed, passed
`remote_qwen_long_prefill_solo_owner_launcher` run. Root owns actual SSH use.
The helper's author has used source files and fabricated CPU fixtures only.
Native execution began during preparation; no candidate stdout or sidecar was
read before the source freeze. A failed parent remains ineligible, even if its
native process returned success. In particular, source-drift failures have no
exception.

```sh
python3 retrieve_owner_sidecars.py \
  --run /absolute/completed/run \
  --launcher-receipt-sha256 EXPLICIT_COMPLETED_RECEIPT_SHA256 \
  --output /absolute/new/retrieval-directory
```

The output directory must be new. All new evidence files use exclusive creation
and mode0600. Successful output retains `phase/phase-trace.json` and
`owner/owner-trace.json`, their exact SSH framing bytes, each fixed remote payload,
and `receipt.json`. Both reads must pass for the pair receipt to pass. A failure
stops subsequent reads and preserves prior or partial evidence. Primary failure
and SSH cleanup errors remain separate and identify the affected sidecar.

Admission checks the explicit launcher receipt pin, passed owner namespace and
both requested flags, original local SSH client completion/reaping, exact three
native archive pins, empty solo stderr, and two successful ready/report records.
It reconstructs the exact configuration, including the fixed8192/512/output1
workload, raw-prompt pin, environment,300-second native bound and separate fixed
`@rank/phase-trace.json` and `@rank/owner-trace.json` paths. It binds the existing
source/bundle manifest hashes and archived launcher file hashes, including the
two frozen owner runtime files. This is a narrow controlling-evidence check,
not a repeated full model, source, process or resource audit. The underlying
passed launcher and separate numerical audit retain their own scope.

The phase payload, `sidecar_ssh.py` and `sidecar_files.py` are byte-identical to
the frozen solo-phase reader. The separate owner payload changes only the
admitted filename and its error text. Its metadata intentionally retains
`qwen_prefill_phase_sidecar_read`; this labels the inherited descriptor-reader
schema, while the exact path and trace kind distinguish the owner file. The
no-follow directory traversal, regular-file/owner/mode0600/link-count checks,
stable fstat signature and512KiB read cap are unchanged. No remote writes,
renames or deletions are performed; reads may affect filesystem access times.

Each SSH read has its own20-second cap and at most2-second local cleanup wait.
Only that read's local SSH process group is terminated on failure. Original
launcher and new reader client PIDs are distinguished. The helper makes no
remote waitpid or native-process reaping claim, and performs no process scan.

Both traces must bind the completed full recorded-request fingerprint,
`long_prefill_8k_v1`, solo role and production DispatchTime clock. The owner
identity additionally binds frame7, offset3584, count512 and frontier4096. Its
separate kind, exact schema/qualification flags, maximumEvents8 and exactly
eight entries are checked. Event values, ordering, elapsed-time arithmetic,
phase containment, numerical values and power are not audited. The phase
response checks retain the previous bounded-envelope scope. The separate
arithmetic auditor is required for semantic qualification.

Sixteen prospective fake/CPU tests cover exact configuration and namespace,
failed-parent rejection, correlation/types/count bounds, crossed files,
paired failures, local post-read drift, exclusive paths, the owner leaf check,
and exact shared-source/leaf-only-delta preservation. All actual subprocess and
socket creation was blocked. The unchanged shared reader/SSH mechanics also
retain their historical23-test receipt; that earlier suite was not rerun here.
No public launcher, native performance, event-semantic or remote execution proof
is produced by these tests.
