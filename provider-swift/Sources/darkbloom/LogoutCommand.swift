import ArgumentParser
import ProviderCore

struct Logout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove local account credentials and unlink this machine."
    )

    @OptionGroup var configOptions: ConfigOptions

    @Flag(
        name: .long,
        help: "Remove unverifiable legacy credentials without sending their token to any coordinator."
    )
    var localOnly = false

    mutating func run() async throws {
        let hadLocalToken = AuthTokenStore.load() != nil
        let hadLocalAccount = ProviderAccountStore.load() != nil
        if localOnly {
            try await unlinkProviderAccount(
                credential: nil,
                localOnly: true
            )
            guard hadLocalToken || hadLocalAccount else {
                print("No local provider credential was present.")
                print("Provider services are stopped.")
                return
            }
            print("Local provider credentials removed.")
            if hadLocalToken {
                print("The coordinator token was not revoked because its issuer could not be verified.")
                print("Remove this Mac from the issuing account before linking it again.")
            }
            return
        }

        let credential = try ProviderCredentialStore.load()
        let hadToken = credential != nil
        let hadAccount = hadLocalAccount
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
