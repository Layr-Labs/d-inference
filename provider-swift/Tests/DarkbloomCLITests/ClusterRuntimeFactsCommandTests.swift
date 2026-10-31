import ArgumentParser
import Testing
@testable import darkbloom

@Suite("Cluster runtime-facts CLI")
struct ClusterRuntimeFactsCommandTests {
    @Test("the app and one or more models parse, and the command stays hidden")
    func accepted() throws {
        let given = try Cluster.RuntimeFacts.parse(["--app", "/A/Darkbloom.app", "--model", "Qwen3.5-9B=/m/q",
                                                    "--model", "glm-5.3-flash=/m/g/config.json,/m/g/manifest.json"])
        #expect(given.models.count == 2 && given.app == "/A/Darkbloom.app")
        #expect(try Darkbloom.parseAsRoot(["cluster", "runtime-facts", "--app", "/A", "--model", "a=/m"]) is Cluster.RuntimeFacts)
        #expect(Cluster.RuntimeFacts.configuration.shouldDisplay == false)
    }

    @Test("a missing app or no model refuses")
    func rejected() {
        for values in [[], ["--app", "/A"], ["--model", "a=/m"]] {
            #expect(throws: (any Error).self, "\(values)") { _ = try Cluster.RuntimeFacts.parse(values) }
        }
    }
}
