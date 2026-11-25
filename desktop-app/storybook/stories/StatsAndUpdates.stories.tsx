import type { Meta, StoryObj } from '@storybook/react-vite';
import { MacPerformance as PerformanceBefore } from '../src/before/desktop-app/src/renderer/features/stats/Performance';
import { MacPerformance as PerformanceAfter } from '../src/after/desktop-app/src/renderer/features/stats/Performance';
import { Updates as UpdatesBefore } from '../src/before/desktop-app/src/renderer/features/Updates';
import { Updates as UpdatesAfter } from '../src/after/desktop-app/src/renderer/features/Updates';
import { parseReleaseHistory as parseBefore } from '../src/before/desktop-app/src/renderer/features/updates/version';
import { parseReleaseHistory as parseAfter } from '../src/after/desktop-app/src/renderer/features/updates/version';
import { HealthBar as HealthBefore } from '../src/before/desktop-app/src/renderer/features/machines/overview/HealthBar';
import { HealthBar as HealthAfter } from '../src/after/desktop-app/src/renderer/features/machines/overview/HealthBar';
import { ReleaseTimeline as TimelineBefore } from '../src/before/desktop-app/src/renderer/features/updates/ReleaseTimeline';
import { ReleaseTimeline as TimelineAfter } from '../src/after/desktop-app/src/renderer/features/updates/ReleaseTimeline';
import type { ReleaseHistory } from '../src/after/desktop-app/src/shared/contracts';
import { Compare } from './support/Compare';
import { resetBridges } from './support/bridge';
import { backendFor, poolSnapshot } from './support/fixtures';

const meta: Meta = { title: 'Fixes/Stats and updates' };
export default meta;
type Story = StoryObj;

const minutesAgo = (minutes: number) => Date.now() / 1000 - minutes * 60;
// DesktopRequestHistory.swift: this session's local history carries completed_at only.
const sessionHistory = {
  observed_at: Date.now() / 1000,
  records: Array.from({ length: 40 }, (_, i) => ({
    id: `local-${i}`,
    completed_at: minutesAgo(i * 9 + 2),
    model: i % 3 ? 'gpt-oss-20b' : 'gemma-4-26b',
    input_tokens: 1800 + i * 37,
    output_tokens: 420 + ((i * 53) % 300),
    outcome: 'completed',
    earnings_micro_usd: null,
  })),
};
const serving = () => {
  const state = poolSnapshot();
  return { ...state, activity: { ...state.activity, samples: [] } };
};

export const StatsCompletedHistory: Story = {
  name: '#1453 Stats traffic while serving',
  beforeEach: () =>
    resetBridges({
      read: async (resource) => {
        if (resource === 'request-history') return sessionHistory;
        throw new Error('Unavailable in Storybook');
      },
    }),
  render: () => (
    <Compare
      pr={1453}
      title="The Stats traffic chart vanished on a serving Mac"
      wrong={
        <p>
          The runtime reports this session's requests with a <code>completed_at</code> time only.
          The chart bucketed by <code>settled_at ?? started_at</code>, got <code>undefined</code>{' '}
          for every record, produced no points, and was hidden. The Activity table already read
          the right field.
        </p>
      }
      fixed={
        <p>
          Traffic is bucketed with the same <code>requestTime()</code> helper as the Activity
          table, and the chart says <b>Completed requests</b> for local history (<b>Settled</b> for
          ledger history).
        </p>
      }
      before={<PerformanceBefore backend={backendFor('before', serving())} />}
      after={<PerformanceAfter backend={backendFor('after', serving())} />}
      stack
    />
  ),
};

// DesktopResources.swift: history synthesized from the latest release, without a support policy.
const nativeHistory = {
  history: [
    {
      version: '0.9.20',
      published_at: '2026-10-12T00:00:00Z',
      notes: 'Improved provider reliability.',
      active: true,
    },
  ],
};
const readHistory = (parse: (value: unknown) => ReleaseHistory): ReleaseHistory => {
  // Mirrors useBackend's handling of a failed parse.
  try {
    return parse(nativeHistory);
  } catch {
    return { history: [], error: 'Release history and support policy are unavailable.' };
  }
};
const installed = () => poolSnapshot({}, { version: '0.9.16' });
const release = { version: '0.9.20', published_at: '2026-10-12T00:00:00Z', notes: 'Reliability.' };

