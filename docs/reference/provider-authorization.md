# Provider Serving Authorization

> Last updated: 2026-10-09

Provider trust status reports external serving permission, not a guarantee of
correct model output, physical uniqueness or secrecy from the executing process.
Legacy MDM/APNs and App Attest authorization are independent evidence paths.

## Provider Contract

| Evidence | Meaning and limits |
|---|---|
| Legacy verification | Secure Enclave signatures, posture, MDM/MDA and code identity retain separate meanings. App Attest does not set legacy flags. |
| App Attest | Exact qualified app identity, current connection/endpoint binding, freshness and revocation are required; shadow collection alone authorizes nothing. |
| Reported machine/resources | App measurements are not a physical uniqueness or certified RAM proof. |
| Removal readiness | Do not remove enrollment merely because a shadow exchange succeeded. Follow explicit current readiness and preserve employer/other profiles. |
| Public status | Do not publish credentials, raw Apple evidence or stable private identifiers as diagnostics. |

Provider implementation is in `provider-swift/Sources/ProviderAppAttest/` and
`provider-swift/Sources/ProviderCore/Security/`. The [App Attest wire reference](app-attest-shadow.md)
and [provider procedure](../provider/attestation.md) describe local behavior.

## External Authority

Exact backend grant, expiry, revocation and qualification behavior is maintained
in [platform authorization](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/reference/provider-authorization.md).
The release workflow calls the approved qualification/registration APIs, but a
publication key cannot approve its own build. No local backend build or policy
rollout is authorized by this reference.

Keep signed-artifact and physical security-transition qualification separate from
public Swift fixture checks. A denied, expired or unknown grant must not become
permission through a diagnostic fallback.

## Related

- [Identity binding](../architecture/security/identity-binding.md)
- [Privacy and cache storage](../architecture/security/encryption.md)
- [Release qualification](../operations/provider-release.md)
