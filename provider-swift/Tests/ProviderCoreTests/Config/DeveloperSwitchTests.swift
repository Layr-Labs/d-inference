import Foundation
import Testing
@testable import ProviderBuildEnvironment
@testable import ProviderCore

/// `DeveloperSwitch` declares which builds honour each developer-only
/// variable, and `value(environment:posture:)` is the only reader. The first
/// half checks the declarations against every build posture, by the
/// variables' literal names. The second half reads the sources with
/// `ServiceEnvironmentReachTests.scan`: a variable that is developer-only by
/// its declared reason or by its name is a switch, a switch's variable is
/// spelled only in its declaration and no environment is read through a
/// constant that holds its name, and the `DEBUG` condition becomes a value
/// in one place.
@Suite struct DeveloperSwitchTests {
    // MARK: - The declarations

    /// The configuration axis: honoured by a debug build, by no signed build.
    static let debugOnly: Set<String> = [
        "DARKBLOOM_ADDON_DEV_IDENTITY", "DARKBLOOM_AUTH_TOKEN_PATH", "DARKBLOOM_CLUSTER_FORCE_MODE",
        "DARKBLOOM_DEBUG_CACHE_KEY_FILE", "DARKBLOOM_DEBUG_CLUSTER_SOLO_GRACE_SECONDS",
        "DARKBLOOM_DEBUG_COORDINATOR_CERT_SHA256", "DARKBLOOM_DEBUG_OWNER_EXECUTABLE", "DARKBLOOM_DEBUG_ROSTER_UNPAIRED",
        "DARKBLOOM_DEBUG_SE_KEY_FILE", "DARKBLOOM_DEV_BENCH_CHIP", "DARKBLOOM_DEV_BENCH_PLANNER_CAP_GIB",
        "DARKBLOOM_KEYCHAIN_ACCESS_GROUP", "DARKBLOOM_KV_BACKEND_GUARD", "DARKBLOOM_LOADED_MODELS_FILE",
        "DARKBLOOM_LOCAL_DIR", "DARKBLOOM_PID_FILE", "DARKBLOOM_R2_CDN_URL", "DARKBLOOM_STATE_FILE",
        "DARKBLOOM_VERIFIED_WEIGHTS_FILE", "DARKBLOOM_WATCHDOG_STATE",
    ]

    /// The environment axis: honoured by every build but production's, a
    /// signed DevNet or staging build included.
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

    @Test func eachBuildHonoursExactlyTheSwitchesDeclaredForIt() {
        #expect(Set(BuildPosture.allCases).count == 6)
        #expect(DeveloperSwitch.allCases.count == Self.debugOnly.count + Self.nonProduction.count + Self.openDecisions.count)
        for environment in BuildEnvironment.allCases {
            let offProduction = environment == .prod ? [] : Self.nonProduction
            #expect(Self.honoured(by: BuildPosture(configuration: .release, environment: environment))
                    == Self.openDecisions.union(offProduction), "a release build for \(environment)")
            #expect(Self.honoured(by: BuildPosture(configuration: .debug, environment: environment))
                    == Self.debugOnly.union(Self.openDecisions).union(offProduction), "a debug build for \(environment)")
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

