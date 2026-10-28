# Root-only 27B collection and numerical comparison

This small private handoff keeps comparator `d072d1e0…72f2`, parent `86998a7a…e534` and prospective agreement `6578cc8c…d634` unchanged. It creates no owner, supervisor, native generation path or numerical policy. Root alone runs remote commands after the candidate's deployment, resource and successful-reference gates.

The successful reference is already collected at `qwen27b-full-generation-reference-physical-20260915/run-4/returned/native/worker-0.stdout`, SHA `65c39fab8ae0fd2dfe8b1a3839d299ab297a103affca7c6e5f45d6d72c53a36e` (2,611,491 bytes). Do not rerun the old collector into its existing output directory. `reference-precheck.json` records the frozen comparator's successful source/request/length/frontier/final-row/state checks after root authorized this one reference read: 128 IDs, 129 frames, frontier159, 496,640 reconstructed BF16 bytes and 144 state entries. No actual candidate has been read by this task.

`commands.json` gives exact argv arrays. From the current directory, after the fixed parent has actually completed and root has reviewed its lifecycle/resource evidence:

```sh
/usr/bin/python3 -B collect_sidecars.py --output-directory /Users/developer/DarkbloomDev/cluster-research/qwen27b-owner-jsonl-rerun-20260915/physical-1/sidecars
```

Use the printed collection SHA256, then:

```sh
/usr/bin/python3 -B prepare_packet.py --collection /Users/developer/DarkbloomDev/cluster-research/qwen27b-owner-jsonl-rerun-20260915/physical-1/sidecars/collection.json --collection-sha256 COLLECTION_SHA256_PRINTED_BY_COLLECTOR --output /Users/developer/DarkbloomDev/cluster-research/qwen27b-owner-jsonl-rerun-20260915/physical-1/comparison-packet.json
/usr/bin/python3 -B /Users/developer/DarkbloomDev/cluster-research/registered-generation-numerical-audit-draft-20260915/audit_generation.py --packet /Users/developer/DarkbloomDev/cluster-research/qwen27b-owner-jsonl-rerun-20260915/physical-1/comparison-packet.json --packet-sha256 PACKET_SHA256_PRINTED_BY_PREPARER --output /Users/developer/DarkbloomDev/cluster-research/qwen27b-owner-jsonl-rerun-20260915/physical-1/comparison.json
```

The two capitalized SHA placeholders are the only values unavailable prospectively. Every output is fresh and exclusive. Alternatively, `prepare_packet.py` accepts explicit `--rank0-evidence/--rank0-sha256` and `--rank1-evidence/--rank1-sha256` together; the reference, request, prompt, Plan and expected agreement remain pinned. It assembles exactly the existing six roles and makes no numerical success claim. The frozen comparator writes the actual comparison result, including a failed result when validation fails.

The request remains UUID `20801ced-ca29-4faf-b71a-9ebbe1886a14`, epoch `1c7b2bc6-744b-41c1-b621-ddef0e9eb31e`, registered27B P32/C16/O128/cut32, serial/MTP-off/empty stops. Source request `d81435fa…7401`, Plan metadata `d1828272…b9d4` and raw prompt `6d4c8898…e81e` are exact parent copies. Both expected worker hashes remain `a7c35b37…43ad6`. Expected storage/arithmetic come from the pre-candidate agreement, never from sidecars.

The collector uses the parent's exact pinned private SSH settings and verifies the public known-host file hash; it does not read private-key contents. Each rank reads only `qwen27b-owner-validation-20260915/evidence/20801ced-ca29-4faf-b71a-9ebbe1886a14.json`. The final file is opened with no-follow/nonblocking flags, checked as a bounded regular owner file before reading (16 MiB), rechecked by FD identity, hashed and encoded. Each remote reader then makes a fresh broad native/owner process observation and reads the canonical journal with the same bounded descriptor checks. It sends no signals and mutates no remote file. Each local SSH invocation has a 30-second timeout; fixed remote sidecar/ps/journal bounds limit the response. The transport parser also caps its completed response at24 MiB. This is a fixed trusted read-only source, not an arbitrary-output SSH command runner.

Raw transport stdout/stderr and collection results are retained. A failed SSH, malformed bytes, hash mismatch, timeout, interruption, live process or nonempty journal remains failed. Valid sidecar bytes are retained even if the fresh postflight refuses. The helper never turns process absence into a native-retirement or authenticated-release acknowledgment. Root must still review the parent/controller's actual bilateral native cleanup and release ACKs, alias restoration, all raw resource samples and unchanged deployed pins separately. Numerical comparison cannot establish those facts, intermediate logits/frontiers, non-offset state values, performance or provider eligibility.

Twelve focused checks passed in0.095s: exact six-role/expected-agreement assembly, wrong hashes, inode alias refusal, exclusive publication, bounded/no-follow files, strict transfer bytes/types, refused postflight preservation, timeout partial output, interrupted failure and pinned collection-to-packet binding. SSH was mocked; all payloads were fabricated and no model/compiler/network action occurred. The original comparator tests and numerical policy were not rerun or changed. `checks-1` and `checks-2` retain the earlier passing7/10-case stages; `checks-3` is final.

## JSONL retry rebinding

This separate derivative changes only prepare_packet.py constants PARENT, PARENT_SHA and AGREEMENT_SHA. The collector, remote reader and all12 prior test bodies are exact. rebind.patch and rebind-check.json prove the inverse, new44-member parent/source/agreement bindings and unchanged request/source/Plan/privateSSH/remote sidecar paths. The prior tests were not repeated for constants. reference-precheck.json is retained historical evidence: its old parent/agreement pins identify the earlier preparatory epoch, while the same successful reference bytes and request semantics remain fixed. Only the current prospective agreement epoch changed. No actual candidate or reference outputs were read during this rebinding.
