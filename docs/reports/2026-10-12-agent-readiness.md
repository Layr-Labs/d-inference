# Agent-readiness audit and implementation disposition

> Last updated: 2026-10-12

The Darkbloom website audit identified discovery and representation gaps. This record maps the complete baseline to the DBLM-711 implementation; it is not a post-deployment score or evidence of a production rollout.

## Baseline and scope

[Is Agentic](https://is-agentic.com/scan/darkbloom.ai) scanned the site at **2026-10-13T01:27:03.475Z**, October 12 at 6:27 PM Pacific. The displayed report scored **50/100**, and the CLI summarized **12 failures and 5 partial results**. The embedded Ora contract 1.30.0 result scored **34/100** under a different classification and scoring view. Do not combine those views or interpret all 132 underlying checks as website requirements.

Read-only baseline requests confirmed missing landing `llms.txt`, sitemap and OpenAPI URLs, a working public documentation introduction, a JSON 401 from the actual API model list and a missing OpenAPI resource on the API host. A scanner probing guessed marketing-host API paths does not establish absence of the existing authenticated API.

## Surfaced report findings

| Finding family | Implementation or explicit boundary |
|---|---|
| Brand and use-case search; developer-resource discovery | Clear SSR product roles, canonical titles and official docs/API/CLI links. Ranking remains a post-deployment observation. |
| Useful HTML without JavaScript | Visible product overview and consumer/provider distinctions, retaining the existing visual homepage. |
| Markdown homepage, alternate URLs and Accept variation | `index.md`, explanatory page twins, media preference handling and `Vary: Accept` alongside framework tokens. |
| Broken-link recovery | Genuine Markdown 404 with home, index and docs recovery links; unrelated APIs/assets are preserved. |
| Agent instructions and authentication guidance | `llms.txt` and `auth.md`, real base URL, placeholder credentials and funded-account requirements. |
| Sitemap and canonical metadata | Public canonical URLs, factual dates where known, crawl policy, OG/Twitter and linked structured identity. |
| Organization and contact completeness | Operator, legal contact and substantive contact page; no invented postal address or generic support inbox. |
| Public API, OpenAPI and function calling | Reviewed existing consumer subset at `openapi.json`, operation IDs, typed schemas, Bearer requirements and documented JSON/SSE errors. |
| API JSON errors and rate/auth handling | Discover actual API behavior; no anonymous paid inference and no fake marketing-host API responses. |
| Existing CLI discovery | Link official provider CLI/install documentation and distinguish it from the consumer API. |
| Pricing, including machine-readable pricing | HTML and Markdown share a live public source, exact token units, retrieval timestamp and explicit unavailable state. |
| MCP, WebMCP and optional agent/payment catalogs | No official supported inference MCP service established by source research. New services/manifests, OAuth, SDKs, A2A, NLWeb and payment protocols excluded. |
| Search listings, Wikipedia, plugins and registries | External publication/product decisions excluded; no listing or ranking result claimed. |

## Verification and release boundary

The implementation uses production-build HTTP tests for representations, negotiation, recovery, metadata, sitemap, discovery, API schema and existing route behavior. Pricing tests use a loopback HTTP source; no automated test sends paid production inference or uses production credentials. Desktop/mobile review covers new public pages and navigation. The [test guide](../developer/test.md) describes the shared HTTP seam.

Next.js 16.2.6 discarded proxy `Vary` tokens in generated page handlers. A narrow version-checked patch runs explicitly before each build and preserves the tokens, following [upstream issue 85999](https://github.com/vercel/next.js/issues/85999) and [proposed fix 91039](https://github.com/vercel/next.js/pull/91039). The HTTP regression verifies actual responses, not patch text. Remove the patch only with a framework version that passes the same test unpatched.

The API artifact is tied to platform revision `baca977134a63678ab12979038d3618901d852ee`; [contract provenance](../../landing/API-CONTRACT.md) documents coverage and maintenance. The provider repository contains documentation only for those operations.

Production deployment was not authorized as part of the specification. After a separately authorized deployment, rerun the complete audit and record deployed revision, timestamp, response headers, redirects, search outcomes and unresolved heuristics. Local success cannot establish CDN caching or search indexing. Preview results, when available, are distinct from production.

## Complete underlying checklist

Each row preserves the raw check ID and baseline status. “Implemented” here refers to source behavior and its indicated verification, not a claimed scanner pass. Optional exclusions are deliberate scope boundaries.

| Layer | Check ID | Baseline | Disposition |
|---|---|---|---|
| Discovery | `ard-catalog` | fail | Excluded: separate platform capability; no service or manifest fabricated. |
| Discovery | `ai-catalog-published` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Discovery | `ard-entries-valid` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Discovery | `ard-trust-manifest` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Discovery | `agentic-search-usecase` | na | Not applicable in baseline; no new protocol or product introduced to change applicability. |
| Discovery | `agentic-search-specific` | warning | DBLM-715: clear titles and product copy; search ranking requires post-deployment observation. |
| Discovery | `brand-search-accuracy` | fail | DBLM-715: clear titles and product copy; search ranking requires post-deployment observation. |
| Discovery | `wikipedia-presence` | fail | Excluded: external publication/listing, outside this website change. |
| Discovery | `robots-ai-policy-quality` | pass | DBLM-712: canonical metadata, structured identity, sitemap and crawl policy; HTTP coverage. |
| Discovery | `mcp-registry-listed` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Discovery | `npm-sdk-package` | fail | Existing-capability discovery: OpenAI-compatible consumer examples and provider CLI; no new SDK distribution. |
| Discovery | `agent-rules-repo` | fail | DBLM-713: guidance, explicit/negotiated Markdown, discovery links and real 404s; HTTP coverage. |
| Discovery | `agent-plugins-repo` | fail | Excluded: external publication/listing, outside this website change. |
| Discovery | `registry-branding` | na | Not applicable in baseline; no new protocol or product introduced to change applicability. |
| Discovery | `chatgpt-app-listed` | fail | Excluded: external publication/listing, outside this website change. |
| Discovery | `noindex-directives` | pass | Preserve; local route/markup coverage or post-deployment observation where externally measured. |
| Access | `sitemap` | fail | DBLM-712: canonical metadata, structured identity, sitemap and crawl policy; HTTP coverage. |
| Access | `content-no-js` | warning | DBLM-715: SSR product/contact/developer/pricing pages and official CLI/docs links; HTTP and visual checks. |
| Access | `bot-detection` | pass | Preserve; local route/markup coverage or post-deployment observation where externally measured. |
| Access | `agent-discovery-file` | fail | DBLM-713: guidance, explicit/negotiated Markdown, discovery links and real 404s; HTTP coverage. |
| Access | `agent-skills-index-v2` | na | Not applicable in baseline; no new protocol or product introduced to change applicability. |
| Access | `a2a-agent-card` | fail | Excluded: separate platform capability; no service or manifest fabricated. |
| Access | `skills-sh-listed` | fail | Excluded: external publication/listing, outside this website change. |
| Access | `pricing-md` | fail | DBLM-715: SSR product/contact/developer/pricing pages and official CLI/docs links; HTTP and visual checks. |
| Access | `nlweb-schema-feeds` | fail | Excluded: separate platform capability; no service or manifest fabricated. |
| Access | `mcp-well-known-discovery` | fail | Excluded: separate platform capability; no service or manifest fabricated. |
| Access | `agent-mode-view` | fail | Explicit Markdown and Accept negotiation are supported; extra URL/UA conventions are not promised. |
| Access | `link-headers-discovery` | fail | DBLM-713: guidance, explicit/negotiated Markdown, discovery links and real 404s; HTTP coverage. |
| Access | `markdown-url-fallback` | fail | DBLM-713: guidance, explicit/negotiated Markdown, discovery links and real 404s; HTTP coverage. |
| Access | `modular-llms-txt` | fail | Explicit Markdown and Accept negotiation are supported; extra URL/UA conventions are not promised. |
| Access | `sitemap-lastmod` | na | DBLM-712: canonical metadata, structured identity, sitemap and crawl policy; HTTP coverage. |
| Access | `robots-agent-user-policy` | pass | DBLM-712: canonical metadata, structured identity, sitemap and crawl policy; HTTP coverage. |
| Access | `llms-txt-exists` | fail | DBLM-713: guidance, explicit/negotiated Markdown, discovery links and real 404s; HTTP coverage. |
| Access | `llms-txt-formatting` | fail | DBLM-713: guidance, explicit/negotiated Markdown, discovery links and real 404s; HTTP coverage. |
| Access | `json-ld` | fail | DBLM-712: canonical metadata, structured identity, sitemap and crawl policy; HTTP coverage. |
| Access | `pricing-info` | warning | DBLM-715: SSR product/contact/developer/pricing pages and official CLI/docs links; HTTP and visual checks. |
| Access | `public-api-docs` | pass | DBLM-715: SSR product/contact/developer/pricing pages and official CLI/docs links; HTTP and visual checks. |
| Access | `agent-instruction` | fail | DBLM-713: guidance, explicit/negotiated Markdown, discovery links and real 404s; HTTP coverage. |
| Access | `skills-sh-quality` | fail | Excluded: external publication/listing, outside this website change. |
| Access | `json-ld-entity-linking` | fail | DBLM-712: canonical metadata, structured identity, sitemap and crawl policy; HTTP coverage. |
| Access | `metadata-completeness` | warning | DBLM-712: canonical metadata, structured identity, sitemap and crawl policy; HTTP coverage. |
| Access | `org-schema-completeness` | fail | DBLM-712: verified operator and legal contact; postal address omitted because unverified. Heuristic may remain partial. |
| Access | `schema-type-breadth` | fail | DBLM-715: SSR product/contact/developer/pricing pages and official CLI/docs links; HTTP and visual checks. |
| Access | `trust-anchors` | warning | DBLM-715: SSR product/contact/developer/pricing pages and official CLI/docs links; HTTP and visual checks. |
| Access | `llms-txt-links-resolve` | na | DBLM-713: guidance, explicit/negotiated Markdown, discovery links and real 404s; HTTP coverage. |
| Access | `markdown-link-alternate` | fail | DBLM-713: guidance, explicit/negotiated Markdown, discovery links and real 404s; HTTP coverage. |
| Access | `markdown-frontmatter` | na | Explicit Markdown and Accept negotiation are supported; extra URL/UA conventions are not promised. |
| Access | `redirect-hygiene` | pass | Preserve; local route/markup coverage or post-deployment observation where externally measured. |
| Access | `page-token-budget` | pass | Preserve; local route/markup coverage or post-deployment observation where externally measured. |
| Access | `code-fence-validity` | na | Explicit Markdown and Accept negotiation are supported; extra URL/UA conventions are not promised. |
| Access | `docs-auth-gate` | pass | Preserve; local route/markup coverage or post-deployment observation where externally measured. |
| Access | `openapi-spec` | fail | DBLM-714: source-pinned OpenAPI subset and real auth/error/SSE contract. No new backend behavior. |
| Access | `developer-portal` | pass | DBLM-715: SSR product/contact/developer/pricing pages and official CLI/docs links; HTTP and visual checks. |
| Access | `api-catalog-rfc9727` | fail | Excluded: separate platform capability; no service or manifest fabricated. |
| Access | `markdown-negotiation` | fail | DBLM-713: guidance, explicit/negotiated Markdown, discovery links and real 404s; HTTP coverage. |
| Access | `markdown-negotiation-vary` | fail | DBLM-713: guidance, explicit/negotiated Markdown, discovery links and real 404s; HTTP coverage. |
| Access | `agent-ua-markdown` | fail | Explicit Markdown and Accept negotiation are supported; extra URL/UA conventions are not promised. |
| Access | `agent-crawler-reachability` | pass | Preserve; local route/markup coverage or post-deployment observation where externally measured. |
| Usability | `mcp-tool-descriptions` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `mcp-param-schemas` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `mcp-server-identity` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `mcp-tool-listing` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `mcp-tool-naming` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `public-api` | fail | DBLM-714: source-pinned OpenAPI subset and real auth/error/SSE contract. No new backend behavior. |
| Usability | `oauth-support` | fail | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `scoped-permissions` | fail | Existing auth/billing documented; no new scopes or relaxed authorization. Platform change excluded. |
| Usability | `mcp-auth-mechanism` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `mcp-oauth-metadata` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `mcp-pkce-s256` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `onboarding-friction` | fail | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `web-bot-auth-directory` | fail | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `oauth-protected-resource` | fail | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `auth-md-exists` | fail | DBLM-713: guidance, explicit/negotiated Markdown, discovery links and real 404s; HTTP coverage. |
| Usability | `auth-md-structure` | fail | DBLM-713: guidance, explicit/negotiated Markdown, discovery links and real 404s; HTTP coverage. |
| Usability | `auth-md-walkthrough-simulation` | na | DBLM-713: guidance, explicit/negotiated Markdown, discovery links and real 404s; HTTP coverage. |
| Usability | `agent-auth-discovery-metadata` | fail | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `agent-auth-www-authenticate` | fail | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `agent-auth-endpoints-reachable` | fail | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `pap-discovery` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `pap-issuer-binding` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `pap-auth-config` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `pap-interfaces` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `pap-endpoint-enforcement` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `pap-cross-protocol` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `mcp-server` | fail | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `mcp-error-handling` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `mcp-transport-modern` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `webmcp` | warning | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `rate-limit-headers` | na | DBLM-714: source-pinned OpenAPI subset and real auth/error/SSE contract. No new backend behavior. |
| Usability | `idempotency-key-support` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `json-error-responses` | fail | DBLM-714: source-pinned OpenAPI subset and real auth/error/SSE contract. No new backend behavior. |
| Usability | `api-error-model` | na | DBLM-714: source-pinned OpenAPI subset and real auth/error/SSE contract. No new backend behavior. |
| Usability | `api-versioning-policy` | na | Current /v1 contract documented; no invented versioning policy or pagination support. |
| Usability | `pagination-shape` | na | Current /v1 contract documented; no invented versioning policy or pagination support. |
| Usability | `async-job-pattern` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `cli-tool` | fail | DBLM-715: SSR product/contact/developer/pricing pages and official CLI/docs links; HTTP and visual checks. |
| Usability | `rest-sdk-packages` | fail | Existing-capability discovery: OpenAI-compatible consumer examples and provider CLI; no new SDK distribution. |
| Usability | `nlweb-ask` | fail | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `nlweb-streaming` | fail | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `response-schema-coverage` | na | DBLM-714: source-pinned OpenAPI subset and real auth/error/SSE contract. No new backend behavior. |
| Usability | `mcp-tool-annotations` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `mcp-server-card` | fail | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `mcp-multi-surface-coverage` | fail | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `sandbox-environment` | fail | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `batch-endpoints` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `mcp-resource-listing` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `graphql-error-type-definition` | na | Not applicable in baseline; no new protocol or product introduced to change applicability. |
| Usability | `graphql-versioning-policy` | na | Not applicable in baseline; no new protocol or product introduced to change applicability. |
| Usability | `graphql-pagination-pattern` | na | Not applicable in baseline; no new protocol or product introduced to change applicability. |
| Usability | `graphql-async-job-pattern` | na | Not applicable in baseline; no new protocol or product introduced to change applicability. |
| Usability | `graphql-schema-completeness` | na | Not applicable in baseline; no new protocol or product introduced to change applicability. |
| Usability | `graphql-batch-mutations` | na | Not applicable in baseline; no new protocol or product introduced to change applicability. |
| Usability | `agent-friendly-404` | warning | DBLM-713: guidance, explicit/negotiated Markdown, discovery links and real 404s; HTTP coverage. |
| Usability | `ax-document-structure` | pass | Preserve; local route/markup coverage or post-deployment observation where externally measured. |
| Usability | `ax-native-controls` | pass | Preserve; local route/markup coverage or post-deployment observation where externally measured. |
| Usability | `ax-accessible-names` | pass | Preserve; local route/markup coverage or post-deployment observation where externally measured. |
| Usability | `ax-form-labeling` | pass | Preserve; local route/markup coverage or post-deployment observation where externally measured. |
| Usability | `ax-tree-injection-safe` | pass | Preserve; local route/markup coverage or post-deployment observation where externally measured. |
| Usability | `mcp-app-registry` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `a2ui-support` | na | Not applicable in baseline; no new protocol or product introduced to change applicability. |
| Usability | `mcp-apps-ui-quality` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `mcp-view-domain` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `mcp-view-csp` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Usability | `api-schema-analysis` | fail | DBLM-714: source-pinned OpenAPI subset and real auth/error/SSE contract. No new backend behavior. |
| Usability | `function-calling-compat` | fail | DBLM-714: source-pinned OpenAPI subset and real auth/error/SSE contract. No new backend behavior. |
| Usability | `mcp-resource-quality` | na | Excluded: separate platform capability; no service or manifest fabricated. |
| Payments | `mpp-support` | na | Not applicable in baseline; no new protocol or product introduced to change applicability. |
| Payments | `x402-support` | na | Not applicable in baseline; no new protocol or product introduced to change applicability. |
| Payments | `ucp-support` | na | Not applicable in baseline; no new protocol or product introduced to change applicability. |
| Payments | `acp-support` | na | Not applicable in baseline; no new protocol or product introduced to change applicability. |
| Payments | `acp-delegate-payment` | na | Not applicable in baseline; no new protocol or product introduced to change applicability. |
| Payments | `ap2-support` | na | Not applicable in baseline; no new protocol or product introduced to change applicability. |
