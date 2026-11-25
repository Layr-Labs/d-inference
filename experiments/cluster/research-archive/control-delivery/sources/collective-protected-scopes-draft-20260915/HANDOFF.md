# Private protected Collective source slice — 2026-09-16

Eleven Runtime files plus three repository test sources implement a reusable facade over the actual native completed P2P path. This is source-only, uncompiled, unqualified and not enabled by serving. `CollectiveProtectedResourcePolicy.unqualified` refuses before native group creation; the internal load seam also refuses before process admission. The ordinary public resident loader selects nil protection.

`Collective` retains a private `CollectiveNativeEndpoint`. Only that endpoint implements the typed ciphertext IO protocol; the facade cannot recursively encrypt its own ciphertext. Failed native group/array construction releases its untransferred C handle. All scoped facade views retain the same endpoint and `CollectiveProtectedSession`, which owns exactly one codec and global directional counters. Scope creation neither resets keys nor admits a request. Scope values bind epoch, Plan, request UUID, full generation agreement, operation kind, locally expected metadata and array geometry. Control length/body have distinct authenticated subcontexts.

| Operation | Independently expected binding |
|---|---|
| Load intent / loaded readiness | Existing common load / loaded identity; distinct setup record kinds |
| Request readiness | Actual generation agreement and request UUID |
| Residual header | Actual local boundary expectation |
| Residual array | Authenticated and exactly decoded boundary packet fingerprint + local dtype/shape |
| Target token | Known boundary/history/ordinal/committed frontier, excluding the not-yet-known token |
| Decision | Known returned token fingerprint |
| ACK / retirement | Exact phase and packet fingerprint; retirement has a separate record kind |

The lookahead consumed ticket retains its immutable ACK endpoint. New scopes cannot overwrite its context. All protected transfers authenticate before native plaintext publication; local semantic validation and consumer commit still precede ACK. AEAD/context/cancellation/reentrancy failure poisons the shared session and propagates into the existing generation failure/retirement path. There is no plaintext error or retirement bypass. Independent process deadlines still bound blocked backend calls. Raw reductions/barriers/token all-reduce refuse under protection; existing plaintext call order/payloads remain, with no numeric state/model changes.

Seven staged Swift test methods use the actual Security codec/transport with completed in-memory bytes and actual Qwen wire DTOs. They cover immutable scope/parts, wrong epoch/Plan/request/type, shared counters across setup/two requests/retirement, exact one-frame lengths, replay, reentrancy, cancellation, closed construction and retained lookahead metadata. They do not simulate native cleanup or prove native facade execution. Run the existing Runtime test target with `--filter 'CollectiveScopeTests|QwenRecordScopeTests'` only in a root-authorized private build; no compile/test has run here.

`RESOURCE-PROBE.md` defines the small next executable allocation probe, OS lifetime high-water requirement, closed profile and exact load/request resource join needed to open this gate. A key/binding supplied to this internal type is not coordinator membership, fresh-key establishment, or device reservation proof. Those trusted-peer controls remain a separate required integration. No new package/CLI flag or handshake is silently enabled.

`integration.json` binds current MAIN preimages and proposed files; `controls.json` pins unchanged numeric/wire/security/native-tail controls. `runtime.patch` includes only these Runtime/test changes. Run `python3 -B check_source.py` for source pins and private patch replay; this does not compile or execute Swift/MLX. Any future source correction belongs in a successor after freeze.
