import { contextBridge, ipcRenderer } from 'electron';
import type { DesktopAPI } from '../shared/contracts';
const subscribe = (channel: string, callback: (value: any) => void) => {
  const listener = (_: Electron.IpcRendererEvent, value: unknown) => callback(value);
  ipcRenderer.on(channel, listener);
  return () => ipcRenderer.removeListener(channel, listener);
};
const api: DesktopAPI = {
  read: (resource) => ipcRenderer.invoke('backend:read', resource),
  act: (action) => ipcRenderer.invoke('backend:act', action),
  status: () => ipcRenderer.invoke('backend:status'),
  install: () => ipcRenderer.invoke('backend:install'),
  openExternal: (target) => ipcRenderer.invoke('app:external', target),
  copy: (text) => ipcRenderer.invoke('app:copy', text),
  checkUpdate: () => ipcRenderer.invoke('app:update'),
  applyUpdate: () => ipcRenderer.invoke('app:apply-update'),
  onState: (callback) => subscribe('backend:state', callback),
  onStatus: (callback) => subscribe('backend:status', callback),
  onNavigate: (callback) => subscribe('app:navigate', callback),
};
contextBridge.exposeInMainWorld('darkbloom', api);
