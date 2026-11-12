# Installed product qualification handoff

Ready for root to compile and materialize. Source-only work: exact leader/follower templates, pinned capability, actual-MAIN-codec generator, and bounded physical-run plan. No configuration, remote command, tokenizer/model call, or compiler ran in this task. JSON metadata checks and shell syntax passed.

```sh
/Users/developer/DarkbloomDev/cluster-research/installed-product-qualification-plan-20260915/build-generator.sh /Users/developer/DarkbloomDev/cluster-research/installed-product-config-generator-build-20260915
/Users/developer/DarkbloomDev/cluster-research/installed-product-config-generator-build-20260915/generate /Users/developer/DarkbloomDev/cluster-research/installed-product-qualification-plan-20260915 /Users/developer/DarkbloomDev/cluster-research/installed-product-configurations-20260915 /Users/developer/DarkbloomDev/installed-distributed-runtime-20260915 bf3f5f182083488c40fef46807adb07d78f9df6b8e14e5a78a21377c98b97001
```

Both output directories must be new. The build first rechecks all 53 source/metadata/input pins. Its sixteen Swift source inputs are the actual Protocol module, four actual configuration helpers, and the small generator. Generated files still do not prove deployment: root verifies the ten-file product bundle on each host before invoking the actual configure command with each role's file.

Leader route: `192.0.2.250:18081`; follower: `192.0.2.223`; public model: `Qwen3.5-9B`. Native b833, cut4, chunk512, output≤128, serial, greedy, 120-second per-request cap, 300-second owner lifetime and sixteen requests. Dedicated private key/known-host paths and exact tokenizer inventory are present in both templates. Default configuration backup and remote trust/bootstrap/resource/alias observations remain root-owned.

Client uses chat streaming with explicit `temperature:0`, `top_p:1`, `enable_thinking:false`, `reasoning_parser:"qwen3"`, `stream_options:{include_usage:true}`. Measure send→first nonempty content, record reasoning separately, and use actual terminal prompt usage. `/apply-template` does not apply false-thinking controls; its count is not that request's proof. Client disconnect, EOF or SSH exit cannot establish native cleanup or owner lease release.

Current product gaps preserved: no configured lookahead selector, no dedicated cluster status/doctor, and no release/performance qualification. These do not prevent the first configured serial HTTP run. See PLAN.md for exact configure/lifecycle sequence and checks.json for this task's limited verification scope.
