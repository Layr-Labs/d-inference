import ArgumentParser
import Testing
@testable import darkbloom

@Suite("Cluster runtime-facts CLI")
struct ClusterRuntimeFactsCommandTests {
    @Test("each mode parses: the model list, given models, release candidates; the command stays hidden")
    func accepted() throws {
        #expect(try Cluster.RuntimeFacts.parse(["--list-release-models"]).listReleaseModels)
        let given = try Cluster.RuntimeFacts.parse(["--app", "/A/Darkbloom.app", "--model", "Qwen3.5-9B=/m/q",
                                                    "--model", "glm-5.3-flash=/m/g/config.json,/m/g/manifest.json"])
        #expect(given.models.count == 2 && given.app == "/A/Darkbloom.app")
        let release = try Cluster.RuntimeFacts.parse(["--app", "/A/Darkbloom.app", "--release-candidates", "/c"])
        #expect(release.releaseCandidates == "/c" && release.models.isEmpty)
        #expect(try Darkbloom.parseAsRoot(["cluster", "runtime-facts", "--list-release-models"]) is Cluster.RuntimeFacts)
        #expect(try Darkbloom.parseAsRoot(["cluster", "runtime-facts", "--app", "/A", "--model", "a=/m"]) is Cluster.RuntimeFacts)
        #expect(Cluster.RuntimeFacts.configuration.shouldDisplay == false)
    }

    @Test("mixed, incomplete or contradictory modes refuse")
    func rejected() {
        for values in [["--list-release-models", "--app", "/A"], ["--list-release-models", "--model", "a=/m"],
                       ["--list-release-models", "--release-candidates", "/c"],
                       [], ["--app", "/A"], ["--model", "a=/m"], ["--release-candidates", "/c"],
                       ["--app", "/A", "--model", "a=/m", "--release-candidates", "/c"],
                       ["--app", "/A", "--require-model", "a", "--release-candidates", "/c"]] {
            #expect(throws: (any Error).self, "\(values)") { _ = try Cluster.RuntimeFacts.parse(values) }
        }
    }
}
