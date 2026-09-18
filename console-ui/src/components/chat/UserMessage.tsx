"use client";

import type { Message } from "@/lib/store";

export function UserMessage({ message }: { message: Message }) {
  const hasImages = !!message.images && message.images.length > 0;
  return (
    <div className="message-animate py-4">
      <div className="max-w-3xl mx-auto px-4 sm:px-6 flex justify-end">
        <div className="max-w-[90%] sm:max-w-[80%] flex flex-col items-end gap-2">
          {hasImages && (
            <div className="flex flex-wrap gap-2 justify-end">
              {message.images!.map((src, i) => (
                <img
                  key={i}
                  src={src}
                  alt={`Attached image ${i + 1}`}
                  className="max-h-48 max-w-[12rem] rounded-xl border border-border-dim object-cover"
                />
              ))}
            </div>
          )}
          {message.content && (
            <div className="rounded-2xl rounded-br-md bg-bg-secondary px-5 py-3.5">
              <p className="text-[15px] text-text-primary leading-relaxed whitespace-pre-wrap">
                {message.content}
              </p>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
