import Foundation
import Testing
@testable import ProviderCore

/// launchd does not inherit the installing shell, so a `DARKBLOOM_*` key the
/// sources read reaches an installed service only through
/// `LaunchAgent.passthroughEnvKeys`. A key in no list works in a foreground
/// run and is silently unset in the service. These tests read the sources:
/// every key is declared once, as forwarded or as not forwarded with a reason
/// (`LaunchAgent.unforwardedEnvKeyGroups`), and no declaration outlives its key.
@Suite struct ServiceEnvironmentReachTests {
    // MARK: - The scan

    /// The `"DARKBLOOM_..."` string literals of `provider-swift/Sources`.
    /// `libs/` is not read: the SDK declares its own names there.
    struct Literals {
        /// A complete key, with the files that spell it.
        var keys: [String: Set<String>] = [:]
        /// A literal keys are built from: it ends in an interpolation, or in
        /// `_` anywhere but as the argument of `hasPrefix(`.
        var builtPrefixes: Set<String> = []
        /// A literal ending in `_` that is the argument of `hasPrefix(`: it
        /// selects a family from an environment and builds no key.
        var filterPrefixes: Set<String> = []
        /// A literal that starts with a key and goes on with other text.
        var unclassified: [String] = []
        var files: Set<String> = []

        /// The keys spelled in any file but `excluded`.
        func keys(outside excluded: Set<String>) -> Set<String> {
            Set(keys.filter { !$0.value.isSubset(of: excluded) }.keys)
        }

        /// An opening quote and the name after it. Held here so one scan
        /// compiles it once, not once a file.
        private let literal = #/"(DARKBLOOM_[A-Z0-9_]*)/#

        /// Sorts each `"DARKBLOOM_..."` literal of one source file's text
        /// into the sets above.
        mutating func add(source text: String, file: String) {
            for match in text.matches(of: literal) {
                let name = String(match.output.1)
                let rest = text[match.range.upperBound...]
                if rest.hasPrefix("\\(") {
                    builtPrefixes.insert(name)
                } else if !rest.hasPrefix("\"") {
                    unclassified.append("\(file): \"\(name)\(rest.prefix(24))")
                } else if !name.hasSuffix("_") {
                    keys[name, default: []].insert(file)
                } else if text[..<match.range.lowerBound].hasSuffix("hasPrefix(") {
                    filterPrefixes.insert(name)
                } else {
                    builtPrefixes.insert(name)
                }
            }
        }
    }

    static let registryFile = "ProviderCore/Service/LaunchAgent+UnforwardedEnvironment.swift"
    static let forwardListFile = "ProviderCore/Service/LaunchAgent.swift"

    /// The registry spells every key it declares, so it is never a reader.
    static func scan() throws -> Literals {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
            .standardizedFileURL
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var found = Literals()
        for case let url as URL in files where url.pathExtension == "swift" {
            let file = String(url.standardizedFileURL.path.dropFirst(sources.path.count + 1))
            found.files.insert(file)
            guard file != registryFile else { continue }
            found.add(source: try String(contentsOf: url, encoding: .utf8), file: file)
        }
        return found
    }

    // MARK: - The audit

    /// What is wrong between the keys the sources spell and the declarations.
    struct Audit: Equatable {
        /// Read in the sources, in neither list.
        var undeclared: [String] = []
        /// Declared more than once: in both lists, twice in one, or beside a
        /// prefix that already covers it.
        var declaredTwice: [String] = []
        /// Declared, and no source outside the two lists spells it any more.
        var stale: [String] = []
        /// Forwarded, and no provider source outside the forward list reads it.
        var forwardedWithoutReader: [String] = []
        /// A prefix keys are built from that is not a declared key family, or
        /// a filter's prefix that is neither one nor a known family filter.
        var undeclaredPrefixes: [String] = []
    }

