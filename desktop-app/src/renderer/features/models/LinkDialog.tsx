import { Modal } from '../../components/UI';
import { LinkPanel } from '../../components/onboarding/LinkPanel';
import type { BackendState } from '../../useBackend';

// Turning Autopilot on links an unlinked Mac first. This shows the code and opens the link page
// when the user asks, until the account is linked; Cancel stops the link.
export function LinkDialog({ backend }: { backend: BackendState }) {
  const state = backend.state!;
  if (!state.link) return null;
  const cancel = () => {
    const linking = state.operations.find(
      (operation) => operation.action === 'link' && operation.state === 'running',
    );
    if (linking?.cancellable) void backend.act({ action: 'cancel', operation: linking.id });
  };
  return (
    <Modal title="Link this Mac" onClose={cancel}>
      <LinkPanel link={state.link} cancel={cancel} />
    </Modal>
  );
}
