import { useState } from 'react';
import type { Meta, StoryObj } from '@storybook/react-vite';
import { Compare } from './support/Compare';

const meta: Meta = { title: 'Fixes/My Macs/Navigation' };
export default meta;
type Story = StoryObj;

function Framed({ version }: { version: 'before' | 'after' }) {
  const [result, setResult] = useState('Running: scroll Home to the bottom, then open My Macs…');
  return (
    <div className="sb-framed">
      <div className="sb-frame-box">
        <iframe
          title={`Full app ${version}`}
          src={`iframe.html?id=internal-full-app--${version}&viewMode=story`}
          onLoad={async (event) => {
            const frame = event.currentTarget.contentWindow!;
            await new Promise((resolve) => setTimeout(resolve, 3500));
            frame.scrollTo(0, frame.document.documentElement.scrollHeight);
            await new Promise((resolve) => setTimeout(resolve, 600));
            const home = Math.round(frame.scrollY);
            frame.document.querySelector<HTMLButtonElement>('nav button[aria-label="My Macs"]')?.click();
            await new Promise((resolve) => setTimeout(resolve, 1500));
            const macs = Math.round(frame.scrollY);
            setResult(
              `Home scrolled to ${home}px → after opening My Macs the page is at ${macs}px${
                macs > 0 ? ': the title and Overview/Models/Cooling tabs are above the fold.' : ': its header is in view.'
              }`,
            );
          }}
        />
      </div>
      <p className="sb-observed">{result}</p>
    </div>
  );
}

export const ScrollPosition: Story = {
  name: '#1452 Page opens at the previous scroll position',
  render: () => (
    <Compare
      pr={1452}
      title="Pages, Macs and tabs opened where the previous page was scrolled"
      wrong={
        <p>
          The desktop window's document is its scroll container and nothing reset it on
          navigation. Following <b>View earnings</b> or <b>Explore Stats</b> from lower on Home,
          switching Macs or changing tabs opened the new page mid-way, with its header and tabs out
          of view.
        </p>
      }
      fixed={
        <p>
          Every route or Mac change resets the scroll position before paint. Each pane below runs
          the whole app (scaled to half size, 1320×880) in its own frame: it scrolls Home to the
          bottom and opens My Macs.
        </p>
      }
      before={<Framed version="before" />}
      after={<Framed version="after" />}
    />
  ),
};
