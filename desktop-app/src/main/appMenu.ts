import { Menu } from 'electron';
import type { Route } from '../shared/contracts';
import { quit } from './lifecycle';

export function installApplicationMenu(show: (route?: Route) => void) {
  Menu.setApplicationMenu(
    Menu.buildFromTemplate([
      {
        label: 'Darkbloom',
        submenu: [
          { role: 'about' },
          { type: 'separator' },
          { label: 'Settings', accelerator: 'CmdOrCtrl+,', click: () => show('settings') },
          { role: 'hide' },
          { label: 'Quit', accelerator: 'CmdOrCtrl+Q', click: quit },
        ],
      },
      { role: 'editMenu' },
      { role: 'windowMenu' },
    ]),
  );
}
