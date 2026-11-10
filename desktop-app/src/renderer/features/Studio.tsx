import { useState } from 'react';
import { Terminal } from 'lucide-react';
import type { Route } from '../../shared/contracts';
import type { BackendState } from '../useBackend';
import { Header, Status } from '../components/UI';
import { ConnectionDetails } from './studio/ConnectionDetails';
import { LegacyServingMode } from './studio/LegacyServingMode';
import { MeFirst } from './studio/MeFirst';
import { RequestExample } from './studio/RequestExample';
import { RequestRoute } from './studio/RequestRoute';
import { ServingChoice } from './studio/ServingChoice';
import { ToolSetup } from './studio/ToolSetup';
import { useCopy } from './studio/useCopy';
import { useEndpointKey } from './studio/useEndpointKey';
import { localServing } from './studio/words';
import styles from './studio/studio.module.css';

// This Mac's local API: how this Mac serves (from a runtime with local-first serving, the CLI's
// three choices, me first and where your requests go), the address and key, tool setup and a
// request that works as copied.
export function Studio({
  backend,
  embedded = false,
  navigate,
}: {
  backend: BackendState;
  embedded?: boolean;
  navigate?: (route: Route) => void;
}) {
  const state = backend.state!;
  const local = localServing(state);
  const endpoint = state.endpoint;
  const [problem, setProblem] = useState('');
  const endpointKey = useEndpointKey(backend, setProblem);
  const copier = useCopy(setProblem);
  const models = state.models.filter((model) => model.downloaded && model.eligible);
  // Default to what the endpoint serves now, so the example works as copied and applying the
  // serving mode does not switch models unless the user chooses another.
  const served = endpoint?.models.filter((id) => models.some((model) => model.id === id)) ?? [];
  const [selected, setSelected] = useState('');
  const model = selected || served[0] || models[0]?.id || '';
  const example = served.length && !served.includes(model) ? served[0] : model;
  // With local-first serving, the local API's parts show only where a local API serves.
  const localAPI = !local || !!endpoint || local.mode === 'local' || local.mode === 'both';
  return (
    <div className={styles.studio}>
      <Header
        level={embedded ? 2 : 1}
        title="Studio"
        description="Use the models on your Mac in your own applications."
        action={<span className="tag">Local API</span>}
      />
      <div className="studio-intro">
        <Terminal size={32} strokeWidth={1.2} />
        <div>
          <h2>Your Mac. Your endpoint.</h2>
          <p>Run models through an OpenAI-compatible API.</p>
        </div>
        {endpoint && <Status state="online">Listening</Status>}
      </div>
      {local ? (
        <>
          <ServingChoice backend={backend} local={local} navigate={navigate} />
          {local.mode === 'both' && <MeFirst backend={backend} local={local} />}
          {localAPI && <RequestRoute backend={backend} local={local} />}
        </>
      ) : (
        <LegacyServingMode backend={backend} models={models} model={model} onModel={setSelected} />
      )}
      {localAPI && (
        <>
          <ConnectionDetails
            endpoint={endpoint}
            local={local}
            endpointKey={endpointKey}
            copier={copier}
            problem={problem}
          />
          {local && <ToolSetup backend={backend} copier={copier} />}
          <RequestExample baseURL={endpoint?.base_url} model={example} copier={copier} />
        </>
      )}
    </div>
  );
}
