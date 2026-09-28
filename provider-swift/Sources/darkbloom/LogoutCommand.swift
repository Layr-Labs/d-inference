import ArgumentParser
import ProviderCore

struct Logout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove local account credentials and unlink this machine."
    )

    mutating func run() async throws {
        guard AuthTokenStore.load() != nil else {
            print("Not currently logged in.")
            return
        }

        try AuthTokenStore.delete()
        print("Logged out. This machine is no longer linked to an account.")
        print("Provider earnings are not credited to an account until you log in again.")
    }
}