    @Test func productionsReleaseBuildHonoursOnlyTheOpenDecisions() {
        let production = BuildPosture(configuration: .release, environment: .prod)
        let undecided = Set(DeveloperSwitch.allCases.filter { $0.availability == .everyBuild(.undecided) }.map(\.environmentKey))
        #expect(Self.honoured(by: production) == undecided)
        #expect(undecided.subtracting(Self.openDecisions).isEmpty, """
            declared undecided, which is closed to new switches; gate it, or give it a reason of its own: \
            \(undecided.subtracting(Self.openDecisions).sorted())
            """)
        #expect(Self.openDecisions.subtracting(undecided).isEmpty, """
            decided; remove it from openDecisions here: \(Self.openDecisions.subtracting(undecided).sorted())
            """)
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

    /// The constants that hold a switch's variable name: the file that
    /// declares each, its type and its name. A name is for words, for a
    /// test's environment and for what a process writes into a child's
    /// environment. An environment read through one ignores the build.
    static let variableNames: [(file: String, type: String, name: String)] = [
        ("ProviderBuildEnvironment/KeychainAccessGroup.swift", "KeychainAccessGroup", "environmentKey"),
        ("ProviderCore/Addon/AddonHoldPaths.swift", "AddonHoldPaths", "socketOverrideVariable"),
        ("ProviderCore/Addon/AddonPeerPolicy.swift", "AddonPeerPolicy", "developmentIdentityVariable"),
        ("ProviderCore/Coordinator/CoordinatorDebugCertificatePin.swift", "CoordinatorDebugCertificatePin", "environmentKey"),
        ("ProviderCore/Inference/Distributed/Installed/ClusterBenchChip.swift", "ClusterBenchChip", "environmentName"),
        ("ProviderCore/Inference/Distributed/Installed/DistributedInstalledPrefixSSD.swift", "DistributedInstalledPrefixSSD",
         "directoryName"),
        ("ProviderCore/Inference/Distributed/Installed/DistributedInstalledSession.swift", "DistributedInstalledDeveloperSSH",
         "environmentKey"),
        ("ProviderCore/Inference/Distributed/Onboarding/ClusterControlLeadership.swift", "ClusterControlSoloGrace", "environmentKey"),
        ("ProviderCore/Inference/Distributed/Placement/ClusterForcedModeSetting.swift", "ClusterForcedModeSetting", "environmentName"),
        ("ProviderCore/Inference/Distributed/Placement/ClusterPlannerBenchCap.swift", "ClusterPlannerBenchCap", "environmentName"),
        ("ProviderCore/KVCacheSSD/SSDDebugCacheKeyFile.swift", "SSDDebugCacheKeyFile", "environmentKey"),
        ("ProviderCore/KVCacheSSD/SSDPrefixCacheFactory.swift", "SSDPrefixCacheFactory", "testRootEnvironmentKey"),
        ("ProviderCore/Service/ClusterSupervision/ClusterMemberHealth.swift", "ClusterSupervisionFiles", "statePathEnvironmentKey"),
        ("ProviderCore/Service/KVBackendGuard.swift", "KVBackendGuardStore", "pathEnvKey"),
        ("darkbloom/Sandbox/SandboxAddon.swift", "SandboxAddon", "rootOverrideVariable"),
    ]

    /// `variableNames` as the scan reports a declaration: `file: name`.
    static let listedNames = Set(variableNames.map { "\($0.file): \($0.name)" })

    /// The words a source spells when it reads through a name: the names
    /// above and a switch's own `environmentKey`.
    static let variableNameWords = Set(variableNames.map(\.name) + ["environmentKey"])

    /// What the sources do with the switches, beyond the literals
    /// `ServiceEnvironmentReachTests.Literals` reads.
    struct Uses {
        /// The cases that sources outside the two declarations name.
        var referenced: Set<String> = []
        /// Each constant initialised from a switch's `environmentKey`, as
        /// `file: name`.
        var names: Set<String> = []
        /// Each environment subscripted by one of `variableNames` or by a
        /// switch's `environmentKey`, as `file: expression`. An assignment is
        /// not one.
        var reads: [String] = []
        /// The files where a `DEBUG` condition only selects a constant: a
        /// build configuration turned into a value.
        var debugConstants: Set<String> = []

        private let reference = #/DeveloperSwitch\.([a-z][A-Za-z0-9]*)/#
        private let name = #/let\s+(\w+)\s*=\s*(?:DeveloperSwitch|LocationOverride)\.\w+\.environmentKey\b/#
        private let subscripted = #/(?:[eE]nvironment|\benv)\s*\[\s*([A-Za-z_][A-Za-z0-9_.]*)\s*\](\s*=(?!=))?/#
        private let debugConstant = #/#if\s+!?DEBUG\s*\n\s*(?:return\s+|[^\n]*=\s*)?(?:true|false|\.debug|\.release|"debug"|"release")\s*\n\s*#else\s*\n\s*(?:return\s+|[^\n]*=\s*)?(?:true|false|\.debug|\.release|"debug"|"release")\s*\n\s*#endif/#

        mutating func add(source: String, file: String) {
            // Most files name no switch. A search of the file's bytes, which costs a hundredth of a pattern's
            // pass, keeps the patterns off them.
            let bytes = source.data(using: .utf8) ?? Data()
            func spells(_ word: String) -> Bool { bytes.range(of: Data(word.utf8)) != nil }
            if spells("DEBUG"), source.contains(debugConstant) { debugConstants.insert(file) }
            guard file != declarationFile, file != ServiceEnvironmentReachTests.registryFile else { return }
            if spells("DeveloperSwitch.") {
                referenced.formUnion(source.matches(of: reference).map { String($0.output.1) })
            }
            guard variableNameWords.contains(where: spells) else { return }
            names.formUnion(source.matches(of: name).map { "\(file): \($0.output.1)" })
            for match in source.matches(of: subscripted) where match.output.2 == nil {
                let expression = String(match.output.1)
                let throughAName = variableNames.contains {
                    let qualified = $0.type + "." + $0.name
                    return expression == qualified || expression.hasSuffix("." + qualified)
                        || ($0.file == file && expression == $0.name)
                }
                let throughTheKey = expression.hasSuffix(".environmentKey")
                    && (expression.hasPrefix("DeveloperSwitch.") || expression.hasPrefix("LocationOverride."))
                if throughAName || throughTheKey { reads.append("\(file): \(expression)") }
            }
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
        /// An environment read through a switch's variable name.
        var readThroughAName: [String] = []
        /// A constant that holds a switch's variable name and is not in
        /// `variableNames`, or an entry there that no source declares.
        var unlistedNames: [String] = []
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
        audit.unlistedNames = uses.names.symmetricDifference(listedNames).sorted()
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
        #expect(audit.unlistedNames.isEmpty, """
            the constants that hold a switch's variable name differ from variableNames here; list a new one so \
            reads through it are found, and remove one that is gone: \(audit.unlistedNames)
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
    /// switch's variable spelled where a read ignores the build.
    @Test func aReadThatIgnoresTheBuildIsReported() {
        let source = #"""
            static func enabled(_ environment: [String: String]) -> Bool { environment["DARKBLOOM_CLUSTER_DEVELOPER_SSH"] == "1" }
            let group = environment["DARKBLOOM_KEYCHAIN_ACCESS_GROUP"] ?? signedApp
            let state = ProcessInfo.processInfo.environment["DARKBLOOM_STATE_FILE"].map(URL.init(fileURLWithPath:))
            let verbose = environment["DARKBLOOM_DEBUG_NEW_TRACE"] == "1", harness = environment["DARKBLOOM_NEW_HARNESS_SSH"]
            let limit = environment["DARKBLOOM_NEW_LIMIT"], telemetry = environment["DARKBLOOM_MLX_RESOURCE_DEBUG"]
            """#
        var literals = ServiceEnvironmentReachTests.Literals()
        literals.add(source: source, file: "Reader.swift")
        var uses = Uses()
        uses.referenced = Set(DeveloperSwitch.allCases.map { String(describing: $0) }).subtracting(["sandboxRoot"])
        uses.names = Self.listedNames
        let audit = Self.audit(spelled: literals.keys, uses: uses,
                               reasons: LaunchAgent.unforwardedEnvKeys.merging(["DARKBLOOM_NEW_HARNESS_SSH": .debugOnly]) { $1 })
        #expect(audit == Audit(
            undeclared: ["DARKBLOOM_DEBUG_NEW_TRACE", "DARKBLOOM_NEW_HARNESS_SSH"],
            spelledElsewhere: ["DARKBLOOM_CLUSTER_DEVELOPER_SSH: Reader.swift", "DARKBLOOM_KEYCHAIN_ACCESS_GROUP: Reader.swift",
                               "DARKBLOOM_STATE_FILE: Reader.swift"],
            unused: ["sandboxRoot"]))
        // Declared debug-only to the service while a signed DevNet build honours it.
        uses.referenced.insert("sandboxRoot")
        #expect(Self.audit(spelled: [:], uses: uses, reasons: ["DARKBLOOM_CLUSTER_DEVELOPER_SSH": .debugOnly])
                == Audit(honouredBySignedBuilds: ["DARKBLOOM_CLUSTER_DEVELOPER_SSH"]))
        // Through its declaration, production's release build reads none of the three.
        let production = BuildPosture(configuration: .release, environment: .prod)
        for developerSwitch in [DeveloperSwitch.clusterDeveloperSSH, .keychainAccessGroup, .daemonStateFile] {
            #expect(developerSwitch.value(environment: [developerSwitch.environmentKey: "1"], posture: production) == nil)
        }
    }

    /// A constant that holds a switch's variable name reads an environment
    /// as its literal would. Writing a child's environment, and reading the
    /// one this process built for a child, are not reads of the variable.
    @Test func aReadThroughAVariableNameIsReported() {
        var uses = Uses()
        uses.add(source: #"""
            guard environment[ClusterForcedModeSetting.environmentName] == nil else { return nil }
            let group = processEnvironment[KeychainAccessGroup.environmentKey], state = env[LocationOverride.pidFile.environmentKey]
            let root = ProcessInfo.processInfo.environment[DeveloperSwitch.sandboxRoot.environmentKey]
            effectiveEnvironment[DeveloperSwitch.prefixCacheTestPersistentKey.environmentKey] = "1"
            guard configured[DistributedInstalledPrefixSSD.directoryName] != nil else { return nil }
            let other = environment[ClusterHandOffModes.environmentName], result = [SandboxAddon.rootOverrideVariable: root]
            static let newName = DeveloperSwitch.debugLocalErrors.environmentKey
            """#, file: "Reader.swift")
        uses.add(source: "let seconds = environment[environmentKey], other = environment[otherKey]",
                 file: "ProviderCore/Inference/Distributed/Onboarding/ClusterControlLeadership.swift")
        #expect(uses.reads == [
            "Reader.swift: ClusterForcedModeSetting.environmentName", "Reader.swift: KeychainAccessGroup.environmentKey",
            "Reader.swift: LocationOverride.pidFile.environmentKey", "Reader.swift: DeveloperSwitch.sandboxRoot.environmentKey",
            "ProviderCore/Inference/Distributed/Onboarding/ClusterControlLeadership.swift: environmentKey",
        ])
        #expect(uses.names == ["Reader.swift: newName"])
        #expect(Self.audit(spelled: [:], uses: uses).unlistedNames.contains("Reader.swift: newName"))
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
