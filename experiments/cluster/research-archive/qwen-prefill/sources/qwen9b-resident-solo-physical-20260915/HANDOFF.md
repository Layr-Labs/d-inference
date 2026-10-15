# Root-only solo48GB operations

This small wrapper uses the existing registered-reference attempt4 local
supervisor and collector, plus the existing canonical-gate/resource preflight.
`physical.patch` contains only bound directory, job/launcher and import changes.
The fresh-deployment helper copies the exact45 declared files; it deliberately
excludes root's unmanifested source-review file. It never overwrites a prior
remote root or local attempt. No remote operation has been executed by the author.

The parent source manifest is c59521b53eeac0b7fcf213c44e3058c2bcd530da3f73ee762e4e5a77c40568c7.
The job is da9b19233d6ca24879c1ee6ccafbc8ae7dd509eb70ce43f9d796f1709941bd37.
The native8952b0f…252d3/bundle71617e27…6cb7 is the compiled15/24 CPU-checked solo
candidate. All references point to frozen source and bundle members; no model
weights, native owner controls or installed-provider configuration are copied.

After root review, with no other compiler/transfer/model/timing active:

```sh
cd /Users/developer/DarkbloomDev/cluster-research/qwen9b-resident-solo-physical-20260915
/usr/bin/python3 -B prepare_remote.py
/usr/bin/python3 -B run_physical.py
/usr/bin/python3 -B collect_run.py 1
```

Preparation creates only the new remote root, copies the exact native,
supervisor and input files, and rechecks modes/hashes, no competing process,
the existing canonical empty gate under nonblocking flock, and actual resources.
The gate is released before native startup so the native process can own it.
The physical wrapper repeats the old observed process/journal/resource check,
then execs the frozen supervisor. It retains the original420-second local SSH
timeout,300-second native alarm and315-second owned native supervisor deadline.
SSH exit alone never proves native cleanup. Collection retains file hashes,
native stdout/stderr, terminal evidence and a fresh process/journal observation.

The later-run terminal and all four native request timings must be reviewed;
exclude warmup and report the three measured requests and median. A failure or
resource refusal stays failed. No IPv4 alias is involved. Incomplete retrieval,
timeout or nonempty journal requires inspection, never automatic journal clear.
The collector's inherited fresh process/journal observation is read-only and
does not itself acquire the canonical flock; the native owns that gate through
process exit. Native reaping/group cleanup is recorded by the unchanged parent.
