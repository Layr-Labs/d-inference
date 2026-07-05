"use client";

import type { Message } from "@/lib/store";

export function UserMessage({ message }: { message: Message }) {
  const hasImages = !!message.images && message.images.length > 0;
  return (
    <div className="message-animate py-4">
      <div className="max-w-4xl mx-auto px-3 sm:px-6 flex justify-end">
        <div className="max-w-[90%] sm:max-w-[80%] flex flex-col items-end gap-2">
          {hasImages && (
            <div className="flex flex-wrap gap-2 justify-end">
              {message.images!.map((src, i) => (
                <img
                  key={i}
                  src={src}
                  alt={`Attached image ${i + 1}`}
                  className="max-h-48 max-w-[12rem] rounded-xl border-2 border-coral/30 object-cover"
                />
              ))}
            </div>
          )}
          {message.content && (
            <div className="bg-coral/10 border-2 border-coral/30 rounded-2xl rounded-br-md px-4 py-3">
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
