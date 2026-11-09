import type { ClusterConsoleEvent, ClusterSession } from '../../../shared/cluster';

// The guided setup's screen, as the app shows it: the CLI's own lines in its own order, grouped
// under its steps ("2/4 Pair"), with the live work, the question's own lines and the outcome
// lifted out where the page gives them their own place.

export type Tone = 'plain' | 'done' | 'failed';

export interface Line {
  key: string;
  // Without the ✓ or ✗ the tone carries.
  text: string;
  // The part a terminal shows in bold, within `text`.
  stressed?: { lead: string; stressed: string; tail: string };
  tone: Tone;
  // A detail under the line before it.
  indent: boolean;
  // A six-digit pairing code ("482 913"); `text` is then what follows it.
  code?: string;
  // The one command a "Run `…`" line asks for, offered to copy.
  command?: string;
  // A "Label:   value" row of the pair's card, or a "darkbloom stop     Stop both Macs" row
  // (`command`).
  fact?: { label: string; value: string; command?: boolean };
}

export type Block =
  | { kind: 'line'; line: Line }
  | { kind: 'result'; key: string; ok: boolean; title: string; lines: string[] }
  | { kind: 'terminal'; key: string; text: string; command?: string };

export interface Step {
  key: string;
  title: string;
  // From a numbered heading such as "2/4 Pair".
  index?: number;
  total?: number;
  blocks: Block[];
}

export interface LiveRow {
  text: string;
  percent?: number;
}

export type Live =
  | { kind: 'working'; rows: LiveRow[] }
  | { kind: 'progress'; label: string; figures: string[]; percent?: number };

export interface Prompt {
  code?: string;
  lines: Line[];
}

export interface Transcript {
  title: string;
  subtitle: string;
  // Said before the first step.
  intro: Block[];
  steps: Step[];
  live: Live | null;
  // The lines that ask the open question, lifted out of their step.
  prompt: Prompt | null;
  // The last outcome block.
  outcome: Extract<Block, { kind: 'result' }> | null;
  meter: { index: number; total: number } | null;
}

const text = (value: unknown) => (typeof value === 'string' ? value : '');

// "2/4 Pair" → step 2 of 4, "Pair"; any other heading is a step without a number.
export function heading(title: string): Pick<Step, 'title' | 'index' | 'total'> {
  const match = title.trim().match(/^(\d)\s?\/\s?(\d)\s+(.+)$/);
  if (!match) return { title: title.trim() };
  const index = Number(match[1]);
  const total = Number(match[2]);
  if (total < 1 || index < 1 || index > total) return { title: title.trim() };
  return { title: match[3], index, total };
}

// A share such as "M3 Ultra 50% / M5 Max 50%" is not progress.
const share = /\d\s?%\s*\//;

export function percent(value: string): number | undefined {
  if (share.test(value)) return undefined;
  const match = value.match(/(\d{1,3}(?:\.\d+)?)\s?%/);
  if (!match) return undefined;
  const number = Number(match[1]);
  return number >= 0 && number <= 100 ? number : undefined;
}

