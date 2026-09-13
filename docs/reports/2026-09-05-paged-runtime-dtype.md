# Paged runtime dtype protection

> Last updated: 2026-09-05 · commit `da05f883d`

The native runtime now rejects projected KV dtypes that differ from the paged
pool's observed contract before sampling the failed result. The exact candidate
passed 272 unique test functions and 353 actual cases across 24 complete suite
filters, with zero failures or skips. This is a correctness milestone for the
0.9.0 migration; no fleet-size model or latency result is claimed here.

## Change and ownership

Native commit `990475e3ae6f93615bebe0fc36e352aa601ea4a5`, based on
`f93134e537c594f6b5c69fb08115062c205cf655`, changes 32 files. One pool-owned
fault latch validates K/V dtype metadata at write and attention boundaries.
Checked engine forward paths reject the failed graph before evaluation or
sampling. Existing submitted work synchronizes before valid write fences are
restored and affected rows, recurrent state and detached MTP owners retire.
The request reservation remains charged until those aliases drain. A later
healthy request does not inherit the failed graph.

The error reports expected/actual dtypes and the layer index where available.
It contains no prompt or tensor data. Production backend defaults and model
capability gates remain unchanged.

## Validation

| Evidence | Result |
|---|---|
| Runtime dtype tests | Six functions, 18 parameterized cases |
| New tiny Qwen fault test | One function, serial and captured MTP fault scenarios internally |
| Tiny Qwen dense/MoE suite | Three functions, including healthy MTP rollback/cancel and token equality |
| Full selected native coverage | 272 unique functions, 353 actual cases; 24 filters; zero failures/skips |
| Native build | 48.92 seconds reported by SwiftPM |
| Source verification | 453 candidate native, 451 primary baseline, 32 owned and 1,353 selected MLX dependency inputs unchanged |

Affected suites also cover packed prefill, prefix reuse, page kernels, backend
admission/grants, checkpoint storage/adoption, recurrent state, resizing,
teacher-forced scoring, shared KV layers, frozen gathers and end-to-end engine
behavior. Test counts distinguish framework cases from internal scenarios.

Validation uses an isolated native package with an explicit local MLX dependency:
mlx-swift `eafd98a7c53c145ff40faa486c5f696b7104ae92`, MLX
`9b3f4d1ec6bd65314e06825658334e5788ee3167`, and mlx-c
`720953eff635e772d9f3d73e46942bc49fac04c3`. The archived before/after compiler
graphs identify the actual isolated runtime6 source paths and local dependencies.

Five prior failed compile/fixture attempts are preserved. Corrections propagated
missing `try`, forwarded the real top-two MTP capability in a fault fixture, and
aligned old TinyTestModel paged pools with their seeded float32 projections.
The exhaustion fixture scales 256 KiB FP16 to 512 KiB FP32 to preserve its exact
physical page count; one request still fits and two refuse. Token, bitwise,
boundary and refusal assertions remain intact. No production guard was relaxed.
A separate addendum corrects stale verdict prose naming runtime5; actual graphs
before and after the passing run both point to runtime6.

## Reproducible evidence and limits

The [manifest](evidence/paged-runtime-dtype-2026-09-05/manifest.json) has SHA-256
`0f7786f138f71450b112431c0aea926ac938a471a6a4321a2b997c57ea27515d`.
Its [archive](evidence/paged-runtime-dtype-2026-09-05/payloads.tar.gz) contains
226 verified payloads, including passing and failed logs, patches, exact owned
source archive, dependency/source hashes, build graphs and the verdict addendum.
Archive SHA-256 is
`af423bf82ba0793054e18175a7535e94041d0f9e2631dc28e6b057f0b6865dc1`.
The accepted validation manifest is
`79634bae0e831714461b22d277a0390c35f5f6700329f9360b7bc15091482cd3`.

This run does not prove allocator-footprint admission, paged complete SSD serving,
production-key restart, or the five exact fleet models. Healthy-path fence and
snapshot overhead still needs measurement. It changes no release version,
rollout setting, production machine, or resident-cache default.
