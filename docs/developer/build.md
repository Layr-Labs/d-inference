# Build

Toolchain versions are pinned in `mise.toml`. Build/test commands are wrapped
in the root `Makefile`.

## One-time setup

```bash
mise install            # installs every tool pinned in mise.toml
make ui-install         # console-ui npm deps
```

## Coordinator (Go)

```bash
make coordinator-test         # cd coordinator && go test ./...
make coordinator-build        # cd coordinator && go build ./cmd/coordinator
make coordinator-build-linux  # GOOS=linux GOARCH=amd64 CGO_ENABLED=0
make coordinator              # test + build
```

## Provider (Swift)

```bash
make provider-build           # cd provider-swift && swift build
make provider-test            # cd provider-swift && swift test
make provider                 # build + test
```

### Custom Apple Team ID

The signed provider embeds Eigen Labs' Team ID (`SLDQ2GJ6TL`) in its keychain access group and
application identifier. To build and sign under your own Apple Developer account, regenerate the
entitlements from their templates before signing:

```bash
TEAM_ID=YOURTEAMID ./scripts/generate-entitlements.sh
```

`APPLE_TEAM_ID` is honoured as a fallback. Edit `*.plist.template`, never the generated `*.plist` —
CI fails the **Release Integrity** check if the two drift apart. Note that the official release
workflow (`.github/workflows/release-swift.yml`) still pins `SLDQ2GJ6TL` in its provisioning-profile
and signature gates; a custom Team ID is for local and fork builds.

## Console UI (Next.js 16)

```bash
make ui-install               # npm install
make ui-build                 # npm run build
make ui-lint                  # npx eslint src/
make ui-test                  # vitest (npm test)
make ui                       # install + lint + test + build
```

## Aggregates

```bash
make test                     # all unit tests
make build                    # build all components
make all                      # test + build everything
make clean                    # remove built artifacts
```

## Pre-commit formatting

```bash
git config core.hooksPath .githooks
```

| Component | Check | Manual fix |
|---|---|---|
| Go (`coordinator/`) | `gofmt -l` | `gofmt -w <file>` |
| Swift (`provider-swift/`) | `swift test` | — |
| TypeScript (`console-ui/`) | `npx eslint src/` | `npx eslint src/ --fix` |
