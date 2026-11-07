import Foundation

extension LocalRouterConfig {
    public static func pairLeaderOutsideDarkbloom(local: LocalSettings?, coordinatorURL: String?) -> LocalRouterConfig {
        .host(local: local, coordinatorURL: coordinatorURL, takesCoordinatorWork: true)
    }
}
