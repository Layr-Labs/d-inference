# Provider Security Model

The provider is a hardened process on macOS. Its security properties come from
Apple platform features plus Darkbloom-specific runtime checks.

## Protections

| Attack | Blocked by |
|---|---|
| Attach debugger | PT_DENY_ATTACH + Hardened Runtime |
| Read process memory | Hardened Runtime (kernel denies `task_for_pid`) |
| Sniff IPC/network | No IPC — inference is in-process |
| Modify the binary | Code signing + SIP |
| Replace with fake binary | Code-identity attestation via APNs |
| Inject malicious Python package | No embedded Python interpreter |
| Load unsigned kernel extension | SIP |
| Modify kernel at runtime | KIP (hardware-enforced) |
| Disable SIP at runtime | Requires Recovery Mode reboot |
| DMA attack | IOMMU default-deny |

## What the provider can see

The provider is the decryption endpoint for prompts. It receives plaintext
inside its hardened process and feeds it to MLX. This is a deliberate design
choice: in-process inference at native speed requires the provider to see the
prompt. The coordinator is blind to plaintext (it re-encrypts per-request to
the provider), but the provider is not.

APNs-based code-identity attestation bounds which binary may act as the
decryption endpoint. See [`architecture/decisions/apns-code-attestation.md`](../architecture/decisions/apns-code-attestation.md).

## SIP and Secure Boot

SIP cannot be disabled without rebooting into Recovery Mode, which kills the
inference process and wipes memory. The provider self-checks SIP status and the
coordinator verifies fresh SIP/SecureBoot status in every challenge-response.

## Honest limits

- A compromised provider binary signed by a stolen team key could inspect
  prompts. Mitigation: reproducible builds + a public transparency log of
  blessed cdhashes, plus least-access controls on signing identities.
- RDMA over Thunderbolt (multi-node inference) bypasses the in-process memory
  protections. Single-node inference is the supported security boundary today.
- A provider with root access to its own machine can always choose to run a
  modified OS offline; the attestation gate catches this when it reconnects.
