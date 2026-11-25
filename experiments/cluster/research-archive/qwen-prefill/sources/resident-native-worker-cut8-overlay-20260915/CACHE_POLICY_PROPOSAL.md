# Dedicated-worker cache policy proposal

This is a source map only. The cut8 overlay does not change allocator policy, lifetime, live resource admission or protocol messages. The frozen worker still has the inherited default freed-buffer cache; the existing d904 benchmark worker requested zero explicitly. No benefit for the new worker is claimed before measured execution.

Use an explicit two-case process policy on `QwenResidentLoadConfiguration`, defaulting to unchanged; only `NativeWorkerRuntime` selects the dedicated-worker cache-disabled case. This keeps the synchronous facade's default behavior stable and avoids changing the local production provider. Do not add a generic cache-size knob or global provider setting.

The minimal runtime changes would be:

1. In `QwenResidentRuntime.load`, after metadata/JACCL/arithmetic admission, exclusive process lease and `control.check()` plus `QwenResidentResourceEnvironment.require()`, request `Memory.cacheLimit = 0` for the explicit dedicated-worker policy. Do this in a native-error scope, check native error and deadline after the setter, and before `Collective`/model creation. Bind the selected policy identifier into the existing common load-agreement digest so both workers agree. Never change `Memory.memoryLimit`, model arithmetic or the actual-free floor.
2. After `loadQwenResidentStage` returns, inside the current native-error scope and before `maximum.requireLive()` and the bilateral loaded-readiness exchange, synchronize GPU and CPU streams, check native error/deadline/native error, snapshot, clear the cache, check again, and snapshot. Require `after.cacheMemory == 0`, unchanged active storage, and a valid peak. This follows d904's bounded `prepareReady` method and places cleanup before the post-load reserve check, while all earlier materializer samples still enforce their unchanged bounds.
3. Preserve the existing inner catch's native-error preference and failed-load retirement path. Publish Ready only after local checks and the existing bilateral loaded-identity exchange. No added warmup or request-state allocation. Keep cache-off for the dedicated process lifetime; do not pretend to restore a verified prior backend value through the cached Swift getter. The hard process lifetime and owner fencing still apply.

The current pure Ready DTO has no allocator-observation field. The smallest implementation can keep its wire shape unchanged and enforce the policy checks inside the native owner, with source/build policy correlation recorded by the launcher. That does not give the parent independent before/after cache evidence. If that evidence is required, use a separately reviewed optional operational DTO/version extension on both sides; do not insert undeclared JSON keys into the frozen closed protocol. The public model/Plan/token identity must not be repurposed to encode a memory observation.

Source facts supporting this proposal:

- `Memory.swift:283–305` caches the requested value in Swift; its getter is not an independent backend attestation. `clearCache` at line388 invokes cache eviction under the eval lock.
- `allocator.cpp:108–112` sets only the pool limit. `free` at lines236–254 recycles only while cached bytes are below that limit; a positive ceiling can overshoot by the newly returned buffer. Zero prevents that recycling branch. `clear_cache` at lines232–235 clears cached buffers, not active model/state storage.
- Frozen d904 `QwenResidentBenchmarkWorkerEntry.swift:57–60` sets zero only for rank workers after typed/actual gates. `QwenResidentBenchmarkAllocatorPolicy.prepareReady` synchronizes, uses its own native-error scope, checks actual before/after cache and active bytes, and makes no getter-as-proof claim.
- Current facade `QwenResidentRuntime+Load.swift` already has both the pre-native typed/OS gates and the post-load/bilateral-ready boundary needed for this placement. The worker owns a dedicated native executor; its startup deadline still needs the independent parent fence during blocked load.

The pinned files are listed in `source-pins.json`. No cache-policy implementation, compiler, model, GPU or remote execution was performed for this proposal. Cache clearing cannot reclaim active KV/recurrent/fused weights, prove a particular earlier RSS cause, or guarantee that later 6GiB samples pass.
