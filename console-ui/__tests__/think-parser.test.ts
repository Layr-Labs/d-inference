import { describe, it, expect, vi } from "vitest";
import { parseThinkFromContent, ThinkStreamParser } from "@/lib/chat/think-parser";

describe("parseThinkFromContent", () => {
  it("returns plain content unchanged", () => {
    expect(parseThinkFromContent("hello world")).toEqual({ thinking: "", content: "hello world" });
  });

  it("extracts a <think> block", () => {
    const r = parseThinkFromContent("<think>reason here</think>\nanswer");
    expect(r.thinking).toBe("reason here");
    expect(r.content).toBe("answer");
  });

  it("extracts a Gemma <|channel>thought block", () => {
    const r = parseThinkFromContent("<|channel>thought\nplanning<channel|>\nresult");
    expect(r.thinking).toBe("planning");
    expect(r.content).toBe("result");
  });

  it("strips inline think tags but keeps server-provided thinking", () => {
    const r = parseThinkFromContent("<think>x</think>visible", "server-think");
    expect(r.thinking).toBe("server-think");
    expect(r.content).toBe("visible");
  });
});

describe("ThinkStreamParser", () => {
  function collect() {
    const thinking: string[] = [];
    const content: string[] = [];
    const parser = new ThinkStreamParser(
      (t) => thinking.push(t),
      (c) => content.push(c),
    );
    return { parser, thinking, content };
  }

  it("routes plain content to onContent", () => {
    const { parser, thinking, content } = collect();
    parser.handleContent("this is a long enough plain answer");
    parser.flush();
    expect(thinking.join("")).toBe("");
    expect(content.join("")).toContain("plain answer");
  });

  it("routes a think block to onThinking then content after the close tag", () => {
    const { parser, thinking, content } = collect();
    parser.handleContent("<think>step one and two");
    parser.handleContent(" more thinking</think>final answer");
    parser.flush();
    expect(thinking.join("")).toContain("step one");
    expect(content.join("")).toContain("final answer");
  });

  it("handles a close tag split across pushes (post-detection)", () => {
    const { parser, content } = collect();
    // First push is long enough to trigger detection inside the think block.
    parser.handleContent("<think>reasoning is happening here");
    // The close tag then arrives split across two later pushes.
    parser.handleContent(" and more</thi");
    parser.handleContent("nk>done");
    parser.flush();
    expect(content.join("")).toContain("done");
  });

  it("discards a buffered opener when reasoning starts server-side", () => {
    const { parser, content } = collect();
    parser.handleContent("<|chan"); // buffered, undecided
    parser.onReasoningStart();
    parser.flush();
    expect(content.join("")).toBe("");
  });
});
