import Foundation
import Testing
@testable import ProviderCore

@Suite("ChatCompletionRequest pass-through fields (stop / seed / tools / response_format)")
struct ChatRequestExtraFieldsTests {

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    @Test("stop accepts a string and round-trips")
    func stopAcceptsString() throws {
        let json = #"""
        {"model":"m","messages":[{"role":"user","content":"hi"}],"stop":"\n\n"}
        """#
        let req = try decoder.decode(ChatCompletionRequest.self, from: Data(json.utf8))
        #expect(req.stop?.asArray == ["\n\n"])

        let reEncoded = try encoder.encode(req)
        let reDecoded = try decoder.decode(ChatCompletionRequest.self, from: reEncoded)
        #expect(reDecoded.stop == req.stop)
    }

    @Test("stop accepts an array and round-trips")
    func stopAcceptsArray() throws {
        let json = #"""
        {"model":"m","messages":[{"role":"user","content":"hi"}],"stop":["</s>","<|eot|>"]}
        """#
        let req = try decoder.decode(ChatCompletionRequest.self, from: Data(json.utf8))
        #expect(req.stop?.asArray == ["</s>", "<|eot|>"])
    }

    @Test("seed decodes as UInt64 and round-trips")
    func seedRoundTrips() throws {
        let json = #"""
        {"model":"m","messages":[{"role":"user","content":"x"}],"seed":42}
        """#
        let req = try decoder.decode(ChatCompletionRequest.self, from: Data(json.utf8))
        #expect(req.seed == 42)
    }

    @Test("tool_choice 'auto' decodes as mode")
    func toolChoiceModeString() throws {
        let json = #"""
        {"model":"m","messages":[{"role":"user","content":"x"}],"tool_choice":"auto"}
        """#
        let req = try decoder.decode(ChatCompletionRequest.self, from: Data(json.utf8))
        if case .mode(let s) = req.tool_choice {
            #expect(s == "auto")
        } else {
            Issue.record("expected .mode(\"auto\"), got \(String(describing: req.tool_choice))")
        }
    }

    @Test("tool_choice with named function decodes")
    func toolChoiceNamed() throws {
        let json = #"""
        {"model":"m","messages":[{"role":"user","content":"x"}],"tool_choice":{"type":"function","function":{"name":"get_weather"}}}
        """#
        let req = try decoder.decode(ChatCompletionRequest.self, from: Data(json.utf8))
        if case .named(let type, let fn) = req.tool_choice {
            #expect(type == "function")
            #expect(fn.name == "get_weather")
        } else {
            Issue.record("expected .named, got \(String(describing: req.tool_choice))")
        }
    }

    @Test("tools array round-trips with arbitrary JSON parameters")
    func toolsRoundTrip() throws {
        let json = #"""
        {
          "model":"m",
          "messages":[{"role":"user","content":"x"}],
          "tools":[
            {"type":"function","function":{"name":"add","description":"add two ints","parameters":{"type":"object","properties":{"a":{"type":"integer"},"b":{"type":"integer"}},"required":["a","b"]}}}
          ]
        }
        """#
        let req = try decoder.decode(ChatCompletionRequest.self, from: Data(json.utf8))
        #expect(req.tools?.count == 1)
        let fn = req.tools?[0].function
        #expect(fn?.name == "add")
        #expect(fn?.description == "add two ints")

        let reEncoded = try encoder.encode(req)
        let reDecoded = try decoder.decode(ChatCompletionRequest.self, from: reEncoded)
        #expect(reDecoded.tools?[0].function.name == "add")
    }

    @Test("response_format json_object round-trips")
    func responseFormatRoundTrips() throws {
        let json = #"""
        {"model":"m","messages":[{"role":"user","content":"x"}],"response_format":{"type":"json_object"}}
        """#
        let req = try decoder.decode(ChatCompletionRequest.self, from: Data(json.utf8))
        #expect(req.response_format?.type == "json_object")
    }

    @Test("requests without the new fields decode unchanged")
    func backwardCompatible() throws {
        let json = #"""
        {"model":"m","messages":[{"role":"user","content":"hi"}],"temperature":0.5}
        """#
        let req = try decoder.decode(ChatCompletionRequest.self, from: Data(json.utf8))
        #expect(req.stop == nil)
        #expect(req.seed == nil)
        #expect(req.tools == nil)
        #expect(req.tool_choice == nil)
        #expect(req.response_format == nil)
        #expect(req.temperature == 0.5)
    }
}
