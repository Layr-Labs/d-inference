import Jinja
import Testing

@Suite("Swift Jinja loop context")
struct SwiftJinjaLoopContextTests {
    @Test("Qwen tool responses share one user turn", arguments: [1, 2])
    func qwenToolResponseGrouping(resultCount: Int) throws {
        // These branches are the unchanged Qwen3.5/3.6/3.8 template's
        // neighboring-message policy, with assistant reasoning omitted.
        let source = """
            {%- for message in messages %}
                {%- if message.role == 'tool' %}
                    {%- if loop.previtem and loop.previtem.role != 'tool' %}
                        {{- '<|im_start|>user' }}
                    {%- endif %}
                    {{- '\\n<tool_response>\\n' + message.content + '\\n</tool_response>' }}
                    {%- if not loop.last and loop.nextitem.role != 'tool' %}
                        {{- '<|im_end|>\\n' }}
                    {%- elif loop.last %}
                        {{- '<|im_end|>\\n' }}
                    {%- endif %}
                {%- else %}
                    {{- '<|im_start|>' + message.role + '\\n' + message.content + '<|im_end|>\\n' }}
                {%- endif %}
            {%- endfor %}
            """
        let template = try Template(source, with: .init(lstripBlocks: true, trimBlocks: true))
        let prefix = [message("user", "question"), message("assistant", "calling")]
        let results = (1 ... resultCount).map { message("tool", "result\($0)") }
        let expectedPrefix = "<|im_start|>user\nquestion<|im_end|>\n<|im_start|>assistant\ncalling<|im_end|>\n"
        let expectedResults = "<|im_start|>user" + (1 ... resultCount).map {
            "\n<tool_response>\nresult\($0)\n</tool_response>"
        }.joined() + "<|im_end|>\n"
        #expect(try template.render(["messages": .array(prefix + results)])
            == expectedPrefix + expectedResults)
        let followUp = message("user", "continue")
        #expect(try template.render(["messages": .array(prefix + results + [followUp])])
            == expectedPrefix + expectedResults + "<|im_start|>user\ncontinue<|im_end|>\n")
        #expect(try template.render(["messages": .array(prefix)]) == expectedPrefix)
    }

    @Test("neighbor boundaries distinguish missing from false values")
    func boundariesAndFalseValues() throws {
        let template = try Template("{% for item in items %}{{ loop.previtem is defined }}:{{ loop.nextitem is defined }};{% endfor %}")
        #expect(try template.render(["items": .array([])]) == "")
        #expect(try template.render(["items": .array([.int(0)])]) == "false:false;")
        #expect(try template.render(["items": .array([.int(0), .boolean(false), .string("")])])
            == "false:true;true:true;true:false;")
    }

    @Test("nested loops restore the outer neighboring items")
    func nestedLoopScope() throws {
        let template = try Template("{% for outer in outers %}O{{ loop.index0 }}({{ loop.previtem }}|{{ loop.nextitem }}):{% for inner in inners %}I{{ loop.index0 }}({{ loop.previtem }}|{{ loop.nextitem }});{% endfor %}A{{ loop.index0 }}({{ loop.previtem }}|{{ loop.nextitem }});{% endfor %}")
        let actual = try template.render([
            "outers": .array([.string("a"), .string("b")]),
            "inners": .array([.string("x"), .string("y")]),
        ])
        #expect(actual == "O0(|b):I0(|y);I1(x|);A0(|b);O1(a|):I0(|y);I1(x|);A1(a|);")
    }

    @Test("dictionary and string loop neighbors use their iteration values")
    func mapAndStringNeighbors() throws {
        let keys = try Template("{% for key in obj %}[{{ loop.previtem }}|{{ key }}|{{ loop.nextitem }}]{% endfor %}")
        let object = Value.object(["a": .int(1), "b": .int(2)])
        #expect(try keys.render(["obj": object]) == "[|a|b][a|b|]")
        let pairs = try Template("{% for key, value in obj.items() %}{% if not loop.first %}{{ loop.previtem[0] }}={{ loop.previtem[1] }}{% endif %}{% endfor %}")
        #expect(try pairs.render(["obj": object]) == "a=1")
        let characters = try Template("{% for character in text %}[{{ loop.previtem }}{{ character }}{{ loop.nextitem }}]{% endfor %}")
        #expect(try characters.render(["text": .string("abc")]) == "[ab][abc][bc]")
    }

    private func message(_ role: String, _ content: String) -> Value {
        .object(["role": .string(role), "content": .string(content)])
    }
}
