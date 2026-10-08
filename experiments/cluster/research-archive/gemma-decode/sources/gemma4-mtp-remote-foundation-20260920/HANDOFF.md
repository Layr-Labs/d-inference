# Actual Foundation protocol and budget controls — root only

Run after the current compiler retires, before physical qualification:

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/gemma4-mtp-remote-foundation-20260920/run.py --output /Users/developer/DarkbloomDev/cluster-research/gemma4-mtp-remote-foundation-20260920/qualification-1
```

The create-only runner verifies all ten source pins before and after, uses the exact existing owned-child helper, and executes four strictly sequential children: core compile120s, core check15s, budget compile120s, budget check15s. Both compilers use xcrun swiftc Swift6/warnings-as-errors/jobs2. Every child must exit0, be reaped, and leave its group absent. Logs and the final receipt are retained on failure; no retries. Output caps remain 1MiB stdout/4MiB stderr per step.

The core uses exact original ledger/record/mirror and all18 original fixtures, with the effective cohort transfer plan3a7 (individually rounded sender heads and nine receiver roots). Expected core-check.stdout is the exact JSON schema gemma4_mtp_remote_pull_cpu_v1 with the18 ordered labels in inputs.json, passed=true, groupCount=18, and false model/native/physical claims. The budget uses the final dense-scope budget0c19 with serialTargetHead at its unchanged defaultfalse and all six original a572 assertions. It must print exactly: `PASS 6 synthetic remote target budget groups; no allocator, model or physical qualification` followed by newline. The checked-in integer helper prefix is extracted at the original unique marker with its complete source preimage verified.

Only Foundation/CryptoKit scalar code is compiled. No MLX module/library, model weights, native tensor computation, lease, SSH, socket or physical resource owner is invoked. These controls do not establish allocation or physical memory safety; the original real-native resource/floor/lease controls remain mandatory for the later tiny JACCL run. Author source checks only; no tests or compiler executed.
