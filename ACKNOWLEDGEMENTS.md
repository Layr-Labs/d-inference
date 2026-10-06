# Third-party acknowledgements

> Last updated: 2026-10-06

Darkbloom builds on the work of third-party library authors, maintainers, and
contributors. Thank you for the software that makes this project possible.

This page acknowledges our direct library dependencies, the core inference
stack, and explicitly credited adaptations. Each linked project provides its
own license information.

## Inference and provider

| Project | Used for |
| --- | --- |
| [MLX](https://github.com/ml-explore/mlx) | Array operations and machine learning on Apple Silicon. |
| [MLX Swift](https://github.com/ml-explore/mlx-swift) | Swift bindings and neural-network APIs for MLX. |
| [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) | Language and vision-language model loading and inference. |
| [Swift Transformers](https://github.com/huggingface/swift-transformers) | Tokenization and model configuration. |
| [Swift Hugging Face](https://github.com/huggingface/swift-huggingface) | Hugging Face model downloads through the inference stack. |
| [Swift Jinja](https://github.com/huggingface/swift-jinja) | Rendering and validating model chat templates. |
| [Swift Argument Parser](https://github.com/apple/swift-argument-parser) | Provider command-line commands and options. |
| [Swift Crypto](https://github.com/apple/swift-crypto) | Cryptographic operations in provider and publishing code. |
| [Swift Log](https://github.com/apple/swift-log) | Structured logging. |
| [Swift NIO](https://github.com/apple/swift-nio) | Asynchronous networking. |
| [Hummingbird](https://github.com/hummingbird-project/hummingbird) | The provider's local HTTP API. |
| [EventSource](https://github.com/mattt/EventSource) | Server-sent event support in the Hugging Face client dependency stack. |
| [Swift Sodium](https://github.com/jedisct1/swift-sodium) | Swift access to libsodium cryptography. |
| [libsodium](https://github.com/jedisct1/libsodium) | Authenticated encryption used through Swift Sodium. |
| [TOMLKit](https://github.com/LebJe/TOMLKit) | Provider configuration parsing. |
| [Swift Collections](https://github.com/apple/swift-collections) | Collection types used by the provider dependency stack. |
| [Swift Numerics](https://github.com/apple/swift-numerics) | Numeric types used by the inference dependency stack. |

Our MLX dependencies include the Darkbloom-maintained forks of
[MLX](https://github.com/Layr-Labs/mlx),
[MLX Swift](https://github.com/Layr-Labs/mlx-swift), and
[MLX Swift LM](https://github.com/Layr-Labs/mlx-swift-lm). We acknowledge the
original projects and their contributors for the foundations of these forks.

## Coordinator

| Project | Used for |
| --- | --- |
| [age](https://github.com/FiloSottile/age) | Encrypting exported coordinator state. |
| [bbolt](https://github.com/etcd-io/bbolt) | Validating Bolt database files during state export. |
| [CBOR](https://github.com/fxamacker/cbor) | Decoding App Attest proof data. |
| [Datadog Go](https://github.com/DataDog/datadog-go) | Operational metrics. |
| [Datadog Go tracer](https://github.com/DataDog/dd-trace-go) | Application tracing and instrumentation. |
| [Go JWT](https://github.com/golang-jwt/jwt) | Authentication token verification. |
| [Google UUID](https://github.com/google/uuid) | Unique identifiers. |
| [goose](https://github.com/pressly/goose) | Versioned PostgreSQL schema migrations. |
| [pgx](https://github.com/jackc/pgx) | PostgreSQL access. |
| [Smallstep PKCS7](https://github.com/smallstep/pkcs7) | Signing enrollment profiles. |
| [Go PKCS12](https://github.com/SSLMate/go-pkcs12) | Loading signing certificates and keys. |
| [WebSocket](https://github.com/coder/websocket) | Provider WebSocket connections, using the `nhooyr.io/websocket` module. |
| [Go Cryptography](https://go.googlesource.com/crypto) | Request encryption and cryptographic primitives. |
| [Go Modules](https://go.googlesource.com/mod) | Release-version comparison. |
| [Go Networking](https://go.googlesource.com/net) | Network and hostname handling. |
| [Go Sync](https://go.googlesource.com/sync) | Concurrency coordination. |
| [Go Sys](https://go.googlesource.com/sys) | Operating-system interfaces. |
| [Go Time](https://go.googlesource.com/time) | Rate limiting. |

## Web applications

| Project | Used for |
| --- | --- |
| [React](https://github.com/facebook/react), including React DOM | User-interface components and rendering. |
| [Next.js](https://github.com/vercel/next.js) | The console, landing site, and admin application. |
| [Lucide](https://github.com/lucide-icons/lucide) | Interface icons. |
| [React Markdown](https://github.com/remarkjs/react-markdown) | Rendering Markdown in the console. |
| [remark-gfm](https://github.com/remarkjs/remark-gfm) | GitHub-flavored Markdown support. |
| [TweetNaCl.js](https://github.com/dchest/tweetnacl-js) | Browser-side request encryption. |
| [Zustand](https://github.com/pmndrs/zustand) | Console state management. |
| [node-postgres](https://github.com/brianc/node-postgres) | PostgreSQL queries in the admin application. |
| [Datadog Browser SDK](https://github.com/DataDog/browser-sdk) | Browser observability. |
| [Privy React Auth SDK](https://www.npmjs.com/package/@privy-io/react-auth) | Console authentication. |
| [Vercel Analytics](https://github.com/vercel/analytics) | Web analytics. |
| [Tailwind CSS](https://github.com/tailwindlabs/tailwindcss), including its PostCSS integration | Web application styling. |

## Development and testing

| Project | Used for |
| --- | --- |
| [ESLint](https://github.com/eslint/eslint) and its [Next.js integration](https://github.com/vercel/next.js) | JavaScript and TypeScript linting. |
| [typescript-eslint](https://github.com/typescript-eslint/typescript-eslint) | TypeScript-aware linting. |
| [ESLint Promise](https://github.com/eslint-community/eslint-plugin-promise) | Promise-handling lint rules. |
| [ESLint Security](https://github.com/eslint-community/eslint-plugin-security) | Security-focused lint rules. |
| [SonarJS](https://github.com/SonarSource/SonarJS) | Additional code-quality lint rules. |
| [TypeScript](https://github.com/microsoft/TypeScript) | Static type checking. |
| [DefinitelyTyped](https://github.com/DefinitelyTyped/DefinitelyTyped) | Type definitions for JavaScript dependencies. |
| [Vitest](https://github.com/vitest-dev/vitest) | Web application tests. |
| [Testing Library](https://github.com/testing-library), including DOM, React, and jest-dom | Interface and component tests. |
| [jsdom](https://github.com/jsdom/jsdom) | A DOM environment for interface tests. |
| [Testify](https://github.com/stretchr/testify) | Go test assertions. |
| [OpenAI Go](https://github.com/openai/openai-go) | API compatibility tests. |
| [Hummingbird WebSocket](https://github.com/hummingbird-project/hummingbird-websocket) | WebSocket support for provider test servers. |

## Adapted work

We acknowledge [oMLX](https://github.com/jundot/omlx) and its contributors for
the persistent-residency policy intent adapted in our MiMo provider code. The
source attribution is retained in
[MiMoV26WiredResidency.swift](provider-swift/Sources/ProviderCore/Inference/Engine/Factory/MiMo/MiMoV26WiredResidency.swift).
