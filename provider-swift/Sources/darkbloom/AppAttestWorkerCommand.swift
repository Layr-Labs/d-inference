import Darwin
import ProviderAppAttest

enum AppAttestWorkerCommand {
    static func runIfRequested(_ arguments: [String]) async {
        guard arguments.first == AppAttestWorkerHost.argument else { return }
        guard arguments.count == 1 else { _exit(78) }
        do {
            try await AppAttestWorkerHost.run()
            _exit(0)
        } catch {
            // The private IPC peer, not stdout or a daemon state file, owns the
            // exchange. Never print bootstrap secrets or proof material here.
            _exit(78)
        }
    }
}
