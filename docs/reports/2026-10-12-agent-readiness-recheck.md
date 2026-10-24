# Agent-readiness branch recheck and CI cleanup repair

> Last updated: 2026-10-12

The DBLM-711 branch satisfies 22 of 24 directly inspected local checks; two remain partial. This is a measurement against the audit criteria, not a new Is Agentic score or a production deployment result.

## Evidence and scope

Source before the CI-only repair: `787bf8dd46e174ea5135af4d13af5a60685e690c`. The landing source is unchanged by the CI repair. The site was rebuilt with its explicit header patch and all 32 production-build HTTP tests passed before measurement. Requests used the isolated server in `landing/tests/helpers/site-server.mjs`, with unavailable upstream fixtures and no credentials.

The public report API still returns the original **50/100**, scanned at `2026-10-13T01:27:03.475Z`. Its denominator is 24 eligible checks: eight essential and 16 recommended, plus bonus signals. The [full baseline disposition](2026-10-12-agent-readiness.md) separately covers 132 underlying checks. Do not compare that larger checklist to the public score as if the denominators were equal.

A new CLI request using `is-agentic@1.0.1` against the branch preview did not produce a completed report. The public report API returned `report_not_found`. Anonymous requests to the preview redirect to Vercel Authentication; no protection setting was changed or bypass credential created. A valid new public weighted score, CDN result and search-ranking result are therefore unavailable.

## Original failed and partial criteria

| Original criterion | Branch result | Evidence or remaining limit |
|---|---|---|
| Agent-friendly 404 | Meets locally | HTTP 404, `text/markdown`, explanatory body and recovery links. |
| Content without JavaScript | Partial | One H1 and 1,917 readable characters; text/HTML ratio 1.82%, below the 5% target. |
| OpenAPI published | Meets locally | `/openapi.json`: four reviewed paths; actual document passes Swagger Parser validation. |
| JSON error responses | Existing API rediscovered | Public unauthenticated `GET https://api.darkbloom.dev/v1/models` returns JSON 401. Landing links that API and describes its errors. |
| Markdown negotiation and Vary | Meets locally | Markdown for explicit `Accept`; HTML for browsers; both retain `Vary: Accept`, with framework tokens preserved. |
| Brand discoverability | Unverified | Public search/indexing does not reflect an undeployed branch. |
| Public API reachability | Existing API rediscovered | Correct API host linked; public pricing returns JSON 200, model discovery retains required authentication. A scanner may still penalize auth-gated operations. |
| JSON-LD | Meets locally | Parsed linked Organization, WebSite and SoftwareApplication graph. |
| CLI availability | Existing CLI discoverable locally | Official provider source/reference linked from HTML and the agent index. No new package registry publication. |
| Agent instructions | Meets locally | Root index contains explicit when-to-use, consumer/provider, authentication and pricing guidance. |
| API schema analysis | Meets locally | Descriptions, typed requests/responses and unique operation IDs in the reviewed subset. |
| Function calling compatibility | Meets locally | The published operation descriptions, IDs and schemas satisfy the declared subset; no new model feature promised. |
| Sitemap | Meets locally | Seven unique canonical public URLs. Known legal modification dates are preserved. |
| Organization completeness | Partial | Verified operator and legal contact present. Unverified postal address deliberately omitted. |
| Developer-resource search | Unverified | Predictable URLs and links exist; public search results require deployment and indexing. |
| Metadata completeness | Meets locally | Canonical URL, HTML language, `og:image` and `og:type` are present. |
| Trust anchors | Meets locally | About, Contact and Privacy all return substantive public HTML exceeding 500 readable characters. |

These are 11 locally satisfied criteria, two existing API capabilities now explicitly discoverable, two remaining partials and two search observations that cannot be established from a local branch. They are not weighted score points.

## Direct measurements

Text excludes `head`, scripts, styles and SVG content, collapses whitespace, then divides readable characters by decoded HTML characters. This is a transparent approximation of the published content-ratio check; the hosted auditor may tokenize differently. Token estimates use readable characters divided by four, rounded up.

| Page | Readable characters | HTML characters | Text ratio | H1 count | Estimated text tokens |
|---|---:|---:|---:|---:|---:|
| `/` | 1,917 | 105,264 | 1.82% | 1 | 480 |
| `/about` | 4,343 | 24,940 | 17.41% | 1 | 1,086 |
| `/contact` | 1,158 | 18,500 | 6.26% | 1 | 290 |
| `/developers` | 2,554 | 23,870 | 10.70% | 1 | 639 |
| `/pricing` with unavailable source | 815 | 16,572 | 4.92% | 1 | 204 |
| `/privacy` | 18,155 | 49,809 | 36.45% | 1 | 4,539 |
| `/terms` | 26,192 | 58,463 | 44.80% | 1 | 6,548 |

The 24 direct checks also cover four crawler user agents, no-index directives, robots/sitemap links, root guidance and auth Markdown, explicit Markdown URLs, discovery response links, developer entry, pricing representations and page-size limits. Twenty-two pass and the two partials above remain. The 5% ratio is a homepage criterion; the unavailable pricing-page ratio is disclosed, not counted as another failed homepage check.

No padding or hidden keyword text was added to raise the ratio. The existing interactive homepage and its serialized application content dominate the HTML size; the concise Markdown representation avoids that overhead for agents.

## CI root cause and repair

Release Integrity failed twice in different `SourceTimestampTests` during temporary `.git` directory deletion. Git Trace2 showed fixture commits invoking `git maintenance run --auto --quiet --detach`. Those child writers could outlive a successful commit and race fixture cleanup, even though assertions passed.

`FixtureProcessTests` first failed with the actual detached child event. The test Git helper now supplies `maintenance.auto=false` and `gc.auto=0` for each command, including cloned submodules. The regression commits both an initialized repository and a clone while inherited global settings enable maintenance. The full 28-test run then passes and records zero automatic-maintenance child processes. This changes disposable tests only; production release code and Git settings remain unchanged. See the [test guide](../developer/test.md).

## Remaining boundaries

A fresh public audit must target the deployed revision through a publicly readable host. Search results, optional MCP/OAuth/SDK/registry capabilities, unknown organization address details and production CDN behavior are not established by this recheck. The original full-checklist exclusions remain in force.
