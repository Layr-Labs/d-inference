import { expect, it } from 'vitest';
import { machineStatus, modelActivity } from '../src/renderer/presentation/status';
import { operationLabel } from '../src/renderer/components/operations/labels';
import { coolingStatus } from '../src/renderer/features/cooling/status';

it('distinguishes online Macs and idle models from requests being processed', () => {
  expect(machineStatus('running')).toBe('Online');
  expect(machineStatus('untrusted')).toBe('Verification needed');
  expect(machineStatus('unknown_from_new_runtime')).toBe('Status unavailable');
  expect(modelActivity('idle', 0)).toBe('Ready');
  expect(modelActivity('running', 0)).toBe('Ready');
  expect(modelActivity('running', 3)).toBe('3 processing');
  expect(modelActivity('crashed', 3)).toBe('Needs restart');
  expect(modelActivity('idle_shutdown', 0)).toBe('Unloaded');
});

it('presents operations as user actions and keeps completion distinct from failure', () => {
  expect(operationLabel({ action: 'autopilot_pin', state: 'running' })).toBe(
    'Keeping models in memory',
  );
  expect(operationLabel({ action: 'autopilot_models', state: 'succeeded' })).toBe(
    'Model refresh · Complete',
  );
  expect(operationLabel({ action: 'account-signin', state: 'failed' })).toBe('Sign-in · Failed');
  expect(operationLabel({ action: 'cooling', state: 'cancelled' })).toBe(
    'Fan settings · Cancelled',
  );
});

it('shows enabled fan policy independently from its current firmware control mode', () => {
  const cooling = { supported: true, mode: 'automatic' as const, enabled: true, fans: [] };
  expect(coolingStatus(cooling)).toBe('Auto fan on');
  expect(coolingStatus({ ...cooling, enabled: false })).toBe('Auto fan off');
  expect(coolingStatus({ ...cooling, observed_at: 1 })).toBe('Fan status unavailable');
  expect(coolingStatus({ ...cooling, error: 'SMC diagnostic' })).toBe('Fan status unavailable');
});
