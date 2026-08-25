import ArgumentParser
import ProviderCore

struct Logout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove local account credentials and unlink this machine."
    )

    @OptionGroup var configOptions: ConfigOptions

    mutating func run() async throws {
        let credential = try ProviderCredentialStore.load()
        let hadToken = credential != nil
        let hadAccount = ProviderAccountStore.load() != nil
        try await unlinkProviderAccount(
            credential: credential
        )

        guard hadToken || hadAccount else {
            print("Not currently logged in.")
            print("Provider services are stopped.")
            return
        }

        print("Logged out. This machine is no longer linked to an account.")
        if hadToken {
            print("Provider services were stopped and the coordinator token was revoked.")
        } else {
            print("Provider services were stopped and stale account state was removed.")
        }
        print("Provider earnings will use the local wallet until you log in again.")
    }
}
