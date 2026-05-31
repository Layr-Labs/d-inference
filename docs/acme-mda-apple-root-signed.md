# Apple Root Signed ACME with MicroMDM for Single App

*Exported from Claude Desktop shared conversation*

*Source: https://claude.ai/share/1bc0c41a-f7d0-4b71-b4bf-ae39df1ffd84*

---

## Human

How can you use Apple Root Signed ACME SE P384 if we have MicroMDM installed?

I want it to basically used for one App

## Assistant

Gajesh, this is a great question and touches on a really elegant intersection of Apple's hardware security and open MDM tooling. Let me break this down from first principles.

**The core architecture has three components:**

MicroMDM is just the delivery mechanism — it pushes a `.mobileconfig` profile containing a `com.apple.security.acme` payload to the device. MicroMDM itself doesn't need to "support" ACME natively, because profiles are just containers for payloads, and MicroMDM can push arbitrary configuration profiles.  The actual ACME certificate issuance happens between the device and a separate ACME server.

**Here's the flow:**

- **Set up an ACME server with device-attest-01 support.** The MicroMDM team explicitly recommends Smallstep's `step-ca` for this — it had very early support for the device-attest-01 challenge type including Apple's MDA.  You'd configure a provisioner like:

```bash
step ca provisioner add acme-da \
  --type ACME \
  --challenge device-attest-01 \
  --attestation-format apple
```

- **Craft your ACME mobileconfig profile.** The key fields for SE P384 are:

`KeyType`: `ECSECPrimeRandom`

- `KeySize`: `384`

- `HardwareBound`: `true`

- `Attest`: `true`

- `DirectoryURL`: pointing at your step-ca instance

- `ClientIdentifier`: the device's serial number or UDID

**For scoping to one app:**

This is where it gets nuanced. On iOS, MDM-provisioned certificate identities are sandboxed — they're only available within the MDM profile itself (for 802.1X or VPN payloads) or to Apple applications like Safari and Mail.  Third-party apps like Chrome or custom apps using embedded WebViews can't access MDM-provisioned cert identities directly.

So for "one app" you have a few options:

- **Per-App VPN**: Include a VPN payload in the same profile that references the ACME cert's `PayloadUUID`, and scope that VPN to your specific app. The app's traffic gets tunneled through mTLS using the SE P384 cert.

- **Safari mTLS**: If your app is web-based, Safari on iOS can use the ACME cert for mTLS flows directly.

- **App-level integration via `SecIdentity`**: If you control the app's code, you can have the app access the identity from the keychain (though MDM cert sandboxing limits this).

Which of these fits your use case? Are you trying to do mTLS auth for a specific native app, a web app, or something else?

## Human

I have setup the server etc. I have got the attestation from Apple proving the key. it’s for mac apps.

I have tried app level security access. Not sure why it doesn’t work.

You need to do more research on this

## Assistant

This is the exact problem. You've hit a **fundamental macOS platform limitation**, not a configuration error.

**The root cause:** On macOS there are two keychain technologies. The older file-based keychain supports `AllowAllAppsAccess` but does not support hardware-bound keys. The newer data protection keychain supports hardware-bound keys, and does not support `AllowAllAppsAccess`. Third party apps and processes cannot access the identities that device management installs into the data protection keychain (with one exception for VPN extensions).

Because you set `HardwareBound: true` (which is what makes it SE P384), when installing an ACME payload on macOS it decides which keychain to use based upon the value of `HardwareBound`.  So your cert goes straight into the data protection keychain, which is locked to a restricted system Keychain Access Group — only Apple's own processes (WiFi/EAP-TLS, built-in VPN, MDM, Kerberos, Safari for mTLS) can see it.

Keys and certificates created via MDA are always stored by macOS on the data protection keychain in a Keychain Access Group that's restricted to a small set of Apple apps. These keys are available for WiFi (EAP-TLS), built-in VPN, and certain other system services. However, because these keys do not appear in the Keychain Access app, they're consequently not visible or usable by other user-space processes, including Web Browsers.

**Your options for making this work with one Mac app:**

