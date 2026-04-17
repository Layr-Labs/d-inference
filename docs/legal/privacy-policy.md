# Darkbloom Privacy Policy

Updated: April 17, 2026

This Privacy Policy explains how Eigen Labs, Inc., operating the Darkbloom platform ("Eigen Labs," "Darkbloom," "we," "us," or "our") collects, uses, discloses, and otherwise processes personal information in connection with Darkbloom's websites, console, APIs, software, provider applications, hosted services, and related products and features (collectively, the "Services").

**Standalone Document.** This Privacy Policy is a standalone document governing the Darkbloom Services only. It is separate from and does not incorporate the Eigen Labs Privacy Policy or other privacy notices governing EigenLayer, EigenCloud, EigenDA, EigenCompute, or other Eigen Labs products. Your use of those products is governed solely by their respective privacy notices. This Privacy Policy is designed for the Darkbloom product, including consumer-facing API and console features and provider-facing node software. It does not apply to third-party services we do not control, even if they interoperate with the Services.

## 1. Scope

This Privacy Policy applies when you:

- Visit our websites or console
- Create or use an account, API key, wallet-linked session, or device-link flow
- Submit prompts, files, images, or audio to the Services
- Install or operate provider software or the macOS app
- Communicate with us about the Services

Additional notices may apply to specific products, integrations, or enterprise relationships.

## 2. Personal Information We Collect

The categories of personal information we collect depend on how you use the Services.

**2.1 Account and identity information.** We may collect: name and business details you provide to us; email address; authentication identifiers from our identity providers, including Privy user identifiers; wallet addresses and related wallet identifiers used for authentication or payment-related features; API keys and account identifiers associated with the Services; and tax identification information (such as W-9 or W-8BEN data) collected from providers for tax reporting purposes.

**2.2 Payment, transaction, and billing information.** We may collect: billing session identifiers; payment method type; deposit and withdrawal information; Stripe checkout or other processor transaction identifiers; blockchain transaction signatures, wallet addresses, transfer details, and related public-ledger information; account balances, credit history, payout history, referral codes, and ledger entries. We generally do not receive full payment card numbers from Stripe or similar payment processors.

**2.3 Usage and service metadata.** We collect service usage information such as: request identifiers; account and provider identifiers; selected model or feature; token counts, audio duration, image count, or similar usage measures; timestamps; per-request cost or billing metadata; and API route, status code, and related operational metrics.

**2.4 Content you submit and receive.** Depending on the feature you use, we may process: prompts, messages, and instructions; files and attachments; audio submitted for transcription; image-generation prompts and generated images; and model outputs and responses. We refer to this material as "Content."

