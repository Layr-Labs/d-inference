import { Button, Modal } from '../../components/UI';

export type AutopilotChange = 'pause' | 'disable';

const copy: Record<AutopilotChange, { title: string; body: string; confirm: string }> = {
  pause: {
    title: 'Pause Autopilot?',
    body: 'Autopilot stops changing what’s loaded. Models stay loaded as they are, pins keep protecting theirs, and you can resume any time.',
    confirm: 'Pause Autopilot',
  },
  disable: {
    title: 'Turn off Autopilot?',
    body: 'Models stay loaded as they are and manual selection takes over: you choose what serves with Apply selection. Your pool and pins are kept for when you turn Autopilot back on.',
    confirm: 'Turn off Autopilot',
  },
};

export function AutopilotConfirm({
  change,
  onConfirm,
  onClose,
}: {
  change: AutopilotChange;
  onConfirm: () => void;
  onClose: () => void;
}) {
  const { title, body, confirm } = copy[change];
  return (
    <Modal title={title} onClose={onClose}>
      <p>{body}</p>
      <div className="dialog-actions">
        <Button onClick={onClose}>Cancel</Button>
        <Button
          variant={change === 'disable' ? 'danger' : 'primary'}
          onClick={() => {
            onConfirm();
            onClose();
          }}
        >
          {confirm}
        </Button>
      </div>
    </Modal>
  );
}
