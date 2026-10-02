# Bounded owner diagnostic drain

This private candidate fixes loss of stderr emitted after an authenticated owner
release ACK. The baseline regression reproduced the loss, the corrected checks passed, and
the local Foundation controller build passed. No MAIN, remote installation, native worker, model or physical run
has changed.

The retained diagnostic27B attempt failed before tokens, with both native cleanup
and both authenticated release ACKs observed, but both endpoint tails empty.
`source-diagnosis.json` binds those actual records and the exact source ordering:
the service publishes `released` before returning; the diagnostic owner publishes
its tail after that return; the endpoint used to stop reading on `released` and
close unread stderr after SSH exited. The controller also took its snapshot after
the ACK without waiting for the endpoint's transport termination barrier. The
native refusal's actual cause remains unknown.

The shared change is confined to `ClusterRemoteWorkerEndpoint.swift` and the
focused `ClusterOwnerDiagnostics.swift` helper. The endpoint keeps reading during
its existing two-second exit grace, capped by the absolute lifetime plus two
seconds. After actual transport reaping it drains buffered stderr to EOF within
that same deadline, closes the descriptors, and only then leaves `ownerEnded`.
The existing1MiB capture cap is preserved. A read error, excessive bytes or an
inherited writer that never closes leaves `diagnosticDrainComplete` false.
This flag is separate from native cleanup, authenticated lease release and actual
transport exit; no EOF or elapsed time supplies either native/lease proof.

The private controller waits for the existing owner-release barrier before its
diagnostic snapshot. Its transport wait uses one shared absolute deadline for
both ranks, sampled after the ACK wait and capped by the original owner drain
limit. The original failure remains primary. The result additionally records
owner transport release, actual termination and diagnostic completeness.
Missing EOF or a nonzero/signalled owner exit cannot produce a successful result.

The two controller files and two Remote files are the only runtime deltas;
36other copied runtime sources are exact. The baseline Endpoint also matches
current MAIN. Wire codecs, native commands, owner service, lease resolution and
the installed diagnostic owner `da5542b1...` are unchanged. The intended actual
rerun needs only a new local controller and its coherent four Foundation dylibs.
The remote diagnostic owner and its existing Remote dependency remain installed.

All five new fixture groups passed in3.645seconds. A real owner service launches a real local
child that writes a fixed diagnostic and exits7 before Ready. A test-owned file
gate permits the owner to emit that diagnostic only after the endpoint observes
both terminal and `released`. The baseline must reproduce loss despite natural
owner exit; the candidate must retain it before its barrier. Further cases retain
the tail from an owner exiting9 and fence a post-ACK hung owner within two seconds.
A real exited child with an independently held pipe writer demonstrates that
termination cannot fabricate EOF; an oversized diagnostic checks the byte cap.
The six existing retirement cases passed in3.336seconds and13existing SSH groups
passed in9.761seconds; both fixture sources are copied unchanged.
All test children are model-free and local; no SSH transport is launched.

The completed sequence from this directory was:

```sh
/usr/bin/python3 run_checks.py baseline 3
/usr/bin/python3 run_checks.py proposed 1
/usr/bin/python3 build_local.py 1
```

Both runners use fresh attempt directories, pinned sources, at most two Swift
compiler jobs, bounded owned process groups and retained stdout/stderr/exit
receipts. `build_local.py` produces only the local controller and four modules,
using the established macOS14 Foundation build flags; it does not run the result.
The five inspected artifacts are in `local-bundle` (bundle manifest
SHAe650ebc820b42e7b57cf105b81b60c01320d22f40cfe1e1de70c52a13440fdaa).
They target arm64/macOS14 with system or @rpath imports only. Controller
SHA862f7a391afd8f490233db793034c1ec8648c52fd908ba39abbefbf46e899d78;
Remote SHAe8de34addd754cad53c0295452c1722db46a253779f0efbf11caafafaf1cb704.
Production build passed in4.164seconds with43inputs unchanged. The compiler slot
was released. Fresh physical configuration/epoch binding follows separately; root
owns execution, with all existing remote artifacts unchanged.

The first author-only source assertion mistakenly expected four failure-coalescing
statements rather than three; that failed check is retained separately. A source
initialization correction before compilation changed the capture helper to use
the already-owned descriptor at each call, avoiding access to an uninitialized
Endpoint stored property. Its earlier three source files are retained under
`source-revisions`. Neither correction changed the native/runtime policy.

Independent four-file review: `cluster-owner-diagnostic-drain-review-20260915/`
`source-review.json`, SHA750193b50edab803e91ce10aa616a764561f55457100481960646e29f7452415.
The reviewer found no concrete source blocker and did not execute fixtures.

Baseline1 failed only because Bash3.2 rejects an empty array expansion with
`set -u`; the runner now always has one test define. Baseline2 then found a missing
required `bootstrapProfile: nil` argument in the new fake owner. Both failures and
prior source bytes remain. Baseline3 built in5.580seconds and reproduced the
actual lost diagnostic in1.365seconds. Proposed1 built in5.912seconds without
runtime corrections. All passing phase stderr files are empty. These local
checks prove pipe/owner behavior, not a newly observed27B failure cause.
