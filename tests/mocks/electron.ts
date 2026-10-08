/**
 * Minimal Electron stub for unit tests. Main-process modules import
 * electron at module load; tests only need these calls not to throw.
 */
const noop = () => {};

export const app = {
  getVersion: () => '0.0.0-test',
  getPath: () => '/tmp',
  isPackaged: false,
  setLoginItemSettings: noop,
  on: noop,
};

export const ipcMain = { on: noop, handle: noop, removeAllListeners: noop };
export const ipcRenderer = {
  on: noop,
  send: noop,
  invoke: async () => undefined,
};
export const shell = {
  showItemInFolder: noop,
  openExternal: async () => undefined,
};
export const dialog = {
  showOpenDialog: async () => ({ canceled: true, filePaths: [] }),
};
export const powerMonitor = { on: noop };
export const screen = {
  getPrimaryDisplay: () => ({}),
  getAllDisplays: () => [],
};
export const systemPreferences = {
  getMediaAccessStatus: () => 'granted',
  askForMediaAccess: async () => true,
};
export const contextBridge = { exposeInMainWorld: noop };
export const protocol = { registerSchemesAsPrivileged: noop, handle: noop };
export const net = { fetch: async () => undefined };
export class BrowserWindow {}
export class Tray {}
export const Menu = { buildFromTemplate: () => ({}), setApplicationMenu: noop };

export default { app, ipcMain, shell, dialog, powerMonitor, screen };
