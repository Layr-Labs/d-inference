import type { Route } from '../../../../shared/contracts';
import type { BackendState } from '../../../useBackend';
import { api } from '../../../useBackend';
import { Button } from '../../../components/UI';
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
  const run = (action: StepAction) => {
    if (action.kind === 'route') navigate(action.route);
    else if (action.kind === 'act') void backend.act(action.action);
    else if (action.kind === 'link-page') void api?.openExternal('link');
    else
      void api
        ?.install()
        .catch(() =>
          backend.setError('Runtime installation failed. Check your connection and retry.'),
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
