import { useState } from 'react';
import type { Route } from '../../../../shared/contracts';
import type { BackendState } from '../../../useBackend';
import { api } from '../../../useBackend';
import { Button } from '../../../components/UI';
import { openSoftwareUpdate } from '../../../softwareUpdate';
import type { ReadinessStep, StepAction } from './readiness';
import styles from './overview.module.css';

export function NextSteps({
  steps,
  backend,
  navigate,
}: {
  steps: ReadinessStep[];
  backend: BackendState;
  navigate: (route: Route) => void;
}) {
  const [copied, setCopied] = useState('');
  const copy = async (code: string) => {
    try {
      await api?.copy(code);
      setCopied(code);
    } catch {
      setCopied('');
    }
  };
  const run = (action: StepAction) => {
    if (action.kind === 'route') navigate(action.route);
    else if (action.kind === 'act') void backend.act(action.action);
    else if (action.kind === 'link-page') void api?.openExternal('link');
    else if (action.kind === 'software-update') openSoftwareUpdate();
    else
      void api
        ?.install()
        .catch(() =>
          backend.setError('Darkbloom CLI installation failed. Check your connection and retry.'),
        );
  };
  const disabled = (action: StepAction) =>
    action.kind === 'act'
      ? backend.busy
      : action.kind === 'install' && backend.status.state === 'installing';
  return (
    <div className={styles.steps}>
      <h3>Next steps</h3>
      <ol>
        {steps.map((step, index) => (
          <li key={step.id}>
            <div>
              <strong>{step.title}</strong>
              <p>{step.detail}</p>
              {step.code && (
                <div className={styles.stepCode}>
                  <strong aria-label={`Link code ${step.code}`}>{step.code}</strong>
                  <button type="button" className="text-link" onClick={() => void copy(step.code!)}>
                    {copied === step.code ? 'Copied' : 'Copy code'}
                  </button>
                </div>
              )}
            </div>
            {step.actions.length > 0 && (
              <div className={styles.stepActions}>
                {step.actions.map((action, position) => (
                  <Button
                    key={action.label}
                    variant={index === 0 && position === 0 ? 'primary' : 'secondary'}
                    disabled={disabled(action)}
                    onClick={() => run(action)}
                  >
                    {action.label}
                  </Button>
                ))}
              </div>
            )}
          </li>
        ))}
      </ol>
    </div>
  );
}
