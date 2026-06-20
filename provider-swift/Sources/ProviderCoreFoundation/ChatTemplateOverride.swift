// Copyright © 2026 Eigen Labs.
//
// Hash-gated, NON-MUTATING chat-template override (DAR-329).
//
// Some published model snapshots ship a `chat_template.jinja` that throws at
// request time on legitimate request shapes (see `GemmaToolTemplate` for the
// Gemma 4 case: unguarded `value['type'] | upper` over union / typeless / null
// tool-schema fields). The durable fix is to render with the upstream-fixed
// template instead — WITHOUT touching the bytes on disk.
//
// Why non-mutating: `chat_template.jinja` is part of the model's integrity set
// (`ModelScanner.integrityFileNames`), so `WeightHasher.computeHash` — the
// attestation / integrity hash the provider reports — hashes it. Rewriting the
// file on disk would change that hash and break the match against the published
// registry manifest (which was built from the original template), failing
// attestation. So instead we keep the file untouched and substitute the
// corrected template ONLY at the two render chokepoints:
//
//   • `TemplateRenderCheck.renderOK` (scan-time self-check → `template_render_ok`)
//   • `LocalTokenizerLoader` / `LocalTokenizerBridge.applyChatTemplate`
//     (runtime tokenize, via swift-transformers' `.literal` template argument)
//
// Gating on the on-disk template's SHA-256 keeps this surgical: it fires ONLY
// for the exact known-broken revision and self-disables the moment the registry
// republishes a corrected template (the on-disk hash stops matching). It never
// touches any other model or any healthy template, and — because the corrected
// template renders byte-identically for healthy inputs (covered by tests) — it
// is behavior-preserving outside the previously-crashing shapes.
//
// Relationship to `ToolSchemaNormalization` (DAR-130): that pass already
// collapses union types and defaults typeless nodes within
// `tools[].function.parameters` before render, so the common tool path is
// protected even with the old template. This override removes the reliance on
// that (lossy) normalization for Gemma: it renders unions faithfully and also
// covers paths normalization does not walk (e.g. `function.response`). Both
// layers are kept — normalization still defends every OTHER model's template.

import Crypto
import Foundation

public enum ChatTemplateOverride {

    /// Map of known-broken `chat_template.jinja` SHA-256 (lowercase hex) to the
    /// corrected template text to render in its place.
    ///
    /// Keyed by content hash (not model ID) so the substitution is exact and
    /// self-limiting. Add an entry per known-broken published revision.
    static let replacements: [String: String] = [
        GemmaToolTemplate.brokenSHA256: GemmaToolTemplate.correctedToolTemplate
    ]

    /// Corrected template for a raw template STRING, or `nil` when the string is
    /// not a known-broken revision. Pure; does not touch disk. Used by the
    /// scan-time render self-check, which already holds the template text.
    public static func corrected(forTemplate template: String) -> String? {
        corrected(forTemplate: template, using: replacements)
    }

    /// Corrected template for the `chat_template.jinja` in a model snapshot
    /// directory, or `nil` when the file is absent or not a known-broken
    /// revision. Reads (but never writes) the on-disk file. Used at tokenizer
    /// load so the runtime render uses the corrected template via swift-
    /// transformers' `.literal` chat-template argument.
    public static func correctedTemplate(forSnapshotDir snapshotDir: URL) -> String? {
        correctedTemplate(forSnapshotDir: snapshotDir, using: replacements)
    }

    // MARK: - Testable cores (replacement map injected)

    static func corrected(forTemplate template: String, using map: [String: String]) -> String? {
        map[sha256Hex(Data(template.utf8))]
    }

    static func correctedTemplate(forSnapshotDir snapshotDir: URL, using map: [String: String]) -> String? {
        let url = snapshotDir.appendingPathComponent("chat_template.jinja")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return map[sha256Hex(data)]
    }

    /// Lowercase-hex SHA-256, matching `WeightHasher`'s digest formatting and
    /// the `shasum -a 256` values pinned in `GemmaToolTemplate`.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