**2.5 Provider and device information.** If you run provider software or use provider-related features, we may collect: hardware and device characteristics, such as machine model, chip family, memory, CPU/GPU information, and available capacity; provider wallet addresses; attestation materials and related security data, including Secure Enclave-generated P-256 public keys and ECDSA attestation signatures, SHA-256 hashes of the provider binary, hardware serial numbers used to cross-reference device identity in our MDM server, SIP status, Secure Boot level, and Authenticated Root Volume integrity status as reported by the device; challenge-response verification data (approximately every five minutes, our coordinator sends a 32-byte cryptographic nonce to the provider's device, which signs the nonce using its Secure Enclave key and returns a response including fresh SIP and Secure Boot status); heartbeats, health checks, thermal state, memory pressure, security posture, and version information; and device-linking tokens and account-link status. Provider Macs enrolled in the platform are subject to periodic automated SecurityInfo queries sent via Apple's MDM protocol through Apple's Push Notification service (APNs). These queries request SIP status, Secure Boot level, and Authenticated Root Volume integrity from the device's OS MDM client. MDM enrollment is configured for security verification. Darkbloom requests only the minimum MDM permissions necessary to verify your device's security posture, specifically the ability to query device information and security status. We have deliberately not requested MDM permissions that would allow us to erase, lock, install or remove applications, or access user content or application data.

**2.6 Technical and log information.** When you use the Services, we may automatically collect: IP address and network information; request logs, including route, response status, duration, and remote address; device, browser, and operating system information exposed to us; local storage or similar client-side state used to support the Services, such as stored API keys, preferred coordinator URL, theme preference, verification mode preference, and dismissed UI state; and cookies, SDK storage, or similar session technologies used by our authentication or wallet partners.

**2.7 Communications and support information.** If you contact us, we collect the contents of your message, attachments, and related contact details.

## 3. How We Collect Personal Information

We collect personal information: directly from you when you create an account, authenticate, submit Content, operate provider software, make payments, or contact us; automatically when you use the Services; from service providers and partners that help us authenticate users, process payments, provide wallet functionality, operate infrastructure, or verify transactions; and from public sources, including public blockchain records, when relevant to payment and fraud-prevention workflows.

## 4. How We Use Personal Information

We use personal information to: provide, operate, maintain, secure, and improve the Services; authenticate users and devices, generate API keys, and manage access control; route requests, return outputs, meter usage, and support billing, accounting, payouts, and fraud prevention; operate provider onboarding, MDM enrollment, attestation, integrity verification, challenge-response verification, and account-linking features; collect tax identification information and fulfill tax reporting obligations, including IRS Form 1099-NEC reporting for qualifying US providers; communicate with you about the Services, updates, support issues, and legal or security notices; monitor performance, reliability, and abuse; investigate and enforce compliance with our Terms of Service and other legal requirements; comply with law, regulation, court order, or lawful government request; and create aggregated or de-identified information for analytics, reporting, security, and service improvement, where permitted by law.

## 5. Important Content-Handling Disclosures

Because Darkbloom is an inference platform, Content handling is central to how the Services work. The following disclosures are intended to be precise and conservative.

**5.1 Transit and relay.** Content sent to the Services is transmitted to our coordinator over TLS. Depending on the service path and provider capabilities, we may also encrypt request bodies before relaying them to a selected provider.

**5.2 Coordinator access.** The current service architecture requires our coordinator to process request payloads in plaintext on a transient basis for routing, compatibility, metering, and operation of the Services. You should not treat the current architecture as guaranteeing that the coordinator is technically incapable of accessing request payloads in every service path.

**5.3 Logging.** Our coordinator code is designed not to log prompt content in ordinary request logs. However, we do log operational metadata such as request path, status, duration, and remote address. Content may also be disclosed to us if you intentionally provide it in support requests, bug reports, or other communications.

**5.4 Selected providers.** To fulfill inference requests, we disclose relevant Content to the provider selected to process the request. If you operate provider software, that means customer requests may be routed to your device subject to the Services' security and attestation controls.

**5.5 Images and uploads.** Generated images may be temporarily stored in service memory pending retrieval and delivery to the requesting user. These in-memory image uploads are removed after retrieval, but no system can guarantee perfect deletion or eliminate all risk.

**5.6 Training.** This Privacy Policy does not grant us a right to use your Content for general-purpose model training. If we decide to do so in the future, we will update this Privacy Policy and any related contractual terms before doing so, to the extent required by law.

## 6. How We Disclose Personal Information

We may disclose personal information: to service providers and subprocessors that host infrastructure, provide observability, process payments, verify transactions, support authentication, or otherwise help us operate the Services; to identity, wallet, or payment partners such as Privy, Stripe, card networks, banks, blockchain RPC providers, or wallet providers when needed to authenticate you or complete a transaction; to providers participating in the network, to the extent needed to process your requests; to your organization, if you use the Services through a company or enterprise account; to law enforcement, regulators, courts, or other third parties when required by law or when we believe disclosure is necessary to protect rights, safety, property, or the Services; in connection with an actual or proposed merger, acquisition, financing, reorganization, bankruptcy, receivership, or sale of assets; or with your direction or consent.

Some information may also be public by design: blockchain transaction data may be visible on public ledgers; attestation or verification artifacts may be made available through public or customer-facing verification endpoints. We do not sell personal information for money. We also do not share personal information for cross-context behavioral advertising as those terms are used in certain U.S. privacy laws.

## 7. Legal Bases

If and to the extent a legal basis is required for our processing, we rely on: performance of our contract with you; our legitimate interests in operating, securing, improving, and enforcing the Services; compliance with legal obligations; and your consent, where required by law.

## 8. Retention

We retain personal information for as long as reasonably necessary for the purposes described in this Privacy Policy, including to: provide the Services; maintain account, billing, ledger, tax, and compliance records; investigate incidents, fraud, or abuse; enforce our agreements; and satisfy legal, regulatory, audit, accounting, or reporting requirements. Retention periods may vary by data type. For example: account and billing records may be retained for legal and accounting periods; usage and security logs may be retained for operational, fraud-prevention, and support purposes; tax identification information (W-9/W-8BEN data) is retained for as long as required by IRS regulations; provider attestation and device-link data, including hardware serial numbers, binary hashes, Secure Enclave public keys, MDM SecurityInfo responses, and challenge-response records, may be retained for trust, audit, and network-integrity purposes; and Content may be retained for shorter operational periods unless preserved longer for support, abuse review, legal compliance, or dispute resolution.

## 9. Your Privacy Choices and Rights

Depending on where you live, you may have rights to: know or access the personal information we hold about you; correct inaccurate personal information; delete personal information; receive a portable copy of certain information; opt out of sale, sharing, targeted advertising, or certain profiling, if applicable; limit the use or disclosure of sensitive personal information, where applicable under state law; and not receive discriminatory treatment for exercising privacy rights.

We may need to verify your identity before fulfilling a request. We may deny or limit requests where permitted by law, including where we cannot verify identity, where the request is legally exempt, or where retention is necessary for security, billing, compliance, or dispute purposes. To submit a privacy request, contact us at notices@eigenlabs.org. Authorized agents may submit requests on your behalf where permitted by law, subject to verification. California residents may have rights described in the California Consumer Privacy Act, including rights to know, delete, correct, and opt out, subject to applicable exceptions.

## 10. Cookies, Local Storage, and Similar Technologies

We and our partners may use cookies, local storage, SDK storage, or similar technologies to: keep you signed in or authenticated; store API keys or configuration choices you elect to save in the browser; remember preferences such as theme, coordinator URL, or verification mode; support wallet or authentication SDK functionality; and secure sessions and detect abuse. You can control some browser storage through your browser settings, but disabling these features may impair the Services. Our websites and apps are not currently designed to respond to browser "Do Not Track" signals.

## 11. Third-Party Sites, Wallets, and Social Features

The Services may link to third-party websites, repositories, social channels, wallet providers, identity providers, and payment services. If you follow those links or use those services, your information will be governed by the applicable third party's terms and privacy practices, not ours. This includes services used for authentication and embedded wallet flows; payment processing and billing; blockchain transaction broadcasting, indexing, or verification; and social, support, or community interactions outside our Services. We are not responsible for the privacy, security, availability, or accuracy of third-party services we do not control.

## 12. Security

We use administrative, technical, and organizational safeguards designed to protect personal information appropriate to the nature of the data and the Services. These may include authentication controls, TLS, integrity checks, attestation workflows, access restrictions, and logging. No security program is perfect, and we cannot guarantee absolute security.

## 13. International Transfers

We may process personal information in the United States and other jurisdictions where we or our service providers operate. Those jurisdictions may not provide the same level of data protection as your home jurisdiction. Where required by applicable law, we rely on appropriate legal mechanisms for international transfers of personal information, which may include Standard Contractual Clauses approved by the European Commission or other lawful transfer mechanisms. For more information about the transfer mechanisms we use, contact us at notices@eigenlabs.org.

## 14. Children's Privacy

The Services are not directed to children under 13, and we do not knowingly collect personal information from children under 13. We also do not permit users under 18 to use the Services under our Terms of Service. If you believe a child has provided personal information to us in violation of this Privacy Policy, contact us so we can take appropriate steps.

## 15. Changes to This Privacy Policy

We may update this Privacy Policy from time to time. If we make material changes, we will post the updated version, update the effective date, and take any additional steps required by law.

## 16. Contact Us

For questions or requests about this Privacy Policy, contact: notices@eigenlabs.org
