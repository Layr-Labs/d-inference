import ArgumentParser
import ProviderCore

struct Logout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove local account credentials and unlink this machine."
    )

    mutating func run() async throws {
        let hadToken = AuthTokenStore.load() != nil
        let hadAccount = ProviderAccountStore.load() != nil
        guard hadToken || hadAccount else {
            print("Not currently logged in.")
            return
        }

        try AuthTokenStore.delete()
        // The account id names the earnings wallet (`darkbloom earnings`,
        // daemon-state `identity`) — leaving it after unlink would keep
        // granular surfaces reporting the PREVIOUS account's earnings. Best-
        // effort like the store's own delete: a missing file is already gone.
        ProviderAccountStore.delete()
        print("Logged out. This machine is no longer linked to an account.")
        print("Provider earnings will use the local wallet until you log in again.")
    }
}
