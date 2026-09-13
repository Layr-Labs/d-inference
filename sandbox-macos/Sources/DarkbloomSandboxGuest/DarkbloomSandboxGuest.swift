import Foundation
import SandboxGuestRuntime

@main
enum DarkbloomSandboxGuest {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            if arguments == ["disable-persistent-schedulers"] {
                try await GuestBootstrapInstallation.disablePersistentSchedulers()
                return
            }
            if arguments == ["provision-workspace-mountpoint"] {
                try GuestBootstrapInstallation.provisionWorkspaceMountpoint()
                return
            }
            if arguments == ["quiesce-tenant"] {
                try await GuestTenantExecutor.quiesceTenant()
                return
            }
            if arguments.first == "tenant-exec" || arguments.first == "tenant-cleanup" {
                try GuestTenantWorker.run(arguments: arguments)
            }
            guard arguments.count == 3, arguments[0] == "serve", arguments[1] == "--configuration" else {
                FileHandle.standardError.write(Data("usage: darkbloom-sandbox-guest serve --configuration /var/db/darkbloom-sandbox/instance.json\n".utf8))
                exit(64)
            }
            let configuration = try GuestConfiguration.loadProduction(from: arguments[2])
            try await GuestSocketServer.serve(configuration: configuration)
        } catch {
            let bootstrap = arguments == ["provision-workspace-mountpoint"] || arguments == ["disable-persistent-schedulers"]
            let message = bootstrap ? (error as? GuestBootstrapDiagnostic)?.code : nil
            FileHandle.standardError.write(Data("darkbloom-sandbox-guest: \(message ?? "startup or control channel unavailable")\n".utf8))
            exit(78)
        }
    }
}
