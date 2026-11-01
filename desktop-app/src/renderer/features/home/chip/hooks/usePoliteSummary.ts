import { useEffect, useRef, useState } from 'react';

/** Holds `text` back so a polite live region announces at most once per `interval` ms. */
export function usePoliteSummary(text: string, interval = 5000) {
  const [spoken, setSpoken] = useState(text);
  const last = useRef(0);
  useEffect(() => {
    if (text === spoken) return;
    const timer = setTimeout(
      () => {
        last.current = Date.now();
        setSpoken(text);
      },
      Math.max(0, last.current + interval - Date.now()),
    );
    return () => clearTimeout(timer);
  }, [text, spoken, interval]);
  return spoken;
}
