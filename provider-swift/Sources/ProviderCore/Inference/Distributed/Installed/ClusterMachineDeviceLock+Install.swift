import Darwin
import DarkbloomClusterProcess
import Foundation

extension ClusterMachineDeviceLock {
    /// In no build's own folder, and one macOS never empties: production's, DevNet's and staging's builds all take
    /// `~/Library/Application Support/Darkbloom/cluster-native-device.lock`.
    static let relativePath = "Library/Application Support/Darkbloom/cluster-native-device.lock"

    /// The Mac's lock as `paths`' build takes it, with a refusal that names the other app installed in the same home.
    static func forInstall(_ paths: ClusterUserPaths) -> ClusterMachineDeviceLock {
        let others = BuildEnvironment.allCases.filter { $0 != paths.environment && installed($0, home: paths.homeDirectory) }
        return .init(file: paths.homeDirectory.appendingPathComponent(relativePath), heldElsewhere: heldElsewhere(by: others))
    }

    /// An install counts when its app or its `bin/` command is in its own folder (as `ProviderUninstallPaths.otherEnvironment`).
    static func installed(_ environment: BuildEnvironment, home: URL) -> Bool {
        let folder = environment.installDirectory(home: home)
        return [environment.appBundleName, "bin/\(environment.cliName)"].contains {
            var info = stat()
            return lstat(folder.appendingPathComponent($0).path, &info) == 0
        }
    }

    /// What a start says while another build's pair (or its model check) holds this Mac's GPU.
    static func heldElsewhere(by others: [BuildEnvironment]) -> String {
        let fit = "on this Mac's GPU, and two pairs don't fit one Mac's memory"
        guard others.count == 1, let other = others.first else {
            return "Another Darkbloom app on this Mac is running its pair (or a model check) \(fit). Stop that app's pair "
                + "first (`<that app> cluster stop`), then start this pair again."
        }
        let name = other == .prod ? "The production Darkbloom" : other.appDisplayName
        return "\(name) on this Mac is running its pair (or a model check) \(fit). Run `\(other.cliName) cluster stop` to "
            + "stop it, then start this pair again."
    }
}

extension ClusterUserPaths {
    /// The device lock every Darkbloom build on this Mac shares (`ClusterMachineDeviceLock`): each native session,
    /// member preparation and GLM calibration holds it with this build's own device scope, so one build's pair never
    /// starts on the GPU beside another's.
    public var machineDeviceLock: ClusterMachineDeviceLock { .forInstall(self) }
}