// A copy's or download's report, "Downloading X  42%  6.8 GB of 16.3 GB  1.2 GB/s  2 min left":
// its label, then its figures, with any drawn bar left out (the page draws its own).
export function progressReport(value: string): Extract<Live, { kind: 'progress' }> {
  const parts = value
    .replace(/\[[█░#.= -]*\]/g, ' ')
    .trim()
    .split(/\s{2,}| · /)
    .filter(Boolean);
  return {
    kind: 'progress',
    label: parts[0] ?? '',
    figures: parts.slice(1),
    percent: percent(value),
  };
}

const rule = /^[─━—-]{6,}$/;
const codeLine = /^(?:Pairing code:\s*|Code\s+)(\d{3} \d{3})\b\.?\s*(.*)$/;
const commandLine = /^Run `([^`]+)`/;
const factLine = /^([A-Z][A-Za-z ]{1,18}):\s{2,}(\S.*)$/;
const commandRow = /^((?:darkbloom|darkbloom-dev)(?: [a-z][a-z-]*)+)\s{2,}(\S.*)$/;

function stressedWithin(
  shown: string,
  stressed: { lead: string; stressed: string; tail: string } | undefined,
) {
  if (!stressed?.stressed) return undefined;
  const at = shown.indexOf(stressed.stressed);
  if (at < 0) return undefined;
  return {
    lead: shown.slice(0, at),
    stressed: stressed.stressed,
    tail: shown.slice(at + stressed.stressed.length),
  };
}

// One said line. Blank lines and the outcome block's rules are spacing, not lines.
export function sayLine(event: Extract<ClusterConsoleEvent, { type: 'say' }>, key: string) {
  const raw = text(event.text);
  const trimmed = raw.trim();
  if (!trimmed || rule.test(trimmed)) return null;
  const leading = raw.length - raw.trimStart().length;
  let shown = trimmed;
  let tone: Tone = 'plain';
  if (/^[✓✔]/.test(shown)) {
    tone = 'done';
    shown = shown.slice(1).trimStart();
  } else if (/^[✗✘]/.test(shown)) {
    tone = 'failed';
    shown = shown.slice(1).trimStart();
  }
  const line: Line = { key, text: shown, tone, indent: leading >= 4 || shown.startsWith('· ') };
  const code = shown.match(codeLine);
  if (code) {
    line.code = code[1];
    line.text = code[2];
  }
  const command = shown.match(commandLine);
  if (command) line.command = command[1];
  const fact = !code && shown.match(factLine);
  if (fact) line.fact = { label: fact[1], value: fact[2] };
  const row = !code && shown.match(commandRow);
  if (row) line.fact = { label: row[1], value: row[2], command: true };
  const stressed = stressedWithin(line.text, event.stressed);
  if (stressed) line.stressed = stressed;
  return line;
}

// A line that asks: it ends with "?", or with a short "Type y or n:" after one.
const isQuestion = (line: Line) => /\?["”)]?(\s+[^?]{1,30}:)?$/.test(line.text.trim());

// The last index whose item passes (`Array.prototype.findLastIndex` is ES2023).
function lastIndex<T>(items: T[], test: (item: T, index: number) => boolean) {
  for (let index = items.length - 1; index >= 0; index -= 1)
    if (test(items[index], index)) return index;
  return -1;
}

// The lines that ask the open question: the last few said lines of its step, from the one that
// ends with "?" (a pairing code just above it comes too). Lines the page shows with the question
// leave the step.
function liftPrompt(blocks: Block[]): Prompt | null {
  let start = blocks.length;
  while (start > 0 && blocks[start - 1].kind === 'line' && blocks.length - start < 4) start -= 1;
  const tail = blocks.slice(start).map((block) => (block as Extract<Block, { kind: 'line' }>).line);
  const asks = lastIndex(tail, isQuestion);
  if (asks < 0) return null;
  const codeAt = lastIndex(tail, (line, index) => index <= asks && !!line.code);
  const from = codeAt >= 0 && asks - codeAt <= 2 ? codeAt : asks;
  const lines = tail.slice(from);
  blocks.splice(start + from);
  const code = lines.find((line) => line.code)?.code;
  return {
    code,
    lines: lines
      .map((line) => (line.code ? { ...line, code: undefined } : line))
      .filter((line) => line.text.trim()),
  };
}

export function transcript(session: ClusterSession): Transcript {
  let title = '';
  let subtitle = '';
  const intro: Block[] = [];
  const steps: Step[] = [];
  let live: Live | null = null;
  let outcome: Transcript['outcome'] = null;
  let meter: Transcript['meter'] = null;
  const into = () => steps.at(-1)?.blocks ?? intro;
  session.events.forEach((event, position) => {
    const key = String(position);
    switch (event.type) {
      case 'banner':
        title = text(event.title);
        subtitle = text(event.subtitle);
        live = null;
        break;
      case 'heading': {
        live = null;
        const step = { key, ...heading(text(event.text)), blocks: [] };
        if (!step.title) break;
        steps.push(step);
        if (step.index && step.total) meter = { index: step.index, total: step.total };
        break;
      }
      case 'say': {
        live = null;
        const line = sayLine(event, key);
        if (line) into().push({ kind: 'line', line });
        break;
      }
      case 'working': {
        const rows = (Array.isArray(event.rows) ? event.rows : [])
          .map(text)
          .filter((row) => row.trim())
          .map((row) => ({ text: row.trim(), percent: percent(row) }));
        live = rows.length ? { kind: 'working', rows } : null;
        break;
      }
      case 'settle':
        live = null;
        break;
      case 'progress':
        live = text(event.text).trim() ? progressReport(text(event.text)) : null;
        break;
      case 'result': {
        live = null;
        const block = {
          kind: 'result' as const,
          key,
          ok: event.ok === true,
          title: text(event.title),
          lines: (Array.isArray(event.lines) ? event.lines : [])
            .map(text)
            .map((line) => line.trim())
            .filter(Boolean),
        };
        into().push(block);
        outcome = block;
        break;
      }
      case 'needs_terminal': {
        live = null;
        const said = text(event.text).trim();
        if (said)
          into().push({ kind: 'terminal', key, text: said, command: said.match(/`([^`]+)`/)?.[1] });
        break;
      }
      default:
        // An event a newer runtime added: nothing to show for it here.
        break;
    }
  });
  // Work stops with the session; a finished one has nothing live.
  if (session.state !== 'running') live = null;
  const prompt = session.question && session.state === 'running' ? liftPrompt(into()) : null;
  return { title, subtitle, intro, steps, live, prompt, outcome, meter };
}

