"use client";

import { useEffect, useState } from "react";
import { selectedChatKey, type ChatAccessMode } from "@/lib/chat/credentials";

export function useChatAccess() {
  const [mode, setMode] = useState<ChatAccessMode>("session");
  const [hasSelectedKey, setHasSelectedKey] = useState(false);
  const [ready, setReady] = useState(false);
  useEffect(() => {
    const selected = !!selectedChatKey();
    setHasSelectedKey(selected);
    setMode(selected ? "api-key" : "session");
    setReady(true);
  }, []);
  return { mode, setMode, hasSelectedKey, ready };
}
