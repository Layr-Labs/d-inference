import ArgumentParser
import Foundation
import ProviderCore

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Link this machine to a Darkbloom account.",
        discussion: """
        Uses the RFC 8628 device code flow. The CLI requests a one-time code
        from the coordinator, displays it, and opens the verification URL in
        your browser. Once you authorize the code, the provider is linked to
        your account and earnings are credited to your account wallet.
        """
    )

    @OptionGroup var configOptions: ConfigOptions

    mutating func run() async throws {
        let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
        let coordinatorURL = snapshot.config.coordinator.url

        do {
            try await performDeviceCodeLogin(
                coordinatorURL: coordinatorURL,
                onDisplayCode: { userCode, verificationURI, expiresIn in
                    print()
                    print("  To link this machine, open this URL in your browser:")
                    print()
                    print("    \(verificationURI)")
                    print()
                    print("  Then enter this code:")
                    print()
                    print("    \(userCode)")
                    print()
                    print("  Waiting for approval (expires in \(expiresIn / 60) minutes)...")
                },
                onPollTick: {
                    print(".", terminator: "")
                    fflush(stdout)
                }
            )

            print()
            print()
            print("  Account linked successfully!")
            print("  Your provider will now be connected to your account.")
            print("  Earnings will be credited to your account wallet.")
            print()
            print("  Start serving with: darkbloom serve")
        } catch let error as DeviceAuthError {
            printError("\(error)")
            throw ExitCode.failure
        }
    }
}
