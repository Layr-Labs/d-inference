import { Button, Modal } from '../UI';

/** Unlinking stops attributing this Mac's earnings, so it is confirmed like other removals. */
export function UnlinkDialog({ onUnlink, onClose }: { onUnlink: () => void; onClose: () => void }) {
  return (
    <Modal title="Unlink this Mac?" onClose={onClose}>
      <p>
        Earnings from this Mac stop being attributed to your Darkbloom account until you link it
        again.
      </p>
      <div className="dialog-actions">
        <Button onClick={onClose}>Keep linked</Button>
        <Button
          variant="danger"
          onClick={() => {
            onUnlink();
            onClose();
          }}
        >
          Unlink this Mac
        </Button>
      </div>
    </Modal>
  );
}