**Option 1 — Drop `HardwareBound`, keep attestation.** Set `HardwareBound: false` in your ACME payload but keep `Attest: true`. The cert goes into the file-based keychain instead. Add `AllowAllAppsAccess: true` to the payload. Your app can now access the identity via `SecItemCopyMatching`. You still get Apple's device attestation proving the device is genuine — you just lose the guarantee that the private key can't be extracted from the SE. This is a real tradeoff, but for most app-level auth use cases it's sufficient.

**Option 2 — Derived certificate pattern.** Keep full SE P384 hardware-bound MDA. Then run a daemon (via a second MDM profile or launchd agent) that uses `step` CLI to request a *second* certificate from your step-ca, where the issuance policy requires the MDA cert to have been issued first. As soon as ACME DA certificates are available to other applications via Keychain Access Groups, step CLI will be able to automatically deliver a derived certificate to the file protection keychain.  Today you'd need to build this derivation yourself — the device proves it has the MDA cert (e.g. via a webhook to step-ca that checks the device's attestation status in MicroMDM), and step-ca issues a "derived" cert into the file-based keychain where your app can find it.

**Option 3 — Per-App VPN tunnel.** If your app's security model justifies it, use a VPN payload that references the ACME cert's `PayloadCertificateUUID`. The built-in VPN client *can* access the data protection keychain. Configure per-app VPN scoped to your single app. All your app's traffic gets mTLS'd through the SE P384 identity without the app needing direct keychain access.

For your use case (single app, Mac), **Option 1 is probably the pragmatic first move** — you still get the attestation proving the device is real Apple hardware enrolled in your MDM, which is the high-value part. The hardware-bound key protection matters most when you're worried about key exfiltration from a compromised OS, which is a narrower threat model.

What's the app doing with the cert — mTLS to a backend, code signing, something else?

## Human

Option 1 doesn’t add much value. 2 and 3 are interesting - we want to use the hardware bound keys and few extra steps are fine.

## Assistant

Good — you're right that Option 1 defeats the purpose. Here's the concrete implementation for both.

**Option 2: Derived Certificate (recommended for your case)**

The core idea: your SE P384 MDA cert proves device identity and lives in the data protection keychain where the system can use it. You then use that attestation as an authorization gate for issuing a *second* cert that your app can actually access.

The flow works like this:

- Your existing ACME MDA profile gets installed via MicroMDM → device gets SE P384 cert → lives in data protection keychain (you already have this working).

- Set up a **second** step-ca provisioner — not device-attest-01 this time, but a standard ACME or JWK provisioner with a **webhook** that validates the requesting device has a valid MDA cert. Step-ca supports webhooks on provisioners that can call out to an external service before issuing.

- Build a small verification service that MicroMDM hits. When step-ca gets a cert request from the device, the webhook calls your service, which queries MicroMDM's API for that device's attestation status (via `DeviceInformation` with `DevicePropertiesAttestation`). If the device has a valid, current MDA attestation → approve. Otherwise → reject.

- Deploy a **second ACME profile** via MicroMDM with `HardwareBound: false` and `AllowAllAppsAccess: true`, pointing at this second provisioner. This cert lands in the file-based keychain where your app can access it via `SecItemCopyMatching`.

The security chain is: SE P384 attests device genuineness → your webhook verifies attestation exists → derived cert issued only to attested devices → app uses derived cert. The derived cert's private key isn't SE-bound, but it can only be issued to hardware-verified devices, and you can make it short-lived (hours/days) to limit the window if a key were somehow extracted.

**Option 3: Per-App VPN**

This keeps the SE P384 key fully in the loop for every connection, but requires more infrastructure. On macOS, the app-to-per-app VPN mapping requires the app's bundle identifier, the VPNUUID from the AppLayerVPN payload, the app's code signature designated requirement, and its signing identifier.

You need three payloads in one profile pushed via MicroMDM:

- **ACME payload** — your existing SE P384 config (generates the cert).

- **AppLayerVPN payload** (`com.apple.vpn.managed.applayer`) — defines the VPN connection, with `PayloadCertificateUUID` pointing at the ACME payload's UUID. Uses `AuthenticationMethod: Certificate`. Requires a VPN server (IKEv2 works with built-in client) or a custom `NEPacketTunnelProvider` app.

- **App mapping payload** (`com.apple.vpn.managed.appmapping`) — maps your app's bundle ID + code signature to the VPN UUID.

