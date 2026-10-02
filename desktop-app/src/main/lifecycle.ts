import { app } from 'electron';

// Closing the window only hides it; a real quit is marked here first so the
// window's close handler lets it through.
let quitting = false;
export const isQuitting = () => quitting;
export function prepareQuit() {
  quitting = true;
}
export function quit() {
  prepareQuit();
  app.quit();
}