// Leaving now would stop a pairing that has begun and not finished: the pairing step is on screen
// and has not said "Paired".
export function pairingInProgress(view: Transcript) {
  const step = view.steps.at(-1);
  if (!step || !/\bpair\b/i.test(step.title)) return false;
  return !step.blocks.some(
    (block) =>
      block.kind === 'line' && block.line.tone === 'done' && /^Paired\b/.test(block.line.text),
  );
}

// A choose option's rows: the title (first row), its detail rows, and the small markers the CLI
// joins to a list line with " · ": the split ("tensor parallel", "pipeline"), its state ("serving
// now"), what it needs ("copy", "16.3 GB") and why it can't run now.
export interface Option {
  title: string;
  details: string[];
  modes: string[];
  marks: string[];
  warnings: string[];
  facts: string[];
}

const modeWords = [
  'tensor parallel',
  'pipeline',
  'speculative pipeline',
  'pipeline with speculative decoding',
  'pipeline prefill, tensor parallel decode',
  'prompt split, then one mac decodes',
  'split across the macs',
];
const isMode = (part: string) =>
  part
    .toLowerCase()
    .split(' or ')
    .every((word) => modeWords.includes(word.trim()));
const isMark = (part: string) =>
  /^(serving now\b.*|last used|recommended( for these Macs)?)$/i.test(part);
const isWarning = (part: string) => /^(does not fit now|not enough free disk)$/i.test(part);
// A planner note ("tensor parallel: slower here") or a split ("M3 Ultra 40 layers / M5 Ultra 24 layers").
const isNote = (part: string) =>
  /^(tensor parallel|pipeline)\b.*:/i.test(part) || /\d+(\s?%| layers?) \/ /.test(part);
const isSentence = (part: string) => part.length > 48 || /[.!?]$/.test(part);

export function option(rows: string[]): Option {
  const [first = '', ...rest] = rows.map((row) => row.trim()).filter(Boolean);
  // A menu line pads its label before what it does ("Tensor parallel     both Macs …").
  const [label, ...said] = first.split(/\s{3,}/);
  const parts = label.split(' · ');
  const result: Option = {
    title: parts[0] ?? '',
    details: [],
    modes: [],
    marks: [],
    warnings: [],
    facts: [],
  };
  for (const part of parts.slice(1)) {
    if (isMode(part)) result.modes.push(part);
    else if (isMark(part)) result.marks.push(part);
    else if (isWarning(part)) result.warnings.push(part);
    else if (isNote(part)) result.facts.push(part);
    else if (isSentence(part)) result.details.push(part);
    else result.facts.push(part);
  }
  result.details.push(...said.map((part) => part.trim()).filter(Boolean), ...rest);
  return result;
}
