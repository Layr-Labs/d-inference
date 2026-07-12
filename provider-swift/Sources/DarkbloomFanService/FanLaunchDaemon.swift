import DarkbloomFanProtocol
import Foundation

public enum FanLaunchDaemon {
    public static func propertyList(paths: FanServicePaths) -> [String: Any] {
        [
            "Label": FanIPC.machServiceName,
            "ProgramArguments": [paths.helper.path],
            "MachServices": [FanIPC.machServiceName: true],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "ProcessType": "Background",
        ]
    }
}
