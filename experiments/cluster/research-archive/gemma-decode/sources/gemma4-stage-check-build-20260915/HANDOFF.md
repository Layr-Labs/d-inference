# Gemma native stage compiled check

This private derivative builds the five frozen native runtime files and runs seven value-only policy groups plus all 29 cuts against the pinned artifact config. It does not construct a Gemma Module, load tensors, execute a native kernel or use a GPU. The separately executed Foundation closure passed 191 accepts and 36 refusals; its exact receipt is retained here.

The base is the completed tiny Session workspace. Preparation copies its exact 3,075 pinned sources, applies 17 reviewed additions/replacements (3,090 final source files), and makes an APFS clone of its idle compiler cache. All 8,755 dependency files must remain byte-identical. The two replaced files are the package manifest and Gemma4Text.swift. All MAIN and prior build trees stay untouched. Nested local MLX package paths remain within the copied closure.

The product depends only on MLXLLM and MLXLMCommon. Its target contains a mechanical translation of the seven frozen Swift Testing methods; the assertion bodies and vectors are unchanged. `-enable-testing` permits those internal policy checks. The full worker/Runtime/MTP products are not selected. The eight frozen Runtime mapper files are nevertheless present in the combined source snapshot and have separate Foundation test evidence.

Run sequentially from this directory, only with the exclusive compiler slot:

```sh
python3 -B prepare.py
python3 -B build_native.py native-1
```

Preparation refuses an existing workspace/cache/snapshot. The build uses release, jobs 2, macOS 26.2 Swift/C++ targets, no dependency update/resolution and a fresh build manifest. The reviewed owned-process helper bounds compilation at 900 seconds, vtool at 10 seconds, and metadata execution at 20 seconds (the executable also has a 15-second alarm). It signals only its still-unreaped owned process group; a post-reap group probe is observational. Helper launch output is captured in bounded fixed-content memory so a broken parent stdout cannot bypass cleanup. Each step retains stdout/stderr/argv/exit/cleanup and source checks; failed attempts are never overwritten. Output files are retained, not streamed through an unbounded memory buffer.

`native-1/receipt.json` is authoritative for actual results. A passed build checks one macOS LC_BUILD_VERSION with minos 26.2, exact fixture JSON, empty fixture stderr, source/dependency pins unchanged and child groups absent. No metallib installation is needed for value-only execution.

Native stage construction, loaded tensor assignment, guarded one-token KV dtype probing, request cache allocation and whole/split numerical equality remain unexecuted. `loadedEmbeddingOutputDType` is not accepted as proof of KV or boundary residual dtype. A future adapter must use existing CBv2 state/probe machinery and compare observed K/V dtypes before committing any request state.
