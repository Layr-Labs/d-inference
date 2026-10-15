import './install.before';
export * from '../../src/before/desktop-app/src/renderer/useBackend';
import { bridges } from './bridge';
export const api = bridges.before.api;
export const isPreview = false;