    static func audit(
        spelled: Set<String>, read: Set<String>, builtPrefixes: Set<String>, filterPrefixes: Set<String>,
        forwarded: Set<String>, unforwarded: [String], unforwardedPrefixes: Set<String>
    ) -> Audit {
        let declared = Set(unforwarded)
        func covered(_ key: String) -> Bool { unforwardedPrefixes.contains { key.hasPrefix($0) } }
        var audit = Audit()
        audit.undeclared = spelled.filter {
            !forwarded.contains($0) && !declared.contains($0) && !covered($0) && !notEnvironmentKeys.contains($0)
        }.sorted()
        let repeated = Dictionary(grouping: unforwarded, by: { $0 }).filter { $0.value.count > 1 }.keys
        audit.declaredTwice = Set(repeated).union(declared.intersection(forwarded))
            .union(declared.union(forwarded).filter(covered))
            .union(declared.union(forwarded).intersection(notEnvironmentKeys)).sorted()
        audit.stale = declared.subtracting(read)
            .union(unforwardedPrefixes.subtracting(builtPrefixes).subtracting(filterPrefixes))
            .union(notEnvironmentKeys.subtracting(spelled)).union(familyFilters.subtracting(filterPrefixes)).sorted()
        audit.forwardedWithoutReader = forwarded.subtracting(read).sorted()
        // `familyFilters` excuses a filter only: a prefix that builds keys is a family to declare.
        audit.undeclaredPrefixes = builtPrefixes.subtracting(unforwardedPrefixes)
            .union(filterPrefixes.subtracting(unforwardedPrefixes).subtracting(familyFilters)).sorted()
        return audit
    }

    static func audit(_ literals: Literals, forwarded: Set<String> = LaunchAgent.forwardedEnvKeys) -> Audit {
        audit(spelled: Set(literals.keys.keys), read: literals.keys(outside: [forwardListFile]),
              builtPrefixes: literals.builtPrefixes, filterPrefixes: literals.filterPrefixes, forwarded: forwarded,
              unforwarded: LaunchAgent.unforwardedEnvKeyGroups.flatMap(\.keys),
              unforwardedPrefixes: Set(LaunchAgent.unforwardedEnvKeyPrefixes.keys))
    }

    // MARK: - What the scan cannot decide by itself

    /// A heredoc delimiter in a printed shell command
    /// (`ClusterLinkIsolationPlan.manualDelimiter`), not a variable.
    static let notEnvironmentKeys: Set<String> = ["DARKBLOOM_CLUSTER_LINK"]

    /// Prefixes the sources filter an environment by (`hasPrefix`: the
    /// checkpoint identity, the calibration launch, the deadline and
    /// performance profiles). An entry excuses the filter, never a key built
    /// from the same prefix.
    static let familyFilters: Set<String> = [
        "DARKBLOOM_", "DARKBLOOM_CBV2_", "DARKBLOOM_DIFFUSION_", "DARKBLOOM_GEMMA4_", "DARKBLOOM_GPTOSS_",
        "DARKBLOOM_MIMO_", "DARKBLOOM_MTP_", "DARKBLOOM_NEMOTRON35_", "DARKBLOOM_QWEN4_", "DARKBLOOM_QWEN_",
    ]

    /// Forwarded keys no provider source reads. The SDK under `libs/` reads
    /// them, which this scan does not cover, so a retired one is not caught
    /// here. `DARKBLOOM_MLX_RESOURCE_DEBUG` has no reader in this repository
    /// or its submodules; it stays because the forward list must not change
    /// without a maintainer's decision.
    static let forwardedForTheSDK: Set<String> = [
        "DARKBLOOM_GEMMA4_COMPILED_FEEDFORWARD", "DARKBLOOM_GEMMA4_COMPILED_FEEDFORWARD_SORTED",
        "DARKBLOOM_GEMMA4_MTP_COMMAND_BUFFERS", "DARKBLOOM_GEMMA4_NAX_ROW_MAP",
        "DARKBLOOM_GRAMMAR_ONLY_TOOL_PARSING", "DARKBLOOM_MIMO_DECODE_EXPERTS", "DARKBLOOM_MIMO_DECODE_ROUTER_GEMV",
        "DARKBLOOM_MIMO_FUSED_DECODE_NORMS", "DARKBLOOM_MIMO_RECTANGULAR_SCALAR_DENSE",
        "DARKBLOOM_MIMO_ROW_EXACT_PROJECTION", "DARKBLOOM_MLX_RESOURCE_DEBUG", "DARKBLOOM_NATIVE_SEGMENT_RELEASE",
        "DARKBLOOM_QWEN35_DECODE_COMMAND_BUFFERS", "DARKBLOOM_TTFT_GDN_BLOCKED",
    ]

