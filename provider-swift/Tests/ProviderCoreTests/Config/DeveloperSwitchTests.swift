import Foundation
import Testing
@testable import ProviderBuildEnvironment
@testable import ProviderCore

/// `DeveloperSwitch` declares which builds honour each developer-only
/// variable, and `value(environment:posture:)` is the only reader. The first
/// half checks the reader against the declarations in every build posture,
/// and pins, by their literal names, the variables that were gated before
/// they became switches and the ones production still honours. The second
/// half reads the sources with `ServiceEnvironmentReachTests.scan`: a
/// variable that is developer-only by its declared reason or by its name is
/// a switch, a switch's variable is spelled only in its declaration and no
/// environment is read through a constant that holds its name, and the
/// `DEBUG` condition becomes a value in one place.
///
/// Nothing here is a copy of a list that grows: a switch, a location or a
/// constant added later needs no entry in this file unless a signed build
/// honours it. Two sets are exact, and are meant to need a second hand:
/// `openDecisions`, every developer-only variable production's release build
/// honours, which may only shrink; and `nonProduction`, what a signed DevNet
/// or staging build honours beside it.
@Suite struct DeveloperSwitchTests {
    // MARK: - The declarations

    /// The variables a debug build read and no signed build did, before they
    /// became switches. Each keeps that gate (the configuration axis).
    static let debugOnly: Set<String> = [
        "DARKBLOOM_ADDON_DEV_IDENTITY", "DARKBLOOM_AUTH_TOKEN_PATH", "DARKBLOOM_CLUSTER_FORCE_MODE",
        "DARKBLOOM_DEBUG_CACHE_KEY_FILE", "DARKBLOOM_DEBUG_CLUSTER_SOLO_GRACE_SECONDS",
        "DARKBLOOM_DEBUG_COORDINATOR_CERT_SHA256", "DARKBLOOM_DEBUG_OWNER_EXECUTABLE", "DARKBLOOM_DEBUG_ROSTER_UNPAIRED",
        "DARKBLOOM_DEBUG_SE_KEY_FILE", "DARKBLOOM_DEV_BENCH_CHIP", "DARKBLOOM_DEV_BENCH_PLANNER_CAP_GIB",
        "DARKBLOOM_KEYCHAIN_ACCESS_GROUP", "DARKBLOOM_KV_BACKEND_GUARD", "DARKBLOOM_LOADED_MODELS_FILE",
        "DARKBLOOM_LOCAL_DIR", "DARKBLOOM_PID_FILE", "DARKBLOOM_R2_CDN_URL", "DARKBLOOM_STATE_FILE",
        "DARKBLOOM_VERIFIED_WEIGHTS_FILE", "DARKBLOOM_WATCHDOG_STATE",
    ]

    /// The variable every build but production's read, a signed DevNet or
    /// staging build included, before it became a switch. It keeps that gate
    /// (the environment axis).
    static let nonProduction: Set<String> = ["DARKBLOOM_CLUSTER_DEVELOPER_SSH"]

    /// The switches production's release build honours, each an open
    /// maintainer decision (`DeveloperSwitch.EveryBuildReason.undecided`).
    /// This set only loses variables: a decided switch becomes `debugOnly`
    /// or `nonProduction`, or gets a reason of its own, and leaves here.
    static let openDecisions: Set<String> = [
        "DARKBLOOM_ADDON_SOCKET", "DARKBLOOM_CLUSTER_PREFIX_SSD_DIR", "DARKBLOOM_CLUSTER_SUPERVISOR_STATE",
        "DARKBLOOM_DEBUG_LOCAL_ERRORS", "DARKBLOOM_DESKTOP_DIR", "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL",
        "DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY", "DARKBLOOM_PREFIX_CACHE_TEST_ROOT", "DARKBLOOM_SANDBOX_ROOT",
    ]

    /// The variables `posture` reads when every one of them is set.
    static func honoured(by posture: BuildPosture) -> Set<String> {
        Set(DeveloperSwitch.allCases.filter { $0.value(environment: [$0.environmentKey: "set"], posture: posture) == "set" }
            .map(\.environmentKey))
    }

