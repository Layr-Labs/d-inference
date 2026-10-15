import DarkbloomClusterRuntime
import Foundation

struct WorkerProtectedConfiguration {
    static let names: Set<String> = ["--protected-record-profile", "--native-authorization-start-base64"]
    let profile: String
    let start: Data

    static func parse(_ fields: [String: String], bootstrap: WorkerBootstrapConfiguration?) throws -> Self? {
        let present = names.filter { fields[$0] != nil }
        guard !present.isEmpty else { return nil }
        guard present.count == names.count, bootstrap != nil,
              let profile = fields["--protected-record-profile"],
              profile == QwenResidentProtectedExperiment.identifier,
              let encoded = fields["--native-authorization-start-base64"],
              encoded.utf8.count <= 4096, let start = Data(base64Encoded: encoded),
              !start.isEmpty, start.count <= 4096, start.base64EncodedString() == encoded else {
            throw WorkerFailure.invalid("Protected experiment needs its exact profile, public start and complete bootstrap triple")
        }
        return .init(profile: profile, start: start)
    }
}
