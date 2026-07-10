# coordinator-rs Style Guide (code organization)

Prescriptive rules for decomposing and organizing the `protocol`, `core`, and `server`
crates. Derived from a study of otter-sec/anchor (a professionally structured Rust
workspace) plus a measurement of this workspace. Refactoring agents apply the
"Rules" section mechanically; the "Source" section is the evidence.

---

## Source: conventions observed in otter-sec/anchor

Measured over `lang/`, `cli/`, `client/`, `avm/`, `idl/`, `spl/` (excluding tests,
examples, benches): **179 files, 64,759 lines. p50 = 127, p75 = 337, p90 = 919,
p95 = 1332, max = 7885.** The p90+ tail is dominated by acknowledged CLI monoliths
(`cli/src/lib.rs` 7885, `cli/src/program.rs` 2840, `cli/src/config.rs` 2389,
`cli/src/template.rs` 2168) and two single-cohesive-match constraint files
(`lang/syn/src/parser/accounts/constraints.rs` 1858,
`lang/syn/src/codegen/accounts/constraints.rs` 1876). The *well-factored* trees that
anchor's own newer code follows (`lang/src/accounts/`, `lang/syn/src/codegen/`,
`cli/src/fetch/`, `cli/src/debugger/`) sit at p50 ≈ 130 with almost everything under
~500 lines. **Model the `lang/` and `cli/src/fetch|debugger` trees, not the CLI monolith.**

### Workspace / crate decomposition
- Crates split by *dependency direction and compile target*, not by size: runtime API
  (`lang/`), macro implementation library (`lang/syn/`), one thin proc-macro crate per
  macro (`lang/attribute/account/`, `lang/attribute/program/`, `lang/derive/accounts/` —
  each a single `lib.rs` delegating into `anchor-syn`), a standalone error crate
  (`lang/error/`), a spec crate (`idl/spec/`).
- Root `Cargo.toml` holds ALL versions in `[workspace.dependencies]`, including internal
  path deps pinned `=1.1.2`; member crates use `foo.workspace = true`. Comments in the
  root manifest explain any version pin (e.g. their `solana-sysvar` FIXME).
- `rustfmt.toml`: `imports_granularity = "One"`, `group_imports = "One"`,
  `format_strings = true`. `clippy.toml`: `allow-unwrap-in-tests = true`.

### Directory-per-concern layout
- Pipeline stages get directories: `lang/syn/src/parser/`, `lang/syn/src/codegen/`, with
  one subdirectory per domain (`codegen/program/`, `codegen/accounts/`, `parser/accounts/`)
  and **one file per output artifact or concern** inside: `codegen/program/{entry,dispatch,
  handlers,cpi,instruction,accounts,idl,common}.rs`.
- One-type-per-file where the types are peers: `lang/src/accounts/{account,signer,program,
  sysvar,interface_account,...}.rs`. Flat one-integration-per-file: `spl/src/{token,mint,
  metadata,stake}.rs`.
- Directory modules always use `mod.rs` (never `foo.rs` + `foo/` side by side).
- Maximum module-directory depth below `src/` is **2** (`codegen/program/`,
  `parser/accounts/`). Deeper nesting is flattened.
- No `types.rs`/`state/`/`config/` convention: shared AST/domain types live in the crate's
  `lib.rs` (`lang/syn/src/lib.rs`) or in the domain file that owns them. The only sanctioned
  grab-bag name is `common.rs` (`codegen/program/common.rs`, `idl/common.rs`), kept small.

### mod.rs orchestration style
- Norm: docs + module list + re-exports + at most one thin entry function.
  `lang/syn/src/codegen/program/mod.rs` (40 lines): private `mod accounts; mod cpi; ...`
  plus a `generate()` that calls each submodule. `parser/mod.rs` is 9 lines;
  `lang/src/accounts/mod.rs` is a 1-line doc + `pub mod` list; `cli/src/fetch/mod.rs`
  declares 9 private submodules and re-exports the narrow surface with `use self::{...}`.
- Submodules inside a directory are **private by default** (`mod cpi;`), exposed only
  through the `mod.rs` surface. (`parser/accounts/mod.rs` at 833 lines is their exception,
  not the rule.)

### Naming
- Files are snake_case nouns for the thing owned (`account.rs` → `Account`) or verbs/nouns
  for the pipeline stage (`dispatch.rs`, `handlers.rs`, `resolve.rs`, `convert.rs`).
- Errors: library crates define one thiserror-style enum per crate (`client/src/lib.rs`
  `ClientError`; `lang/error/src/lib.rs` `ErrorCode` with documented numeric ranges);
  binaries use `anyhow` (`avm/src/lib.rs`, `cli/`). Error modules are named `error.rs`
  singular (`codegen/error.rs`, `parser/error.rs`, `idl/error.rs`).

### Public API discipline
- Curated root re-exports: `lang/src/lib.rs` does `pub use anchor_lang_error as error;`
  and builds a `pub mod prelude` for downstream users (lines 553–603).