    /// The variables of the switches whose declared availability `matches`.
    static func declared(_ matches: (DeveloperSwitch.Availability) -> Bool) -> Set<String> {
        Set(DeveloperSwitch.allCases.filter { matches($0.availability) }.map(\.environmentKey))
    }

    /// The reader against the declarations: every switch there is, so one
    /// added later is checked without an entry here.
    @Test func eachBuildHonoursExactlyTheSwitchesDeclaredForIt() {
        #expect(Set(BuildPosture.allCases).count == BuildPosture.Configuration.allCases.count * BuildEnvironment.allCases.count)
        let debugOnly = Self.declared { $0 == .debugOnly }, nonProduction = Self.declared { $0 == .nonProduction }
        let everyBuild = Self.declared { if case .everyBuild = $0 { true } else { false } }
        #expect(debugOnly.count + nonProduction.count + everyBuild.count == DeveloperSwitch.allCases.count)
        for environment in BuildEnvironment.allCases {
            let offProduction = environment == .prod ? [] : nonProduction
            #expect(Self.honoured(by: BuildPosture(configuration: .release, environment: environment))
                    == everyBuild.union(offProduction), "a release build for \(environment)")
            #expect(Self.honoured(by: BuildPosture(configuration: .debug, environment: environment))
                    == debugOnly.union(everyBuild).union(offProduction), "a debug build for \(environment)")
        }
    }

    /// The variables that were gated before the move, by name: a debug build
    /// of production's environment ignores the SSH switch, a signed DevNet
    /// build honours it and none of the debug-only ones.
    @Test func aSwitchThatWasGatedKeepsItsBuilds() {
        for posture in BuildPosture.allCases {
            let honoured = Self.honoured(by: posture)
            #expect(honoured.intersection(Self.debugOnly) == (posture.configuration == .debug ? Self.debugOnly : []), "\(posture)")
            #expect(honoured.intersection(Self.nonProduction) == (posture.environment == .prod ? [] : Self.nonProduction),
                    "\(posture)")
            #expect(honoured.isSuperset(of: Self.openDecisions), "\(posture)")
        }
    }

    @Test func aSwitchABuildIgnoresReadsAsUnset() {
        for developerSwitch in DeveloperSwitch.allCases {
            let key = developerSwitch.environmentKey
            for posture in BuildPosture.allCases {
                let honoured = developerSwitch.isHonoured(by: posture)
                #expect(developerSwitch.value(environment: [key: "set"], posture: posture) == (honoured ? "set" : nil))
                #expect(developerSwitch.ignoredValue(environment: [key: "set"], posture: posture) == (honoured ? nil : "set"))
                // Exactly as set: each reader keeps its own rule for an empty value.
                #expect(developerSwitch.value(environment: [key: ""], posture: posture) == (honoured ? "" : nil))
                #expect(developerSwitch.value(environment: [:], posture: posture) == nil)
                #expect(developerSwitch.ignoredValue(environment: [:], posture: posture) == nil)
            }
        }
    }

    /// What production's release build reads, exactly and by name: the open
    /// decisions and nothing else. The comparison is with the names above,
    /// not with the declarations, so a switch declared for every build under
    /// a reason of its own is refused here until it is named.
    @Test func productionsReleaseBuildHonoursExactlyTheOpenDecisions() {
        let honoured = Self.honoured(by: BuildPosture(configuration: .release, environment: .prod))
        #expect(honoured == Self.openDecisions, """
            production's release build honours a developer switch that openDecisions does not name, or ignores one it \
            names: \(honoured.symmetricDifference(Self.openDecisions).sorted())
            """)
        let undecided = Self.declared { $0 == .everyBuild(.undecided) }
        #expect(undecided.subtracting(Self.openDecisions).isEmpty, """
            declared undecided, which is closed to new switches; gate it, or give it a reason of its own: \
            \(undecided.subtracting(Self.openDecisions).sorted())
            """)
        #expect(Self.openDecisions.subtracting(undecided).isEmpty, """
            decided; remove it from openDecisions here: \(Self.openDecisions.subtracting(undecided).sorted())
            """)
    }

    /// A signed DevNet or staging build is a release build too. It honours
    /// what production's does and the one variable gated on the environment,
    /// by name. A second `nonProduction` switch is a variable signed builds
    /// read, so it is pinned here by hand as well.
    @Test func aSignedNonProductionBuildHonoursExactlyTheOpenDecisionsAndTheEnvironmentGatedSwitch() {
        let expected = Self.openDecisions.union(Self.nonProduction)
        for environment in BuildEnvironment.allCases where environment != .prod {
            let honoured = Self.honoured(by: BuildPosture(configuration: .release, environment: environment))
            #expect(honoured == expected, """
                the release build for \(environment) honours a developer-only variable outside openDecisions and \
                nonProduction, or ignores one of them: \(honoured.symmetricDifference(expected).sorted())
                """)
        }
    }

    @Test func theCurrentPostureIsThisBuild() {
        #expect(BuildPosture.current == BuildPosture(configuration: .current, environment: .current))
        #expect(BuildPosture.current.environment == BuildEnvironment.current)
        #if DEBUG
        #expect(BuildPosture.current.configuration == .debug && BuildPosture.current.isDebug)
        #else
        #expect(BuildPosture.current.configuration == .release && !BuildPosture.current.isDebug)
        #endif
        #expect(BuildPosture(debug: true) == BuildPosture(configuration: .debug, environment: .current))
        #expect(BuildPosture(debug: false) == BuildPosture(configuration: .release, environment: .current))
        for environment in BuildEnvironment.allCases {
            #expect(BuildPosture(environment: environment).isProduction == (environment == .prod))
            #expect(BuildPosture(environment: environment).configuration == .current)
        }
        // The benchmark reports write these words.
        #expect(BuildPosture.Configuration.allCases.map(\.rawValue) == ["debug", "release"])
    }

    @Test func everyLocationOverrideIsADebugOnlySwitchOfItsOwn() {
        let switches = LocationOverride.allCases.map(\.developerSwitch)
        #expect(Set(switches).count == LocationOverride.allCases.count)
        #expect(switches.allSatisfy { $0.availability == .debugOnly })
    }

    // MARK: - The sources

    static let declarationFile = "ProviderBuildEnvironment/DeveloperSwitch.swift"
    static let postureFile = "ProviderBuildEnvironment/BuildPosture.swift"

    /// A name that says the variable is not for a release.
    static func saysDeveloperOnly(_ key: String) -> Bool {
        !Set(key.split(separator: "_")).isDisjoint(with: ["DEBUG", "DEV", "DEVELOPER", "TEST"])
    }

    /// What the sources do with the switches, beyond the literals
    /// `ServiceEnvironmentReachTests.Literals` reads.
    struct Uses {
        /// A constant initialised from a switch's `environmentKey` or
        /// `rawValue`: a second name for the variable. It is for words, for a
        /// test's environment and for what a process writes into a child's
        /// environment.
        struct Name: Hashable {
            var file: String
            /// The type that declares it.
            var type: String
            var name: String
        }

        /// An environment subscripted by a path of identifiers and not
        /// assigned through.
        struct Subscript: Hashable {
            var file: String
            /// The type whose body holds it, for a bare name declared in the
            /// same file; empty otherwise.
            var type: String
            var expression: String
        }

        /// The cases that sources outside the two declarations name.
        var referenced: Set<String> = []
        var names: Set<Name> = []
        var subscripts: [Subscript] = []
        /// The files where a `DEBUG` condition only selects a constant: a
        /// build configuration turned into a value.
        var debugConstants: Set<String> = []

        private let reference = #/DeveloperSwitch\.([a-z][A-Za-z0-9]*)/#
        private let name = #/let\s+(\w+)\s*(?::\s*String\s*)?=\s*(?:DeveloperSwitch|LocationOverride)\.\w+\.(?:environmentKey|rawValue)\b/#
        // Two patterns, each led by plain text: one that starts with a choice costs five times as much.
        private let subscripted = #/nvironment\[\s*([A-Za-z_][A-Za-z0-9_.]*)\s*\](\s*=(?!=))?/#
        private let subscriptedShort = #/\benv\[\s*([A-Za-z_][A-Za-z0-9_.]*)\s*\](\s*=(?!=))?/#
        private let typeDeclaration = #/\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private|open|final|indirect|nonisolated)\s+)*(?:enum|struct|class|actor|extension)\s+(?!func\b|var\b|let\b)([A-Za-z_][A-Za-z0-9_.]*)/#
        private let debugConstant = #/#if\s+!?DEBUG\s*\n\s*(?:return\s+|[^\n]*=\s*)?(?:true|false|\.debug|\.release|"debug"|"release")\s*\n\s*#else\s*\n\s*(?:return\s+|[^\n]*=\s*)?(?:true|false|\.debug|\.release|"debug"|"release")\s*\n\s*#endif/#

        /// Each environment read through one of `names`, by its qualified
        /// name anywhere or by its bare or `Self.` name in the type that
        /// declares it, or through a switch itself (its `environmentKey` or
        /// its `rawValue`): `file: expression`. Such a read ignores the build.
        var reads: [String] {
            subscripts.filter { read in
                if read.expression.hasPrefix("DeveloperSwitch.") || read.expression.hasPrefix("LocationOverride.") { return true }
                return names.contains { name in
                    let qualified = name.type + "." + name.name
                    return read.expression == qualified || read.expression.hasSuffix("." + qualified)
                        || (Self.bare(read.expression) == name.name && read.file == name.file && read.type == name.type)
                }
            }.map { "\($0.file): \($0.expression)" }
        }

        /// `Self.name` names the same constant as `name` does.
        private static func bare(_ expression: String) -> String {
            expression.hasPrefix("Self.") ? String(expression.dropFirst("Self.".count)) : expression
        }

        mutating func add(source: String, file: String) {
            // Most files name no switch. A search of the file's bytes, which costs a hundredth of a pattern's
            // pass, keeps the patterns off them.
            let bytes = source.data(using: .utf8) ?? Data()
            func spells(_ word: String) -> Bool { bytes.range(of: Data(word.utf8)) != nil }
            if spells("DEBUG"), source.contains(debugConstant) { debugConstants.insert(file) }
            guard file != declarationFile, file != ServiceEnvironmentReachTests.registryFile else { return }
            let namesASwitch = spells("DeveloperSwitch.")
            if namesASwitch {
                referenced.formUnion(source.matches(of: reference).map { String($0.output.1) })
            }
            let declaredHere = !(namesASwitch || spells("LocationOverride.")) ? [] : source.matches(of: name).map {
                Name(file: file, type: enclosingType(of: $0.range.lowerBound, in: source), name: String($0.output.1))
            }
            names.formUnion(declaredHere)
            let patterns = [spells("nvironment[") ? subscripted : nil, spells("env[") ? subscriptedShort : nil]
            for match in patterns.compactMap({ $0 }).flatMap({ source.matches(of: $0) }) where match.output.2 == nil {
                let expression = String(match.output.1)
                let bareName = declaredHere.contains { $0.name == Self.bare(expression) }
                subscripts.append(Subscript(file: file, type: bareName ? enclosingType(of: match.range.lowerBound, in: source) : "",
                                            expression: expression))
            }
        }

        /// The type whose body holds `position`: walking up the lines, the
        /// first `enum`, `struct`, `class`, `actor` or `extension` line that
        /// is indented less than every line passed on the way.
        func enclosingType(of position: String.Index, in source: String) -> String {
            let lines = source[..<position].split(separator: "\n", omittingEmptySubsequences: false)
            var indentation = lines.last?.prefix { $0 == " " }.count ?? 0
            for line in lines.dropLast().reversed() {
                let indent = line.prefix { $0 == " " }.count, text = line.dropFirst(indent)
                guard indent < indentation, !text.isEmpty, !text.hasPrefix("//"), !text.hasPrefix("#") else { continue }
                indentation = indent
                if let match = line.prefixMatch(of: typeDeclaration) {
                    return String(match.output.1.split(separator: ".").last ?? "")
                }
            }
            return ""
        }
    }

    /// What is wrong between the variables the sources spell and the switches.
    struct Audit: Equatable {
        /// Developer-only by its declared reason (`debugOnly`, `pathOverride`)
        /// or, when it does not reach the service, by its name, and not a
        /// `DeveloperSwitch`.
        var undeclared: [String] = []
        /// A switch's variable spelled in a source that is not its declaration.
        var spelledElsewhere: [String] = []
        /// An environment read through a constant that holds a switch's
        /// variable name, or through its `environmentKey`.
        var readThroughAName: [String] = []
        /// A case no source outside the declarations refers to.
        var unused: [String] = []
        /// Declared `debugOnly` to the service and honoured by a signed build.
        var honouredBySignedBuilds: [String] = []
    }

    /// `spelled`: each variable with the files that spell it.
    static func audit(spelled: [String: Set<String>], uses: Uses,
                      forwarded: Set<String> = LaunchAgent.forwardedEnvKeys,
                      reasons: [String: LaunchAgent.UnforwardedReason] = LaunchAgent.unforwardedEnvKeys,
                      switches: [DeveloperSwitch] = DeveloperSwitch.allCases) -> Audit {
        let declared = Dictionary(uniqueKeysWithValues: switches.map { ($0.environmentKey, $0) })
        var audit = Audit()
        audit.undeclared = Set(spelled.keys).union(reasons.keys).filter { key in
            guard declared[key] == nil else { return false }
            if let reason = reasons[key], [.debugOnly, .pathOverride].contains(reason) { return true }
            return !forwarded.contains(key) && saysDeveloperOnly(key)
        }.sorted()
        audit.spelledElsewhere = declared.keys.compactMap { key -> String? in
            let files = (spelled[key] ?? []).subtracting([declarationFile]).sorted()
            return files.isEmpty ? nil : "\(key): \(files.joined(separator: ", "))"
        }.sorted()
        audit.readThroughAName = uses.reads.sorted()
        audit.unused = switches.map { String(describing: $0) }.filter { !uses.referenced.contains($0) }.sorted()
        audit.honouredBySignedBuilds = declared.filter { reasons[$0.key] == .debugOnly && $0.value.availability != .debugOnly }
            .keys.sorted()
        return audit
    }

    /// One pass over the sources: their literals, and what they do with the
    /// switches.
    static func scan() throws -> (literals: ServiceEnvironmentReachTests.Literals, uses: Uses) {
        var uses = Uses()
        let literals = try ServiceEnvironmentReachTests.scan { file, source in uses.add(source: source, file: file) }
        return (literals, uses)
    }

    @Test func aDeveloperOnlyVariableIsASwitchReadOnlyThroughItsDeclaration() throws {
        let (literals, uses) = try Self.scan()
        #expect(literals.files.contains(Self.declarationFile), "the declaration moved; update the path this scan sets aside")
        let audit = Self.audit(spelled: literals.keys, uses: uses)
        #expect(audit.undeclared.isEmpty, """
            developer-only by its reason in LaunchAgent.unforwardedEnvKeyGroups or by its name, and not a \
            DeveloperSwitch. Declare it there with the builds that honour it and read it with \
            value(environment:posture:): \(audit.undeclared)
            """)
        #expect(audit.spelledElsewhere.isEmpty, """
            a DeveloperSwitch's variable is spelled outside its declaration, where a read ignores the build. Read it \
            with value(environment:posture:) and name it with environmentKey: \(audit.spelledElsewhere)
            """)
        #expect(audit.readThroughAName.isEmpty, """
            an environment is read through a switch's variable name, which ignores the build. Read it with \
            value(environment:posture:), or with ignoredValue where a build that ignores the switch must still \
            notice it is set: \(audit.readThroughAName)
            """)
        #expect(uses.names.allSatisfy { !$0.type.isEmpty }, """
            a constant holds a switch's variable name and the scan found no type around it, so a read through its \
            qualified name would be missed: \(uses.names.filter { $0.type.isEmpty }.map { "\($0.file): \($0.name)" }.sorted())
            """)
        #expect(audit.unused.isEmpty, """
            no source refers to this case as DeveloperSwitch.<case>; remove it and its entry in \
            LaunchAgent.unforwardedEnvKeyGroups: \(audit.unused)
            """)
        #expect(audit.honouredBySignedBuilds.isEmpty, """
            LaunchAgent.unforwardedEnvKeyGroups says only a debug build reads it, and its DeveloperSwitch lets a \
            signed build read it: \(audit.honouredBySignedBuilds)
            """)
    }

    @Test func theDebugConditionBecomesAValueInOnePlace() throws {
        let definitions = try Self.scan().uses.debugConstants
        #expect(definitions == [Self.postureFile], """
            a DEBUG condition that only selects a constant defines the build's configuration a second time; ask \
            BuildPosture.current instead: \(definitions.subtracting([Self.postureFile]).sorted())
            """)
    }

    /// The reads this suite exists for, in the shape each had before its fix:
    /// the developer SSH switch and the keychain group honoured by every
    /// build, a state file's variable read at its call site. Each is a
    /// switch's variable spelled where a read ignores the build. The reasons,
    /// the forwarded variable and the four switches are this test's own, so
    /// no later declaration changes what it finds.
    @Test func aReadThatIgnoresTheBuildIsReported() {
        var literals = ServiceEnvironmentReachTests.Literals()
        literals.add(source: #"""
            static func enabled(_ environment: [String: String]) -> Bool { environment["DARKBLOOM_CLUSTER_DEVELOPER_SSH"] == "1" }
            let group = environment["DARKBLOOM_KEYCHAIN_ACCESS_GROUP"] ?? signedApp
            let state = ProcessInfo.processInfo.environment["DARKBLOOM_STATE_FILE"].map(URL.init(fileURLWithPath:))
            let verbose = environment["DARKBLOOM_DEBUG_NEW_TRACE"] == "1", harness = environment["DARKBLOOM_NEW_HARNESS_SSH"]
            let limit = environment["DARKBLOOM_NEW_LIMIT"], telemetry = environment["DARKBLOOM_NEW_FORWARDED_DEBUG"]
            """#, file: "Reader.swift")
        let switches: [DeveloperSwitch] = [.clusterDeveloperSSH, .keychainAccessGroup, .daemonStateFile, .sandboxRoot]
        var uses = Uses()
        uses.referenced = ["clusterDeveloperSSH", "keychainAccessGroup", "daemonStateFile"]
        let audit = Self.audit(spelled: literals.keys, uses: uses, forwarded: ["DARKBLOOM_NEW_FORWARDED_DEBUG"],
                               reasons: ["DARKBLOOM_NEW_HARNESS_SSH": .debugOnly, "DARKBLOOM_NEW_LIMIT": .undecided],
                               switches: switches)
        #expect(audit == Audit(
            undeclared: ["DARKBLOOM_DEBUG_NEW_TRACE", "DARKBLOOM_NEW_HARNESS_SSH"],
            spelledElsewhere: ["DARKBLOOM_CLUSTER_DEVELOPER_SSH: Reader.swift", "DARKBLOOM_KEYCHAIN_ACCESS_GROUP: Reader.swift",
                               "DARKBLOOM_STATE_FILE: Reader.swift"],
            unused: ["sandboxRoot"]))
        // Declared debug-only to the service while a signed DevNet build honours it.
        uses.referenced.insert("sandboxRoot")
        #expect(Self.audit(spelled: [:], uses: uses, forwarded: [], reasons: ["DARKBLOOM_CLUSTER_DEVELOPER_SSH": .debugOnly],
                           switches: switches) == Audit(honouredBySignedBuilds: ["DARKBLOOM_CLUSTER_DEVELOPER_SSH"]))
        // Through its declaration, production's release build reads none of the three.
        let production = BuildPosture(configuration: .release, environment: .prod)
        for developerSwitch in [DeveloperSwitch.clusterDeveloperSSH, .keychainAccessGroup, .daemonStateFile] {
            #expect(developerSwitch.value(environment: [developerSwitch.environmentKey: "1"], posture: production) == nil)
        }
    }

    /// A constant that holds a switch's variable name reads an environment
    /// as its literal would: by its qualified name anywhere, by its bare or
    /// `Self.` name in its own type. So does the switch's `rawValue`, which
    /// is its `environmentKey`. The scan finds the constant and its type;
    /// nothing lists them. Writing a child's environment, reading the one
    /// this process built for a child, and another type's constant of the
    /// same name are not reads of the variable.
    @Test func aReadThroughAVariableNameIsReported() {
        var uses = Uses()
        uses.add(source: #"""
            import Foundation

            /// Forces a mode.
            public enum ForcedMode {
                struct Words { let text: String }

                public static let environmentName = DeveloperSwitch.clusterForceMode.environmentKey

                static func mode(environment: [String: String]) -> String? {
                    #if DEBUG
                    return environment[environmentName]
                    #else
                    return nil
                    #endif
                }

                static func isSet(environment: [String: String]) -> Bool { environment[Self.environmentName] != nil }
            }

            enum HandOffModes {
                static let environmentName = "DARKBLOOM_CLUSTER_HANDOFF_MODES"
                static func enabled(environment: [String: String]) -> Bool { environment[environmentName] == "1" }
                static func disabled(environment: [String: String]) -> Bool { environment[Self.environmentName] == "0" }
            }

            struct KeyFile {
                static let variable: String = DeveloperSwitch.debugSEKeyFile.rawValue
            }

            extension Outer.GuardStore {
                @available(macOS 14, *) public static let pathEnvKey = LocationOverride.kvBackendGuard.environmentKey
            }
            """#, file: "Declares.swift")
        uses.add(source: #"""
            guard environment[ForcedMode.environmentName] == nil else { return nil }
            let path = processEnvironment[GuardStore.pathEnvKey], state = env[LocationOverride.pidFile.environmentKey]
            let root = ProcessInfo.processInfo.environment[DeveloperSwitch.sandboxRoot.environmentKey]
            effectiveEnvironment[DeveloperSwitch.prefixCacheTestPersistentKey.environmentKey] = "1"
            guard configured[ForcedMode.environmentName] != nil else { return nil }
            let other = environment[HandOffModes.environmentName], result = [ForcedMode.environmentName: root]
            let bare = environment[environmentName], unrelated = environment[pathEnvKey]
            let key = environment[KeyFile.variable], raw = env[DeveloperSwitch.debugSEKeyFile.rawValue]
            """#, file: "Reader.swift")
        #expect(uses.names == [
            Uses.Name(file: "Declares.swift", type: "ForcedMode", name: "environmentName"),
            Uses.Name(file: "Declares.swift", type: "GuardStore", name: "pathEnvKey"),
            Uses.Name(file: "Declares.swift", type: "KeyFile", name: "variable"),
        ])
        #expect(Self.audit(spelled: [:], uses: uses, forwarded: [], reasons: [:]).readThroughAName == [
            "Declares.swift: Self.environmentName", "Declares.swift: environmentName",
            "Reader.swift: DeveloperSwitch.debugSEKeyFile.rawValue", "Reader.swift: DeveloperSwitch.sandboxRoot.environmentKey",
            "Reader.swift: ForcedMode.environmentName", "Reader.swift: GuardStore.pathEnvKey", "Reader.swift: KeyFile.variable",
            "Reader.swift: LocationOverride.pidFile.environmentKey",
        ])
    }

    @Test func aDebugConditionThatOnlySelectsAConstantIsRecognised() {
        let definitions = [
            "var enforced: Bool {\n    #if DEBUG\n    return false\n    #else\n    return true\n    #endif\n}",
            "isReleaseBuild: {\n    #if DEBUG\n    false\n    #else\n    true\n    #endif\n},",
            "static var current: Self {\n    #if DEBUG\n    .debug\n    #else\n    .release\n    #endif\n}",
            "var name: String {\n    #if DEBUG\n    \"debug\"\n    #else\n    \"release\"\n    #endif\n}",
            "#if !DEBUG\nlet enforced = true\n#else\nlet enforced = false\n#endif",
        ]
        // A block that reads, or that compiles code in or out, is not one.
        let blocks = [
            "#if DEBUG\nreturn DeveloperSwitch.debugRosterUnpaired.value() == \"1\"\n#else\nreturn false\n#endif",
            "#if DEBUG\ncommands.append(TestLease.self)\n#endif",
            "#if DEBUG\nstatic let debugHint = \", or set a key file.\"\n#else\nstatic let debugHint = \".\"\n#endif",
        ]
        var uses = Uses()
        for (index, text) in (definitions + blocks).enumerated() { uses.add(source: text, file: "\(index)") }
        #expect(uses.debugConstants == Set(definitions.indices.map { "\($0)" }))
    }
}