export const ReleaseHistoryWithoutPolicy: Story = {
  name: '#1454 Release history from the real runtime',
  beforeEach: () => resetBridges(),
  render: () => (
    <Compare
      pr={1454}
      title="Updates always said release history was unavailable"
      wrong={
        <p>
          Until the coordinator's desktop release feed ships, the native API returns release
          history without a <code>minimum_provider_version</code>. The parser rejected anything
          without it, so with the real runtime the history was <i>always</i> unavailable. Look under
          <b>Release history</b>: “History unavailable · showing the latest release”.
        </p>
      }
      fixed={
        <p>
          A missing support policy is treated as unknown (account data can still supply it) and
          the history is shown. Malformed values are still rejected.
        </p>
      }
      before={
        <UpdatesBefore
          backend={backendFor('before', installed(), {
            release,
            releaseHistory: readHistory(parseBefore),
          })}
        />
      }
      after={
        <UpdatesAfter
          backend={backendFor('after', installed(), {
            release,
            releaseHistory: readHistory(parseAfter),
          })}
        />
      }
    />
  ),
};

const belowFloor = () => poolSnapshot({}, { version: '0.9.2', state: 'running' });
const cloud = {
  linked: true,
  observed_at: Date.now() / 1000,
  machines: [],
  minimum_provider_version: '0.9.10',
};

export const RequiredUpdateOnOverview: Story = {
  name: '#1454 Required update on This Mac',
  beforeEach: () => resetBridges(),
  render: () => (
    <Compare
      pr={1454}
      title="This Mac's Overview hid an available required update"
      wrong={
        <p>
          The Overview decides between “Update now” and “no compatible update yet” using the
          latest release, but the My Macs page never loaded it, only Updates did. Opening My Macs
          first showed a dead end with no button.
        </p>
      }
      fixed={
        <p>
          My Macs now loads the (cached) release resources too, so a runtime below the supported
          floor offers <b>Update now</b> immediately. Before: release data absent, as it was on
          that page. After: loaded.
        </p>
      }
      before={
        <HealthBefore
          backend={backendFor('before', belowFloor(), { cloud: cloud as never })}
          navigate={() => {}}
        />
      }
      after={
        <HealthAfter
          backend={backendFor('after', belowFloor(), { cloud: cloud as never, release })}
          navigate={() => {}}
        />
      }
    />
  ),
};

// The shape of the published Provider 0.9.20 notes: the release text followed by the signed tag's
// signature block (placeholder signature data, not the real one).
const signedNotes = [
  'Provider 0.9.20',
  '',
  '- Faster recovery after a network interruption.',
  '- Clearer errors when a model cannot load.',
  '-----BEGIN SSH SIGNATURE-----',
  'U1NIU0lHAAAAAQAAADMAAAALc3NoLWVkMjU1MTkAAAAgPLACEHOLDERPLACEHOLDERPLACE',
  'HOLDERPLACEHOLDERAAAAA2dpdAAAAAAAAAAGc2hhNTEyAAAAUwAAAAtzc2gtZWQyNTUxOQ',
  '-----END SSH SIGNATURE-----',
].join('\n');
const signedHistory: ReleaseHistory = {
  history: [
    { version: '0.9.20', published_at: '2026-10-12T00:00:00Z', notes: signedNotes, active: true },
    { version: '0.9.19', published_at: '2026-10-05T00:00:00Z', notes: 'Reliability fixes.', active: true },
  ],
};

export const ReleaseNotesSignature: Story = {
  name: '#1481 / #1482 Signature block in release notes',
  beforeEach: () => resetBridges(),
  // Open 0.9.20's notes in both panes.
  play: ({ canvasElement }) => {
    for (const pane of canvasElement.querySelectorAll('.sb-pane'))
      pane.querySelector('details')?.setAttribute('open', '');
  },
  render: () => (
    <Compare
      pr={1481}
      title="Provider 0.9.20's release notes ended in an SSH signature"
      wrong={
        <p>
          The release publisher read the signed git tag's message with{' '}
          <code>%(contents)</code>, which includes the tag's signature block, so the published
          0.9.20 notes ended in <code>-----BEGIN SSH SIGNATURE-----</code> and base64. The Updates
          timeline showed it as release text (the play step opens 0.9.20's notes).
        </p>
      }
      fixed={
        <>
          <p>
            #1481: the desktop app never shows SSH or PGP signature blocks in notes (including one
            cut off before its END line), so already-published records read correctly.
          </p>
          <p>
            #1482 (against <code>master</code>): the publisher reads the subject and body only, so
            future releases don't include it. The stored 0.9.20 record still needs a coordinator
            admin to edit.
          </p>
        </>
      }
      before={<TimelineBefore history={signedHistory} installed="0.9.19" />}
      after={<TimelineAfter history={signedHistory} installed="0.9.19" />}
    />
  ),
};