- Macro-only/unstable surface is quarantined in `#[doc(hidden)] pub mod __private`
  (`lang/src/lib.rs` line 606) — public for technical reasons, invisible in docs.
- `pub(crate)` is rare in the public library (its API *is* the product) but used to gate
  feature-conditional internals (`lang/syn/src/lib.rs`: `pub(crate) mod hash` when the
  `hash` feature is off).

### Docs
- Every module file opens with a one-sentence `//!` line (`lang/src/accounts/account.rs`:
  "Account container that checks ownership on deserialization."). Crate `lib.rs` gets a
  multi-paragraph `//!` overview. User-facing types carry long `///` docs with examples;
  internal codegen files stay terse.

### Tests
- Integration tests: one file per feature in the crate's `tests/` dir
  (`lang/tests/{space,zero_copy,serialization,generics_test}.rs`, `lang/syn/tests/`,
  `avm/tests/`, `cli/tests/`).
- In-file `#[cfg(test)] mod tests` used sparingly, testing only that file's code
  (`avm/src/lib.rs`, `idl/src/convert.rs`, `lang/src/vec.rs`).

---

## Rules for coordinator-rs

Apply in order. All rules are subordinate to the non-goals at the bottom.

1. **File length.** Non-test code: soft cap **300** lines, hard cap **500** lines
   (excluding any trailing `#[cfg(test)] mod tests` block). Any source file over 500
   MUST be split; 300–500 should be split unless it is one cohesive `match`/state table.
   Test files (`crates/*/tests/*.rs` and `*_support/`): soft cap 800; split by scenario
   family when larger.
2. **Directory conversion.** When splitting `foo.rs`, create `foo/` with `mod.rs` and
   move the code into sibling files — never leave `foo.rs` next to `foo/`. Reuse the
   existing sibling files of the module first (e.g. `request_task/types.rs`) before
   inventing new ones.