    /// The keys whose forwarding is an open maintainer decision
    /// (`UnforwardedReason.undecided`). This set only loses keys: a decided
    /// key moves to `passthroughEnvKeys` or to a real reason and leaves here.
    static let openDecisions: Set<String> = [
        "DARKBLOOM_ACTIVATION_RESERVE_GB", "DARKBLOOM_CBV2_LEGACY_REQUEST_TIMEOUT", "DARKBLOOM_CLUSTER_QUEUE_WAITING",
        "DARKBLOOM_CLUSTER_WARMUP", "DARKBLOOM_ENGINE_V2_VLM_PARITY_CHECK", "DARKBLOOM_EXPERIMENT_HASH_STREAM_FIRST",
        "DARKBLOOM_EXPERIMENT_HASH_WORKERS", "DARKBLOOM_MAX_IMAGE_MEGAPIXELS", "DARKBLOOM_MAX_MEDIA_MIB",
        "DARKBLOOM_MAX_REQUEST_IMAGE_MEGAPIXELS", "DARKBLOOM_MAX_REQUEST_VIDEO_FRAME_MEGAPIXELS",
        "DARKBLOOM_MAX_VIDEOS_PER_REQUEST", "DARKBLOOM_MAX_VIDEO_SECONDS", "DARKBLOOM_MEM_CAP_FRACTION",
        "DARKBLOOM_NO_UPDATE_CHECK", "DARKBLOOM_PREFIX_CACHE_SSD_TTL_SECONDS", "DARKBLOOM_TEMPLATE_JSON",
        "DARKBLOOM_TEMPLATE_JSON_LEGACY", "DARKBLOOM_VISION_MAX_TOWER_PATCHES",
    ]

    // MARK: - Tests

