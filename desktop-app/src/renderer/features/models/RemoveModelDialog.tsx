import type { NativeModel } from '../../../shared/contracts';
import { Button, Modal } from '../../components/UI';

export function RemoveModelDialog({
  model,
  inPool = false,
  onRemove,
  onClose,
}: {
  model: NativeModel;
  inPool?: boolean;
  onRemove: () => void;
  onClose: () => void;
}) {
  return (
    <Modal title={`Remove ${model.display_name}?`} onClose={onClose}>
      <p>
        {inPool
          ? `This deletes ${model.display_name} from this Mac and takes it out of the Autopilot pool.${model.loaded ? ' Autopilot unloads it first.' : ''} You can download it again later.`
          : 'This deletes the downloaded model from this Mac. You can download it again later.'}
      </p>
      <div className="dialog-actions">
        <Button onClick={onClose}>Keep model</Button>
        <Button
          variant="danger"
          onClick={() => {
            onRemove();
            onClose();
          }}
        >
          Remove model
        </Button>
      </div>
    </Modal>
  );
}
