# Provider Code-Identity Attestation via APNs — Design Doc

Status: **Implemented (Phases 1–3) + verified-foundations.** Most claims below are empirically
proven on-box (macOS 26.5 laptop + M5 Max as root, macOS 26.4) or confirmed against Apple
documentation. Where something is still an open risk, it is marked **⚠️ TEST**.

> **Update (June 2026) — R-snoop re-verified closed + post-review hardening.** A clean on-box re-test
> shows the encrypted `code_challenge` is **not** harvestable by root (redacted `<private>` in the
> log; absent from every on-disk store; CLI un-redaction removed on 26.4) — correcting the earlier
> "R-snoop is real" claim (see **§1.6.1**). Alert mode is safe only because the provider requests no
> `UNUserNotificationCenter` authorization (invariant). Four post-review fixes landed on this PR:
> delegate strong-retain (release-build brick), early-push buffering, late-token re-registration,
> and drain-queues-on-`CodeAttested` — each with tests; both reviewers PASS.

**Build status (June 2026, worktree `apns-r2-test`, both reviewers PASS):**
- **Phase 1 — protocol contract:** ✅ `RegisterMessage` APNs fields + `code_attestation_response`
  message, Go↔Swift symmetric, parity-tested.
- **Phase 2 Track A — coordinator (Go):** ✅ `coordinator/apns/` (JWT/HTTP2 sender, dual-mode,
  `E_K(nonce)` via `e2e.Encrypt`, `CodeIdentityAttestor` seam) + push-attest step in `api/provider.go`
  + `CodeAttested` gate at the single chokepoint (rollout flag, default-off, fail-closed when on) +
  `server.go`/`main.go` wiring. `go test ./...` green (incl `-race`).
- **Phase 2 Track B — provider (Swift):** ✅ decrypt→`Sign_SE`→reply handler, `APNsBridge`,
  `CoordinatorClientConfig` token threading, and the `NSApplication(.accessory)` rehost
  (`main.swift` + `ProviderAppKitHost`). `swift build` green; non-MLX suites pass (full `swift test`
  needs the MLX metallib — env-only).
- **Phase 3 — integration test:** ✅ full coordinator round-trip (real encrypt→decrypt→sign→verify→
  `CodeAttested`) + wrong-SE-key negative.
- **Remaining (not code):** the Apple-portal step (enable Push, `.p8`, push profile,
  `PROVISIONING_PROFILE_BASE64`); on-device validation of the rehosted-provider APNs flow (pattern
  proven by `apns-r2-probe/coexist.swift` + the M5 Max receipt test); fleet background-push
  reliability measurement (mitigation built: `APNS_MODE=alert`). **Deferred by design:** binaryHash
  trust-demotion (additive) and §4.5 enrollment slim (would remove the SIP attestation). Worktree is
  **not committed** (libs symlinked → restore gitlinks before any git op).

The goal: in a **permissionless** network, give the coordinator (and ultimately the client) a
**remotely-verifiable, non-self-reportable** assurance that a provider is running the genuine,
unmodified Darkbloom binary — so a malicious operator can't clone the repo, add prompt-logging,
and join — **with ~0% inference-time overhead and no human allowlist.**

---

## Part 1 — Everything we learned this session (knowledge ledger)