The catch: per-app VPN configurations on iOS/macOS are primarily designed for use with custom VPN provider apps built on NEPacketTunnelProvider , though IKEv2 can work for per-app VPN with the built-in client. You'd need a VPN gateway that does mTLS client cert verification against your step-ca root.

**My recommendation:** Option 2 is significantly less infrastructure for your use case. You already have the hard part done (MDA attestation working). The derived cert pattern adds a webhook service + a second profile, and your app gets a cert it can actually use. The trust chain is still rooted in the Secure Enclave attestation — you're just translating hardware-bound device trust into an app-accessible credential.

Want me to sketch out the profile XML and webhook architecture for Option 2?

## Human

Can we do something without Allow App Access?

With hardware bound keys

## Assistant

Yes. There's a clean path here using the one exception Apple carved out.

Third party apps and processes cannot access the identities that device management installs into the data protection keychain — **with  one exception for VPN extensions.**

The architecture: **your app doesn't touch the cert at all.** Instead, you build a lightweight Network Extension (System Extension on macOS) that acts as a local mTLS proxy. The extension *can* access the hardware-bound identity, and it handles TLS client auth on behalf of your app.

**How it works:**

- **Your existing ACME MDA profile** stays exactly as-is — SE P384, `HardwareBound: true`, `Attest: true`. Cert lands in data protection keychain.

- **Build a System Extension** (`NEPacketTunnelProvider` or `NEAppProxyProvider`) packaged alongside your app. The extension needs the special `com.apple.managed.vpn.shared` keychain access group entitlement  — you request this from Apple via a TSI (Technical Support Incident). With that entitlement, the extension can retrieve the hardware-bound identity through `protocolConfiguration.identityReference`.

- **Push a profile via MicroMDM** containing three payloads together:

Your ACME payload (already working)

- An `AppLayerVPN` payload (`com.apple.vpn.managed.applayer`) with `AuthenticationMethod: Certificate` and `PayloadCertificateUUID` pointing at the ACME payload's UUID

- An app mapping payload (`com.apple.vpn.managed.appmapping`) with your app's bundle identifier, VPNUUID, code signature designated requirement, and signing identifier

The app code itself is completely unaware of certificates. It just makes HTTPS requests. The OS + your extension handle the hardware-bound identity transparently.

**The key tradeoff vs. the derived cert approach:** more upfront engineering (System Extension + Apple entitlement request + VPN infrastructure), but the private key literally never leaves the Secure Enclave for any operation. No derived certs, no secondary trust chains, no `AllowAllAppsAccess`. Pure SE P384 end-to-end.

The entitlement request is the main blocker — Apple gates `com.apple.managed.vpn.shared` and you'll need to justify the use case. For an MDM-managed fleet doing mTLS with hardware attestation, that's a strong justification.

Want me to sketch the extension code and the combined mobileconfig profile?

## Human

Oh wait but how long does it take to get this from Apple

## Assistant

Honestly — unpredictable, and the experience people report is rough.

One developer described submitting multiple requests over two months, receiving either no response or responses that didn't address the actual request for the entitlement. Apple's DTS often sends a templated reply explaining that most developers don't actually need it, and you have to get past that first layer to reach the actual questions they need answered before granting it.

