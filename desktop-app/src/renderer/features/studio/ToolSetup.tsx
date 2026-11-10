import { useId } from 'react';
import { Check, Copy, Wrench } from 'lucide-react';
import type { LocalTool } from '../../../shared/localServing';
import type { BackendState } from '../../useBackend';
import { supports } from '../../capabilities';
import { Button } from '../../components/UI';
import type { Copier } from './useCopy';
import { toolCommand, toolName } from './words';
import styles from './studio.module.css';

const tools: LocalTool[] = ['opencode', 'hermes'];

// `darkbloom --opencode` / `--hermes` point the tool at this Mac's local API, with a backup and a
// one-line undo in the result. A runtime without `tool_setup` gets the command to run instead.
export function ToolSetup({ backend, copier }: { backend: BackendState; copier: Copier }) {
  const state = backend.state!;
  const endpoint = state.endpoint;
  const { copied, copy } = copier;
  const heading = useId();
  if (!supports(state, 'tool_setup'))
    return (
      <section className="settings-section" aria-labelledby={heading}>
        <h2 id={heading}>Use it in your tools</h2>
        {tools.map((tool) => (
          <div key={tool} className="setting-row">
            <span>{toolName[tool]}</span>
            <code>{toolCommand[tool]}</code>
            <button
              className="icon-button"
              aria-label={
                copied === tool ? `${toolCommand[tool]} copied` : `Copy ${toolCommand[tool]}`
              }
              onClick={() => void copy(toolCommand[tool], tool)}
            >
              {copied === tool ? <Check size={16} /> : <Copy size={16} />}
            </button>
          </div>
        ))}
        <small className="muted">Run it in Terminal.</small>
      </section>
    );
  // Tools need this Mac's local API running, with its key.
  const blocked = !endpoint
    ? 'Start serving first.'
    : !endpoint.authenticated
      ? 'Tools need the local API’s key. Start it without --no-auth.'
      : undefined;
  return (
    <section className="settings-section" aria-labelledby={heading}>
      <h2 id={heading}>Use it in your tools</h2>
      <div className={styles.tools}>
        {tools.map((tool) => (
          <Button
            key={tool}
            disabled={!!blocked || backend.busy}
            onClick={() => void backend.act({ action: 'tool_setup', tool })}
          >
            <Wrench size={14} /> Set up {toolName[tool]}
          </Button>
        ))}
      </div>
      {blocked && <small className={styles.note}>{blocked}</small>}
    </section>
  );
}
