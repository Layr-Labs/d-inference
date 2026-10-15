# Local HTTP origin and distributed registry

This isolated overlay carries the earliest local HTTP handler receipt through body collection, model acquisition, tokenization and distributed admission. It adds no remote transport, model loading or default solo deadline. Main and all timing bundles are untouched.

`LocalRequestOriginResponder` wraps the existing auth/CORS/upload/router stack. Its request-scoped `ContinuousClock` instant is not read from headers or a client wall timestamp. `MultiModelBatchSchedulerEngine.streamChatCompletion` copies it before its first suspension and passes it explicitly to both bridge submission paths. The bridge chooses the earliest handler/profile/current instant and uses the existing `DistributedRequestDeadlineContext` and owner deadline translation. Upstream completions/responses share the same outer scope; the staged handler fixture exercises normal streaming chat.

An optional `DistributedFirstTokenBudgetPolicy(baseMilliseconds:millisecondsPerInputToken:)` is selected at distributed factory construction. Nil preserves the prior absence of a local first-token policy. For the requested acceptance run, explicitly select `10_000, 1`: actual 8192 tokenized inputs receive 18.192 seconds from handler receipt. The factory checks arithmetic across the admitted prompt range before taking owner ownership. The bridge uses the actual tokenized count, keeps earlier coordinator deadlines, and clamps against the profile/explicit generation deadline. Existing PipeOwner translation and its actual worker lifetime cap remain authoritative. Ordinary solo engines ignore the added distributed origin/policy fields. Expiry before content uses the existing `PreContentDeadlineFailure` → HTTP 503 mapping.

The origin is server-handler receipt, not external request-send time. Network latency before receipt and client-visible streaming latency still require the external client benchmark. This overlay makes no external TTFT or performance claim.

## Installed session boundary

After `DistributedInstalledSession.prepare(...)` and successful `await start()`, use:

```swift
let entry = try DistributedEngineFactory.makeRegistryEntry(
    owner: session,
    expectedIdentity: session.expectedIdentity,
    publicModelID: session.configuration.publicModelID,
    profile: session.profile,
    tokenizer: verifiedTokenizer,
    eosTokenIDs: verifiedEOSTokenIDs,
    modelType: verifiedModelType,
    firstTokenBudgetPolicy: try .init(
        baseMilliseconds: 10_000, millisecondsPerInputToken: 1))
```

`verifiedTokenizer` can use the existing `LocalTokenizerLoader` on the session-verified local tokenizer directory; no `ModelContainer` or solo weights are needed. Tokenizer/template/EOS/product-manifest verification belongs to installed-session preflight, not this factory. The required public ID is an explicitly supplied, caller-validated route. Its separate product `ModelManifest.model_id` join must be implemented by that preflight: the native capability pins `CheckpointManifest`, which has no `model_id`, and saved configuration alone is operator input. This factory only checks public-ID bounds. The native identity remains unchanged. Neither is inferred by rewriting the other. Public ID bounds match `ClusterConfiguration`.

The returned entry has `container:nil`, `isVLM:false`, `visionGate:nil` and one distributed bridge. Supply it through the existing `makeLocalInferenceApplication` acquisition/tokenizer/catalog closures. The installed session owns registry pinning and exact public-route lookup, and retains the bridge/session through shutdown, actual native cleanup and lease ACK. As before, failed factory construction leaves owner cleanup with its caller; successful construction gives the engine exclusive ownership until shutdown. Existing `makeBridge` callers retain their native-ID route unless they explicitly pass the new optional `publicModelID`.

## Verification and integration

`checks-1/` retains a successful five-group Foundation-only fixture for token-count arithmetic, overflow, deadline restriction, earliest-origin selection and concurrent task-scope restoration. It compiles the exact proposed policy/origin plus the unchanged deadline-context source. No MLX, model, network or native-worker execution occurred. All proposed Swift sources and staged tests parse; final source pins are in the manifest.

Seven `DistributedHTTPOriginTests` methods are staged for root's full Provider integration run. They use the production HTTP responder stack with an actual delayed `RequestBody`, fake resident owner, tokenizer and SSE writer; there is no listening socket or model. They cover body/acquisition/tokenizer time, pre-reservation expiry/HTTP status, nil policy, ordinary solo behavior, unready/overflow refusal, invalid public IDs, and an earlier explicit context. The normal HTTP route intentionally differs from the native identity and produces real framed SSE from fabricated tokens. These tests have **not** been compiled or executed here. Run after applying the overlay:

```sh
cd provider-swift
swift test --filter DistributedHTTPOriginTests
```

`runtime-and-tests.patch` and `integration.json` contain only this bounded slice. Apply after checking the six original-source hashes; preserve concurrent main changes. A full Provider typecheck and the staged handler tests remain required before production integration.
