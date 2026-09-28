import Foundation

// Generated from the independent Python canonical-JSON/domain recipe; no native output.
func checkQwenLayerStageProfiledWireGolden(fixture: QwenLayerStageProfiledWireCheckFixture) throws {
    guard fixture.agreement.request.request.profile.fingerprint == "2b7f484488df61c4f6042acfb472a8099828c8a6246819501c88d4f6e07bcc0b",
          fixture.agreement.request.request.fingerprint == "5e62a0b7b030e5428561ba8f1e5d56b100a47c07c210a4a3f4e9755d725bbf82",
          fixture.agreement.request.fingerprint == "2c129dc979d575262741491856fe70cb454757b1e35d1cec1733d69683cc0c9a",
          fixture.agreement.fingerprint == "d21343fcc3a4e220b28f48f6353bd9343dc2093c906b47097a3af64410fc0a0f",
          sha256(try fixture.final.boundary.encoded()) == "1bfa5e3327a1c28ffebe909a07591387ced62c8f66a9eecd5913431d4a825dcd",
          fixture.start.wireBytesSHA256 == "a4642b4023253bb09e9cf97c8bc6c034004b8fe6fbb7fde37db4533ef8ceb211",
          fixture.start.fingerprint == "98b8e518f41f971f73c0e9933d74eee8d5a6de70e1a47a0a14749a3e90359a33",
          fixture.final.wireBytesSHA256 == "0bf40d2f9a8c805504920e9f6d4eada7794d6ea1ad4b9f4825351098f875a261",
          fixture.final.fingerprint == "db57a908f5e6c700162c88ac0df433870ab19fce2f80365e43916d95c3aeec85",
          fixture.token.wireBytesSHA256 == "6b1a4cdfaba9194921ad8ba8f393f00d3ba9ee26408a2dd9ea282943b53f08d3",
          fixture.token.fingerprint == "b77b73200a19483005fb4f35bd7e15b2f5f9ddcd7015e83d5770c8cdafa236cc",
          QwenLayerStageProfiledPrefillBoundaryAcknowledgement.values(envelope: fixture.final, phase: .ready) == Array("4798e4c5fade4c57e2c8abfe6d2f07754c3139adcad0f650b4fc08f67aca5a87".utf8).map(Int32.init),
          QwenLayerStageProfiledPrefillBoundaryAcknowledgement.values(envelope: fixture.final, phase: .received) == Array("f70e369c65b53235a2cf8d72618aac77e41e3bbb79af27c45a044386de4755c0".utf8).map(Int32.init),
          QwenLayerStageProfiledPrefillBoundaryAcknowledgement.values(envelope: fixture.final, phase: .consumed) == Array("58d26ec21a9bbbef2c5535a2777d3726cf829daefd7a77bd4eca2d22784771d6".utf8).map(Int32.init),
          QwenLayerStageProfiledPrefillPostStopAcknowledgement.values(token: fixture.token) == Array("3a063f1ab0900a89a3c77cea3cf1bd3a52c35bd6126d83676243398a61029cc5".utf8).map(Int32.init) else {
        throw ProbeError("Profiled wire differs from independently derived raw/domain/ACK golden vectors")
    }
    let legacy = try QwenLayerStagePrefillWireCheckFixture()
    let expected = try legacy.agreement.boundaryExpectation(for: legacy.final.boundary.frame)
    let lookahead = try QwenLayerStageLookaheadWireEnvelope(boundary: legacy.final.boundary, expected: expected)
    guard sha256(try legacy.final.boundary.encoded()) == "b47e22afbfeae54883422fd7a85203cfb13b43949bacc4fd9f04095876b7a89e",
          sha256(lookahead.encoded()) == "dda7fa500559d7d8ef2e154a5b41637ea8fdef875776bf4b1ff4794ba68cf005",
          sha256(legacy.start.encoded()) == "dc4e6f02b28d150352a1fd7dd78d619d2fea2ad5eeab61dacede5c01b8dc07c6",
          sha256(legacy.final.encoded()) == "d5b3a2e36a4e886c73d710131e4209150d3b47a4e1ba9dace70e2a8597215c83",
          sha256(legacy.token.encoded()) == "198fa86ecf3060f858067a045094528ec3b0c95aa7e9eeab934a5a7978494c67" else {
        throw ProbeError("Existing v1/v2/v3 fixture bytes changed while adding the new profiled namespace")
    }
}
