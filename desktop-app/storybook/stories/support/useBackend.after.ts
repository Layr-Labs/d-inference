import './install.after';
export * from '../../src/after/desktop-app/src/renderer/useBackend';
import { bridges } from './bridge';
export const api = bridges.after.api;
export const isPreview = false;
