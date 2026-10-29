import ArgumentParser
import Testing
@testable import darkbloom
@testable import ProviderCore

@Suite("Cluster runtime-facts CLI")
struct ClusterRuntimeFactsCommandTests {
    @Test("each mode parses: the model list, given models, release candidates with required models")
    func accepted() throws {
        #expect(try Cluster.RuntimeFacts.parse(["--list-release-models"]).listReleaseModels)
        let given = try Cluster.RuntimeFacts.parse(["--app", "/A/Darkbloom.app", "--model", "Qwen3.5-9B=/m/q",
                                                    "--model", "glm-5.3-flash=/m/g/config.json,/m/g/manifest.json"])
        #expect(given.models.count == 2 && given.app == "/A/Darkbloom.app")
        let release = try Cluster.RuntimeFacts.parse(["--app", "/A/Darkbloom.app", "--release-candidates", "/c",
                                                      "--require-model", "Qwen3.5-9B", "--require-model", "glm-5.3-flash"])
        #expect(release.requiredModels == ["Qwen3.5-9B", "glm-5.3-flash"] && release.releaseCandidates == "/c")
        #expect(try Darkbloom.parseAsRoot(["cluster", "runtime-facts", "--list-release-models"]) is Cluster.RuntimeFacts)
        #expect(Cluster.RuntimeFacts.configuration.shouldDisplay == false)
    }

    @Test("a model the facts leave out is one line the release workflow matches")
    func leftOutLine() {
        let line = Cluster.RuntimeFacts.leftOutLine(.init(model: "glm-5.3-flash", runtimeModelID: "registered_glm53_flash",
                                                           reason: "/c/000/manifest.json: refused\nsecond line"))
        #expect(line == "Left out of the cluster runtime facts: glm-5.3-flash (registered_glm53_flash): "
                + "/c/000/manifest.json: refused second line\n")
    }

    @Test("mixed, incomplete or contradictory modes refuse")
    func rejected() {
        for values in [["--list-release-models", "--app", "/A"], ["--list-release-models", "--model", "a=/m"],
                       ["--list-release-models", "--release-candidates", "/c"], ["--list-release-models", "--require-model", "a"],
                       [], ["--app", "/A"], ["--model", "a=/m"], ["--release-candidates", "/c"],
                       ["--app", "/A", "--model", "a=/m", "--release-candidates", "/c"],
                       ["--app", "/A", "--model", "a=/m", "--require-model", "a"]] {
            #expect(throws: (any Error).self, "\(values)") { _ = try Cluster.RuntimeFacts.parse(values) }
        }
    }
}
