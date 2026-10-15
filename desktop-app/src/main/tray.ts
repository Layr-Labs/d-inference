import { Menu, nativeImage, Tray } from 'electron';
import path from 'node:path';
import type { Route } from '../shared/contracts';
import type { Backend } from './backend';
import { quit } from './lifecycle';
import { startableModels, trayMenuTemplate, trayMenuUpdater } from './trayMenu';

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
      Menu.buildFromTemplate(
        trayMenuTemplate(model, {
          show,
          start: () => {
            const models = startableModels(backend.snapshot);
            if (models.length)
              void backend.act({ action: 'start', models }).catch(() => show('models'));
            else show('models');
          },
          stop: () => {
            void backend.act({ action: 'stop' }).catch(() => show());
          },
          restart: () => {
            void backend.act({ action: 'restart' }).catch(() => show());
          },
          quit,
        }),
      ),
    );
  });
  update(backend.snapshot);
  return update;
}
