# Invocation-local allocation-bound memo

Source-only successor over actual diagnostics composition `05ed94d8` and successful native build receipt `6096d8b3`. Root's phase2 measurements identify target admission as 167.27 ms/request (40.30% of decode); this patch has no measured speed result yet.

Apply the three files in `integration.json` only after verifying exact preimages. The auxiliary preimage is the actual phase2 source `9ba7124b`, not the older original owner; all its timing hooks remain. No applied workspace, vendor, MAIN, native binary, resource policy, floor or old package was edited by the author.

Each call to either `admitVerification` creates a fresh local scalar dictionary. For each exact distinct byte count, the original `QwenResidentResourceEnvironment.allocationBound` still runs, including native upper-bound calculation, overflow handling and actual Metal maximum-buffer validation. Equal byte counts reuse that scalar only until this synchronous method returns. Every named array still updates its own persistent maximum, and every named maximum is still summed separately. Equal allocation quanta with *different* logical bytes are deliberately not merged.

The pinned `Memory.allocationFootprintUpperBound` is documented and implemented as a metadata calculation, with no allocation, cache inspection or stream operation. Its Metal implementation derives the bound from immutable `vm_page_size` scalars. `GPU.deviceInfo` reads the same process-default Metal device's `maxBufferLength`; this private Apple-silicon execution does not change devices during a synchronous admission. `Memory.withError` installs scoped error collection around that one calculation; it does not poll or drain asynchronous faults. All existing outer native fault checks remain. This is not a reusable cache across devices, invocations, async boundaries or requests.

No state/graph operation is inserted or skipped. `requireObserved`, plan geometry validation, named-map publication, revision increment/invalidation, original owner's fresh OS/native observation, deadline and cancellation/fault gates remain byte-identical. Resolving a new size throws before map/revision publication exactly as before. The auxiliary checked sum still occurs before publication; the remote reservation's existing checked sum remains in its original location. The helper has no error recovery. Its small dictionary contains at most one pair per distinct plan size (four for the current Gemma full/window geometry) within the existing 16 MiB host scratch allowance; it retains no arrays or GPU resources.

Source-only validation: exact source hashes and inverse below. Seven Foundation test groups are staged, not executed by the author. Tests cover exact-size reuse, different sizes with the same rounded result, fresh admission, failure propagation/no failed-result cache, scalar edge values, all 158 synthetic named charges/persistent maxima, and failed-transaction non-publication. These controls do not substitute for actual native resource and numerical replay.

Root command, in a fresh owned output directory and under the usual bounded compiler helper:

```sh
/usr/bin/swiftc -swift-version 6 -warnings-as-errors Runtime/InvocationAllocationBoundMemo.swift Tests/InvocationAllocationBoundMemoChecks.swift -o QUALIFICATION_DIR/checks
QUALIFICATION_DIR/checks
```

Then root composes the exact three files into the existing native candidate, builds once, and compares phase2 admission time, all actual reservation terms/totals, fresh-observation revisions and numerical rows/state against the same workload. Equal charged bytes are mandatory; no tolerance, floor, timeout or source-policy relaxation is authorized.
