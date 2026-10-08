/**
 * Stub for src/main/main.ts, which bootstraps the whole Electron app at
 * module load. Modules only import these helpers from it.
 */
export const send = jest.fn();
export const playSoundAlert = jest.fn();
export const getNativeWindowHandle = jest.fn(() => Buffer.alloc(8));
