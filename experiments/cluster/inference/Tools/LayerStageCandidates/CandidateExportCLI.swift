import Foundation

struct QwenCandidateExportCLI {
    let configuration: URL
    let configurationSHA256: String
    let canonicalNames: URL
    let canonicalNamesSHA256: String

    init(arguments: [String]) throws {
        let allowed = Set(["--config", "--config-sha256", "--canonical-names", "--canonical-names-sha256"])
        guard arguments.count == 8 else {
            throw ProbeError("Usage: run.sh --config FILE --config-sha256 SHA256 --canonical-names FILE --canonical-names-sha256 SHA256")
        }
        var values: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index], value = arguments[index + 1]
            guard allowed.contains(key), values[key] == nil, !value.isEmpty else {
                throw ProbeError("Candidate export requires each known argument exactly once")
            }
            values[key] = value
        }
        guard let config = values["--config"], let names = values["--canonical-names"],
              let configSHA = values["--config-sha256"], let namesSHA = values["--canonical-names-sha256"],
              [config, names].allSatisfy({ $0.utf8.count <= 4_096 && !$0.utf8.contains(0) }),
              QwenCandidateExport.isSHA256(configSHA), QwenCandidateExport.isSHA256(namesSHA) else {
            throw ProbeError("Candidate export paths or SHA-256 arguments are invalid")
        }
        configuration = URL(fileURLWithPath: config)
        canonicalNames = URL(fileURLWithPath: names)
        configurationSHA256 = configSHA
        canonicalNamesSHA256 = namesSHA
    }

    func encoded(read: (URL, Int) throws -> Data = { try QwenCandidateExportInput.read($0, maximumBytes: $1) })
        throws -> Data {
        let config = try read(configuration, QwenCandidateExport.maximumConfigurationBytes)
        let names = try read(canonicalNames, QwenCandidateExport.maximumNamesBytes)
        let result = try QwenCandidateExport.make(configuration: config, canonicalNamesJSON: names,
            expectedConfigurationSHA256: configurationSHA256,
            expectedCanonicalNamesSHA256: canonicalNamesSHA256)
        return try QwenCandidateExportEncoding.record(result)
    }
}
