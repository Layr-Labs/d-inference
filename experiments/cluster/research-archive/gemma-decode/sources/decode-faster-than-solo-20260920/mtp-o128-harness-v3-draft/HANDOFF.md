# O128 description harness v3

This thin successor preserves frozen v1/v2 and both failed native metadata receipts. The only native delta is ba368a85: O16 description still derives full/stage0/stage1, while O128 describes its admitted full job. The actual job dtype/profile chain, budgets, floors, execution and numerical paths are unchanged.

`prepare.py --check` replays predecessor dd0b8979, checks the exact corrected 122-file map and AST, and changes executable namespaces to fresh v3. A small installed metadata helper additionally requires ordinary description targets exactly `[full,stage0,stage1]` for O16 and `[full]` for O128. Dedicated remote metadata retains its original schema. Timing, counters, all numerical readers, limits and physical retirement joins are byte-identical to v2 except namespace substitutions.

Root commands, after the new actual successful build:

```sh
python3 -B prepare.py --check
python3 -B -m unittest discover -s Tests -p 'test_*.py' -v
python3 -B prepare.py --prepare --build-receipt /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/build/o128-description-build-1/receipt.json --sources /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/build/o128-description-composition-1/sources.json
```

Preparation creates only `harness-local-mtp-o128-v3`, `harness-remote-mtp-o128-v3`, and `remote-mtp-o128-numerical-v3`. It binds the actual successful compiler receipt, corrected source receipt, exact inherited resource bijection, native size/hash and all earlier source fields. Native identity remains late-bound. Existing root_run/numerical commands are unchanged; use fresh cases. Actual `--describe` must pass before any model launch.

Seven synthetic metadata controls are staged, not author-executed. They verify target-set selection, strict integer fields, schema/flag refusal and the installed callsite. They do not replace the actual native description and full-model numerical/resource gates. No compiler, native, remote or sidecar execution by this author.