    @Test func everyKeyTheSourcesReadIsDeclaredOnce() throws {
        let literals = try Self.scan()
        #expect(literals.files.count > 100, "found only \(literals.files.count) source files")
        #expect(literals.files.isSuperset(of: [Self.registryFile, Self.forwardListFile]),
                "the two lists moved; update the paths this scan sets aside")
        #expect(literals.keys.count > 200, "found only \(literals.keys.count) keys")
        #expect(literals.unclassified.isEmpty, """
            a literal starts with a DARKBLOOM_ key and continues with other text; spell the key alone \
            (or interpolate its constant) so this scan can read it: \(literals.unclassified)
            """)
        let audit = Self.audit(literals)
        #expect(audit.undeclared.isEmpty, """
            read in the sources and declared in neither list, so an installed service never sees it. Add it to \
            LaunchAgent.passthroughEnvKeys if it must reach the service, or to LaunchAgent.unforwardedEnvKeyGroups \
            with the reason it must not: \(audit.undeclared)
            """)
        #expect(audit.declaredTwice.isEmpty, "declared more than once; keep one declaration: \(audit.declaredTwice)")
        #expect(audit.stale.isEmpty, "declared, but no source spells it any more; remove the entry: \(audit.stale)")
        #expect(audit.undeclaredPrefixes.isEmpty, """
            a key prefix this scan does not know. If keys are built from it (it ends in an interpolation, or in _ \
            outside hasPrefix), declare the family in LaunchAgent.unforwardedEnvKeyPrefixes or spell each key as \
            its own literal; if it is only a hasPrefix argument, add it to familyFilters here: \
            \(audit.undeclaredPrefixes)
            """)
        #expect(Set(audit.forwardedWithoutReader) == Self.forwardedForTheSDK, """
            forwarded keys that no provider source reads changed: \
            \(Set(audit.forwardedWithoutReader).symmetricDifference(Self.forwardedForTheSDK).sorted())
            """)
    }

    /// The defect this suite exists for: a key the request path reads, missing
    /// from the forward list. The image cap is the key that was once missing.
    @Test func aReadKeyMissingFromTheForwardListIsReported() throws {
        let imageCap = MediaIngest.maxImagesEnvironmentKey
        #expect(LaunchAgent.forwardedEnvKeys.contains(imageCap))
        let audit = Self.audit(try Self.scan(), forwarded: LaunchAgent.forwardedEnvKeys.subtracting([imageCap]))
        #expect(audit.undeclared == [imageCap])
    }

    @Test func theAuditNamesEachKindOfFault() {
        let audit = Self.audit(
            spelled: ["DARKBLOOM_A", "DARKBLOOM_B", "DARKBLOOM_NEW", "DARKBLOOM_FAMILY_X", "DARKBLOOM_CLUSTER_LINK"],
            read: ["DARKBLOOM_B", "DARKBLOOM_NEW", "DARKBLOOM_FAMILY_X", "DARKBLOOM_CLUSTER_LINK"],
            builtPrefixes: ["DARKBLOOM_FAMILY_", "DARKBLOOM_BUILT_"], filterPrefixes: Self.familyFilters,
            forwarded: ["DARKBLOOM_A", "DARKBLOOM_B"],
            unforwarded: ["DARKBLOOM_B", "DARKBLOOM_GONE", "DARKBLOOM_GONE", "DARKBLOOM_FAMILY_X"],
            unforwardedPrefixes: ["DARKBLOOM_FAMILY_", "DARKBLOOM_UNUSED_"])
        #expect(audit == Audit(
            undeclared: ["DARKBLOOM_NEW"],
            declaredTwice: ["DARKBLOOM_B", "DARKBLOOM_FAMILY_X", "DARKBLOOM_GONE"],
            stale: ["DARKBLOOM_GONE", "DARKBLOOM_UNUSED_"],
            forwardedWithoutReader: ["DARKBLOOM_A"],
            undeclaredPrefixes: ["DARKBLOOM_BUILT_"]))
    }

    /// A prefix is a filter only as the argument of `hasPrefix(`. Joined or
    /// interpolated it builds keys the scan cannot read, so it is reported
    /// even when the same text is a known family filter.
    @Test func aPrefixThatBuildsKeysIsNotExcusedAsAFilter() {
        var literals = Literals()
        literals.add(source: #"""
            for (key, value) in environment where key.hasPrefix("DARKBLOOM_CBV2_") { hash(key, value) }
            let joined = environment["DARKBLOOM_" + name], spliced = environment["DARKBLOOM_CBV2_\(model)_CAP"]
            let whole = environment["DARKBLOOM_WHOLE"]; print("DARKBLOOM_WHOLE is set")
            """#, file: "Reader.swift")
        #expect(literals.filterPrefixes == ["DARKBLOOM_CBV2_"])
        #expect(literals.builtPrefixes == ["DARKBLOOM_", "DARKBLOOM_CBV2_"])
        #expect(literals.keys == ["DARKBLOOM_WHOLE": ["Reader.swift"]])
        #expect(literals.unclassified.count == 1)
        #expect(Self.familyFilters.isSuperset(of: literals.builtPrefixes))
        #expect(Self.audit(literals).undeclaredPrefixes == ["DARKBLOOM_", "DARKBLOOM_CBV2_"])
    }

    /// The declarations describe what `passthroughEnvironment` does: with
    /// every key exported, exactly the forwarded ones are in the plist.
    @Test func theForwardedKeysAreWhatThePlistCarries() throws {
        let everyKey = Set(try Self.scan().keys.keys).union(LaunchAgent.forwardedEnvKeys)
            .union(["DARKBLOOM_CLUSTER_PREFIX_SSD_MIN_FREE_GB"])
        let shell = Dictionary(uniqueKeysWithValues: everyKey.map { ($0, "1") })
        let plist = LaunchAgent.passthroughEnvironment(from: shell, injected: [])
        #expect(Set(plist.keys) == LaunchAgent.forwardedEnvKeys)
        let unforwarded = everyKey.subtracting(LaunchAgent.forwardedEnvKeys).subtracting(Self.notEnvironmentKeys)
        let withoutReason = unforwarded.filter { LaunchAgent.unforwardedReason(for: $0) == nil }.sorted()
        #expect(withoutReason.isEmpty, "not forwarded and without a reason: \(withoutReason)")
        let withReason = LaunchAgent.forwardedEnvKeys.filter { LaunchAgent.unforwardedReason(for: $0) != nil }.sorted()
        #expect(withReason.isEmpty, "forwarded and given a reason not to be: \(withReason)")
    }

    @Test func theOpenDecisionsOnlyShrink() {
        let open = Set(LaunchAgent.unforwardedEnvKeys.filter { $0.value == .undecided }.keys)
        #expect(open.subtracting(Self.openDecisions).isEmpty, """
            declared undecided, which is closed to new keys; forward it or give it a real reason: \
            \(open.subtracting(Self.openDecisions).sorted())
            """)
        #expect(Self.openDecisions.subtracting(open).isEmpty, """
            decided; remove it from openDecisions here: \(Self.openDecisions.subtracting(open).sorted())
            """)
        #expect(!LaunchAgent.unforwardedEnvKeyPrefixes.values.contains(.undecided))
    }

    /// `unforwardedReason(for:)` answers with a declared prefix the key starts
    /// with. Were one declared prefix to start with another, a key under both
    /// would get whichever the dictionary yields first.
    @Test func noDeclaredPrefixCoversAnother() {
        let prefixes = Array(LaunchAgent.unforwardedEnvKeyPrefixes.keys)
        let covered = prefixes.filter { prefix in prefixes.contains { $0 != prefix && prefix.hasPrefix($0) } }
        #expect(covered.isEmpty, """
            a declared prefix lies under another, so a key under both has no one reason; keep the wider \
            prefix or list the keys: \(covered.sorted())
            """)
    }
}