### 1.1 The original gap
- The coordinator **cannot verify the running binary's code identity.** `binaryHash` in the
  attestation/challenge is **self-reported** by the provider's own (possibly modified) code →
  worthless against a malicious provider. Enrollment is **open** (`enroll.go`: "No authentication
  required"). MIN_TRUST=hardware proves *device*, not *code*.
- E2E encryption makes the **coordinator** blind to plaintext (it runs in a Confidential VM and
  re-encrypts to the provider) — but the **provider is the decryption endpoint by design**, so a
  malicious provider sees plaintext. "E2E" = coordinator-blind, **not** provider-blind.

### 1.2 Why the "obvious" fixes don't work on macOS
- **App Attest** (`DCAppAttestService`) — the one Apple primitive that binds a key to an App ID
  (Team+bundle), fork-proof — is **hard-`false` on every Mac** (native, Catalyst, iOS-on-AS), and
  Apple DTS reconfirmed in 2026. The capability can't even be added to a macOS target in Xcode.
- **No** first-class third-party **remote code-identity attestation** exists on macOS: exclaves
  (Apple-private entitlements), Platform SSO `attestKey()` (device+key only, SSO-scoped), cryptexes
  (no 3rd-party ticketing), PCC (no developer API; reaching it needs SIP+AMFI off) — all checked, all no.
- **Cryptographic prevention** (provider never sees plaintext) is **infeasible at our perf budget**:
  MPC for a 7-8B model = **750×–19,000×** slowdown; FHE 10⁴–10⁶×; blinded-outsourcing is decode-
  dominated/"premium-slow". Only a **hardware GPU TEE** hits ~1.05× (= NVIDIA CC, ruled out: Mac-only).
- **Key reframe:** the ≤25% confidential environment *already exists* — a hardened process is
  unreadable by root at native speed. The missing piece is **provability** (attestation), which is a
  **binary hardware primitive, not a perf dial** — you can't buy it with overhead.

### 1.3 The insight that works: APNs is a code-identity-gated channel
- To receive a push for an App-ID topic, an app needs the `aps-environment` entitlement, authorized
  by an **Apple-signed provisioning profile** bound to **(App ID + the team's signing certs)**.
- Bundle IDs/App IDs are **globally unique** (Apple's portal rejects duplicates); an attacker can't
  register our App ID, can't get our profile, and can't sign with our certs.
- Therefore **"received our push" is a remotely-verifiable capability only our genuine, team-signed,
  Apple-provisioned code has** — the non-self-reportable signal every prior idea lacked.

### 1.4 Empirically verified on-box (clean contrasts, only the variable changed)
- AMFI **`Killed: 9`** an ad-hoc binary carrying a restricted entitlement (`aps-environment`).
- A **different-team** binary spoofing our bundle ID + entitlement → **`Killed: 9`**, no token.
- `.accessory` agent **gets a token and receives the push**; `.prohibited` does not.
- Hardened Runtime (`CS_RUNTIME`, **no `get-task-allow`**): same-user lldb attach **blocked**;
  `DYLD_INSERT_LIBRARIES` **ignored**. (plain binary: both succeed.)
- keychain-access-group: owner (provisioned, team P7373SVQX6) reads the item; a **different-team**
  binary claiming the same group is **`Killed: 9`**.
- **On the M5 Max as ROOT, SIP on:** against the hardened (no-`get-task-allow`) process —
  `task_for_pid` → **kr=5 (failure)**, `lldb` attach **failed**, `dtrace` **failed to grab**;
  the non-hardened control allowed all three. Root **cannot** read `apsd`'s memory either (kr=5).
- End-to-end APNs push **received** by a headless `.accessory` agent on two machines.

### 1.5 Confirmed in Apple documentation
- **SIP cannot be disabled at runtime** — requires recoveryOS + reboot; no reboot-free path.
- With SIP on, even **root** can't `task_for_pid`/debug a protected/hardened process; **DTrace**
  is restricted on protected processes.
- Apple-Silicon boot levels **Full/Reduced/Permissive** via **LocalPolicy**, which is an **Image4
  file signed by the Secure Enclave** → attestable, unforgeable by a compromised OS.
- **MDA/ACME** attestation chains to the **Apple Enterprise Attestation Root CA**, is generated by
  the SEP, Apple refuses to issue it for non-genuine hardware, and it **carries SIP status (OID
  `1.2.840.113635.100.8.13.1`) + Secure Boot (`.13.2`)** (macOS 14+ Apple Silicon) + serial/UDID/OS
  + a caller-supplied **freshness nonce**.
- **Secure-Enclave private keys are non-extractable** (hardware guarantee). The access-group ACL
  ("who may *use* the key") is **securityd/AMFI-enforced OS policy** (depends on SIP being on).

### 1.6 Caught by testing — would have broken a naive build
- **R-snoop — re-verified, does NOT reproduce (see §1.6.1):** an earlier ad-hoc run suggested root
  could read the push nonce from the unified log, which drove the decision to encrypt the challenge.
  A **clean re-test on macOS 26.4** shows the payload is redacted (`<private>`) in the log and is
  **never on disk** — the earlier positive was a grep false-positive (it matched the probe app's
  *directory name*, not the payload). We **still encrypt the challenge to the provider's key `K`**
  (`E_K(nonce)`) as **defense-in-depth** — it protects on older macOS, under a user-enabled
  private-data logging profile, or via any other log facility, and costs nothing. The logged
  ciphertext is useless to a root attacker who does not hold `K`. Prompts are **not** affected —
  they ride the WebSocket, not the push.
- **APNs app-push needs the user's GUI/Aqua session** — over SSH (non-GUI) the agent got
  `NO_CALLBACK`; via `launchctl asuser <uid>` (GUI session) it got a token. The provider already
  runs as a **gui-domain LaunchAgent** (`io.darkbloom.provider`), so this is satisfied — *provided
  a user is logged in.*
- **Load-bearing detail:** it's the **absence of `get-task-allow`** (not "Hardened Runtime" in
  general) that blocks even-root injection. Notarization strips it; we must guarantee it's absent.

### 1.6.1 R-snoop re-verified on-box — the encrypted payload is **not** harvestable (June 2026)

A focused re-test on the M5 Max (macOS **26.4**, as root) **does not reproduce** the "root reads the
challenge from the log" finding. The earlier positive was a measurement artifact — a grep that
matched the probe app's *directory name* (`rsnoop-probe`), not the payload (a false positive of
exactly that class was caught and corrected during this re-test). Grepping for the actual payload
markers shows the challenge is redacted and never on disk:

| Harvest surface (as root) | Result |
|---|---|
| Unified log (`log show`, all processes) | `apsd` logs `payload <private>`; marker-only grep (`RSNOOPepk-…`) = **0** |
| Un-redact via CLI (`log config … private_data:on`) | rejected — `Invalid Modes` |
| Install a private-data logging profile (CLI) | blocked — "profiles tool no longer supports installs" (GUI/MDM only) |
| Notification Center DB (alert push) | **0** — provider requests no notification auth, so an alert is never persisted |
| apsd on-disk store + keychain + prefs + `/var/db` | **0** (background **and** alert) |
| Our own provider logs | never logs the ciphertext or nonce |

**Invariant that keeps alert mode safe:** the provider registers for *remote* notifications only and
**never requests `UNUserNotificationCenter` authorization** — so an `APNS_MODE=alert` push is never
presented or persisted to the root-readable Notification Center DB. If that ever changes, the
attestation push must be forced background-only. (Documented at both ends: `ProviderAppKitHost.swift`
+ `coordinator/apns/attestor.go`.)

**Scope & residual:** verified on macOS **26.4** (min target is 15 — treat the claim as "current
macOS"). The `E_K(nonce)` encryption (§3.0) is retained as defense-in-depth for older macOS / any
other log facility. A *determined* attacker on their own hardware could manually install a
private-data logging profile via System Settings (conspicuous, persistent) **and** harvest a genuine
device token **and** race the genuine `T↔K` registration — the same "patient insider on own hardware"
residual in §3.5, not a casual `log show` harvest. Reproduction tooling (not shipped):
`apns-r2-probe/run-m5-rsnoop.sh`, `run-m5-ondisk.sh`.

### 1.7 APNs rate limits (the reason we checked before designing)
- **Background pushes** (`apns-push-type: background`, `content-available:1`, **priority 5**) are
  **throttled to ~2–3 per hour per *device*** (device-wide budget, **undocumented/dynamic**,
  battery/data-budget dependent), **delivery NOT guaranteed**, can be delayed hours or dropped,
  blocked by Low Power Mode / Background-App-Refresh-off / "app not recently used"; the throttle is
  *disabled under a debugger* (test artifact only).
  ([Apple: Pushing background updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app))
- **Sender-side 429s:** `TooManyProviderTokenUpdates` if the **JWT** is regenerated < 20 min (reuse
  one JWT ~60 min across all hosts); `TooManyRequests` if too many pushes hit the **same device
  token** in quick succession (backoff, honor `Retry-After`).
- `apns-expiration: 0` = discard if offline (don't store stale challenges); `apns-collapse-id`
  coalesces.

---

## Part 2 — What was wrong with the previous design

1. **Trusted a self-reported `binaryHash`** as if it proved code identity. It proves nothing against
   a malicious provider (the measurer is the adversary).
2. **Open enrollment + no global admission control** — anyone with a genuine Mac could join and be
   routed traffic; "privacy" rested on no cryptographic or economic gate.
3. **Conflated device attestation with code attestation** — MDA/MDM prove genuine hardware + SIP,
   never *which binary* runs. Trust was upgraded to `hardware` on device facts alone.
4. **Overstated guarantee** — marketing/threat-model implied provider-blindness; reality is
   coordinator-blind (CVM) + unverified provider code.
5. **The naive APNs idea (had we shipped it) was itself broken** — a plaintext challenge nonce is
   log-snoopable by root and relayable to a fake binary.
6. **Assumed a daemon could do APNs and that we could poll attestation** — both false (GUI session
   required; background push is rate-limited and unreliable).

---

## Part 3 — The new design

### 3.0 Why this attaches Apple-backed proof to the WebSocket (read this first)

**The objection this section answers** (the right one to stress-test): *"The provider opens a normal
outbound WebSocket; the coordinator only sees unauthenticated bytes. macOS code signing is **local**
policy — Apple is not in that network path and emits no kernel statement binding the WebSocket to a
code identity (TeamID/bundle/cdhash). So how is this remote attestation and not local policy?"*

Correct — and the design does **not** try to authenticate the WebSocket directly. It **imports an
Apple-gated proof from a second channel (APNs) and binds it onto this WebSocket session** via a key
only the genuine process can use. The chain, with the empirical anchor for each link:

1. **APNs is the Apple-mediated channel that code signing alone isn't.** Apple delivers a push for
   topic `io.darkbloom.provider` **only** to a process whose `aps-environment` entitlement is
   authorized by an **Apple-signed provisioning profile** for that App ID — i.e. only our genuine,
   team-signed binary. *Proven on-box:* a different-Team-ID binary claiming that bundle ID +
   entitlement is **AMFI `Killed: 9`** (won't even launch); only the genuine provisioned `.accessory`
   agent gets a device token and receives the push. This **is** the "only Eigen's App ID can
   receive/handle this request" enforcement that a self-declared SE key + WebSocket cannot provide.

2. **The challenge is `E_K(nonce)`, never a raw nonce.** It is encrypted to the provider's registered
   X25519 key `K` (`NodeKeyPair` — a **raw, in-memory libsodium key, NOT keychain-stored and NOT
   Secure-Enclave-backed**; the SE only holds P-256). *Defense-in-depth against a log-readable
   payload* — a clean re-test on macOS 26.4 shows the payload is redacted `<private>` and not
   harvestable from log or disk (§1.6.1), but encrypting `E_K(nonce)` still protects on older macOS /
   under user-enabled private logging, at zero cost. The
   logged ciphertext is useless to root because **`K` exists only inside the genuine process's memory,
   and that memory is unreadable**: SIP-on + Hardened Runtime (no `get-task-allow`) ⟹ even root gets
   `task_for_pid → kr=5`, lldb/dtrace denied (proven as root on the M5 Max). **The keychain-ACL +
   SE-non-extractable guarantee protects the _separate SE signing key_, NOT `K`.** Consequence:
   K-confidentiality (and prompt-confidentiality) rest **entirely on SIP being on** — which is exactly
   why the Apple-signed SIP attestation (pillar 2) is load-bearing, and why MDM cannot be removed yet
   (see §3.4).

3. **The round-trip transfers the proof onto *this* WebSocket.** The peer answers over its pinned TLS
   connection by **returning the decrypted `nonce`** (proves it could decrypt `E_K(nonce)` ⟹ it holds
   `K`) **together with `Sign_SE(nonce)`** (proves it holds the registered persistent SE identity).
   Note: `K` is X25519 / **decrypt-only and cannot sign** — there is no `Sign_K`; the signature comes
   from the **separate SE P-256 key**. Both legs are required (decrypt-and-echo binds `K`; `Sign_SE`
   binds the persistent SE identity for free and ties the response to registration). Answering proves
   the peer **(a) received the Apple-gated push** ⟹ genuine, App-ID-provisioned code, **and (b)
   controls both `K` and the registered SE key.** The anonymous WebSocket is now bound to "genuine
   code holding `K`." A **relay can't help**: a fake sibling process can't receive the push (no valid
   token for our App ID), can't read the nonce from the genuine process (memory protected), and can't
   lift it from the logs (ciphertext). All three legs are empirically closed.

4. **The binding is continuous, not one-shot.** Every prompt is encrypted to `K` afterward, so only
   genuine code can decrypt each request — the proof rides every message, not just the handshake.
   Re-attest on reconnect (a reboot — the only way to turn SIP off — drops the connection), so no
   polling is needed.

**Proves:** the WebSocket peer is *our genuine, team-signed, Apple-provisioned binary, on a
SIP-attested device, controlling `K`.* **Does NOT prove:** the exact release **cdhash** — APNs binds
App-ID/Team, not version. That last gap is closed not by anything Apple gives us but by **reproducible
builds + a public transparency log** of blessed cdhashes (§3.5); and once APNs establishes the code is
our genuine unmodified binary, that binary's *self-reported* cdhash becomes trustworthy, so the two
compose.

**What does NOT work — and why the keychain access-group key is the wrong place to look for remote
identity:** requiring "the provider use the Eigen access-group SE key" does **not** by itself block a
fork remotely. The access-group restriction is enforced by `securityd` **locally, at call time**, and
leaves **no transferable artifact** on the public key — so the coordinator **cannot distinguish** a
genuine access-group key from a fork's own SE key (both produce identical signatures). The SE
access-group key's job is **signing** (`Sign_SE(nonce)`, binding the response to a persistent SE
identity) — **not** remote identity, and **not** the decryption step. The **decryption binding** in
step 2 is done by `K`, whose confidentiality comes from **process-memory opacity** (SIP + Hardened
Runtime), **not** from any keychain ACL (`K` isn't in the keychain). Remote identity comes from
**APNs** (step 1). The three roles are distinct — **APNs = identity, `K`-in-protected-memory =
decryption, SE key = signature** — and conflating any two of them is the single most common wrong turn
here.

### 3.1 The three orthogonal pillars (plus the lifecycle trick)
1. **Code identity ← APNs.** Coordinator sends an attestation **push** to the provider's App-ID
   topic; only our genuine, provisioned binary can receive it. Carries an **`E_K(nonce)`**
   (encrypted to the provider's attested key), so a log-snooping root can't relay it.
2. **Locked environment ← MDA/ACME.** Apple-signed proof of **genuine HW + SIP-on + Secure-Boot-
   Full + boot policy** — the thing the binary can't self-attest (self-report is circular). This is
   what makes pillar 1 and the SE-ACL trustworthy (AMFI only enforces while SIP is on).
3. **Continuous binding ← in-memory X25519 key `K`.** Inference is encrypted to `K` (`NodeKeyPair`; a
   raw libsodium key held **only in the genuine process's protected memory** — not SE-backed, not
   keychain-ACL'd). Even a relayed attestation can't help a fake binary: only the genuine hardened
   process can read/use `K`, and its memory can't be read (proven: root `task_for_pid → kr=5` under
   SIP). A **separate persistent SE P-256 key** signs attestations (`Sign_SE`); *that* key is the one
   that is keychain-access-group + SE-non-extractable. The two keys play distinct roles — do not
   conflate `K` (decrypt) with the SE key (sign).
4. **Lifecycle, not polling.** Attest **once per WebSocket connection**. SIP can't be disabled
   without a **reboot**, which **drops the connection** → any downgrade forces a reconnect → forces
   re-attestation (which the MDA check catches). No 5-minute polling — which is *mandatory* given
   the background-push rate limit.

### 3.2 Attestation flow (per connection)
1. Provider (genuine, signed + push-provisioned, Hardened Runtime, **no get-task-allow**, running
   as a **gui-session LaunchAgent**) on launch: creates/loads SE key + X25519 key `K`,
   `registerForRemoteNotifications()` → **device token `T`**, opens **pinned-TLS** WebSocket,
   sends `{X25519 pubkey K, device token T}` (signed by the SE key).
2. Coordinator: binds `T ↔ K` (one-to-one; first genuine registration wins); runs MDA/ACME check
   (with a freshness nonce) → confirms **genuine HW + SIP-on + Secure-Boot-Full**; sends an APNs
   **background push** to `T` with payload `E_K(nonce)` (`apns-priority 5`, `apns-push-type
   background`, short `apns-expiration`). The `nonce` is **single-use, short-TTL, encrypted to this
   connection's `K`**, and must be answered **on the same WebSocket that registered that `K`+`T`** —
   tracked per-connection, **not** in a global serial-keyed map (two connections claiming one serial
   would otherwise race).
3. Provider receives the push (only genuine code can), **decrypts `nonce` with `K`**, and returns
   **the decrypted `nonce` plus `Sign_SE(nonce)`** over the pinned WebSocket (`K` is decrypt-only; the
   signature is the SE P-256 key).
4. Coordinator verifies → marks the connection **code-attested**; routes private inference,
   **encrypting each prompt to `K`**. Holds until disconnect; **re-attest on reconnect.**

### 3.3 Rate-limit handling (driven by Part 1.7)
- **Attest once per connection**, not per request and not polled — push rate ≈ reconnect rate, well
  within ~2–3/hr for stable long-lived connections.
- **Fail-closed:** no code-attestation → provider stays in a non-private/pending state, not routed
  private traffic. (Availability hit, not a security hole.)
- **Per-provider push backoff** + honor `Retry-After`; **one shared JWT** per (Team/Key), refreshed
  ~hourly (avoid `TooManyProviderTokenUpdates`); `apns-expiration` short so stale challenges expire.
- **⚠️ TEST (open risk):** background-push delivery to provider *agents* is best-effort and
  device-budget-throttled — measure real-world **delivery latency/success** on the fleet (plugged-in,
  caffeinated, logged-in Macs may have a healthier budget, but this is *unconfirmed*). **Fallback if
  unreliable:** use an **alert** push (`priority 10`, not background-throttled, reliable & prompt) at
  the cost of requiring notification permission + a benign visible notification — acceptable for an
  *infrequent* per-connection attestation. Decide after measurement.

### 3.4 The MDM-removal question (answered)
- **Push capability needs NO user-installed profile** — the `aps-environment` provisioning profile
  is **embedded in the .app bundle at build time** (invisible to the user).
- **SIP attestation still requires a user-installed config profile** — it's the only Apple-signed
  "SIP is on" oracle; **not removable** for the hard guarantee.

**⚠️ Correction (verified against the code — do NOT slim enrollment as part of this feature):** the
earlier "slim to ACME-only" plan is **deferred and decoupled**. Three findings from the code map make
removing the MDM payload *unsafe today*:
- The **only trustworthy, non-circular SIP/Secure-Boot signal is the Apple-signed MDA**
  (`attestation/mda.go` parses OID `.13.1`/`.13.2`), and **MDA is obtained via an MDM command**
  (`DeviceInformation`, `verifyAppleDeviceAttestation`). The **ACME step-ca cert carries no SIP OIDs**.
- The **ACME→hardware path is non-functional today**: P-384 cert vs the P-256-only SE; no mTLS ingress
  populates the `X-Ssl-Client` headers `acme_verify.go` reads; the HardwareBound cert lands in an
  Apple-only keychain group. The operative prod hardware-trust path is the **MDM SecurityInfo
  cross-check** (`verifyProviderViaMDM`).
- Per §3.0, **`K`-confidentiality and prompt-confidentiality both rest on SIP-on**, which is *only*
  provable via that Apple-signed MDA. Pull MDM and you don't just lose pillar 2 — you lose the
  attestation that `K` and every plaintext prompt are actually unreadable.

Net: **keep MDM, ship APNs** (the code-identity feature needs zero enrollment changes). MDM-removal
becomes a **separate later project** that must first make ACME `device-attest-01` actually carry +
verify the SIP OID (and add mTLS ingress + provider-side key-identity), at which point the
no-management UX win is real. The provider already self-reports SIP in the SE-signed challenge, but
that is **circular** against a malicious operator — it is liveness, not proof.

### 3.5 Trust model & honest residuals
- Root of trust = **Apple's silicon/attestation + our control of our Apple signing identity**
  (Developer-ID key, provisioning, APNs `.p8`). **These become crown jewels** — HSM/least-access/
  monitoring; their compromise breaks the scheme (that's "compromise the trusted party").
- **Insider** with our signing key could sign passing code → mitigated by **reproducible build +
  public transparency log** of blessed cdhashes (so the binary is community-auditable, not just
  team-signed). This is also why APNs *upgrades* the previously-worthless self-reported `binaryHash`
  into a real check: once APNs proves it's our genuine unmodified code, that code's self-reported
  cdhash is trustworthy → pair with the transparency log for version/downgrade control.
- **R-snoop (log/disk harvest of the challenge) — verified closed on current macOS** (§1.6.1): the
  encrypted payload is redacted (`<private>`) in the unified log and absent from every on-disk store
  (apsd store, Notification Center DB) for background **and** alert pushes; CLI un-redaction is
  removed on macOS 26.4. **Alert mode is safe only because the provider requests no
  `UNUserNotificationCenter` authorization** — an invariant enforced by code review + comments at
  both ends. Residual: a determined attacker on their own hardware could manually enable private-data
  logging via the GUI **and** harvest a genuine token **and** race the `T↔K` registration.
- **Irreducible:** requires a logged-in GUI session; APNs delivery is best-effort (availability, not
  confidentiality); and the whole thing assumes SIP-on, which we attest but the user could lower
  (→ caught by MDA → fail-closed).

---

## Part 4 — Code changes required (drastic), by component

Legend: **[NEW]** new code/subsystem · **[CHG]** significant change · **[BUILD]** build/signing/portal.

### 4.1 Build, signing & Apple portal **[BUILD]** — prerequisite for everything
- Apple portal: enable **Push Notifications** on App ID `io.darkbloom.provider`; create an **APNs
  `.p8` auth key** for the team; generate a **push-enabled provisioning profile**.
- `provider-swift/entitlements.plist` **[CHG]**: add `com.apple.developer.aps-environment`
  (`production`). Keep hypervisor + keychain-access-groups. **Assert NO `get-task-allow`.**
- `.github/workflows/release-swift.yml` **[CHG]**: embed the push provisioning profile in the
  `.app`; sign with it (keep `--options runtime` + notarize + staple); **add a CI assertion that the
  signed binary has no `get-task-allow`** and that `aps-environment` is present; (later) make the
  build **reproducible** + publish the cdhash to a **transparency log**.

### 4.2 Provider (Swift) **[CHG/NEW]** — the most architectural change
- The serve path must host an **`NSApplication` run loop in `.accessory` mode** so the agent can
  `registerForRemoteNotifications()` and receive `didReceiveRemoteNotification`. Today the process
  stays alive parked on `for await event in events` (`ProviderLoop.swift:386`) — there is **no**
  AppKit/run loop. AppKit must own the **true main thread** (mutually exclusive with the
  `@main AsyncParsableCommand` main-task drain), so a custom main-thread entrypoint: parse args →
  build `NSApplication` + delegate `.accessory` on the main thread → launch `ProviderLoop.run()` as a
  child `Task` → `app.run()`. The inference/WS loop body itself **does not change** — only *where* it
  is launched. Applies to **all three** long-lived serve paths (`runForeground:219`,
  `runScheduled:372`, `runLocalStandalone:123`). *(This is the single biggest provider-side change.)*
  - **✅ DAY-1 COEXISTENCE SPIKE — architecture PROVEN** (`apns-r2-probe/coexist.swift` +
    `run-coexist.sh` / `verify-delivery.sh` / `verify-open.sh`, M4 Max, macOS 26.5). In ONE process:
    `NSApplication(.accessory)` owned the main thread, a sustained MPS matmul loop (the same Metal path
    MLX rides) ran **110,710 iters / 178s (~620 matmul/s)** on a background thread, the **main run-loop
    heartbeat ticked all 175×** (no starvation), and the APNs **register callback fired on main →
    device token** — all concurrently. The Layer-1 rehost (`app.run()` on main + `Task { loop.run() }`
    off-main) is sound. The current provider does **not** use Hypervisor.framework (`hypervisorActive`
    hardcoded `false`), so the only coexistence question was GPU × AppKit-main × APNs → passes.
  - **The GPU-suppresses-push-receipt hypothesis is REFUTED**: in a controlled test, push receipt failed
    **idle too** (not just under load), so the receipt miss is independent of GPU. Receipt also failed
    across single-clean-registration, LaunchServices `open`-launch, alert (prio 10), and store-and-forward
    — with `apsd` logging **nothing** for the topic. ⟹ today's receipt failure is a **degraded device/APNs
    delivery state** for this heavily-abused test token (dozens of re-signs, incl. adversary-team
    re-signing of the same bundle id — likely poisoned apsd's per-bundle subscription), **NOT** an
    architecture/coexistence problem. Receipt was proven end-to-end in an earlier session.
  - **✅ RECEIPT CONFIRMED end-to-end on a fresh device (M5 Max, macOS 26.4):** app signed here
    (Developer ID + `perstest` profile, which is `ProvisionsAllDevices`), copied to the M5, launched in
    the GUI session via `launchctl asuser 501`, got a fresh device token, and a **single
    background/silent push (prio 5, `content-available`) — the real attestation channel — was received
    on the FIRST try**, nonce matching exactly. ⟹ the push round-trip works end-to-end; this laptop's
    earlier misses were **rate-limit / poisoned device-state** (a burned test token re-signed dozens of
    times incl. under a different team), **not** the mechanism, registrations, launch method, or GPU
    load. The whole spike (coexistence **+** receipt) is now closed. Scripts:
    `apns-r2-probe/run-m5-test.sh` (sign-here/run-there/send-here, no secret moved to the M5).
  - **Device-token ordering:** the token arrives **async** (`didRegisterForRemoteNotifications…`) after
    `registerForRemoteNotifications()`, but Register is sent synchronously at connect
    (`ProviderLoop.swift:346-369`) → either await the token before Register, or deliver it in a
    follow-up message. Plus a delegate→actor bridge so the main-thread callback hops into the
    `ProviderLoop` actor to decrypt with `K` and answer via `SendHandle`.
- **[NEW]** APNs module: register for remote notifications, capture the **device token**, hand it to
  the coordinator client; implement the delegate to receive the push, **decrypt `E_K(nonce)`** with
  the X25519 `NodeKeyPair` (`K`), and return **the decrypted nonce + `Sign_SE(nonce)`** (SE signing
  key) over the WebSocket. (There is no `Sign_K` — `K` is decrypt-only.)
- `ProviderCore/Service/LaunchAgent.swift`: already gui-domain ✓ — confirm `.accessory`/`LSUIElement`
  and that it runs in the logged-in session; document the "must be logged in" requirement.
- `Security/AttestationBuilder.swift`: keep the SE attestation; **stop treating self-reported
  `binaryHash` as security** (drift-only); add the push-challenge response path.

### 4.3 Protocol **[CHG]** — `coordinator/protocol/messages.go`
- `RegisterMessage` (+ Swift mirror): add **`APNsDeviceToken string`** (and APNs environment).
- Repurpose/extend the attestation messages: the **code-identity challenge now travels via APNs
  push** (carrying `E_K(nonce)`), and the **response** returns over the WebSocket. The existing
  WS `AttestationChallengeMessage`/`AttestationResponseMessage` (nonce+timestamp signed by SE key)
  **remains for liveness/status only — it is NOT a code-identity proof.** Keep protocol symmetry
  (Go + Swift).

### 4.4 Coordinator **[NEW/CHG]**
- **[NEW]** `coordinator/apns/` package: load the `.p8`, mint/cache **one JWT per (Team/Key)
  ~hourly**, HTTP/2 sender to APNs, `E_K(nonce)` build (reuse `internal/e2e.Encrypt` to the
  provider's `K`), **429/Retry-After + per-provider backoff** handling, `apns-expiration` short.
  **Build the sender dual-mode from day one** — background (`apns-push-type background`, priority 5)
  vs alert (priority 10) differ only by two headers; expose it as config behind the
  `CodeIdentityAttestor` seam so the unmeasured background-reliability risk becomes a **flag flip**,
  not a rearchitecture, and can be measured on the fleet in parallel.
- `api/provider.go` **[CHG]**: on register, store `APNsDeviceToken`, bind `T ↔ K`; add a
  **push-based code-identity attestation step** at connection (send push, await WS response, mark
  connection code-attested). The existing `challengeLoop`/`sendChallenge` (WS) becomes
  **liveness/status only**. Gate **private-tier routing** on code-attested == true (fail-closed).
- `registry/registry.go` **[CHG]**: `Provider` struct add `APNsDeviceToken` + a `CodeAttested`
  state (**in-memory only, default false, reset on disconnect** — mirror `untrustedRecoverable`,
  never persisted). Gate at the **single chokepoint `providerSupportsPrivateTextLocked`** (one edit
  propagates to all ~11 routing/capacity/warm sites). **Note:** there is no separate "private tier" —
  *all* text/image/STT/embeddings routing already funnels through this predicate, so gating it on
  `CodeAttested` is strictly **fail-closed** (nothing routes until attested). **Self-route decision:**
  this also blocks an owner routing to their *own* un-attested Mac; if self-route should be exempt, add
  an explicit per-request flag mirroring `SelfRouteOnly` — do not rely on `relaxTrust` (it lowers the
  trust floor but does not bypass the chokepoint).
- **`binaryHash` demotion is demote-not-delete:** `binary_hash` is **inside the SE-signed status
  canonical** (`AttestationBuilder.swift` ↔ `attestation/attestation.go BuildStatusCanonical`).
  **Do NOT remove it or change the canonical bytes** — that re-triggers the Go/Swift canonical-drift
  ECDSA failures this repo has hit. Only **stop the coordinator from treating it as a trust/routing
  signal** (`verifyProviderAttestation:1685-1712`, `verifyChallengeResponse:835-884`); keep it as
  drift-detection telemetry. Also decide whether the release-build hard-startup-abort on an empty
  `binaryHash` (`ProviderLoop.swift:476-479`) stays.
- **[NEW]** `CodeIdentityAttestor` interface (seam): one impl today
  (`APNsPushAttestor` fusing APNs + MDA + `K`-binding); future drop-in (`AppAttestAttestor`) if
  Apple ever ships it. Routing/key-release depend only on the interface.

### 4.5 Enrollment — **DEFERRED, out of scope for this feature** (`coordinator/api/enroll.go`)
- **No change.** Per §3.4, slimming the `.mobileconfig` to ACME-only would remove the only working
  Apple-signed SIP attestation (MDA-over-MDM), which the APNs code-identity scheme depends on. The
  code-identity feature requires **zero** enrollment changes. Revisit as a separate project after
  ACME `device-attest-01` is made to carry+verify the SIP OID (+ mTLS ingress + provider key-identity).

### 4.6 Client / console-ui (later, for the strongest variant)
- Move attestation **verification client-side** (verify the transparency-log proof + MDA before the
  prompt is exposed), shrinking reliance on the coordinator-CVM. (PCC-style; optional, phase 2.)

---

## Open risks / test next
1. **⚠️ Background-push delivery reliability to provider agents** — measure on the fleet; decide
   background vs alert push. *This is the top open risk* — and the spike reinforced it: on a repeated
   ad-hoc test today, **both background (prio 5) and alert (prio 10) pushes were accepted by APNs (HTTP
   200) but never reached the device** (`apsd` logged nothing; nonce absent from the unified log) — even
   though the *same* harness delivered successfully in an earlier session. Two confounds make the ad-hoc
   harness a poor *delivery* testbed (it's fine for token/coexistence): (a) the app is **directly-exec'd
   and rebuilt each run**, leaving **multiple stale LaunchServices registrations** for one bundle id,
   which breaks delivery routing; (b) device-side background budget/APNs-connection state varies.
   **→ Real measurement must use a single, properly-installed app** (one LS registration, launched via
   the LaunchAgent/`open`, real bundle id + push profile, notification permission for alert mode) **on
   the fleet.** The sender is already prototyped **dual-mode** (`send-push.swift --alert` / `--expiration`)
   so background-vs-alert is a flag flip. Until measured, **fail-closed** is the safe default.
   **Encouraging data point (M5 Max, fresh device):** a single background/silent push delivered
   **promptly on the first try** to a healthy, plugged-in, logged-in Mac — i.e. our exact provider-fleet
   profile — so the background channel is viable for the once-per-connection cadence (well within the
   ~2–3/hr budget). What remains to measure at scale is delivery *variance over time / across the fleet*
   (sleep/wake, Low Power Mode, long-idle), not whether background delivery works at all.
2. **GUI-session dependency — RESOLVED by policy.** APNs app-push needs a logged-in Aqua session;
   product decision is to **require providers to be logged in before starting the machine** (the
   LaunchAgent already runs gui-domain). Headless/login-screen Macs simply fail-closed (won't
   code-attest, won't be routed). No longer an open *risk* — an onboarding requirement to document.
3. **Phase 2 (optional):** prove the bypass — disable SIP/AMFI in recoveryOS and show the protections
   collapse (fork receives the push, root reads the process, ACL falls) → the empirical proof the
   ACME profile is load-bearing. Needs physical recoveryOS + ideally a spare machine.
4. **Provisioning-profile validity for push under Reduced/Permissive** — confirm a downgraded
   machine's MDA reflects it (expected) so fail-closed holds.
