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
  cancelInstall: () => ipcRenderer.invoke('backend:cancelInstall'),
  openExternal: (target) => ipcRenderer.invoke('app:external', target),
  copy: (text) => ipcRenderer.invoke('app:copy', text),
  system: () => ipcRenderer.invoke('app:system'),
  openSoftwareUpdate: () => ipcRenderer.invoke('app:software-update'),
  updateStatus: () => ipcRenderer.invoke('app:update-status'),
  checkUpdate: () => ipcRenderer.invoke('app:update'),
  applyUpdate: () => ipcRenderer.invoke('app:apply-update'),
  onState: (callback) => subscribe('backend:state', callback),
  onStatus: (callback) => subscribe('backend:status', callback),
  onNavigate: (callback) => subscribe('app:navigate', callback),
  onHardware: (callback) => {
    const unsubscribe = subscribe('hardware:sample', callback);
    void ipcRenderer.invoke('hardware:watch');
    return () => {
      unsubscribe();
      void ipcRenderer.invoke('hardware:unwatch');
    };
  },
  chatModels: () => ipcRenderer.invoke('chat:models'),
  chatSend: (request) => ipcRenderer.invoke('chat:send', request),
  chatCancel: (stream) => ipcRenderer.invoke('chat:cancel', stream),
  onChat: (callback) => subscribe('chat:event', callback),
  clusterSession: () => ipcRenderer.invoke('cluster:session'),
  startClusterSession: (start) => ipcRenderer.invoke('cluster:session-start', start),
  answerClusterSession: (answer) => ipcRenderer.invoke('cluster:session-answer', answer),
  onClusterSession: (callback) => {
    const unsubscribe = subscribe('cluster:session', callback);
    void ipcRenderer.invoke('cluster:session-watch');
    return () => {
      unsubscribe();
      void ipcRenderer.invoke('cluster:session-unwatch');
    };
  },
  openApproval: (url) => ipcRenderer.invoke('app:approval', url),
};
contextBridge.exposeInMainWorld('darkbloom', api);
