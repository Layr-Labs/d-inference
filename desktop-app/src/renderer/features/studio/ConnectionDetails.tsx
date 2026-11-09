import { useId } from 'react';
import { Check, Copy } from 'lucide-react';
import type { Snapshot } from '../../../shared/contracts';
import type { LocalServing } from '../../../shared/localServing';
import { Button, Notice } from '../../components/UI';
import type { Copier } from './useCopy';
import type { EndpointKey } from './useEndpointKey';
import { address, reach } from './words';

// Base URL, the key (read only on Reveal) and, from a runtime that reports it, the port and
// address this Mac's one local API listens on.
export function ConnectionDetails({
  endpoint,
  local,
  endpointKey,
  copier,
  problem,
}: {
  endpoint: Snapshot['endpoint'];
  local?: LocalServing;
  endpointKey: EndpointKey;
  copier: Copier;
  problem: string;
}) {
  const { copied, copy } = copier;
  const heading = useId();
  return (
    <section className="settings-section" aria-labelledby={heading}>
      <h2 id={heading}>Connection details</h2>
      <div className="setting-row">
        <span>Base URL</span>
        <code>{endpoint?.base_url || (local ? 'Not running' : 'Not enabled')}</code>
        {endpoint && (
          <button
            className="icon-button"
            aria-label={copied === 'url' ? 'Base URL copied' : 'Copy base URL'}
            onClick={() => void copy(endpoint.base_url, 'url')}
          >
            {copied === 'url' ? <Check size={16} /> : <Copy size={16} />}
          </button>
        )}
      </div>
      <div className="setting-row">
        <span>API key</span>
        <code>{endpointKey.key || '••••••••••••••••'}</code>
        <Button disabled={!endpointKey.available} onClick={() => void endpointKey.toggle()}>
          {endpointKey.key ? 'Hide' : 'Reveal'}
        </Button>
      </div>
      {local?.port != null && (
        <div className="setting-row">
          <span>Listens on</span>
          <code>{address(local.bind, local.port)}</code>
        </div>
      )}
      <small className="muted">
        {endpoint?.authenticated === false ? 'No API key required.' : 'Requires an API key.'}{' '}
        {reach(local?.bind)}
      </small>
      {problem && <Notice>{problem}</Notice>}
    </section>
  );
}
