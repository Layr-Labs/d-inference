import DarkbloomClusterPlacement
import DarkbloomClusterProcess
import DarkbloomClusterRemote
import DarkbloomClusterRuntime
import DarkbloomClusterSecurity
import Foundation
import Testing
@testable import ProviderCore

/// The DevNet app (`darkbloom-dev`) and the production app (`darkbloom`) on one Mac share no cluster or pairing
/// state: every path, launchd label, lock and port a build's cluster code uses is its own, and production's are what
/// they were before builds had their own, byte for byte. The crossings seen on 2026-11-05 run against real stores,
/// ceremonies and files in private temporary homes; nothing here reads the real home's cluster files.
@Suite("Cluster state: each install its own")
struct ClusterInstallIsolationTests {
    typealias Signer = ClusterPairingProviderTests.SoftwareSigner
    static let home = URL(fileURLWithPath: "/Users/op", isDirectory: true)

    /// Every cluster file or folder `environment` resolves under `home`, by what it holds.
    static func resolved(_ environment: BuildEnvironment, home: URL = home) throws -> [String: String] {
        let paths = try ClusterUserPaths(homeDirectory: home, environment: environment)
        let install = environment.installDirectory(home: home)
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let urls: [String: URL] = [
            "pairing store": ClusterPairingStore.default(home: home, environment: environment).directory,
            "setup and service": ClusterSetupPaths(paths: paths).directory,
            "device": paths.deviceDirectory,
            "saved setups": paths.configurationsDirectory,
            "observability": paths.observabilityDirectory,
            "incidents": ClusterIncidentLog.defaultFile(installDirectory: install, install: environment.rawValue),
            "pair telemetry": ClusterPairTelemetryLog.defaultFile(installDirectory: install),
            "follower status": ClusterLinkStatusBoardFile.defaultFile(installDirectory: install),
            "served speed": ClusterServedSpeedFile.defaultFile(installDirectory: install),
            "link probes": ClusterLinkProbeHistory.defaultFile(installDirectory: install),
            "share probes": ClusterShareProbeHistory.defaultFile(installDirectory: install),
            "member heartbeat": ClusterSupervisionFiles.defaultHealthPath(home: home, install: environment),
            "supervisor state": ClusterSupervisionFiles.statePath(environment: [:], home: home, install: environment),
            "pair prefix cache": caches.appendingPathComponent(ClusterPrefixCacheSettings.directoryName(for: environment), isDirectory: true),
        ]
        return urls.mapValues(\.path)
    }

    static let productionApp = "/Users/someone/.darkbloom/Darkbloom.app/Contents/MacOS/darkbloom"
    static let devnetApp = "/Users/someone/.darkbloom-dev/Darkbloom Dev.app/Contents/MacOS/darkbloom-dev"

