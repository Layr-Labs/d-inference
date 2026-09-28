# Matched timing bundle with pump wakeup

This separate bundle preserves all five timing-controller sources and all three CPU fixture sources from frozen `resident-owner-timing-controller-draft-20260915` manifest `ba5f93b27ea51252fe9ddea43a05a25f455407fafa002b154a39a5f93ca9f9ee`. Settings, warmup exclusion, measurements, deadlines, sequence guard, cleanup and publication semantics are unchanged. The old build-5 and deployed owner bundles remain untouched.

`main-input-pins.json` records 32 current MAIN Foundation inputs, including the three added capability descriptor/codec/validation files and configured-owner entry. The original Process source is preserved under `originals/`. `lineage.json` then applies exactly the two reviewed pump sources from manifest `c5c2e6b2732d439deb88f5fab2fd0b743522e55563ccd5b0a3429510294e2b6d`: Process `e09eb12b…2250` and helper `2177145d…204a`. The current Request retains the partial-admission cleanup fix. No native model, GPU runtime, main repository, frozen package or timing logic is changed.

The first Foundation-only Swift 6 build passed in 7.428 seconds; all seven unchanged actual-local-child CPU groups passed in 2.114 seconds with empty stderr. These cover four fresh requests on the same two loaded fake processes, warmup exclusion, explicit refusal, wrong sequence, exhausted lifetime, failed publication, and strict settings/timestamp validation. All 42 compilation inputs were rehashed unchanged afterward. These fixture elapsed times are not model performance measurements. The receipts and raw output are under `checks-1/`.

To rebuild in a fresh directory:

```sh
bash build.sh /absolute/new-build-directory
/absolute/new-build-directory/timing-check /absolute/new-build-directory/fake-worker
```

Deployment needs the newly built `owner-timing-controller`, `darkbloom-owner-qualification`, and the four adjacent Protocol/Bootstrap/Process/Remote dylibs. Both controller and each configured owner must use this new Process library to remove the command-pump delay at both endpoints. Root will create separate paths/configuration and reuse the unchanged qualified native `009a671d4e355131b6f38166536d00eee0fb5798000407808d716bc3ea31a08b`, guards, geometry and input sequence. Native, actual prefill policy and remote cleanup remain separately bound by root.

The six deployable artifacts and hashes are in `current-artifacts.json`. The controller executable, Bootstrap library and Remote library are byte-identical to old build-5; the Process library changes for wakeup, while Protocol changes for the already-promoted capability descriptor and shared JSON-object extraction. `module-delta.json` records this additional Protocol lineage explicitly. The configured-owner entry is an exact current MAIN copy. This is not a claim that every deployed byte differs only by the pump fix.

Run each controller with one explicit timing configuration path; the configured owner still accepts exactly `cluster worker-owner --stdio` and its adjacent private `owner.json`. No installer or remote action is included. Compare the new matched serial/lookahead cohorts separately from the preserved old-pump cohorts; all results remain internal owner-control latency rather than external HTTP/OpenRouter TTFT.
