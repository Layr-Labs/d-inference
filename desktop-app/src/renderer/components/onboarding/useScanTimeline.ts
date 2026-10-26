import { useEffect, useEffectEvent, useState } from 'react';
import type { ScanFrame, ScanScript } from './scanScript';

const waiting: ScanFrame = { revealed: 0, resolved: 0, phase: 'waiting' };

// Plays a script from its start frame; a new script starts over from its first frame.
export function useScanTimeline(script: ScanScript | undefined, onAdvance: () => void) {
  const [position, setPosition] = useState({ script, index: 0, start: 0 });
  const { index, start } = position.script === script ? position : { index: 0, start: 0 };
  const advance = useEffectEvent(onAdvance);
  useEffect(() => {
    if (!script) return;
    const origin = script.frames[start].at;
    const timers = script.frames
      .slice(start + 1)
      .map((frame, offset) =>
        setTimeout(
          () => setPosition({ script, index: start + 1 + offset, start }),
          frame.at - origin,
        ),
      );
    if (script.advanceAt !== undefined)
      timers.push(setTimeout(() => advance(), script.advanceAt - origin));
    return () => timers.forEach(clearTimeout);
  }, [script, start]);
  return {
    frame: script ? script.frames[index].frame : waiting,
    // Skipping hands an eligible Mac straight on and shows any other verdict at once.
    finish() {
      if (!script) return;
      const last = script.frames.length - 1;
      if (script.advanceAt !== undefined) onAdvance();
      else setPosition({ script, index: last, start: last });
    },
  };
}
