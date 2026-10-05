/**
 * Stub for electron-log, which needs the Electron runtime. Tests log
 * through the real console.
 */
const log = {
  transports: { file: {} as Record<string, unknown>, console: {} },
  functions: {},
  initialize: () => {},
  info: console.info,
  warn: console.warn,
  error: console.error,
  debug: console.debug,
};

export default log;
