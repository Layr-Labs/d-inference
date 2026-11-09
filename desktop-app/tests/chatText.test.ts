import { describe, expect, it } from 'vitest';
import {
  anywhereTaglines,
  chatTitle,
  dateGroups,
  launchIndex,
  launchTagline,
  modelName,
  modelPlace,
  parseBlocks,
  parseInline,
  proseLine,
  staysOnThisMac,
  taglines,
} from '../src/renderer/features/chat/text';
import { inkOpacity } from '../src/renderer/features/chat/Indicators';

describe('replies', () => {
  it('splits prose from fenced code, keeping where each starts', () => {
    const text = 'Run this:\n\n```python\nprint("hi")\nprint(2)\n```\n\nThen look.';
    const blocks = parseBlocks(text);
    expect(blocks).toEqual([
      { kind: 'text', text: 'Run this:', start: 0 },
      {
        kind: 'code',
        text: 'print("hi")\nprint(2)',
        start: text.indexOf('print'),
        language: 'python',
        open: false,
      },
      { kind: 'text', text: 'Then look.', start: text.indexOf('Then') },
    ]);
    for (const block of blocks)
      expect(text.slice(block.start, block.start + block.text.length)).toBe(block.text);
  });

  it('shows a fence still open while the answer streams as code to the end', () => {
    expect(parseBlocks('Here:\n~~~\nlet a = 1\nlet b')).toEqual([
      { kind: 'text', text: 'Here:', start: 0 },
      { kind: 'code', text: 'let a = 1\nlet b', start: 10, language: '', open: true },
    ]);
    expect(parseBlocks('```js')).toEqual([
      { kind: 'code', text: '', start: 5, language: 'js', open: true },
    ]);
  });

  it('closes a fence only with a fence as long, of the same mark', () => {
    const text = '````\n```\ninner\n```\n````';
    expect(parseBlocks(text)).toEqual([
      { kind: 'code', text: '```\ninner\n```', start: 5, language: '', open: false },
    ]);
  });

  it('reads code spans, strong and emphasis, and leaves the rest as written', () => {
    expect(parseInline('Use `ls -la` for **all** files, *not* some_file_name.', 10)).toEqual([
      { kind: 'text', text: 'Use ', start: 10 },
      { kind: 'code', text: 'ls -la', start: 15 },
      { kind: 'text', text: ' for ', start: 22 },
      { kind: 'strong', text: 'all', start: 29 },
      { kind: 'text', text: ' files, ', start: 34 },
      { kind: 'em', text: 'not', start: 43 },
      { kind: 'text', text: ' some_file_name.', start: 47 },
    ]);
    expect(parseInline('2 * 3 * 4 and **unclosed')).toEqual([
      { kind: 'text', text: '2 * 3 * 4 and **unclosed', start: 0 },
    ]);
  });

  it('turns headings and bullets into plain lines', () => {
    expect(proseLine('### Steps', 4)).toEqual({ kind: 'heading', text: 'Steps', start: 8 });
    expect(proseLine('  - one', 0)).toEqual({
      kind: 'bullet',
      indent: '  ',
      text: 'one',
      start: 4,
    });
    expect(proseLine('#hashtag', 0)).toEqual({ kind: 'plain', text: '#hashtag', start: 0 });
  });

  it('settles the newest glyphs from faint to full ink over 28', () => {
    expect(inkOpacity(0, 28)).toBeCloseTo(0.28 + 0.72 / 28);
    expect(inkOpacity(13, 28)).toBeCloseTo(0.28 + 0.72 * (14 / 28));
    expect(inkOpacity(27, 28)).toBe(1);
    expect(inkOpacity(40, 28)).toBe(1);
  });
});

describe('chats', () => {
  it('titles a chat with the first line of its first message', () => {
    expect(chatTitle('  How do I list models?\nAnd more')).toBe('How do I list models?');
    expect(chatTitle('x'.repeat(60))).toBe(`${'x'.repeat(42)}…`);
    expect(chatTitle('   ')).toBe('New chat');
  });

  it('groups chats by their last change: today, yesterday, the week, earlier', () => {
    const now = new Date(2026, 10, 8, 15, 0).getTime();
    const at = (days: number, hour = 10) => new Date(2026, 10, 8 - days, hour).getTime();
    const items = [
      { id: 'week', updated_at: at(3) },
      { id: 'today', updated_at: at(0, 9) },
      { id: 'old', updated_at: at(30) },
      { id: 'yesterday', updated_at: at(1, 23) },
      { id: 'later today', updated_at: at(0, 14) },
    ];
    expect(
      dateGroups(items, now).map((group) => [group.title, group.items.map((item) => item.id)]),
    ).toEqual([
      ['Today', ['later today', 'today']],
      ['Yesterday', ['yesterday']],
      ['Previous 7 days', ['week']],
      ['Earlier', ['old']],
    ]);
  });

  it('shows one launch line per launch, in order, and survives a storage that throws', () => {
    const saved = new Map<string, string>();
    const storage = {
      getItem: (key: string) => saved.get(key) ?? null,
      setItem: (key: string, value: string) => void saved.set(key, value),
    };
    const seen = taglines.map(() => launchTagline(launchIndex(storage), true));
    expect(seen).toEqual(taglines);
    expect(launchIndex(storage)).toBe(0);
    const broken = {
      getItem: () => {
        throw new Error('denied');
      },
      setItem: () => {},
    };
    expect(launchIndex(broken)).toBe(0);
    expect(launchIndex(undefined)).toBe(0);
  });

  it('says your words stay on this Mac only while its local API keeps every request here', () => {
    expect(staysOnThisMac({ route: 'this-mac', route_key: true })).toBe(true);
    expect(staysOnThisMac({ route: null, route_key: false })).toBe(true);
    expect(staysOnThisMac({ route: null, route_key: true })).toBe(false);
    expect(staysOnThisMac({ route: 'my-macs' })).toBe(false);
    expect(staysOnThisMac({ route: 'my-macs-first' })).toBe(false);
    expect(staysOnThisMac(undefined)).toBe(false);
    for (let index = 0; index < taglines.length; index++)
      expect(anywhereTaglines).toContain(launchTagline(index, false));
    expect(launchTagline(7, true)).toBe('Your questions never leave this Mac.');
  });

  it('names a model and where it runs', () => {
    expect(modelName({ id: 'mlx-community/Qwen3-VL-30B', name: null })).toBe('Qwen3-VL-30B');
    expect(modelName({ id: 'gpt-oss-20b', name: 'GPT-OSS 20B' })).toBe('GPT-OSS 20B');
    expect(modelPlace({ owned_by: 'my-macs' })).toBe('my-macs');
    expect(modelPlace({ owned_by: 'darkbloom' })).toBe('darkbloom');
    expect(modelPlace({ owned_by: 'local' })).toBe('this-mac');
    expect(modelPlace(undefined)).toBe('this-mac');
  });
});
