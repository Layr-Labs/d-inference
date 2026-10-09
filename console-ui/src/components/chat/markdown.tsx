"use client";

import type { Components } from "react-markdown";
import { CodeBlock } from "./CodeBlock";

// Custom react-markdown renderers: terminal-style code blocks, transparent
// <pre> wrapper. Typed against react-markdown's Components (removes the 4 `any`
// the inline version used — proposal F10).
export const markdownComponents: Components = {
  code({ className, children }) {
    // No language class → inline code; otherwise a fenced block.
    if (!className) {
      return <code>{children}</code>;
    }
    return <CodeBlock className={className}>{children}</CodeBlock>;
  },
  pre: ({ children }) => <>{children}</>,
};