3. **mod.rs contents.** Docs (`//!`), `mod` declarations, `pub use` re-exports, and at
   most ONE thin orchestration item (a constructor/spawn/entry fn ≤ ~50 lines that only
   delegates, per anchor's `codegen/program/mod.rs`). No business logic, no `impl` blocks
   with branching logic in `mod.rs`. Existing fat `mod.rs` files (e.g.
   `server/src/provider_session/mod.rs` 304, `core/src/request/machine/mod.rs` 276) are
   reduced to this shape by pushing logic into named siblings.
4. **Submodule privacy.** Inside a directory module, declare siblings `mod x;` (private)
   by default; re-export the minimal surface from `mod.rs` so all external paths keep the
   form `crate::module::Item`. Existing import paths from other files/crates must keep
   compiling — add `pub use` shims in `mod.rs`/`lib.rs` rather than rewriting callers.
5. **Where things live.** Shared-across-siblings structs/enums → the module's `types.rs`.
   Types with a single consumer stay in the consumer's file. Shared small helpers →
   `common.rs` (only sanctioned grab-bag name; ≤ 300 lines; never `utils.rs`/`helpers.rs`/
   `misc.rs`). Errors → one thiserror enum per module in `error.rs` (new modules use the
   singular name; existing `errors.rs` files may stay). Constants live next to their
   consumers, not in a global constants file.
6. **Naming.** snake_case file named for its single concern: nouns for type-owners
   (`permits.rs` → `PermitLedger`), verb/noun for pipeline stages (`admit.rs`,
   `settle.rs`, `classify.rs`). The file name must answer "what is the one thing in here."
7. **Visibility.** In `server` (binary crate): items are private or `pub(crate)`; plain
   `pub` only where an item genuinely crosses the crate's `lib.rs` surface for `main.rs`
   or `tests/`. In `core` and `protocol`: `pub` only for the deliberate API re-exported or
   reachable from `lib.rs`; everything else `pub(crate)` or private. No `pub` fields on
   structs unless serde-serialized or constructed literally across a crate boundary.
8. **Crate roots.** Each crate's `lib.rs` = `//!` overview + `pub mod` list + curated
   `pub use` re-exports of the handful of most-used types. No logic in `lib.rs`. No
   prelude module (anchor's prelude serves external consumers; we have none).
9. **Module docs.** Every file (including every new file created by a split) starts with a
   one-sentence `//!` summary; files owning concurrency or money invariants add 1–3 more
   `//!` lines stating the invariant (who owns the state, what must hold). Template:
   `//! <One sentence: what this module does.>` then optionally
   `//! Invariant: <what must always hold>.`
10. **Tests placement.** Unit tests: `#[cfg(test)] mod tests` at the bottom of the file
    whose code they exercise — when splitting a file, each extracted sibling takes its own
    tests with it. Integration/black-box tests: one feature per file in
    `crates/<crate>/tests/`, shared harness code in `tests/<name>_support/mod.rs` (already
    the pattern — keep it). Property tests stay in dedicated `*_properties.rs` files.
11. **Formatting.** Run `cargo fmt` with default settings; do NOT introduce `rustfmt.toml`
    during the decomposition (anchor's `imports_granularity = "One"` style is a possible
    separate follow-up, but mixing a whole-tree reformat into the split diffs makes them
    unreviewable). Adding anchor's `clippy.toml` line `allow-unwrap-in-tests = true` is
    permitted. `cargo clippy --workspace --all-targets` must stay clean.
12. **Split mechanics.** Every split is move-only: cut an item (fn/impl/struct + its
    tests + its `use` lines), paste into the sibling file, fix visibility with the
    narrowest modifier that compiles, re-export from `mod.rs` if outsiders used it.
    `cargo test --workspace` green after every file-level split, not just at the end.

---

## Anti-patterns to eliminate (measured in this workspace)

Current stats: 122 files, 33,607 lines; p50 = 238, p90 = 538, max = 1608. Ten largest
files overall: `server/src/request_task/driver.rs` 1608, `server/tests/http_chat.rs` 1177,
`server/tests/e2e_full_stack.rs` 1038, `server/src/contracts.rs` 860,
`server/src/ledger/settle.rs` 844, `server/tests/ledger_pg.rs` 782,
`server/tests/session_v2.rs` 724, `server/tests/recovery_pg.rs` 668,
`server/tests/http_harness.rs` 627, `server/src/http/chat.rs` 593.

Required decompositions (hard-cap violators first):

- **`server/src/request_task/driver.rs` (1608)** → `driver/` directory. Extract:
  `PermitLedger` + its `Drop` impl → `permits.rs`; `TaskInput`/`WireKind`/`WireOutcome`/
  `TimerKind` → merge into the module's existing `types.rs`; wire-event handling and
  timer handling into their own files; `driver/mod.rs` keeps the spawn/entry + main
  select loop only. Siblings `attempt.rs`, `classify.rs`, `funding.rs`, `terminal.rs`
  already exist — route extracted logic toward them where it belongs.
- **`server/src/contracts.rs` (860)** — a grab-bag of unrelated shared types → `contracts/`
  directory: `policy.rs` (`RequestPolicy`, `PriceCard`), `catalog.rs` (`CatalogSnapshot`,
  `ProtocolGen`), `frames.rs` (`ControlFrame`, `DataFrame`, `AttemptEvent`), `session.rs`
  (`SessionHandle`, `SessionCommand`, channels, `SubmitError`), `chunks.rs` (`ChunkFrame`,
  `chunk_pipe`, `PipeError`). `contracts/mod.rs` re-exports everything so no caller changes.
- **`server/src/ledger/settle.rs` (844)** → split settlement computation from SQL
  execution/idempotency handling within `ledger/` (e.g. `settle.rs` + `settle_sql.rs`, or
  a `settle/` dir if three-plus concerns emerge).
- **`server/src/http/chat.rs` (593)** → handler orchestration vs request validation vs
  SSE-streaming loop, within `http/` (siblings `sse.rs`, `errors.rs`, `limits.rs` exist).
- **`server/src/trust.rs` (548)** → `trust/` directory split by concern (verification vs
  state vs persistence, per its internal structure).
- **`protocol/src/json_v2/frames.rs` (521)** → split by frame family into siblings —
  WITHOUT touching any type name, field name, or serde attribute (golden vectors).
- Soft-cap violators to split opportunistically when touched: `core/src/settlement.rs`
  441, `core/src/fleet/admission.rs` 422, `server/src/fleet/admit.rs` 406,
  `protocol/src/binary.rs` 393, `server/src/provider_session/v2.rs` 376.
- Fat `mod.rs` (rule 3): `provider_session/mod.rs` 304, `core/request/machine/mod.rs` 276,
  `server/http/mod.rs` 202, `server/fleet/mod.rs` 220 — push logic into named siblings.
- Oversized test monoliths: `server/tests/http_chat.rs` 1177 and
  `server/tests/e2e_full_stack.rs` 1038 → split by scenario family, sharing the existing
  `http_harness.rs` / `*_support/` helpers.

---

## Non-goals (violating any of these fails the refactor)

- **No behavior changes.** Moves and visibility tightening only; identical runtime
  semantics; `cargo test --workspace` output unchanged (same tests, same results).
- **No dependency changes.** `[dependencies]` / `[workspace.dependencies]` untouched;
  no new crates; the three-crate structure is fixed.
- **No renaming of public wire types.** Everything in `crates/protocol` that serializes
  (type names, field names, `#[serde(...)]` attributes, enum variant casing) is pinned by
  golden vectors in `fixtures/` and by the Go/Swift peers. Files may move; the serde
  surface may not change by one byte.
- **No public-path breakage across crates.** `darkbloom-core` / `darkbloom-protocol`
  paths used by `server` keep resolving — use re-export shims instead of editing callers
  where possible.
