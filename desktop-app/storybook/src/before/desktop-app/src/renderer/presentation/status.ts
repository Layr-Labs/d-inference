// Product labels never echo protocol states or event messages verbatim.
export function machineStatus(status: string): string {
  switch (status) {
    case 'running':
    case 'online':
    case 'serving':
      return 'Online';
    case 'stopped':
      return 'Stopped';
    case 'offline':
      return 'Offline';
    case 'starting':
      return 'Starting';
    case 'draining':
      return 'Finishing requests';
    case 'idle':
      return 'Ready';
    case 'untrusted':
      return 'Verification needed';
    default:
      return 'Status unavailable';
  }
}

export function modelActivity(state: string, running: number): string {
  switch (state) {
    case 'running':
    case 'idle':
      return running > 0 ? `${running} processing` : 'Ready';
    case 'crashed':
      return 'Needs restart';
    case 'reloading':
      return 'Loading';
    case 'idle_shutdown':
      return 'Unloaded';
    default:
      return 'Status unavailable';
  }
}
