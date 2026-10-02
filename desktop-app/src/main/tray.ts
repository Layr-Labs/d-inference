import { Menu, nativeImage, Tray } from 'electron';
import path from 'node:path';
import type { Route } from '../shared/contracts';
import type { Backend } from './backend';
import { quit } from './lifecycle';
import { startableModels, trayMenuUpdater } from './trayMenu';

// Creates the menu bar item. Returns the snapshot listener that rebuilds the
// native menu only when its visible model changes.
export function createTray(backend: Backend, show: (route?: Route) => void) {
  const icon = nativeImage.createFromPath(path.join(__dirname, 'trayTemplate.png'));
  icon.setTemplateImage(true);
  const tray = new Tray(icon);
  tray.on('double-click', () => show());
  const update = trayMenuUpdater((model) => {
    tray.setToolTip(`Darkbloom · ${model.status}`);
    tray.setContextMenu(
      Menu.buildFromTemplate([
        { label: `Darkbloom — ${model.status}`, enabled: false },
        { label: 'Open Darkbloom', click: () => show() },
        { label: 'Models', click: () => show('models') },
        { label: 'Studio', click: () => show('studio') },
        { type: 'separator' },
        {
          label: 'Start provider',
          enabled: model.canStart,
          click: () => {
            const models = startableModels(backend.snapshot);
            if (models.length)
              void backend.act({ action: 'start', models }).catch(() => show('models'));
            else show('models');
          },
        },
        {
          label: 'Stop provider',
          enabled: model.canStop,
          click: () => {
            void backend.act({ action: 'stop' }).catch(() => show());
          },
        },
        {
          label: 'Restart provider',
          enabled: model.canRestart,
          click: () => {
            void backend.act({ action: 'restart' }).catch(() => show());
          },
        },
        { type: 'separator' },
        { label: 'Quit Darkbloom', click: quit },
      ]),
    );
  });
  update(backend.snapshot);
  return update;
}
