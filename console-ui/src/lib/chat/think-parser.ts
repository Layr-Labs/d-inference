// Think-block grammar — the single source of truth for the reasoning/"thinking"
// markers different model families emit. Previously implemented twice: as a
// streaming state machine inside streamChat and as a post-hoc parser in
// ChatMessage (proposal F9). Both now live here so they can never drift.
//
// Supported formats:
//   Qwen / DeepSeek: "<think>...</think>" or "Thinking Process:\n...</think>"
//   Gemma 4:         "<|channel>thought\n...<channel|>"

/**
 * Post-hoc parser: split a completed assistant message into { thinking, content }.
 * Always strips think tags from the content (old providers leave them inline);
 * when no server-side `existingThinking` is supplied it also extracts the
 * thinking text from a leading think block.
 */
export function parseThinkFromContent(
  content: string,
  existingThinking?: string,
): { thinking: string; content: string } {
  if (!content) return { thinking: existingThinking || "", content };

  let cleaned = content;
  cleaned = cleaned.replace(/<think>[\s\S]*?<\/think>\s*/g, "");
  cleaned = cleaned.replace(/Thinking Process:?[\s\S]*?<\/think>\s*/g, "");
  cleaned = cleaned.replace(/<\|channel>thought[\s\S]*?<channel\|>\s*/g, "");

  if (existingThinking) {
    return { thinking: existingThinking, content: cleaned.trimStart() };
  }

  const trimmed = content.trimStart();

  if (trimmed.startsWith("<think>")) {
    const closeIdx = trimmed.indexOf("</think>");
    if (closeIdx !== -1) {
      const thinking = trimmed.slice(7, closeIdx).trim();
      const rest = trimmed.slice(closeIdx + 8).replace(/^\n+/, "");
      return { thinking, content: rest };
    }
  }

  if (trimmed.startsWith("Thinking Process:") || trimmed.startsWith("Thinking Process\n")) {
    const closeIdx = trimmed.indexOf("</think>");
    if (closeIdx !== -1) {
      const thinkStart = trimmed.indexOf(":") !== -1 && trimmed.indexOf(":") < 20
        ? trimmed.indexOf(":") + 1
        : trimmed.indexOf("\n") + 1;
      const thinking = trimmed.slice(thinkStart, closeIdx).trim();
      const rest = trimmed.slice(closeIdx + 8).replace(/^\n+/, "");
      return { thinking, content: rest };
    }
  }

  if (trimmed.startsWith("<|channel>thought")) {
    const closeIdx = trimmed.indexOf("<channel|>");
    if (closeIdx !== -1) {
      const thinkStart = trimmed.indexOf("\n") + 1;
      const thinking = trimmed.slice(thinkStart, closeIdx).trim();
      const rest = trimmed.slice(closeIdx + 10).replace(/^\n+/, "");
      return { thinking, content: rest };
    }
  }

  return { thinking: "", content: cleaned };
}

/**
 * Streaming counterpart of {@link parseThinkFromContent}. Fed content tokens
 * incrementally as they arrive, it routes them to onThinking / onContent,
 * detecting a leading think block and buffering across token boundaries so a
 * close tag split between chunks is still found.
 */
export class ThinkStreamParser {
  private inThinkBlock = false;
  private thinkCloseTag = "</think>";
  private contentAccum = "";
  private thinkDetectionDone = false;
  private thinkCloseBuffer = "";

  constructor(
    private readonly onThinking: (token: string) => void,
    private readonly onContent: (token: string) => void,
  ) {}

  /** Feed one content token from the stream. */
  handleContent(text: string): void {
    if (!this.thinkDetectionDone) {
      this.contentAccum += text;
      // Wait for enough chars to decide (need ~18 for the longest opener).
      if (
        this.contentAccum.length < 20 &&
        !this.contentAccum.includes("\n\n") &&
        !this.contentAccum.includes("<channel|>")
      ) {
        return;
      }

      this.thinkDetectionDone = true;
      const trimmed = this.contentAccum.trimStart();

      if (trimmed.startsWith("<think>")) {
        this.inThinkBlock = true;
        this.thinkCloseTag = "</think>";
        const afterTag = this.contentAccum.replace(/^\s*<think>\s*/, "");
        if (afterTag) this.onThinking(afterTag);
        return;
      }
      if (trimmed.startsWith("Thinking Process:") || trimmed.startsWith("Thinking Process\n")) {
        this.inThinkBlock = true;
        this.thinkCloseTag = "</think>";
        const afterTag = trimmed.replace(/^Thinking Process:?\s*/, "");
        if (afterTag) this.onThinking(afterTag);
        return;
      }
      if (trimmed.startsWith("<|channel>thought")) {
        this.inThinkBlock = true;
        this.thinkCloseTag = "<channel|>";
        const afterTag = trimmed.replace(/^<\|channel>thought\s*/, "");
        if (afterTag) this.onThinking(afterTag);
        return;
      }

      // Not a think block — flush accumulated content as normal tokens.
      this.onContent(this.contentAccum);
      return;
    }

    if (this.inThinkBlock) {
      this.thinkCloseBuffer += text;
      const closeIdx = this.thinkCloseBuffer.indexOf(this.thinkCloseTag);
      if (closeIdx !== -1) {
        const before = this.thinkCloseBuffer.slice(0, closeIdx);
        if (before) this.onThinking(before);
        const after = this.thinkCloseBuffer.slice(closeIdx + this.thinkCloseTag.length);
        this.inThinkBlock = false;
        this.thinkCloseBuffer = "";
        if (after.replace(/^\n+/, "")) this.onContent(after.replace(/^\n+/, ""));
        return;
      }
      // Flush confirmed non-close content, keeping a tail that could be a
      // partial close tag.
      const tagLen = this.thinkCloseTag.length;
      if (this.thinkCloseBuffer.length > tagLen) {
        const safe = this.thinkCloseBuffer.slice(0, -tagLen);
        this.onThinking(safe);
        this.thinkCloseBuffer = this.thinkCloseBuffer.slice(-tagLen);
      }
      return;
    }

    // Safety net: strip any residual thinking tags the FSM missed.
    const cleaned = text
      .replace(/<\|channel>thought[\s\S]*?<channel\|>/g, "")
      .replace(/<think>[\s\S]*?<\/think>/g, "");
    if (cleaned) this.onContent(cleaned);
  }

  /**
   * Called when the server emits a `reasoning` delta while we still have
   * buffered, undecided content: that buffer was the opening think tag, so
   * discard it and let the server handle thinking extraction.
   */
  onReasoningStart(): void {
    if (!this.thinkDetectionDone && this.contentAccum) {
      this.thinkDetectionDone = true;
      this.inThinkBlock = false;
      this.contentAccum = "";
    }
  }

  /** Flush any buffered content/thinking at end of stream. */
  flush(): void {
    if (!this.thinkDetectionDone && this.contentAccum) {
      this.thinkDetectionDone = true;
      this.onContent(this.contentAccum);
      this.contentAccum = "";
    }
    if (this.inThinkBlock && this.thinkCloseBuffer) {
      this.onThinking(this.thinkCloseBuffer);
      this.thinkCloseBuffer = "";
    }
  }
}