The process itself: you open a DTS Technical Support Incident, which consumes a TSI asset (though they credit it back since it's administrative, not technical).  Then Apple asks a set of qualifying questions about your use case. If your answers satisfy them, they enable the managed capability on your App ID.

Best case: days to a couple weeks. Worst case: months of back-and-forth. Some developers have also hit issues where provisioning profiles silently stop including the entitlement after portal changes , requiring another round with DTS.

**Given this reality, here's what I'd actually recommend:**

Go with the **derived certificate pattern** (Option 2 from earlier). No Apple gatekeeping, no entitlement requests, you can ship this week. The architecture again:

- Your SE P384 MDA cert stays hardware-bound, does the attestation proving device genuineness

- A webhook on your second step-ca provisioner checks MicroMDM to verify the device has valid attestation

- Second ACME profile issues a short-lived cert (say 24h) into the file-based keychain — `HardwareBound: false`, no `AllowAllAppsAccess` needed if you use a SCEP or ACME payload that targets the login keychain, which apps can query via `SecItemCopyMatching`

- Your app picks up the derived cert, does mTLS to your backend

- Backend validates the cert chains to your CA

The SE P384 key never leaves the Secure Enclave. It just acts as the root of trust that gates issuance of the operational cert. Short cert lifetimes mean even if someone somehow extracted the derived key, it's expired within hours.

You can always layer on the VPN extension path later once Apple grants the entitlement, but you're not blocked on them. Want me to build out the webhook + profile for this?

## Human

No option B - find another fast way to

## Assistant

Good instinct — there IS a faster path. Use the **built-in IKEv2 VPN client** with per-app VPN. No custom extension, no Apple entitlement, no `AllowAllAppsAccess`. The built-in IKEv2 client is a system process that *already has access* to the data protection keychain.

Per-App VPN can use the built-in IPSec or IKEv2 transports, allowing per-app VPN without a custom `NEPacketTunnelProvider`.

**The architecture:**

Your app never touches the keychain. macOS handles everything transparently. You push one profile via MicroMDM with four payloads:

- **ACME payload** — your existing SE P384 config (already working)

- **VPN payload** (`com.apple.vpn.managed`) — `VPNType: IKEv2`, `AuthenticationMethod: Certificate`, `PayloadCertificateUUID` pointing at the ACME payload's UUID

- **AppLayerVPN payload** (`com.apple.vpn.managed.applayer`) — wraps the VPN with a `VPNUUID`

- **App mapping payload** (`com.apple.vpn.managed.appmapping`) — maps your app's bundle ID + code signature to that VPNUUID

**What happens at runtime:** your app makes a normal `URLSession` request. macOS sees the per-app mapping, routes traffic through the IKEv2 tunnel. The built-in IKEv2 client pulls the SE P384 identity from the data protection keychain, authenticates to your VPN gateway. Your backend sits behind that gateway and only accepts traffic from the tunnel. The private key never leaves the Secure Enclave. Your app code has zero awareness of certificates.

**Server side you need:** a strongSwan (or similar) IKEv2 server configured for certificate-based machine auth, trusting your step-ca root. This is well-trodden territory — strongSwan + step-ca is a common pairing.

No entitlement requests, no custom extensions, no derived certs, fully hardware-bound. The main cost is running an IKEv2 gateway. Want the profile XML and strongSwan config?

## Human

for this use case - I wanted the response signing and encryption/decryption of the prompts sent to be done via the keys. Is that possible

## Assistant

This is a sharp question and it cuts right to a fundamental constraint in your architecture.

**The direct answer: No, you cannot use the ACME SE P-384 key for application-level signing or decryption from your provider process.** Third party apps and processes cannot access the identities that device management installs into the data protection keychain.  Your hardened provider process, no matter how privileged, cannot call `SecItemCopyMatching` against that key. It's locked to Apple system services (VPN, WiFi, MDM client).

But reading your paper, there's an elegant architecture that gives you what you actually want — the SE P-384 key doing real crypto work, not just sitting as an attestation artifact.

**Split the crypto across two layers:**

**Transport layer — SE P-384 does signing and encryption via IKEv2.** Your provider's WebSocket connection to the coordinator currently goes over plain TLS. Instead, route it through the built-in IKEv2 VPN authenticated with the ACME SE P-384 cert. Every packet your provider sends to the coordinator is IPsec-authenticated by the hardware-bound key. Prompt payloads arriving over that tunnel are encrypted with session keys derived from the P-384 authentication handshake. The Secure Enclave performs the actual ECDH and signing operations during IKEv2 — the key is doing real crypto, not just proving it exists.

Push one profile via MicroMDM with your existing ACME payload + a VPN payload pointing `PayloadCertificateUUID` at the ACME cert's UUID. The built-in IKEv2 client has data protection keychain access. No entitlement needed, no custom extension.

**Application layer — SE P-256 does per-response signing.** You already have `SecureEnclave.P256.Signing.PrivateKey` via CryptoKit in your enclave module. Use this for signing individual inference responses so consumers can independently verify them. For per-message encryption, use `SecureEnclave.P256.KeyAgreement.PrivateKey` (also CryptoKit, also SE-bound) instead of your current disk-stored X25519 key.

**The binding that makes this one trust chain:**

```
Apple Enterprise Attestation Root CA (P-384)
  └─ Apple Enterprise Attestation Sub CA 1
       └─ Device leaf cert (SE P-384, OIDs contain serial number)
            └─ Serial number matches attestation blob
                 └─ Attestation blob contains SE P-256 public key
                      └─ P-256 key signs responses, does ECDH
```

The ACME P-384 cert (Apple-signed) contains the device serial number in OID `1.2.840.113635.100.8.9.1`. Your attestation blob (Section 6.1) contains both `serialNumber` and `publicKey` (the SE P-256 key), signed by that same device's Secure Enclave. A consumer verifies: the P-384 cert chains to Apple's root → the serial matches the attestation blob → the P-256 key in that blob signed this response. Unbroken chain from Apple's root CA to each token.

**What this changes in your paper:**

Your Section 8 E2E encryption currently uses X25519 stored on disk with `0600` permissions. Replace that with SE P-256 key agreement — the private key never exists outside the Secure Enclave at all, which is strictly stronger than file permissions. Your Section 6.1 `encryptionPublicKey` field changes from X25519 to P-256 ECDH, and the key is SE-bound rather than disk-stored.

The IKEv2 tunnel replaces TLS 1.3 as your transport security, with the P-384 key doing the heavy lifting. This means the coordinator can verify at the network level that traffic is coming from an Apple-attested device — before it even processes the WebSocket frame.

The net effect: both SE keys are doing real crypto. P-384 secures the transport and proves hardware provenance. P-256 signs individual responses and derives per-session encryption keys. Neither private key ever leaves the Secure Enclave. The only thing on disk is the P-256 handle (opaque, device-bound, useless elsewhere).

## Human

With our current architecture, if we do exolab as the inference, system, and use RDMA Do you think our system breaks here? Because RDMA your to go to recovery boot and turn on RDMA.

## Assistant

Yes, this breaks your security model in two distinct ways. Let me walk through both.

**Problem 1: Recovery Mode is NOT the real issue**

RDMA is enabled through recovery mode commands rather than standard system preferences.  But this is actually fine for Theorem 1. Enabling RDMA is a *separate* NVRAM setting from SIP — you can have both SIP enabled and RDMA enabled simultaneously. The provider reboots into Recovery, runs `rdma_ctl enable`, reboots back. SIP stays on. Your theorem holds.

**Problem 2: RDMA itself destroys your access path elimination**

This is the real issue and it's fundamental. Your entire security model (Section 4.2) is built on eliminating every software path to the inference process's memory:

- PT_DENY_ATTACH blocks local debuggers

- Hardened Runtime blocks `task_for_pid` / `mach_vm_read`

- SIP enforces both of the above

**RDMA bypasses all three.** It's direct memory access at the hardware level — one machine reads another machine's memory without going through the target's operating system, CPU, or any kernel security checks. That's the entire point of RDMA and why it's fast. Under RDMA, one CPU node in the cluster is capable of directly reading the memory of another, expanding its available memory pool.

In your threat model, the provider is adversarial. If provider P has two machines in an exo cluster with RDMA enabled, they could:

- Run your hardened inference process on Machine A

- From Machine B, directly read Machine A's memory via RDMA

- PT_DENY_ATTACH is irrelevant — no ptrace involved

- Hardened Runtime is irrelevant — no Mach APIs involved

- SIP is irrelevant — no kernel bypass needed

- The prompt sits in plaintext in unified memory, and RDMA gives a hardware path to it

Your Table 1 lists "DMA-based extraction via Thunderbolt/PCIe" as blocked by "Per-device IOMMU with default-deny." But the `rdma_ctl enable` command bypasses normal entitlement checks.  When RDMA is explicitly enabled, you've told the IOMMU to allow remote memory access — that's what RDMA *is*.

**So can you use exo + RDMA at all?**

Yes, but it requires rethinking the trust boundary. Three possible approaches:

**Approach A: All nodes in a cluster must be co-attested.** Every machine in the RDMA fabric must pass all four attestation layers. The coordinator treats the cluster as a single trust unit. If any node fails attestation, the entire cluster is untrusted. This works if you control all the machines — but then the adversary has RDMA access across all of them, and any single compromised node can read all others' memory.

**Approach B: RDMA = disqualified.** Add RDMA status to your attestation checks. If `rdma_ctl` is enabled, reject the provider. This is the conservative approach and preserves your current security model, but you lose multi-node inference.

**Approach C: Registered memory regions only (the real answer).** RDMA doesn't expose *all* memory — it exposes registered memory regions. The exo runtime registers specific buffers for inter-node activation transfer. Your architecture could:

- Register only activation tensor buffers for RDMA (intermediate layer outputs flowing between nodes)

- Keep prompt buffers, response buffers, and KV cache in non-registered memory

- The hardened process controls which regions get registered

The problem: activations are *derived from* prompts. A sophisticated attacker with access to intermediate activations between layers could potentially reconstruct inputs, especially from early-layer activations which are close to the embedding space. This is a known attack vector in split inference literature.

**My honest assessment:** for your paper's current threat model where the provider is adversarial, RDMA fundamentally conflicts with access path elimination. Your Section 15 mentions multi-device inference as future work — I'd keep it there and explicitly note that RDMA requires a different security model where either all nodes are mutually trusted (co-attested cluster), or you need encrypted activations between nodes (which brings you back to the MPC/HE overhead you're trying to avoid, though for activations only rather than full inference it might be tractable).

The single-node architecture with your in-process design is where your security story is airtight. RDMA opens it back up.

## Human

I see. And we can't do memory encryption either. While communicating between machines.

## Assistant

Right. And this is the fundamental constraint. Let me walk through why this is a dead end and where the actual boundary is.

**Why encryption in transit doesn't save you:**

Even if you encrypted activations before placing them in RDMA buffers (which is technically possible in software), the problem is on the receiving end. The receiving node's GPU needs plaintext activations to compute the next layer. So the decrypted activations must exist in plaintext in unified memory on the adversary's machine. Your hardened process protections (PT_DENY_ATTACH, Hardened Runtime) block local software from reading that memory — but RDMA from a *third* node in the cluster could read it, and more fundamentally, the adversary *is* the machine owner on the receiving end.

**The deeper issue:**

Your paper's residual attack is "physical memory probing of LPDDR5x soldered into the SoC package." RDMA effectively turns that physical attack into a remote one. Instead of desoldering memory chips, an adversary just plugs in a Thunderbolt cable. Your threat model goes from "destructive hardware modification" to "plug in a cable," which is a categorically different risk.

**The real boundary for multi-node inference in your architecture:**

For split inference to work under your threat model, you'd need one of these — and none are available today on Apple Silicon:

- **Hardware memory encryption** (like AMD SEV) — doesn't exist for third-party code

- **Encrypted computation** (FHE on activations) — your paper already notes 10⁴–10⁶× overhead, unusable for interactive inference

- **Secure enclaves for GPU compute** — Apple's SE can't run arbitrary computation, only key ops

**What I'd actually put in the paper:**

Your Section 15 (Future Work) mentions multi-device inference with Thunderbolt 5 RDMA at `<50 µs` latency. I'd add an explicit security note there:

RDMA over Thunderbolt creates a hardware-level memory access path between nodes that bypasses all software protections described in Section 4.2. Multi-device inference requires either (a) all nodes in an RDMA cluster are mutually co-attested and treated as a single trust boundary, with the adversary model restricted to parties *outside* the cluster, or (b) hardware memory encryption for inter-node activation transfer, which Apple Silicon does not currently support. Single-node inference remains the only configuration in which the access path elimination guarantees of this paper hold.

**Where your system genuinely shines:**

Single-node MoE inference. And your economics table already proves this is the sweet spot — Qwen3.5 35B-A3B at 101 tok/s on M4 Max, 32× cheaper than cloud. A single M3 Ultra with 192GB can run a 230B MoE model at 40 tok/s. You don't actually *need* multi-node for the models that make economic sense on your hardware. The models that need multi-node (dense 70B+) are already cheaper on cloud H100s (your Table 12 shows Llama 3.1 70B at 0.6× — cloud wins).

The architecture is strongest exactly where the economics are strongest. That's a clean story.