    @Test("production's cluster paths, label, locks and ports are byte for byte what they were")
    func productionIsUnchanged() throws {
        let today = [
            "pairing store": "/Users/op/.darkbloom/cluster-pairing",
            "setup and service": "/Users/op/.darkbloom/cluster-setup",
            "device": "/Users/op/.darkbloom/cluster-device",
            "saved setups": "/Users/op/.config/darkbloom/clusters",
            "observability": "/Users/op/.darkbloom/cluster",
            "incidents": "/Users/op/.darkbloom/cluster/incidents.json",
            "pair telemetry": "/Users/op/.darkbloom/cluster/pair-telemetry.json",
            "follower status": "/Users/op/.darkbloom/cluster/follower-status.json",
            "served speed": "/Users/op/.darkbloom/cluster/served-speed.json",
            "link probes": "/Users/op/.darkbloom/cluster/link-probes.json",
            "share probes": "/Users/op/.darkbloom/cluster/share-probes.json",
            "member heartbeat": "/Users/op/.darkbloom/cluster-member-health.json",
            "supervisor state": "/Users/op/.darkbloom/cluster-supervisor.json",
            "pair prefix cache": "/Users/op/Library/Caches/darkbloom/cluster-prefix-v1",
        ]
        #expect(try Self.resolved(.prod) == today)
        // The label the original code gave production's app (the RED run on 05358af90b printed it), and its shape.
        #expect(ClusterServiceAgentPlan.label(executablePath: Self.productionApp, environment: .prod) == "io.darkbloom.cluster-service.f19aa32ccffd")
        #expect(ClusterServiceAgentPlan.isAgentFileName("io.darkbloom.cluster-service.f19aa32ccffd.plist", environment: .prod))
        #expect(ClusterConsoleInstanceLock.lockFileName("console", environment: .prod) == "darkbloom-cluster-console.lock")
        #expect(ClusterConsoleInstanceLock.lockFileName("exchange", environment: .prod) == "darkbloom-cluster-exchange.lock")
        #expect(ClusterConsoleInstanceLock.lockFileName("control", environment: .prod) == "darkbloom-cluster-control.lock")
        let ports = ClusterCablePorts(environment: .prod)
        #expect([ports.linkControl, ports.pairing, ports.exchange, ports.control, ports.glmCalibration, ports.coordinator]
                == [47_420, 47_421, 47_422, 47_423, 47_424, 52_420])
        #expect(ClusterUserPaths.shown("cluster-setup/service.log", environment: .prod) == "~/.darkbloom/cluster-setup/service.log")
    }

    @Test("DevNet and staging resolve only their own folders, labels, locks and ports, and no install's lies in another's")
    func eachInstallResolvesOnlyItsOwn() throws {
        for environment in BuildEnvironment.allCases {
            let own = [environment.installDirectory(home: Self.home), environment.configDirectory(home: Self.home),
                       Self.home.appendingPathComponent("Library/Caches/\(environment.encryptedCacheNamespace)")].map { $0.path + "/" }
            for (what, path) in try Self.resolved(environment) {
                #expect(own.contains { (path + "/").hasPrefix($0) }, "\(environment) \(what): \(path)")
            }
        }
        for this in BuildEnvironment.allCases {
            for other in BuildEnvironment.allCases where other != this {
                let theirs = try Self.resolved(other).values.map { $0 + "/" }
                for (what, path) in try Self.resolved(this) {
                    #expect(!theirs.contains { ($0).hasPrefix(path + "/") || (path + "/").hasPrefix($0) },
                            "\(this) \(what) \(path) overlaps \(other)'s")
                }
                #expect(Set(ClusterCablePorts(environment: this).all).isDisjoint(with: ClusterCablePorts(environment: other).all),
                        "\(this) and \(other) share a port")
                #expect(ClusterConsoleInstanceLock.lockFileName("console", environment: this)
                        != ClusterConsoleInstanceLock.lockFileName("console", environment: other))
                // Neither build takes the other's job for one of its own, whatever app path made it.
                for app in [Self.productionApp, Self.devnetApp, "/Users/someone/build/.build/debug/darkbloom"] {
                    let label = ClusterServiceAgentPlan.label(executablePath: app, environment: other)
                    #expect(!ClusterServiceAgentPlan.isAgentFileName(label + ".plist", environment: this), "\(this) lists \(other)'s \(label)")
                }
            }
        }
        #expect(ClusterServiceAgentPlan.label(executablePath: Self.devnetApp, environment: .dev).hasPrefix("io.darkbloom.cluster-service.dev."))
    }

    @Test("what the product opens without saying which install follows this build")
    func theProductsDefaultsAreThisBuilds() throws {
        let current = BuildEnvironment.current
        let real = FileManager.default.homeDirectoryForCurrentUser
        // Path arithmetic only: nothing is read or written in the real home.
        let paths = try ClusterUserPaths(), explicit = try ClusterUserPaths(homeDirectory: real, environment: current)
        #expect(paths.environment == current && paths == explicit)
        #expect(ClusterPairingStore.default().directory == ClusterUserPaths.pairingDirectory(home: real, environment: current))
        #expect(try ClusterService.paths().lock.deletingLastPathComponent() == paths.setupDirectory)
        #expect(ClusterPrefixCacheSettings.rootDirectoryName == ClusterPrefixCacheSettings.directoryName(for: current))
        #expect(ClusterSupervisionFiles.defaultHealthPath(home: real) == ClusterSupervisionFiles.defaultHealthPath(home: real, install: current))
        #expect(ClusterServiceAgentPlan.labelPrefix == current.clusterServiceLabelPrefix)
        #expect(ClusterConsoleInstanceLock.fileName == ClusterConsoleInstanceLock.lockFileName("console", environment: current))
        #expect(ClusterSetupLinkExchange.requestLockName == ClusterConsoleInstanceLock.lockFileName("exchange", environment: current))
        #expect(ClusterSetupLinkExchange.controlLockName == ClusterConsoleInstanceLock.lockFileName("control", environment: current))
        #expect(ClusterCablePorts.current == ClusterCablePorts(environment: current))
        #expect(ClusterSetupLinkExchange.port == ClusterCablePorts.current.exchange)
        #expect(ClusterSetupLinkExchange.controlPort == ClusterCablePorts.current.control)
        #expect(ClusterSetupPorts.conventionalCoordinator == ClusterCablePorts.current.coordinator)
        #expect(ClusterSetupPorts.conventionalLinkControl == ClusterCablePorts.current.linkControl)
        #expect(ClusterPairCommandLine.defaultPort == Int(ClusterCablePorts.current.pairing))
        #expect(ClusterPairCommandRequest().port == Int(ClusterCablePorts.current.pairing))
        #expect(ClusterMemberProfiles.defaultFile(homeDirectory: Self.home).path
                == ClusterUserPaths.observabilityDirectory(home: Self.home, environment: current).path + "/member-profiles.json")
        #expect(ClusterDeviceIndexRecord.file(homeDirectory: Self.home).path
                == ClusterUserPaths.observabilityDirectory(home: Self.home, environment: current).path + "/device-index.json")
        let observability = ClusterObservability(homeDirectory: Self.home, hostNames: [], userNames: [])
        #expect(observability.telemetryFile == ClusterPairTelemetryLog.defaultFile(installDirectory: current.installDirectory(home: Self.home)))
        #expect(observability.incidents.file
                == ClusterIncidentLog.defaultFile(installDirectory: current.installDirectory(home: Self.home), install: current.rawValue))
        #expect(ClusterUserPaths.serviceLogShown == "~/\(current.installDirectoryName)/cluster-setup/service.log")
    }

    /// `darkbloom-cluster-plan plan` without `--link` or `--share-probes` reads the probes of the install whose app holds
    /// the helper; it has no build identity of its own.
    @Test("the placement helper reads the probes of the app folder that holds it")
    func placementHelperReadsItsOwnInstallsProbes() {
        for environment in BuildEnvironment.allCases {
            let install = environment.installDirectory(home: Self.home)
            let helper = install.appendingPathComponent("\(environment.appBundleName)/Contents/Helpers/darkbloom-cluster-plan")
            #expect(ClusterPlacementTool.installDirectory(executable: helper, home: Self.home).path == install.path, "\(environment)")
        }
        // A helper outside an app (a development build) reads production's, as every helper did before.
        let built = URL(fileURLWithPath: "/Users/op/src/libs/darkbloom-cluster-worker/.build/debug/darkbloom-cluster-plan")
        #expect(ClusterPlacementTool.installDirectory(executable: built, home: Self.home).path == "/Users/op/.darkbloom")
        #expect(ClusterPlacementTool.installDirectory(executable: nil, home: Self.home).path == "/Users/op/.darkbloom")
    }

    /// The library's cable defaults are production's ports (`ClusterLinkPairing.defaultPort`,
    /// `ClusterLinkControlListener.defaultPort`), so a provider source that leaves one out pairs, probes or listens on
    /// production's port in every build: `darkbloom-dev cluster` paired on 47421 that way. The pairing ceremony and the
    /// discovery run on a real cable only, so this reads the sources.
    @Test("every place the provider pairs, probes or listens on the cable names this build's port")
    func noCableUseFallsBackToProductionsPorts() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let productionPorts = try NSRegularExpression(pattern: #"\b(47_?42[0-4]|52_?420)\b"#)
        var offenders: [String] = [], scanned = 0
        let walker = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" && url.lastPathComponent != "ClusterCablePorts.swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            scanned += 1
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                let next = lines[index..<min(lines.count, index + 4)]
                if code.contains("ClusterLinkPairing.defaultPort") || code.contains("ClusterLinkControlListener.defaultPort")
                    || productionPorts.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
                    || (code.contains("ClusterLinkPairing.Options(") && !next.contains { $0.contains(".port = ") })
                    || (code.contains("ClusterLinkPairingDiscovery.find(") && !code.contains("port:"))
                    || (code.contains("ClusterLinkPairingDiscovery.Responder(") && !code.contains("udpPort:")) {
                    offenders.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(scanned > 100, "the provider sources were found (\(scanned) files)")
        #expect(offenders.isEmpty, "production's cable ports, not ClusterCablePorts.current, at \(offenders.joined(separator: ", "))")
    }

    /// 2026-11-05 crossings 1-3: DevNet's `cluster status` showed production's pair as serving; after production paired,
    /// DevNet said the Secure Enclave key had changed and wanted a re-pair, which would have rewritten production's.
    @Test("production's pairing is invisible to DevNet, and DevNet pairing again leaves production's byte for byte")
    func pairingsDoNotCross() throws {
        let home = try NativePairMemberFixture.privateRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let production = ClusterPairingStore.default(home: home, environment: .prod)
        let devnet = ClusterPairingStore.default(home: home, environment: .dev)
        let productionKey = Signer(), devnetKey = Signer(), otherMac = Signer()
        // Production pairs, with production's Secure Enclave key (a real ceremony, the other Mac in its own store).
        _ = try ClusterPairingProviderTests.pair(productionKey, otherMac, stores: (production, ClusterPairingProviderTests.temporaryStore()))
        let paired = try #require(try ClusterSetupLinkExchange.pairing(store: production))
        #expect(!ClusterService.holdsNoPairing(store: production))
        // DevNet sees no pairing at all: nothing to call serving, no key to call changed.
        #expect(try ClusterSetupLinkExchange.pairing(store: devnet) == nil)
        #expect(ClusterService.holdsNoPairing(store: devnet))
        #expect(try devnet.load() == nil)
        // DevNet pairs with its own key: production's files and pairing are exactly as they were.
        let before = try Self.snapshot(production.directory)
        _ = try ClusterPairingProviderTests.pair(devnetKey, otherMac, stores: (devnet, ClusterPairingProviderTests.temporaryStore()))
        #expect(try Self.snapshot(production.directory) == before)
        #expect(try ClusterSetupLinkExchange.pairing(store: production)?.identity == paired.identity)
        let devnetPairing = try #require(try ClusterSetupLinkExchange.pairing(store: devnet))
        #expect(devnetPairing.localPin != paired.localPin && devnetPairing.identity != paired.identity)
        // DevNet forgetting its pairing (`cluster pair --forget`) leaves production paired.
        _ = try devnet.forget(peerPin: devnetPairing.peerPin)
        #expect(ClusterService.holdsNoPairing(store: devnet) && !ClusterService.holdsNoPairing(store: production))
        #expect(try Self.snapshot(production.directory) == before)
    }

    /// 2026-11-05 crossing: DevNet's `update` asked production's cluster service to restart (the request file and
    /// the service's status were in one shared folder).
    @Test("each build's update request and service status are in its own service folder")
    func serviceFilesDoNotCross() throws {
        let home = try NativePairMemberFixture.privateRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let production = ClusterSetupPaths(paths: try ClusterUserPaths(homeDirectory: home, environment: .prod)).directory
        let devnet = ClusterSetupPaths(paths: try ClusterUserPaths(homeDirectory: home, environment: .dev)).directory
        #expect(production != devnet)
        let request = ClusterPairUpdate.Request(createdAt: Date().timeIntervalSince1970)
        try FileManager.default.createDirectory(at: devnet, withIntermediateDirectories: true)
        #expect(ClusterPairUpdate.writeRequest(request, to: ClusterServiceAgent.updateRequestPath(serviceDirectory: devnet)))
        #expect(!FileManager.default.fileExists(atPath: ClusterServiceAgent.updateRequestPath(serviceDirectory: production).path),
                "production's supervisor finds no request from DevNet")
        for file in [ClusterServiceAgent.supervisorStatePath(serviceDirectory: devnet), ClusterServiceAgent.healthPath(serviceDirectory: devnet),
                     ClusterServiceAgent.partHealthPath(serviceDirectory: devnet), ClusterServiceAgent.updateProgressPath(serviceDirectory: devnet)] {
            #expect(file.path.hasPrefix(home.path + "/.darkbloom-dev/cluster-setup/"), "\(file.lastPathComponent)")
        }
    }

    /// Refactor pass M1: the cable port setup is this Mac's, but each build records its own undo. A port production set
    /// up is adopted by DevNet with production's record of the change (bridge slot, services turned off), read and never
    /// written, so DevNet, uninstalled last, still puts the port back after production's folder is gone.
    @Test("a port the other build set up keeps its whole undo after that build is uninstalled")
    func cableUndoSurvivesTheOtherBuildsUninstall() throws {
        let home = try NativePairMemberFixture.privateRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let production = try ClusterUserPaths(homeDirectory: home, environment: .prod)
        let devnet = try ClusterUserPaths(homeDirectory: home, environment: .dev)
        for paths in [production, devnet] {
            try FileManager.default.createDirectory(at: paths.deviceDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let address = ClusterLinkClusterAddress.derived(machineIdentifier: "FIXTURE-MACHINE", interface: "en7")
        let setUp = ClusterLinkIsolationRecord.Entry(interface: "en7", address: address, hardwarePort: "Thunderbolt 6",
            bridge: .init(bridge: "bridge0", index: 1), disabledServices: ["Thunderbolt 6", "Thunderbolt 2"])
        try ClusterLinkIsolationStore(paths: production).update { $0.set(setUp) }
        let productionRecord = try Data(contentsOf: production.linkIsolationRecordFile)
        // DevNet adopts the port production isolated, with production's undo, in its own record.
        let others = ClusterLinkRepair.otherInstallsIsolationEntries(interface: "en7", paths: devnet)
        #expect(others == [setUp])
        #expect(ClusterLinkRepair.otherInstallsIsolationEntries(interface: "en6", paths: devnet).isEmpty)
        let adopted = ClusterLinkRepair.adoptionEntry(interface: "en7", address: address, hardwarePort: "Thunderbolt 6",
                                                      disabledHere: ["Thunderbolt 6"], others: others)
        #expect(adopted == setUp)
        try ClusterLinkIsolationStore(paths: devnet).update { $0.set(adopted) }
        #expect(try Data(contentsOf: production.linkIsolationRecordFile) == productionRecord, "production's record is only read")
        #expect(ClusterLinkRepair.otherInstallsIsolationEntries(interface: "en7", paths: production) == [adopted],
                "a build never reads its own record as the other's")
        // Production is uninstalled: its folder, and its record, go. DevNet still has the bridge slot and the services.
        try FileManager.default.removeItem(at: production.installDirectory)
        #expect(try ClusterLinkIsolationStore(paths: devnet).load().entry(on: "en7") == setUp)
        // Another address on the port is not that setup: only what this Mac shows now is recorded.
        let elsewhere = ClusterLinkRepair.adoptionEntry(interface: "en7", address: .derived(machineIdentifier: "ANOTHER-MACHINE", interface: "en7"),
            hardwarePort: "Thunderbolt 6", disabledHere: ["Thunderbolt 6"], others: [setUp])
        #expect(elsewhere.bridge == nil && elsewhere.disabledServices == ["Thunderbolt 6"])
    }

    /// Review of #1846: with a lease each, a DevNet pair could start beside production's and push it out of memory.
    /// Each build's scope also takes the one device lock every build shares, in no build's folder.
    @Test("one build's pair never starts on the GPU beside another build's, and the refusal names the other app")
    func devicesAreLockedAcrossBuilds() throws {
        let home = try NativePairMemberFixture.privateRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let production = try ClusterUserPaths(homeDirectory: home, environment: .prod)
        let devnet = try ClusterUserPaths(homeDirectory: home, environment: .dev)
        for (paths, app) in [(production, "Darkbloom.app"), (devnet, "Darkbloom Dev.app")] {
            try FileManager.default.createDirectory(at: paths.installDirectory.appendingPathComponent(app), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: paths.deviceDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let lock = home.appendingPathComponent("Library/Application Support/Darkbloom/cluster-native-device.lock")
        #expect(production.machineDeviceLock.file == lock && devnet.machineDeviceLock.file == lock)
        var productionScope: ClusterDeviceExclusion? = try ClusterDeviceExclusion(directoryURL: production.deviceDirectory,
                                                                                   machineLock: production.machineDeviceLock)
        do {
            _ = try ClusterDeviceExclusion(directoryURL: devnet.deviceDirectory, machineLock: devnet.machineDeviceLock)
            Issue.record("DevNet's pair started on the GPU beside production's")
        } catch {
            #expect("\(error)" == "The production Darkbloom on this Mac is running its pair (or a model check) on this Mac's GPU, "
                + "and two pairs don't fit one Mac's memory. Run `darkbloom cluster stop` to stop it, then start this pair again.")
        }
        productionScope = nil
        let devnetScope = try ClusterDeviceExclusion(directoryURL: devnet.deviceDirectory, machineLock: devnet.machineDeviceLock)
        do {
            _ = try ClusterDeviceExclusion(directoryURL: production.deviceDirectory, machineLock: production.machineDeviceLock)
            Issue.record("production's pair started on the GPU beside DevNet's")
        } catch { #expect("\(error)".hasPrefix("Darkbloom Dev on this Mac is running its pair") && "\(error)".contains("`darkbloom-dev cluster stop`")) }
        withExtendedLifetime((productionScope, devnetScope)) {}
        // The lock is in neither build's folder, and holds nothing.
        for paths in [production, devnet] { #expect(!lock.path.hasPrefix(paths.installDirectory.path + "/")) }
        #expect(try Data(contentsOf: lock).isEmpty)
    }

    /// Review of #1846: `darkbloom-dev cluster link --remove` took away a port production's pair still uses.
    @Test("a build sees which other build's link records still hold a cable port, read only")
    func otherBuildsUsingTheCableAreSeen() throws {
        let home = try NativePairMemberFixture.privateRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let production = try ClusterUserPaths(homeDirectory: home, environment: .prod)
        let devnet = try ClusterUserPaths(homeDirectory: home, environment: .dev)
        #expect(ClusterLinkRepair.otherInstallsUsingCable(paths: devnet).isEmpty)
        try FileManager.default.createDirectory(at: production.deviceDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let entry = ClusterLinkIsolationRecord.Entry(interface: "en7", address: .derived(machineIdentifier: "FIXTURE-MACHINE", interface: "en7"),
            hardwarePort: "Thunderbolt 6", bridge: nil, disabledServices: [])
        try ClusterLinkIsolationStore(paths: production).update { $0.set(entry) }
        let record = try Data(contentsOf: production.linkIsolationRecordFile)
        #expect(ClusterLinkRepair.otherInstallsUsingCable(paths: devnet) == [.prod])
        #expect(ClusterLinkRepair.otherInstallsUsingCable(paths: devnet, device: "rdma_en7") == [.prod])
        #expect(ClusterLinkRepair.otherInstallsUsingCable(paths: devnet, device: "rdma_en6").isEmpty, "another port")
        #expect(ClusterLinkRepair.otherInstallsUsingCable(paths: production).isEmpty, "never its own")
        #expect(try Data(contentsOf: production.linkIsolationRecordFile) == record, "production's record is only read")
    }

    /// Every place the provider takes a device scope also takes the Mac's device lock (`ClusterUserPaths.machineDeviceLock`).
    @Test("every device scope the provider takes also takes the device lock every build shares")
    func everyDeviceScopeTakesTheMachineLock() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        var offenders: [String] = [], scopes = 0
        let walker = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                && ["ClusterDeviceExclusion(directoryURL:", "ClusterDeviceLease(directoryURL:", "ClusterWorkerOwnerService.serveKeyed("]
                    .contains(where: line.contains) {
                scopes += 1
                if !lines[index..<min(lines.count, index + 3)].contains(where: { $0.contains("machineLock:") }) {
                    offenders.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(scopes >= 6, "the provider's device scopes were found (\(scopes))")
        #expect(offenders.isEmpty, "a device scope without the Mac's device lock at \(offenders.joined(separator: ", "))")
    }

    @Test("one build's open console screen does not lock the other build's out")
    func screenLocksDoNotCross() throws {
        let directory = try NativePairMemberFixture.privateRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let production = try ClusterConsoleInstanceLock.acquire(directory: directory, fileName: ClusterConsoleInstanceLock.lockFileName("console",
            environment: .prod), waitSeconds: 0)
        let devnet = try ClusterConsoleInstanceLock.acquire(directory: directory, fileName: ClusterConsoleInstanceLock.lockFileName("console",
            environment: .dev), waitSeconds: 0)
        #expect(throws: ClusterConsoleInstanceLock.Held.self) {
            _ = try ClusterConsoleInstanceLock.acquire(directory: directory, fileName: ClusterConsoleInstanceLock.lockFileName("console",
                environment: .dev), waitSeconds: 0)
        }
        withExtendedLifetime((production, devnet)) {}
    }

    /// Every regular file under `directory` with its bytes.
    static func snapshot(_ directory: URL) throws -> [String: Data] {
        let names = (FileManager.default.enumerator(atPath: directory.path)?.allObjects as? [String]) ?? []
        var files: [String: Data] = [:]
        for name in names {
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            files[name] = try Data(contentsOf: url)
        }
        return files
    }
}
